#if canImport(UIKit)
import BrowserCore
import os
import PerfSignposts
import UIKit
import WebKit

/// Desktop or mobile across the fold (docs/decisions.md, "Desktop or mobile across the fold").
///
/// A navigation takes the mode its pane wants when it starts (`TabWebViewHandler`). When a pane
/// changes size afterwards, the shell says so (`panesWillChange()`, `panesDidChange()`), and
/// once the change has settled each page on screen whose wanted mode differs is switched by a
/// reload in place, under a picture of itself, scrolled back to where it was, when nothing would
/// be lost (`ContentModeRules`). Otherwise it keeps its mode until its next navigation. A tab
/// coming on screen is checked the same way after it is attached.
///
/// Cost: nothing on launch, on scroll or during the fold's animation. A settled pane change
/// compares two values per attached tab; only a page that needs the other mode runs one page
/// script, then reloads.
final class ContentModeCoordinator {
    var debounce = ContentModeDebounce()
    var panesChanging = false
    var pending: Task<Void, Never>?
    /// When the pending check runs. A later, shorter request (a tab attached right after a fold)
    /// never brings it forward, so a pane change always gets its full settle time.
    var pendingDeadline: ContinuousClock.Instant?
    /// Counts pane changes (a fold, a drag), not their passes: a place read belongs to one.
    var changeID = 0
    /// A pane change is under way: from its first notice (`panesMayChange()`, `panesWillChange()`)
    /// until the check that follows it runs. Every notice in between belongs to the same change,
    /// so the place read at the first one (before any reflow) is the one a switch puts back.
    var changeOpen = false
}

/// A tab's mode bookkeeping, kept on its slot.
struct SlotContentMode {
    /// The mode the navigation in flight was given; it becomes the tab's when it commits.
    var pending: ContentMode?
    /// The navigation in flight goes back or forward: its page may come from the back-forward
    /// cache, in the mode it had then.
    var pendingIsBackForward = false
    /// The page kept its mode because it was loading: check it again when the load ends.
    var checkWhenLoaded = false
    /// A back or forward ended: the page may be from the back-forward cache, in the mode it was
    /// loaded in, so the next check asks the page which mode it shows.
    var needsVerify = false
    /// Where the reader was when the pane began to change size (`ContentModeScripts.place`): a
    /// switch after it puts that place back, not the one the fold's reflow left.
    var placeBeforeChange: ContentModeProbe?
    /// A place is being read or was read for the change under way: one read per change.
    var readsPlace = false
    /// Which read a reply belongs to: bumped by every read and every reset, so a late reply from
    /// an earlier change (or an earlier page) is dropped.
    var placeToken = 0
    /// The pane change the place was read for (`ContentModeCoordinator.changeID`): a place from
    /// an earlier change is never used, even if the page left the screen in between (a fold can
    /// detach and attach it again, so leaving the screen does not forget it).
    var placeChange = -1
    /// Someone typed in this document or one of its frames (each reports its first `input`
    /// event): what the probe can't read, such as cross-origin frames.
    var subframeTyped = false
    /// The switch in progress: its picture over the page and where to scroll back to.
    var running: ContentModeSwitch?
    /// Why the last check kept the page's mode (for tests and the log).
    var lastKept: ContentModeRules.KeepReason?
}

/// What `ContentModeScripts.probe` answered, in Swift values.
struct ContentModeProbe: Sendable {
    var hasTypedInput: Bool
    var isEditing: Bool
    /// The document's own mode (`navigator.platform`); nil if the page didn't say.
    var isDesktop: Bool?
    var isScrolled: Bool
    var fraction: Double
    var anchorID: String?
    var anchorPath: [Int]?
    var anchorInto: Double
    var anchorText: String

    init(_ answer: [String: Any]) {
        // Anything missing counts as "something would be lost".
        hasTypedInput = answer["typed"] as? Bool ?? true
        isEditing = answer["editing"] as? Bool ?? true
        isDesktop = answer["desktop"] as? Bool
        isScrolled = answer["scrolled"] as? Bool ?? true
        fraction = answer["fraction"] as? Double ?? 0
        let anchor = answer["anchor"] as? [String: Any]
        anchorID = anchor?["id"] as? String
        anchorPath = (anchor?["path"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue }
        anchorInto = anchor?["into"] as? Double ?? 0
        anchorText = anchor?["text"] as? String ?? ""
    }

    /// The anchor, for the log: how it is found, never its text or its id (both are the page's
    /// words, in private tabs too). A debug build names the id, for the fold tests' timeline.
    var anchorLabel: String {
        guard anchorPath != nil else { return isScrolled ? "none (fraction)" : "none (top)" }
        guard let anchorID else { return "by path" }
        #if DEBUG
        return "#\(anchorID)"
        #else
        return "by id"
        #endif
    }

    /// The arguments of `ContentModeScripts.restore`.
    func restoreArguments(top: Double) -> [String: Any] {
        var anchor: Any = NSNull()
        if let anchorPath {
            anchor = ["id": anchorID ?? NSNull(), "path": anchorPath, "into": anchorInto, "text": anchorText] as [String: Any]
        }
        return ["topInset": top, "fraction": fraction, "anchor": anchor]
    }
}

/// One reload in the other mode.
final class ContentModeSwitch: NSObject {
    let target: ContentMode
    let restore: [String: Any]
    var cover: UIView?
    var deadline: Task<Void, Never>?
    let interval: OSSignpostIntervalState
    /// The reload's navigation: only its finish or failure ends the switch.
    var navigation: WKNavigation?
    /// The check generation it started in: a pane change since means another check is due.
    let generation: Int
    /// The picture had to go before the reload finished (the limit): the place is restored later
    /// only if the user hasn't touched the page since.
    var isUncovered = false
    private(set) var userScrolled = false
    private weak var watchedPan: UIPanGestureRecognizer?

    /// Watches the page's pan from the moment it is uncovered: a finger on it means the user moved
    /// on, and the late restore must not yank the page.
    func watchUserScrolling(_ scrollView: UIScrollView) {
        isUncovered = true
        scrollView.panGestureRecognizer.addTarget(self, action: #selector(userPanned))
        watchedPan = scrollView.panGestureRecognizer
    }

    func stopWatching() {
        watchedPan?.removeTarget(self, action: #selector(userPanned))
        watchedPan = nil
    }

    @objc private func userPanned() {
        userScrolled = true
    }

    init(target: ContentMode, restore: [String: Any], cover: UIView?, interval: OSSignpostIntervalState, generation: Int) {
        self.target = target
        self.restore = restore
        self.cover = cover
        self.interval = interval
        self.generation = generation
        super.init()
    }
}

extension WebViewPool {
    nonisolated static let contentModeLogger = Logger(subsystem: "dev.abrahamgonzalez.plainbrowser", category: "contentMode")

    // MARK: Events from the shell

    /// The first sign that a pane's size is changing, before its web view has the new size: the
    /// safe area or the layout changed (`BrowserViewController.notePaneSizes`). A fold starts
    /// this way: the system changes the safe area (and so the page's width) a few frames before
    /// it announces the window's resize, and a place read after that is the reflowed page's.
    /// Reads each reader's place and checks the pages once things settle; a resize that follows
    /// (`panesWillChange()`) holds that check and keeps the place.
    public func panesMayChange() {
        guard FixedChoices.contentModeFollowsFold else { return }
        readPlaces(notice: "may")
        if !modeChecks.panesChanging { scheduleContentModeCheck(after: FixedChoices.contentModeSettleDelay) }
    }

    /// A pane is about to change size (a fold, an unfold, a rotation): checks wait for it.
    public func panesWillChange() {
        if FixedChoices.contentModeFollowsFold { readPlaces(notice: "will") }
        modeChecks.panesChanging = true
        _ = modeChecks.debounce.paneDidChange()
        modeChecks.pending?.cancel()
        modeChecks.pending = nil
        modeChecks.pendingDeadline = nil
    }

    /// The panes have their new sizes (a transition ended, a split or the side pane opened or
    /// closed). The pages on screen are checked `FixedChoices.contentModeSettleDelay` later, unless
    /// another change comes first.
    public func panesDidChange() {
        WebViewPool.contentModeLogger.notice("panes did change (change \(self.modeChecks.changeID))")
        modeChecks.panesChanging = false
        scheduleContentModeCheck(after: FixedChoices.contentModeSettleDelay)
    }

    func scheduleContentModeCheck(after delay: Duration) {
        guard FixedChoices.contentModeFollowsFold, !modeChecks.panesChanging else { return }
        let now = ContinuousClock.now
        var deadline = now + delay
        if let pending = modeChecks.pendingDeadline, pending > deadline { deadline = pending }
        let generation = modeChecks.debounce.paneDidChange()
        modeChecks.pending?.cancel()
        modeChecks.pendingDeadline = deadline
        modeChecks.pending = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled, let self, modeChecks.debounce.isCurrent(generation) else { return }
            modeChecks.pendingDeadline = nil
            // Settled: the next notice starts another change, with its own places.
            modeChecks.changeOpen = false
            for slot in attachedSlots() {
                await checkContentMode(of: slot, generation: generation)
            }
        }
    }

    /// Where each reader is, before the change reflows the pages: once per change (a fold's
    /// several notices and passes, a drag, read the place it started from). One message per page
    /// on screen, sent before the web view gets its new size, so the page answers from the
    /// layout the reader saw.
    private func readPlaces(notice: String) {
        if !modeChecks.changeOpen {
            modeChecks.changeOpen = true
            modeChecks.changeID += 1
            Signposts.signposter.emitEvent(Signposts.contentModePaneChange, "\(notice)")
            WebViewPool.contentModeLogger.notice("pane change \(self.modeChecks.changeID) begins (\(notice, privacy: .public))")
        }
        let change = modeChecks.changeID
        for slot in attachedSlots() where !slot.contentMode.readsPlace || slot.contentMode.placeChange != change {
            readPlace(of: slot)
        }
    }

    private func readPlace(of slot: Slot) {
        let webView = slot.webView
        guard let url = webView.url, url.scheme == "http" || url.scheme == "https", !webView.isLoading else { return }
        slot.contentMode.readsPlace = true
        slot.contentMode.placeChange = modeChecks.changeID
        slot.contentMode.placeToken += 1
        let token = slot.contentMode.placeToken
        let zoom = max(webView.scrollView.zoomScale, 0.01)
        let top = Double(webView.obscuredContentInsets.top / zoom)
        let change = modeChecks.changeID
        let bounds = webView.bounds.size
        let offset = webView.scrollView.contentOffset.y
        Signposts.signposter.emitEvent(Signposts.contentModePlace, "request")
        WebViewPool.contentModeLogger.notice(
            "place request (change \(change)): view \(Int(bounds.width))x\(Int(bounds.height)) offset \(Int(offset)) top \(Int(top))"
        )
        webView.callAsyncJavaScript(
            ContentModeScripts.place, arguments: ["topInset": top], in: nil, in: UserScripts.world
        ) { [weak slot] result in
            guard let slot, slot.contentMode.placeToken == token, slot.webView.url == url,
                  let answer = (try? result.get()) as? [String: Any] else {
                WebViewPool.contentModeLogger.notice("place reply (change \(change)) dropped")
                return
            }
            let place = ContentModeProbe(answer)
            Signposts.signposter.emitEvent(Signposts.contentModePlace, "reply")
            let width = answer["width"] as? Int ?? -1, scrollY = answer["y"] as? Int ?? -1
            WebViewPool.contentModeLogger.notice(
                "place reply (change \(change)): page width \(width) scrollY \(scrollY) anchor \(place.anchorLabel, privacy: .public)"
            )
            slot.contentMode.placeBeforeChange = place
        }
    }

    /// The change is over for this page (checked, switched or kept), or its web view goes away:
    /// the next change reads afresh.
    func forgetPlace(of slot: Slot) {
        slot.contentMode.readsPlace = false
        slot.contentMode.placeToken += 1
        slot.contentMode.placeBeforeChange = nil
    }

    // MARK: The check

    private func pageState(of slot: Slot, tab: Tab) -> ContentModeRules.PageState {
        let webView = slot.webView
        let scheme = webView.url?.scheme?.lowercased()
        return ContentModeRules.PageState(
            isWebPage: scheme == "http" || scheme == "https",
            isPDF: tab.isPDF,
            isFormResult: tab.isFormResult || tab.isAwaitingResubmit,
            isLoading: webView.isLoading,
            isPlayingMedia: tab.isPlayingMedia || slot.media != .idle,
            isInPictureInPicture: tab.isInPictureInPicture,
            isFullscreen: webView.fullscreenState != .notInFullscreen,
            isCapturing: webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none,
            isDownloading: downloads.hasActiveDownload(fromTab: tab.id),
            isFindActive: webView.findInteraction?.isFindNavigatorVisible ?? false,
            isTranslated: tab.translation != .original
        )
    }

    private func checkContentMode(of slot: Slot, generation: Int) async {
        // A pane change that came while an earlier page was being checked has read new places:
        // this check is not theirs to use up.
        guard modeChecks.debounce.isCurrent(generation) else { return }
        guard let tab = slot.tab, slot.container != nil, slot.contentMode.running == nil, !slot.isRestoring,
              let url = slot.webView.url
        else { return }
        if slot.contentMode.needsVerify {
            slot.contentMode.needsVerify = false
            await verifyContentMode(of: slot, tab: tab)
            guard modeChecks.debounce.isCurrent(generation), slot.tab === tab, slot.container != nil,
                  slot.contentMode.running == nil, slot.webView.url == url
            else { return }
        }
        let wanted = contentMode(for: url, in: tab)
        let state = pageState(of: slot, tab: tab)
        let first = ContentModeRules.decide(current: tab.contentMode, wanted: wanted, state: state)
        switch first {
        case .none, .reload:
            forgetPlace(of: slot)
            return
        case .keep(let reason):
            forgetPlace(of: slot)
            kept(reason, slot: slot)
            return
        case .askPage:
            break
        }

        let webView = slot.webView
        let zoom = max(webView.scrollView.zoomScale, 0.01)
        let top = Double(webView.obscuredContentInsets.top / zoom)
        let answer = await withWebKitTimeout(
            fallback: nil as ContentModeProbe?, timeout: FixedChoices.contentModeProbeTimeout
        ) { done in
            webView.callAsyncJavaScript(
                ContentModeScripts.probe, arguments: ["topInset": top], in: nil, in: UserScripts.world
            ) { result in
                if case .failure(let error) = result {
                    WebViewPool.contentModeLogger.error("probe failed: \(error.localizedDescription, privacy: .public)")
                }
                done(((try? result.get()) as? [String: Any]).map(ContentModeProbe.init))
            }
        }
        // The world may have moved on while the page answered.
        guard modeChecks.debounce.isCurrent(generation), slot.tab === tab, slot.container != nil,
              slot.contentMode.running == nil, webView.url == url
        else { return }
        var current = tab.contentMode
        if let desktop = answer?.isDesktop {
            // A page from the back-forward cache keeps the mode it was loaded in.
            current = desktop ? .desktop : .mobile
            if current != tab.contentMode { tab.set(\.contentMode, current) }
        }
        let report = answer.map {
            ContentModeRules.PageReport(
                hasTypedInput: $0.hasTypedInput || slot.contentMode.subframeTyped, isEditing: $0.isEditing
            )
        }
        let decision = ContentModeRules.decide(
            current: current, wanted: wanted, state: pageState(of: slot, tab: tab), report: report
        )
        switch decision {
        case .none, .askPage:
            forgetPlace(of: slot)
        case .keep(let reason):
            forgetPlace(of: slot)
            kept(reason, slot: slot)
        case .reload(let target):
            // The place the reader saw before the change, else the one now. A page at its top
            // needs no restore: the reload starts there.
            let saved = slot.contentMode.placeChange == modeChecks.changeID ? slot.contentMode.placeBeforeChange : nil
            let place = saved ?? answer
            let source = saved != nil ? "read before the change" : "read now"
            let anchor = place?.anchorLabel ?? "none", current = answer?.anchorLabel ?? "none"
            WebViewPool.contentModeLogger.notice("""
                switch to \(target.rawValue, privacy: .public) (change \(self.modeChecks.changeID)): \
                view \(Int(webView.bounds.width)) top \(Int(top)) place \(source, privacy: .public) \
                anchor \(anchor, privacy: .public) now at \(current, privacy: .public)
                """)
            forgetPlace(of: slot)
            let restore = place.flatMap { $0.isScrolled ? $0.restoreArguments(top: top) : nil } ?? [:]
            beginSwitch(slot, to: target, restore: restore, generation: generation)
        }
    }

    /// Reads the document's own mode (`navigator.platform` is `MacIntel` only in desktop mode,
    /// per document) and corrects `Tab.contentMode`. One IPC, after a back or forward only.
    private func verifyContentMode(of slot: Slot, tab: Tab) async {
        let webView = slot.webView
        let platform = await withWebKitTimeout(fallback: nil as String?, timeout: FixedChoices.contentModeProbeTimeout) { done in
            webView.callAsyncJavaScript("return navigator.platform", in: nil, in: UserScripts.world) { result in
                done((try? result.get()) as? String)
            }
        }
        guard let platform, slot.tab === tab else { return }
        let shown: ContentMode = platform == "MacIntel" ? .desktop : .mobile
        if shown != tab.contentMode { tab.set(\.contentMode, shown) }
    }

    private func kept(_ reason: ContentModeRules.KeepReason, slot: Slot) {
        Signposts.signposter.emitEvent(Signposts.contentModeKept, "\(reason.rawValue)")
        slot.contentMode.lastKept = reason
        if reason == .loading { slot.contentMode.checkWhenLoaded = true }
    }

    // MARK: The switch

    private func beginSwitch(_ slot: Slot, to target: ContentMode, restore: [String: Any], generation: Int) {
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(
            Signposts.contentModeSwitch, id: signposter.makeSignpostID(), "\(target.rawValue)"
        )
        let webView = slot.webView
        var cover: UIView?
        if let container = slot.container, webView.window != nil,
           let picture = webView.snapshotView(afterScreenUpdates: false) {
            picture.frame = webView.frame
            picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.insertSubview(picture, aboveSubview: webView)
            cover = picture
        }
        let change = ContentModeSwitch(
            target: target, restore: restore, cover: cover, interval: interval, generation: generation
        )
        slot.contentMode.running = change
        change.deadline = Task { [weak self, weak slot] in
            try? await Task.sleep(for: FixedChoices.contentModeCoverLimit)
            guard !Task.isCancelled, let self, let slot, slot.contentMode.running === change else { return }
            // A slow network: the picture goes, the switch waits for its page to finish.
            change.watchUserScrolling(slot.webView.scrollView)
            removeCover(of: change, animated: slot.container != nil)
        }
        // The navigation delegate gives the reload the mode the pane wants now.
        change.navigation = webView.reload()
        WebViewPool.contentModeLogger.notice("reload start: \(target.rawValue, privacy: .public) covered \(cover != nil)")
        if change.navigation == nil {
            Task { [weak self, weak slot] in
                guard let self, let slot else { return }
                await finishSwitch(slot, restoring: false, outcome: "noReload")
            }
        }
    }

    /// The reloaded page finished (or the limit passed): reset the zoom WebKit restored from the
    /// old layout, scroll back to the anchor, then fade the picture.
    func finishSwitch(_ slot: Slot, restoring: Bool, outcome: String) async {
        guard let change = slot.contentMode.running else { return }
        change.deadline?.cancel()
        let webView = slot.webView
        // Past the limit the page is already uncovered: put it back only if nobody has scrolled.
        if restoring, !change.userScrolled, slot.container != nil {
            let scrollView = webView.scrollView
            if scrollView.zoomScale != scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
            }
            if !change.restore.isEmpty {
                _ = await withWebKitTimeout(fallback: ()) { done in
                    webView.callAsyncJavaScript(
                        ContentModeScripts.restore, arguments: change.restore, in: nil, in: UserScripts.world
                    ) { result in
                        let scrollY = ((try? result.get()) as? NSNumber)?.intValue ?? -1
                        Signposts.signposter.emitEvent(Signposts.contentModeRestore, "\(scrollY)")
                        WebViewPool.contentModeLogger.notice(
                            "restore: scrollY \(scrollY) view \(Int(webView.bounds.width)) offset \(Int(webView.scrollView.contentOffset.y))"
                        )
                        done(())
                    }
                }
            }
        }
        guard slot.contentMode.running === change else { return }
        slot.contentMode.running = nil
        change.stopWatching()
        removeCover(of: change, animated: slot.container != nil)
        Signposts.signposter.endInterval(Signposts.contentModeSwitch, change.interval, "\(outcome)")
        // A fold or another pane change came while it ran: the page may want the other mode again.
        if !modeChecks.debounce.isCurrent(change.generation) || modeChecks.panesChanging {
            scheduleContentModeCheck(after: FixedChoices.contentModeSettleDelay)
        }
    }

    /// Ends a switch at once: the tab left the screen, moved to another pane or its web view is
    /// going away.
    func cancelSwitch(_ slot: Slot) {
        guard let change = slot.contentMode.running else { return }
        change.deadline?.cancel()
        slot.contentMode.running = nil
        change.stopWatching()
        removeCover(of: change, animated: false)
        Signposts.signposter.endInterval(Signposts.contentModeSwitch, change.interval, "cancelled")
    }

    private func removeCover(of change: ContentModeSwitch, animated: Bool) {
        guard let cover = change.cover else { return }
        change.cover = nil
        guard animated, cover.window != nil else {
            cover.removeFromSuperview()
            return
        }
        UIView.animate(withDuration: FixedChoices.contentModeCrossfade, delay: 0, options: [.curveEaseOut]) {
            cover.alpha = 0
        } completion: { _ in
            cover.removeFromSuperview()
        }
    }

    // MARK: Events from the navigation delegate

    /// A main-frame navigation was allowed with `mode`.
    func contentModeWillNavigate(_ slot: Slot, mode: ContentMode, isBackForward: Bool) {
        slot.contentMode.pending = mode
        slot.contentMode.pendingIsBackForward = isBackForward
    }

    /// The page committed: it is in the mode its navigation was given.
    func contentModeDidCommit(_ slot: Slot) {
        // A new page (or the switch's own reload) has nothing to do with a place read before.
        if slot.contentMode.running == nil {
            forgetPlace(of: slot)
        } else {
            WebViewPool.contentModeLogger.notice("reload commit")
        }
        // A new document starts with nothing typed. Back or forward may show a cached one that
        // was typed in: it says so again (`pageshow`), and until then the flag errs on keeping.
        if !slot.contentMode.pendingIsBackForward { slot.contentMode.subframeTyped = false }
        guard let tab = slot.tab, let mode = slot.contentMode.pending else { return }
        slot.contentMode.pending = nil
        tab.set(\.contentMode, mode)
    }

    func contentModeDidFinish(_ slot: Slot, navigation: WKNavigation?) {
        let backForward = slot.contentMode.pendingIsBackForward
        slot.contentMode.pendingIsBackForward = false
        // Back or forward may have shown a cached page in its old mode: the next check, now or when
        // the tab is shown again, asks the page.
        if backForward { slot.contentMode.needsVerify = true }
        if let change = slot.contentMode.running {
            // Only the reload's own finish ends the switch; another navigation's is not its page.
            guard change.navigation === navigation else { return }
            WebViewPool.contentModeLogger.notice("reload finish: restore \(!change.restore.isEmpty)")
            Task { [weak self, weak slot] in
                guard let self, let slot else { return }
                await finishSwitch(slot, restoring: true, outcome: "painted")
            }
            return
        }
        // A page that kept its mode while loading can switch now.
        if slot.container != nil, backForward || slot.contentMode.checkWhenLoaded {
            slot.contentMode.checkWhenLoaded = false
            scheduleContentModeCheck(after: FixedChoices.contentModeAttachDelay)
        }
    }

    /// A load failed or was replaced by another navigation (a script, a new page): the switch ends
    /// without restoring a place that belonged to the page it reloaded.
    func contentModeDidFail(_ slot: Slot, navigation: WKNavigation?) {
        guard let change = slot.contentMode.running, change.navigation === navigation else { return }
        Task { [weak self, weak slot] in
            guard let self, let slot else { return }
            await finishSwitch(slot, restoring: false, outcome: "failed")
        }
    }
}
#endif
