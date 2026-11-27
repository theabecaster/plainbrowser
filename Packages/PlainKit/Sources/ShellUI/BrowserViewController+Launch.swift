#if canImport(UIKit)
import BrowserCore
import DesignSystem
import PerfSignposts
import UIKit
import WebEngine

/// What a cold launch opens to, decided by the app before the browser is built
/// (`LaunchRules.opening`): the screen, the hint the window left, and its picture decoding off the
/// main thread.
public struct LaunchPlan {
    public let opening: OpeningScreen
    public let hint: LaunchHint?
    public let picture: LaunchPicture?

    public init(opening: OpeningScreen, hint: LaunchHint? = nil, picture: LaunchPicture? = nil) {
        // No hint, no tab to show: search first.
        self.opening = hint == nil ? .search : opening
        self.hint = hint
        self.picture = picture
    }

    /// Search first, keyboard up, no tab behind it (first run, no tabs, a link from another app).
    public static let search = LaunchPlan(opening: .search)
}

/// The launch's state in the browser: the last tab standing in until its page is back, and the
/// frosted paper of a fresh search over a page.
final class LaunchUIState {
    var plan = LaunchPlan.search
    /// The last tab as it was, until the restored session gives the screen a real tab: the bar
    /// follows it so nothing in the chrome moves when the page arrives.
    var placeholder: LaunchHint?
    /// The last tab's picture over the page container, until the live page takes over.
    var cover: LaunchCoverView?
    /// When the picture went up: it stays at most `FixedChoices.launchPictureMaxHold` from here.
    var coverShownAt = ContinuousClock.now
    /// A fresh search is open over a page (state rules, "Launch and return"): the sheet goes clear,
    /// the frost dims the page behind it, and a submitted search opens a new tab.
    var isFreshSearch = false
    /// Between the page and the search sheet: the page shows through, dimmed and blurred.
    let frost = FrostView()
}

// MARK: - Launch and return (docs/state-rules.md, "Launch and return")

extension BrowserViewController {
    /// Whether this launch opens with the search field focused.
    var launchOpensSearch: Bool { launchUI.plan.opening != .lastTab }

    /// Before the first layout: the last tab's picture and bar, or the fresh search's frost.
    func prepareLaunch() {
        let plan = launchUI.plan
        view.insertSubview(launchUI.frost, aboveSubview: panes.view)
        launchUI.frost.frame = view.bounds
        launchUI.frost.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        launchUI.frost.alpha = 0
        guard let hint = plan.hint, plan.opening != .search else { return }
        launchUI.placeholder = hint
        pill.display(url: hint.url, notSecure: hint.notSecure)
        pill.textField.text = plan.opening == .lastTab ? hint.url.absoluteString : ""
        let cover = LaunchCoverView(frame: webContainer.bounds)
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webContainer.addSubview(cover)
        launchUI.cover = cover
        launchUI.coverShownAt = .now
        // The hold holds even if the saved session is slow to come back: past it, the frozen
        // picture goes whatever the restore is doing.
        Task { [weak self, weak cover] in
            try? await Task.sleep(for: FixedChoices.launchPictureMaxHold)
            guard let self, let cover, cover === self.launchUI.cover else { return }
            self.dropLaunchCover(animated: true, reason: "timedOut")
        }
        launchUI.isFreshSearch = plan.opening == .searchOverLastTab
        if launchUI.isFreshSearch { Signposts.signposter.emitEvent(Signposts.freshSearch, "launch") }
    }

    /// Just before the first frame: the picture, if it is decoded by now or within
    /// `FixedChoices.launchPictureWait`; otherwise it fades in the moment it is.
    func showLaunchPicture() {
        guard let cover = launchUI.cover, let picture = launchUI.plan.picture else { return }
        if let image = picture.take(waitingUpTo: FixedChoices.launchPictureWait) {
            cover.image = image
            return
        }
        Task { [weak self, weak cover] in
            let image = await picture.whenReady()
            guard let self, let cover, cover === self.launchUI.cover, let image else { return }
            cover.alpha = 0
            cover.image = image
            Motion.animate(Motion.quick) { cover.alpha = 1 }
        }
    }

    /// The restored session is in (`startSession`): the real tab takes over from the placeholder.
    /// The picture stays over the restored page until it has loaded; a hint that no longer matches
    /// (the tab is gone) gives way to search.
    func launchSessionRestored(_ restored: Tab?) {
        let hint = launchUI.placeholder
        launchUI.placeholder = nil
        if let hint {
            if let tab = currentTab, tab.id == hint.tabID {
                handOffLaunchCover(to: tab)
            } else {
                dropLaunchCover(animated: true, reason: "dropped")
            }
            if currentTab == nil {
                // The saved tab is gone (the store was reset): nothing to show behind the bar.
                pill.display(url: nil)
                launchUI.isFreshSearch = false
                updateButtons()
                updateStartScreen()
                if !isEditingAddress { beginAddressEditing() }
            }
        } else if restored != nil, currentTab === restored, isEditingAddress, launchOpensSearch,
                  (pill.textField.text ?? "").isEmpty {
            // Search came first with no picture (a new window, or the first launch of this
            // build): the restored tab shows through behind it, as a fresh search over it.
            launchUI.isFreshSearch = true
            updateStartScreen()
            Motion.animate(Motion.urlFocus) { self.launchUI.frost.alpha = 1 }
        }
        updateButtons()
    }

    /// Fades the picture once `tab`'s restored page has loaded (and had a moment to paint and
    /// scroll to where it was), or after `FixedChoices.launchPictureMaxHold`.
    private func handOffLaunchCover(to tab: Tab) {
        guard launchUI.cover != nil else { return }
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.launchPictureHandoff, id: signposter.makeSignpostID())
        // The hold counts from the picture going up, not from the restore: a slow database never
        // keeps a frozen picture longer.
        let deadline = launchUI.coverShownAt + FixedChoices.launchPictureMaxHold
        Task { [weak self, weak tab] in
            var sawLoading = false
            var reason = "timedOut"
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let tab, self.launchUI.cover != nil, self.currentTab === tab else {
                    reason = "dropped"
                    break
                }
                if tab.isLoading {
                    sawLoading = true
                    continue
                }
                if tab.loadError != nil || tab.isAwaitingResubmit {
                    reason = "failed"
                    break
                }
                if tab.tier == .live, sawLoading || tab.progress >= 1 {
                    // Painted and scrolled back to where it was: WebKit restores the scroll
                    // position just after the load ends.
                    try? await Task.sleep(for: .milliseconds(100))
                    reason = "loaded"
                    break
                }
            }
            self?.dropLaunchCover(animated: true, reason: reason)
            signposter.endInterval(Signposts.launchPictureHandoff, interval, "\(reason)")
        }
    }

    /// Takes the picture away: a crossfade to the live page, or at once when the page under it is
    /// changing anyway (another tab, a drag).
    func dropLaunchCover(animated: Bool, reason: String = "dropped") {
        guard let cover = launchUI.cover else { return }
        launchUI.cover = nil
        // The decoded picture (about 5 MB) goes with it.
        let plan = launchUI.plan
        launchUI.plan = LaunchPlan(opening: plan.opening, hint: plan.hint)
        guard animated, view.window != nil else { return cover.removeFromSuperview() }
        Motion.animate(Motion.quick, changes: { cover.alpha = 0 }) { cover.removeFromSuperview() }
    }

    /// Keeps the picture over a page the pool attached under it.
    func keepLaunchCoverOnTop() {
        guard let cover = launchUI.cover, cover.superview === webContainer else { return }
        webContainer.bringSubviewToFront(cover)
    }

    /// The bar's state while the placeholder stands in for the last tab (`chromeState`).
    func placeholderState(_ hint: LaunchHint, into state: inout ChromeState) {
        state.hasTab = true
        state.hasPage = true
        state.condition = .loaded
        state.canGoBack = hint.canGoBack
        state.canGoForward = hint.canGoForward
        state.others = hint.others
        state.listCount = hint.others + 1
        let scheme = hint.url.scheme?.lowercased()
        state.isWebPage = scheme == "http" || scheme == "https"
        state.isRecordable = LiveAddressBarData.isRecordable(hint.url)
    }

    // MARK: Leaving and coming back

    /// The app is leaving the foreground: remembers the page on screen and its picture for the
    /// next launch, or that there is none. Private pages, splits and the reader leave nothing.
    public func rememberForLaunch(in memory: LaunchMemory) {
        // Left again before the saved session was read: what it remembered still holds.
        if currentTab == nil, launchUI.placeholder != nil { return }
        guard let tab = currentTab, !tab.isPrivate, !session.tabs.isEmpty(tab.id), let url = tab.url,
              !isSplit, !isShowingReader else {
            memory.clear()
            return
        }
        let hint = LaunchHint(
            tabID: tab.id, windowID: session.windowID, url: url, leftAt: Date(), canGoBack: tab.canGoBack,
            canGoForward: tab.canGoForward, others: session.tabs.otherTabCount(besides: tab.id),
            notSecure: tab.security == .notSecure || tab.security == .certificateBypassed
        )
        // The picture is taken now, while the page is still in the window, and written off the
        // main thread; the system gives the write time to finish in the background (and ends it
        // exactly once, on time or when the time runs out).
        let generation = memory.beginSave()
        let work = BackgroundWork.begin("Plain.launchPicture")
        session.pool.snapshot(of: tab, width: webContainer.bounds.width, timeout: LaunchChoices.snapshotTimeout) {
            [weak self] image in
            // No picture (the page did not answer, and no card thumbnail): open to search rather
            // than to a bar over bare paper.
            guard let picture = image ?? self?.session.pool.thumbnails.cachedThumbnail(for: tab.id) else {
                memory.clear(ifCurrent: generation)
                work?.end()
                return
            }
            memory.save(hint, picture: picture, generation: generation)
            Task {
                await memory.waitForWrites()
                work?.end()
            }
        }
    }

    /// Back from the background after `leftAt`: after a long time away a fresh search opens over
    /// the page (`LaunchRules.onReturn`); otherwise everything is exactly as it was.
    public func appDidReturn(awayFrom leftAt: Date, now: Date) {
        let showsPage = currentTab.map { !session.tabs.isEmpty($0.id) } ?? false
        let occupied = isEditingAddress || isShowingGallery || presentedViewController != nil || view.window == nil
            || currentTab?.isBusy == true
        guard let opening = LaunchRules.onReturn(awayFrom: leftAt, now: now, showsPage: showsPage, isOccupied: occupied)
        else { return }
        if opening == .searchOverLastTab {
            Signposts.signposter.emitEvent(Signposts.freshSearch, "return")
            launchUI.isFreshSearch = true
            updateStartScreen()
        }
        pill.textField.text = ""
        applyEditingLayout(true, animated: true)
        if !pill.beginEditing() {
            launchUI.isFreshSearch = false
            applyEditingLayout(false, animated: false)
        }
    }

    /// The tab a submitted address loads in: a new one from a search over a page (the pill, or a
    /// fresh search after time away), so the page stays as it was; otherwise the tab on screen
    /// (or a new one). Editing the page's own address loads in its tab.
    func tabForSubmittedAddress() -> Tab {
        if launchUI.isFreshSearch, isEditingAddress, let tab = currentTab, !session.tabs.isEmpty(tab.id) {
            // Private stays private. The page is its opener: Back on the new tab's first page
            // closes it and returns there (state rules §8).
            let fresh = session.tabs.newTab(isPrivate: tab.isPrivate, opener: tab)
            show(fresh)
            return fresh
        }
        return currentTab ?? openNewTab()
    }
}

/// The last tab's page as it looked when the app left: fitted to the page's width and pinned to
/// its top, as the live page lays out. Takes no touches: they reach the page under it.
final class LaunchCoverView: UIView {
    private let imageView = UIImageView()

    var image: UIImage? {
        get { imageView.image }
        set {
            imageView.image = newValue
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        accessibilityIdentifier = "launchPicture"
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let size = imageView.image?.size, size.width > 0 else { return }
        imageView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.width * size.height / size.width)
    }
}

/// Frosted paper over the page behind a fresh search: the page reads as "still there" without
/// competing with the suggestions. Takes no touches: the search sheet above it handles them.
final class FrostView: UIView {
    /// Paper over the page, no blur: the system materials blur so much that a page loses its
    /// headings and layout (design review), and the tab must stay recognisable behind the search.
    /// The suggestion rows and the field carry their own paper, so they read over it.
    static let paperOpacity: CGFloat = 0.7

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = Palette.background.withAlphaComponent(Self.paperOpacity)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
#endif
