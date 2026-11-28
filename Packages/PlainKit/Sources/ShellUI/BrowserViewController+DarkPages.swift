#if canImport(UIKit)
import BrowserCore
import DesignSystem
import PerfSignposts
import UIKit
import WebEngine

// Dark Pages in the shell (docs/research/dark-pages-optin.md): the switch from Settings reaching
// the engine, the indicator's tap, the crossfade between a page's light and dark rendering, and
// the one suggestion by the address bar. The rules are BrowserCore's (`DarkPagesChoices`,
// `DarkPagesSuggestion`, `ControlRules.darkPagesIndicator`); the engine darkens.

/// The suggestion card, its pending moment, and the crossfades running.
final class DarkPagesUIState {
    var suggestion: DarkPagesSuggestionView?
    var placement: [NSLayoutConstraint] = []
    /// The suggestion's moment, waiting `FixedChoices.darkPagesSuggestionDelay` after its page
    /// said it could use Dark Pages.
    var pending: Task<Void, Never>?
    /// The snapshot over each pane's page while it crossfades, by container.
    var fades: [ObjectIdentifier: UIView] = [:]
    var fadeGeneration = 0
    let suggestions = DarkPagesSuggestionStore()
    /// This window's scene leaving the foreground hides the card.
    var sceneObserver: (any NSObjectProtocol)?
}

/// The app sessions the suggestion counts in: one per launch, one more per return from the
/// background (`DarkPagesSuggestionStore.session`).
@MainActor
enum DarkPagesSessions {
    private static var started = false
    private static var wasInBackground = false
    private static var observers: [any NSObjectProtocol] = []

    static func start(_ store: DarkPagesSuggestionStore) {
        guard !started else { return }
        started = true
        store.beginSession()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { wasInBackground = true }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    guard wasInBackground else { return }
                    wasInBackground = false
                    store.beginSession()
                }
            },
        ]
    }
}

extension BrowserViewController {
    // MARK: The switch

    /// The settings in effect changed (read at launch, or saved, here or in Settings): the engine
    /// takes the switch. Turning it on anywhere answers the suggestion.
    func applyDarkPagesSetting() {
        DarkPagesSessions.start(darkPagesUI.suggestions)
        guard let on = data.darkPages else { return }
        session.stores.darkPages.setEnabled(on)
        if on { darkPagesUI.suggestions.answer(true) }
    }

    // MARK: The indicator and Site Settings

    /// A tap on the indicator, or on Site Settings' "Dark Pages": off for the site where it
    /// applies, on where it doesn't, with a tick and a crossfade. Remembered for the site.
    func toggleDarkPages(for tab: Tab, source: StaticString) {
        Haptic.selection.play()
        hideDarkPagesSuggestion()
        // The user found the feature: no suggestion after this (a private tab teaches nothing).
        if !tab.isPrivate { darkPagesUI.suggestions.answer(true) }
        let source = String(describing: source)
        crossfadeDarkPages(for: tab) { [weak tab] in
            await tab?.toggleDarkPages(source: source) ?? false
        }
    }

    // MARK: The crossfade

    /// Covers each pane showing `tab`'s site with a snapshot of its page as it is now, runs
    /// `change` (which returns once the pages drew it), then fades the snapshots out. A navigation,
    /// a tab switch or a second change removes them at once; a page that never answers fades
    /// after `FixedChoices.darkPagesCrossfadeTimeout`; no snapshot, no crossfade.
    func crossfadeDarkPages(for tab: Tab, change: @escaping () async -> Bool) {
        let site = tab.siteKey
        removeDarkPagesFades()
        darkPagesUI.fadeGeneration += 1
        let generation = darkPagesUI.fadeGeneration
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.darkPagesCrossfade, id: signposter.makeSignpostID())
        for container in darkPagesContainers(showing: site) {
            guard let snapshot = container.snapshotView(afterScreenUpdates: false) else { continue }
            snapshot.frame = container.bounds
            snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            snapshot.isUserInteractionEnabled = false
            container.addSubview(snapshot)
            darkPagesUI.fades[ObjectIdentifier(container)] = snapshot
        }
        let page = tab.url
        // Whichever comes first: the pages answer, or the timeout.
        var finished = false
        let finish: () -> Void = { [weak self, weak tab] in
            guard !finished else { return }
            finished = true
            guard let self, generation == self.darkPagesUI.fadeGeneration else {
                signposter.endInterval(Signposts.darkPagesCrossfade, interval)
                return
            }
            // The page went somewhere else meanwhile: its old picture must not linger.
            let fades = Array(self.darkPagesUI.fades.values)
            guard tab?.url == page, !fades.isEmpty else {
                self.removeDarkPagesFades()
                signposter.endInterval(Signposts.darkPagesCrossfade, interval)
                return
            }
            // The snapshots stay registered while they fade, so a navigation, a tab switch, a
            // layout change or another tap still removes them at once.
            UIView.animate(
                withDuration: FixedChoices.darkPagesCrossfade, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]
            ) {
                fades.forEach { $0.alpha = 0 }
            } completion: { [weak self] _ in
                signposter.endInterval(Signposts.darkPagesCrossfade, interval)
                guard let self, generation == self.darkPagesUI.fadeGeneration else { return }
                self.removeDarkPagesFades()
            }
        }
        Task {
            // A page that never answered for this document fades with the timeout instead.
            if await change() { finish() }
        }
        Task {
            try? await Task.sleep(for: FixedChoices.darkPagesCrossfadeTimeout)
            finish()
        }
    }

    /// Removes any crossfade's snapshots at once (a navigation, a tab switch, a new change).
    func removeDarkPagesFades() {
        guard !darkPagesUI.fades.isEmpty else { return }
        darkPagesUI.fades.values.forEach { $0.removeFromSuperview() }
        darkPagesUI.fades = [:]
        darkPagesUI.fadeGeneration += 1
    }

    /// The containers of the panes on screen whose page is on `site` (both panes of a split can).
    private func darkPagesContainers(showing site: String?) -> [UIView] {
        guard let site else { return [] }
        let panes = session.tabs.panes
        return shownPanes.compactMap { index -> UIView? in
            guard index < panes.count, let id = panes[index], let shown = session.tabs.existingTab(id),
                  shown.siteKey == site, index < self.panes.slots.count else { return nil }
            return self.panes.slots[index].container
        }
    }

    // MARK: The suggestion

    /// The tab's Dark Pages state or document changed: a suggestion for an earlier page goes, and
    /// a page that could use it gets its moment.
    func darkPagesPageChanged(from old: TabSnapshot?, to new: TabSnapshot) {
        // A reload or any new load counts as another page from its start.
        let samePage = old != nil && old?.url == new.url && old?.darkPagesDocument == new.darkPagesDocument
            && !(new.isLoading && old?.isLoading == false)
        if !samePage || new.darkPages != .available {
            hideDarkPagesSuggestion()
            if !samePage { removeDarkPagesFades() }
        }
        guard new.darkPages == .available, !samePage || old?.darkPages != .available,
              let tab = currentTab, let document = new.darkPagesDocument else { return }
        scheduleDarkPagesSuggestion(for: tab, document: document)
    }

    private func scheduleDarkPagesSuggestion(for tab: Tab, document: String) {
        observeSceneDeactivation()
        let store = darkPagesUI.suggestions
        guard !tab.isPrivate, let site = tab.siteKey,
              store.state.mayShow(onSite: site, session: store.session) else { return }
        darkPagesUI.pending?.cancel()
        darkPagesUI.pending = Task { [weak self, weak tab] in
            try? await Task.sleep(for: FixedChoices.darkPagesSuggestionDelay)
            guard !Task.isCancelled, let self, let tab else { return }
            self.darkPagesUI.pending = nil
            self.showDarkPagesSuggestion(for: tab, document: document, site: site)
        }
    }

    /// The suggestion's moment came: it shows when everything still holds (the same page on
    /// screen, still `available`, nothing else up), else not for this page load.
    private func showDarkPagesSuggestion(for tab: Tab, document: String, site: String) {
        guard tab === currentTab, tab.darkPagesDocument == document, tab.siteKey == site else { return }
        let moment = DarkPagesSuggestion.Moment(
            page: tab.darkPages.page, isPrivate: tab.isPrivate, settingsLoaded: data.darkPages != nil,
            isBarShowing: !isChromeCollapsed && !isEditingAddress && !pill.isHidden && pill.alpha > 0.99,
            isBusy: presentedViewController != nil || isShowingGallery || isShowingReader || isFindOpen
                || tabsUI.toast.isShowing || tab.isLoading || isKeyboardShowing
                || view.window?.windowScene?.activationState != .foregroundActive
        )
        let store = darkPagesUI.suggestions
        guard store.state.shouldShow(onSite: site, session: store.session, at: moment) else { return }
        // Counted the moment it shows: unanswered is ignored, however it goes.
        store.state = store.state.shown(onSite: site, session: store.session)
        let card = darkPagesSuggestionView()
        placeDarkPagesSuggestion(card)
        card.onFinish = { [weak self, weak tab] outcome in
            guard let self else { return }
            switch outcome {
            case .turnOn:
                store.answer(true)
                Signposts.signposter.emitEvent(Signposts.darkPagesSwitch, "on")
                Haptic.selection.play()
                guard let tab else {
                    Task { await self.sheets.setDarkPages(true) }
                    return
                }
                self.crossfadeDarkPages(for: tab) { [weak self] in
                    guard let self else { return false }
                    await self.sheets.setDarkPages(true)
                    return await self.session.pool.darkPagesChoicesDidChange()
                }
            case .noThanks:
                store.answer(false)
            case .timedOut, .hidden:
                break
            }
        }
        card.show()
    }

    /// Takes the suggestion away unanswered (it stays ignored), and drops a pending one.
    func hideDarkPagesSuggestion() {
        darkPagesUI.pending?.cancel()
        darkPagesUI.pending = nil
        darkPagesUI.suggestion?.hide()
    }

    /// The keyboard is up (a page's form): the card never shows over it.
    private var isKeyboardShowing: Bool {
        let keyboard = view.keyboardLayoutGuide.layoutFrame
        return keyboard.height > view.safeAreaInsets.bottom + 1
    }

    private func darkPagesSuggestionView() -> DarkPagesSuggestionView {
        if let card = darkPagesUI.suggestion { return card }
        let card = DarkPagesSuggestionView()
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)
        darkPagesUI.suggestion = card
        // Another toast takes the place by the bar: the card gives way.
        tabsUI.toast.willShow = { [weak self] in self?.darkPagesUI.suggestion?.hide() }
        return card
    }

    /// This window leaving the foreground (another window may stay): a pending or shown card goes.
    private func observeSceneDeactivation() {
        guard darkPagesUI.sceneObserver == nil else { return }
        darkPagesUI.sceneObserver = NotificationCenter.default.addObserver(
            forName: UIScene.willDeactivateNotification, object: nil, queue: .main
        ) { [weak self] note in
            let leaving = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let scene = self.view.window?.windowScene, leaving == ObjectIdentifier(scene) else { return }
                self.hideDarkPagesSuggestion()
            }
        }
    }

    /// By the address bar, on the side away from the screen's edge: above the pill at the bottom,
    /// under it in the top bar (the Duo's inner screen, iPad). As wide as the pill, capped.
    private func placeDarkPagesSuggestion(_ card: DarkPagesSuggestionView) {
        NSLayoutConstraint.deactivate(darkPagesUI.placement)
        view.bringSubviewToFront(card)
        let onTop = duo.top.isPillOnTop
        let wide = card.widthAnchor.constraint(equalTo: pill.widthAnchor)
        wide.priority = .defaultHigh
        darkPagesUI.placement = [
            card.centerXAnchor.constraint(equalTo: pill.centerXAnchor),
            wide,
            card.widthAnchor.constraint(lessThanOrEqualTo: pill.widthAnchor),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            onTop
                ? card.topAnchor.constraint(equalTo: pill.bottomAnchor, constant: Spacing.s)
                : card.bottomAnchor.constraint(equalTo: pill.topAnchor, constant: -Spacing.s),
        ]
        card.slideOffset = onTop ? -12 : 12
        NSLayoutConstraint.activate(darkPagesUI.placement)
        view.layoutIfNeeded()
    }
}
#endif
