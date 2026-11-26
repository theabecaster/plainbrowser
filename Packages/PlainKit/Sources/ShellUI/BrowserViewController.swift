#if canImport(UIKit)
import BrowserCore
import DesignSystem
import os
import PerfSignposts
import UIKit
import WebEngine
import WebKit

/// The browser's root screen: the page, the URL pill at the bottom, the page's buttons, and the
/// search sheet the pill grows into.
///
/// Launch order (docs/plan.md, "Engine rules"):
/// 1. The first frame shows the search sheet with the field already first responder, keyboard up.
/// 2. After that frame, the pool warms one offscreen web view with `about:blank`
///    (`BrowserSession.start()`), and the last session's tab, if any, comes back under the sheet.
/// 3. The first submitted address goes to that tab, or to a new one that gets the warm web view.
///
/// The tab on screen and its page state live in `+Tab`, the engine's questions (dialogs, sign-in,
/// permissions) in `+EngineHost`, the tab gallery in `+Gallery`, the tabs button, bar swipe
/// hand-offs, archive and link menu in `+Tabs`, and zoom, PDF and downloads in `+PageFeatures`.
/// The bar swipe itself is `TabSwipe`.
///
/// Embed it in a `UINavigationController` with a hidden navigation bar: where the system has a
/// vertical bar (iPhone Duo), the page buttons are the navigation controller's toolbar items and
/// go into that bar.
public final class BrowserViewController: UIViewController, UITextFieldDelegate, UIScrollViewDelegate,
    UIAdaptivePresentationControllerDelegate {
    let session: BrowserSession
    let data: any AddressBarData
    let sheets: FeatureSheets
    private let onSearchFieldReady: () -> Void

    /// The page panes: one, or two in a split on the Duo's inner screen (`+Panes`).
    let panes = PanesController()
    /// The Duo layout: panes, sidebar, the chrome's lane, folds (`+Panes`, `+SideTabs`).
    let duo = DuoUIState()
    /// Where the focused pane's tab is attached. The chrome, the bar swipe, the gallery's zoom and
    /// the reader all act on the focused pane.
    var webContainer: UIView { panes.slots[session.tabs.focusedPane].container }
    /// The focused pane's area (beside a vertical bar, under the status bar): it clips the page and
    /// the bar swipe's neighbour, so neither shows under the system's bar while they slide.
    var pageClip: UIView { panes.slots[session.tabs.focusedPane].clip }
    /// The pill and the button bar, rendered as one glass surface (docs/plan.md, section 5,
    /// Chrome). It covers the view but takes no touches of its own.
    let chromeGlass = Glass.makeContainer(spacing: ChromeGeometry.glassMergeSpacing)
    /// The system scroll edge effect under the chrome, so page text under the bar stays readable.
    /// One per control, not on `chromeGlass`: the effect reaches as high as its container, and
    /// `chromeGlass` covers the whole screen. WebKit hides it by itself where it extends a fixed
    /// footer's color to the edge instead.
    let pageEdgeEffects = [UIScrollEdgeElementContainerInteraction(), UIScrollEdgeElementContainerInteraction()]
    let pill = AddressPill()
    let buttonBar = ButtonBar()
    let sheet = SearchSheet()
    private let pullIndicator = PullIndicator()
    var barItems: [PageButton: UIBarButtonItem] = [:]

    /// The tab on screen (BrowserCore's `TabStore` owns the list; `EngineTabs` keeps it in step).
    var currentTab: Tab?
    /// The tab's observation, the reader view, the page's error state and the prompt queue.
    let engineUI = EngineUIState()
    /// The gallery, the bar swipe, neighbour previews and the toast.
    let tabsUI = TabsUIState()
    /// The page menu's last Add to / Remove from Favorites answer, for rebuilding the open menu.
    var lastFavoriteAnswer: Bool?
    /// docs/state-rules.md for the state last applied (`updateButtons`), for hot paths such as
    /// pull to refresh that must not walk the tab list on every scroll callback.
    var rules = ControlRules(ChromeState())

    // Layout.
    private var pillOnBar: NSLayoutConstraint!
    private var pillOnEdge: NSLayoutConstraint!
    private var pillOnKeyboard: NSLayoutConstraint!
    /// The button bar's own constraints, activated again when it comes back after a vertical bar.
    private var buttonBarConstraints: [NSLayoutConstraint] = []
    private var geometry = ChromeGeometry(viewHeight: 0, safeBottom: 0, hasButtonBar: true)
    private(set) var usesVerticalBar = false

    // State.
    private(set) var isEditingAddress = true
    private var didFocusAtLaunch = false
    private var didWarmUp = false
    private var collapse = ChromeCollapse()
    private var collapseInterval: OSSignpostIntervalState?
    /// Runs the toolbar snap frame by frame, so a drag can take the bar from where it is on screen.
    private let snap = SpringDriver(spring: Motion.toolbarSnap)
    private var snapInterval: OSSignpostIntervalState?
    /// Which resting state the page's bottom inset follows, and a change waiting for a bounce.
    private var pageInset = PageInsetState()
    /// A page started loading under the finger: the bar comes back when the finger lifts.
    private var expandOnRelease = false
    /// Counts Reduce Motion crossfades, so only the newest one ends the snap.
    private var crossfades = 0
    /// Where a running Reduce Motion crossfade takes the bar.
    private var crossfadeTarget: CGFloat?
    private var pullTracker = PullToRefreshTracker()
    private var suggestionTask: Task<Void, Never>?
    private var favoritesTask: Task<Void, Never>?
    /// Runs when the presented feature sheet closes, by Done or by a swipe.
    private var sheetClosed: (() -> Void)?

    /// - Parameters:
    ///   - session: the web view pool, tabs, content blocking and reader mode.
    ///   - data: history, favorites, settings and engine suggestions for the address bar.
    ///   - sheets: Settings, History and the favorites editor.
    ///   - onSearchFieldReady: called once, when the field first becomes first responder.
    public init(
        session: BrowserSession, data: any AddressBarData, sheets: FeatureSheets,
        onSearchFieldReady: @escaping () -> Void
    ) {
        self.session = session
        self.data = data
        self.sheets = sheets
        self.onSearchFieldReady = onSearchFieldReady
        super.init(nibName: nil, bundle: nil)
        session.pool.host = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Building

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.background
        view.tintColor = Palette.accent
        defer { updateStartScreen() }

        panes.install(in: self)
        for subview in [panes.view, pullIndicator, sheet, chromeGlass, tabsUI.toast] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        for subview in [buttonBar, pill] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            chromeGlass.contentView.addSubview(subview)
        }
        installPanes()
        for (effect, control) in zip(pageEdgeEffects, [pill, buttonBar] as [UIView]) {
            effect.edge = .bottom
            control.addInteraction(effect)
        }

        pill.textField.delegate = self
        pill.textField.addTarget(self, action: #selector(queryChanged), for: .editingChanged)
        pill.onTap = { [weak self] in self?.pillTapped() }
        pill.menuProvider = { [weak self] in self?.pageMenu(source: .pill) }

        sheet.onPick = { [weak self] pick in self?.open(pick) }
        sheet.onDismiss = { [weak self] in self?.endEditing() }
        sheet.onEditFavorites = { [weak self] in self?.showFavoritesEditor() }

        buildButtons()
        updateButtons()
        layOut()
        updateBarMode()
        // The first frame is the search sheet, focused (viewIsAppearing makes it first responder).
        applyEditingLayout(true, animated: false)

        var traits: [UITrait] = [UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]
        traits += UITraitCollection.systemTraitsAffectingVerticalBarEdge
        registerForTraitChanges(traits) { (controller: BrowserViewController, _) in
            controller.updateBarMode()
            controller.view.setNeedsLayout()
        }
        data.onSettingsChange = { [weak self] in self?.settingsDidChange() }

        tabsUI.swipe.browser = self
        tabsUI.swipe.install(on: [pill, buttonBar])
        tabsUI.openerSwipe.install(on: view, browser: self)
        session.tabs.onChange = { [weak self] in self?.tabsDidChange() }
        session.pool.onMemoryWarning = { [weak self] in
            self?.tabsUI.previews = [:]
            self?.tabsUI.fullPreviews = []
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(willEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil
        )
    }

    /// Back from the background: idle tabs move to the archive.
    @objc private func willEnterForeground() {
        archiveIdleTabs()
    }

    private func layOut() {
        let safe = view.safeAreaLayoutGuide
        // Their constants make room for the sidebar (either side) and the tab strip (`+Panes`).
        duo.panesLeading = panes.view.leadingAnchor.constraint(equalTo: safe.leadingAnchor)
        duo.panesTrailing = panes.view.trailingAnchor.constraint(equalTo: safe.trailingAnchor)
        duo.panesTop = panes.view.topAnchor.constraint(equalTo: safe.topAnchor)
        let margin = Spacing.m
        // The resting chrome's bottom: above the home indicator, or 8 pt above a plain edge.
        let rest = UILayoutGuide()
        view.addLayoutGuide(rest)
        let restOverIndicator = rest.topAnchor.constraint(equalTo: safe.bottomAnchor)
        restOverIndicator.priority = .defaultLow
        let restOverEdge = rest.topAnchor.constraint(equalTo: view.bottomAnchor, constant: -ChromeGeometry.edgeMargin)
        restOverEdge.priority = .defaultLow

        pillOnBar = pill.bottomAnchor.constraint(equalTo: buttonBar.topAnchor, constant: -ChromeGeometry.gap)
        pillOnEdge = pill.bottomAnchor.constraint(equalTo: rest.topAnchor)
        pillOnKeyboard = pill.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -Spacing.s)

        // The chrome's lane: the focused pane, off an active fold and the camera (`DuoLayout`).
        let lane = duo.chromeLane
        view.addLayoutGuide(lane)
        duo.laneLeading = lane.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        // Set before every layout pass (`updateDuoLayout`, from `viewWillLayoutSubviews`).
        duo.laneWidth = lane.widthAnchor.constraint(equalToConstant: 0)

        func capWidth(_ item: UIView) -> [NSLayoutConstraint] {
            let fill = item.widthAnchor.constraint(equalTo: lane.widthAnchor, constant: -2 * margin)
            // Just under required: only the 640 pt cap may override it, never content size.
            fill.priority = .required - 1
            return [
                item.centerXAnchor.constraint(equalTo: lane.centerXAnchor),
                fill,
                item.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
            ]
        }

        NSLayoutConstraint.activate([
            rest.heightAnchor.constraint(equalToConstant: 0),
            rest.topAnchor.constraint(lessThanOrEqualTo: safe.bottomAnchor),
            rest.topAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -ChromeGeometry.edgeMargin),
            restOverIndicator,
            restOverEdge,

            duo.laneLeading, duo.laneWidth,
            lane.topAnchor.constraint(equalTo: view.topAnchor),
            lane.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // The panes fill the view below the status bar and beside a vertical bar and the
            // sidebar. Their bottom runs under the chrome; obscuredContentInsets tells WebKit what
            // the chrome covers.
            duo.panesTop,
            duo.panesLeading,
            duo.panesTrailing,
            panes.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            pullIndicator.topAnchor.constraint(equalTo: panes.view.topAnchor, constant: Spacing.s),
            pullIndicator.centerXAnchor.constraint(equalTo: lane.centerXAnchor),
            pullIndicator.widthAnchor.constraint(equalToConstant: PullIndicator.size),
            pullIndicator.heightAnchor.constraint(equalToConstant: PullIndicator.size),

            chromeGlass.topAnchor.constraint(equalTo: view.topAnchor),
            chromeGlass.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            chromeGlass.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chromeGlass.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            sheet.topAnchor.constraint(equalTo: view.topAnchor),
            sheet.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sheet.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sheet.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sheet.content.topAnchor.constraint(greaterThanOrEqualTo: safe.topAnchor, constant: Spacing.s),
            sheet.content.bottomAnchor.constraint(equalTo: pill.topAnchor, constant: -Spacing.s),

            pill.heightAnchor.constraint(equalToConstant: ChromeGeometry.pillHeight),

            // The toast floats just above the pill, centered on it.
            tabsUI.toast.bottomAnchor.constraint(equalTo: pill.topAnchor, constant: -Spacing.s),
            tabsUI.toast.centerXAnchor.constraint(equalTo: pill.centerXAnchor),
            tabsUI.toast.heightAnchor.constraint(equalToConstant: Metrics.tapTarget),
            tabsUI.toast.widthAnchor.constraint(lessThanOrEqualTo: pill.widthAnchor),
        ] + capWidth(pill) + capWidth(sheet.content))

        buttonBarConstraints = [
            buttonBar.heightAnchor.constraint(equalToConstant: ChromeGeometry.barHeight),
            buttonBar.bottomAnchor.constraint(equalTo: rest.topAnchor),
        ] + capWidth(buttonBar)
        NSLayoutConstraint.activate(buttonBarConstraints)
    }

    private func buildButtons() {
        for kind in PageButton.allCases {
            let button = buttonBar.button(kind)
            let item: UIBarButtonItem
            switch kind {
            case .more:
                button.menu = pageMenu(source: .button)
                button.showsMenuAsPrimaryAction = true
                // The same top-to-bottom order wherever the menu opens, app items last.
                button.preferredMenuElementOrder = .fixed
                item = UIBarButtonItem(
                    title: kind.title, image: UIImage(systemName: kind.symbol), primaryAction: nil, menu: pageMenu(source: .barItem)
                )
                item.preferredMenuElementOrder = .fixed
            case .tabs:
                // A tap shows the gallery; a long press, the tabs menu.
                let action = UIAction(title: kind.title, image: UIImage(systemName: kind.symbol)) { [weak self] _ in
                    self?.tabsButtonTapped()
                }
                button.addAction(action, for: .primaryActionTriggered)
                button.menu = tabsMenu()
                button.showsMenuAsPrimaryAction = false
                item = UIBarButtonItem(primaryAction: action, menu: tabsMenu())
            case .share:
                button.addAction(UIAction { [weak self, weak button] _ in
                    guard let button else { return }
                    self?.share(from: button)
                }, for: .primaryActionTriggered)
                item = UIBarButtonItem(title: kind.title, image: UIImage(systemName: kind.symbol))
                item.primaryAction = UIAction(title: kind.title, image: UIImage(systemName: kind.symbol)) { [weak self, weak item] _ in
                    guard let item else { return }
                    self?.share(from: item)
                }
            case .back, .forward:
                let action = UIAction(title: kind.title, image: UIImage(systemName: kind.symbol)) { [weak self] _ in
                    kind == .back ? self?.goBack() : self?.goForward()
                }
                button.addAction(action, for: .primaryActionTriggered)
                item = UIBarButtonItem(primaryAction: action)
            }
            item.axisBehavior = .verticalPreferred
            // Back, Forward and Tabs overflow last (docs/research/design-audit.md, Duo).
            item.visibilityPriority = kind == .share ? .low : (kind == .more ? .standard : .high)
            item.accessibilityIdentifier = kind.identifier
            item.isEnabled = false
            barItems[kind] = item
        }
        toolbarItems = PageButton.allCases.compactMap { barItems[$0] }
    }

    /// Shows the page buttons in the system's vertical bar where it has one, otherwise in the
    /// glass bar under the pill. Layout follows the traits, never the device.
    private func updateBarMode() {
        let vertical = traitCollection.verticalBarEdge != .unspecified
        let changed = vertical != usesVerticalBar || pillOnBar.isActive == pillOnEdge.isActive
        usesVerticalBar = vertical
        navigationController?.setToolbarHidden(!vertical, animated: false)
        // Nothing is ever pushed; the left edge belongs to the page's swipe back.
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
        // The bar leaves the glass container rather than hiding in it: a hidden view inside a
        // glass container still shows up in the accessibility tree, as a second Back and More.
        if vertical {
            buttonBar.removeFromSuperview()
        } else if buttonBar.superview == nil {
            chromeGlass.contentView.insertSubview(buttonBar, belowSubview: pill)
            NSLayoutConstraint.activate(buttonBarConstraints)
        }
        if changed { updatePillRestConstraint() }
        view.setNeedsLayout()
    }

    private func updatePillRestConstraint() {
        pillOnKeyboard.isActive = false
        pillOnBar.isActive = false
        pillOnEdge.isActive = false
        if isEditingAddress {
            pillOnKeyboard.isActive = true
        } else if usesVerticalBar {
            pillOnEdge.isActive = true
        } else {
            pillOnBar.isActive = true
        }
    }

    override public func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // Every Duo state comes from the bounds, size classes and the fold's regions here.
        updateDuoLayout()
    }

    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let next = ChromeGeometry(
            viewHeight: view.bounds.height, safeBottom: view.safeAreaInsets.bottom, hasButtonBar: !usesVerticalBar
        )
        guard next != geometry else { return }
        geometry = next
        applyCollapse(collapse.progress)
        // During a fold or rotation the insets wait for the transition's completion.
        if !duo.isResizing { updatePageInsets() }
    }

    override public func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        windowWillResize(to: size, with: coordinator)
    }

    /// UIKit re-runs this when the fold's reserved regions change (book pose on and off).
    override public func updateViewConstraints() {
        super.updateViewConstraints()
        view.setNeedsLayout()
    }

    // MARK: Launch

    override public func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // The view is in the window now, so it can take first responder before the first frame
        // is committed.
        guard !didFocusAtLaunch, pill.beginEditing() else { return }
        didFocusAtLaunch = true
        Signposts.signposter.emitEvent(Signposts.searchFieldReady)
        onSearchFieldReady()
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didWarmUp else { return }
        didWarmUp = true
        // A dispatch to the main queue can run before Core Animation commits the first frame.
        // A display link's first callback comes at the vsync after that commit, so the warm-up
        // starts only once the first frame has gone to the render server.
        let link = CADisplayLink(target: self, selector: #selector(firstFrameDidCommit(_:)))
        link.add(to: .main, forMode: .common)
    }

    @objc private func firstFrameDidCommit(_ link: CADisplayLink) {
        link.invalidate()
        startSession()
    }

    /// Call when the address bar's data changed outside the shell (the database opened), so an
    /// open search sheet shows the favorites.
    public func addressBarDataDidChange() {
        // The settings are in: idle tabs can move to the archive.
        archiveIdleTabs()
        guard isEditingAddress else { return }
        loadFavorites()
    }

    // MARK: Address bar

    private func pillTapped() {
        // A collapsed bar first comes back, as Safari's does; the next tap edits. A bar already
        // springing back out takes the tap as an edit.
        let restingProgress = snap.isRunning ? snap.target : collapse.progress
        if restingProgress > 0 {
            expandChrome(animated: true)
            return
        }
        let interval = Signposts.signposter.beginInterval(Signposts.urlBarFocus)
        pill.textField.text = currentTab?.url?.absoluteString ?? ""
        // The layout switches before the keyboard starts, so the keyboard's own animation carries
        // the pill up (keyboardLayoutGuide) and it never falls behind the rising keyboard.
        applyEditingLayout(true, animated: true)
        if !pill.beginEditing() { applyEditingLayout(false, animated: false) }
        Signposts.signposter.endInterval(Signposts.urlBarFocus, interval)
    }

    public func textFieldDidBeginEditing(_ textField: UITextField) {
        // First, so a preconnect to the suggestion host overlaps the sheet opening.
        data.prepareForTyping()
        applyEditingLayout(true, animated: didFocusAtLaunch)
        if !(textField.text ?? "").isEmpty {
            textField.selectAll(nil)
        }
        loadFavorites()
        queryChanged()
    }

    public func textFieldDidEndEditing(_ textField: UITextField) {
        suggestionTask?.cancel()
        data.cancelSuggestions()
        updateStartForTyping(query: "")
        applyEditingLayout(false, animated: true)
    }

    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let signposter = Signposts.signposter
        let state = signposter.beginInterval(Signposts.addressSubmit)
        guard let input = AddressBarInput(textField.text ?? ""),
              let url = input.destination(searchingWith: data.searchEngine)
        else {
            signposter.endInterval(Signposts.addressSubmit, state, "ignored")
            Haptic.nothingThere.play()
            return false
        }
        load(url, kind: .typed)
        signposter.endInterval(Signposts.addressSubmit, state, "loaded")
        return false
    }

    @objc private func queryChanged() {
        let query = pill.textField.text ?? ""
        suggestionTask?.cancel()
        // The current page's address, untouched, is not a query: show favorites, as for an
        // empty field, until the user types.
        let isCurrentAddress = !query.isEmpty && query == currentTab?.url?.absoluteString
        sheet.setFavoritesAllowed(query.isEmpty || isCurrentAddress)
        updateStartForTyping(query: query)
        guard !isCurrentAddress, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            sheet.show([])
            return
        }
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.suggestionsShown)
        suggestionTask = Task { [weak self, data] in
            var shown = false
            await data.suggestions(for: query) { suggestions in
                guard let self, !Task.isCancelled else { return }
                self.sheet.show(suggestions)
                if !shown {
                    shown = true
                    signposter.endInterval(Signposts.suggestionsShown, interval)
                }
            }
            if !shown { signposter.endInterval(Signposts.suggestionsShown, interval, "cancelled") }
        }
    }

    private func loadFavorites() {
        favoritesTask?.cancel()
        favoritesTask = Task { [weak self, data] in
            let favorites = await data.favorites()
            guard let self, !Task.isCancelled else { return }
            self.sheet.setFavorites(favorites)
        }
    }

    private func open(_ pick: SearchPick) {
        let url: URL?
        switch pick {
        case .page(let page):
            url = page
            // What the user typed, unless the field still shows the page's own address.
            let input = pill.textField.text ?? ""
            // A private tab teaches the address bar nothing.
            if input != currentTab?.url?.absoluteString, currentTab?.isPrivate != true {
                data.suggestionPicked(input: input, url: page)
            }
        case .search(let query): url = data.searchEngine.resultsURL(for: query)
        }
        guard let url else { return }
        let state = Signposts.signposter.beginInterval(Signposts.addressSubmit)
        load(url, kind: .typed)
        Signposts.signposter.endInterval(Signposts.addressSubmit, state, "picked")
    }

    /// Closes the search sheet: the layout switches first, so the pill rides the keyboard down.
    private func endEditing() {
        applyEditingLayout(false, animated: true)
        pill.textField.resignFirstResponder()
    }

    /// Closes the search sheet, if it is open.
    func endAddressEditing() {
        guard isEditingAddress else { return }
        endEditing()
    }

    /// Opens the search sheet with the field focused (a new tab, the last tab closed).
    func beginAddressEditing() {
        pill.textField.text = currentTab?.url?.absoluteString ?? ""
        applyEditingLayout(true, animated: true)
        if !pill.beginEditing() { applyEditingLayout(false, animated: false) }
    }

    /// The bar is collapsed, or on its way there.
    var isChromeCollapsed: Bool {
        (snap.isRunning ? snap.target : collapse.progress) > 0
    }

    /// Moves between the resting pill and the open search sheet. The pill itself grows into the
    /// field above the keyboard (`.snappy(0.3)`, bounce 0, following `keyboardLayoutGuide`).
    ///
    /// The pill's move is laid out inside the keyboard's animation, which UIKit runs for views
    /// tied to `keyboardLayoutGuide`, so it tracks the keyboard frame by frame. The sheet's
    /// fade, the field's rim and the bar use the spring.
    func applyEditingLayout(_ editing: Bool, animated: Bool) {
        let changed = editing != isEditingAddress || pillOnKeyboard.isActive != editing
        isEditingAddress = editing
        guard changed || !animated else { return }
        // Editing is a mode: the bar's controls and gestures follow the rules for it.
        updateButtons()
        if editing {
            sheet.isHidden = false
            settleCollapse(at: 0, animated: false)
        }
        updatePillRestConstraint()
        let changes = {
            self.pill.setEditing(editing)
            self.sheet.alpha = editing ? 1 : 0
            self.sheet.content.transform = editing ? .identity : CGAffineTransform(translationX: 0, y: Spacing.l)
            self.buttonBar.alpha = editing ? 0 : ChromeGeometry.barAlpha(progress: self.collapse.progress)
        }
        guard animated else {
            UIView.performWithoutAnimation {
                changes()
                self.view.layoutIfNeeded()
            }
            sheet.isHidden = !editing
            return
        }
        view.setNeedsLayout()
        Motion.animate(Motion.urlFocus, crossfading: view, changes: changes) { [weak self] in
            guard let self, !self.isEditingAddress else { return }
            self.sheet.isHidden = true
        }
    }

    // MARK: Page

    /// Loads `url` in the tab on screen. `.typed` when the address bar asked for it: that visit
    /// then weighs more in ranking.
    func load(_ url: URL, kind: VisitKind = .link) {
        let tab = self.currentTab ?? openNewTab()
        if kind == .typed {
            engineUI.typedVisitTabs.insert(tab.id)
        } else {
            engineUI.typedVisitTabs.remove(tab.id)
        }
        tab.load(url)
        pill.display(url: url)
        pill.textField.text = url.absoluteString
        if isEditingAddress { endEditing() }
    }

    // MARK: Buttons

    /// Tells WebKit what the chrome covers (docs/plan.md, engine rule 4). The bottom inset is the
    /// chrome at rest: expanded or collapsed, as `pageInset` says. It changes when a snap ends or
    /// the geometry changes (rotation, fold, bar mode), never while the bar moves, so the page
    /// never relayouts during the motion. The viewport insets span collapsed to expanded, so CSS
    /// `svh`/`lvh` stay put.
    func updatePageInsets() {
        // During a fold or rotation the insets wait for the transition's completion.
        guard view.bounds.height > 0, !duo.isResizing else { return }
        let pageBottom = panes.view.frame.maxY
        let collapsed = geometry.collapsedInset(pageBottom: pageBottom)
        let expanded = geometry.expandedInset(pageBottom: pageBottom)
        let obscured = pageInset.collapsed ? collapsed : expanded
        applyPageInsets(obscuredBottom: obscured, collapsedBottom: collapsed, expandedBottom: expanded)
    }

    /// Moves the page's inset to the bar's resting state, unless the page is bouncing past an
    /// edge; then the next scroll callback inside the range applies it.
    private func applyPendingInset() {
        guard pageInset.pending != nil else { return }
        let applied: Bool
        if let scrollView = pageScrollView {
            let range = scrollRange(scrollView)
            applied = pageInset.applyIfSettled(offset: scrollView.contentOffset.y, top: range.top, bottom: range.bottom)
        } else {
            applied = pageInset.applyIfSettled(offset: 0, top: 0, bottom: 0)
        }
        guard applied else { return }
        if pageInset.collapsed {
            Signposts.signposter.emitEvent(Signposts.pageInset, "collapsed")
        } else {
            Signposts.signposter.emitEvent(Signposts.pageInset, "expanded")
        }
        updatePageInsets()
    }

    /// The smallest and largest content offsets of the page at rest.
    private func scrollRange(_ scrollView: UIScrollView) -> (top: CGFloat, bottom: CGFloat) {
        let top = -scrollView.adjustedContentInset.top
        let bottom = scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        return (top, bottom)
    }

    // MARK: Toolbar collapse

    /// Places the pill and button bar for collapse `progress` with transform and alpha only.
    private func applyCollapse(_ progress: CGFloat) {
        let pillMove = geometry.pillTransform(progress: progress)
        pill.transform = CGAffineTransform(translationX: 0, y: pillMove.translationY)
            .scaledBy(x: pillMove.scale, y: pillMove.scale)
        pill.isCompact = progress > 0
        guard !usesVerticalBar else { return }
        buttonBar.transform = CGAffineTransform(translationX: 0, y: geometry.barTranslation(progress: progress))
        if !isEditingAddress { buttonBar.alpha = ChromeGeometry.barAlpha(progress: progress) }
    }

    func expandChrome(animated: Bool) {
        settleCollapse(at: 0, animated: animated)
    }

    /// A new page brings the bar back. A finger on the page keeps the bar until it lifts, and then
    /// the snap expands it.
    func expandForNewPage() {
        if pageScrollView?.isDragging == true {
            expandOnRelease = true
        } else {
            expandChrome(animated: true)
        }
    }

    /// Snaps the bar to `target` (0 expanded, 1 collapsed) with `.smooth(0.25)`, from where it is
    /// on screen. A snap already running retargets and keeps its velocity unless `velocity`
    /// (progress per second, from the release) is given. When the bar rests, the page's inset
    /// follows.
    private func settleCollapse(at target: CGFloat, animated: Bool, velocity: CGFloat? = nil) {
        // A crossfade already on its way there finishes on its own.
        if let crossfadeTarget, crossfadeTarget == target, animated { return }
        guard snap.isRunning || crossfadeTarget != nil || collapse.progress != target else {
            // Already there (the finger left the bar at an end): it rests now.
            snapEnded(at: target)
            return
        }
        let signposter = Signposts.signposter
        if collapseInterval == nil { collapseInterval = signposter.beginInterval(Signposts.toolbarCollapse) }
        if snapInterval == nil { snapInterval = signposter.beginInterval(Signposts.toolbarSnap) }
        // A rest that waited for a bounce is stale now that the bar moves again.
        pageInset.barMoved()
        cancelCrossfade()
        if animated, Motion.prefersCrossfade {
            // Reduce Motion: the bar crossfades to its place instead of sliding.
            snap.jump(to: target)
            let crossfade = crossfades
            crossfadeTarget = target
            Motion.crossfade(chromeGlass, changes: {
                self.collapse.settle(at: target)
                self.applyCollapse(target)
            }, completion: { [weak self] in
                // A newer settle or a drag owns the end.
                guard let self, crossfade == self.crossfades else { return }
                self.crossfadeTarget = nil
                self.snapEnded(at: target)
            })
            return
        }
        guard animated else {
            snap.jump(to: target)
            collapse.settle(at: target)
            applyCollapse(target)
            snapEnded(at: target)
            return
        }
        // At rest the driver's value is stale: the drag moved the bar since. Start from the screen.
        if !snap.isRunning { snap.jump(to: collapse.progress) }
        snap.animate(to: target, velocity: velocity, in: view, onFrame: { [weak self] progress in
            guard let self else { return }
            self.collapse.settle(at: progress)
            self.applyCollapse(self.collapse.progress)
        }, completion: { [weak self] in
            self?.snapEnded(at: target)
        })
    }

    /// Forgets a running Reduce Motion crossfade, so its completion no longer ends the snap.
    private func cancelCrossfade() {
        crossfades += 1
        crossfadeTarget = nil
    }

    /// The bar is at rest at `target`: close the signposts and let the page's inset follow.
    private func snapEnded(at target: CGFloat) {
        let signposter = Signposts.signposter
        if let interval = snapInterval {
            signposter.endInterval(Signposts.toolbarSnap, interval, "settled")
            snapInterval = nil
        }
        if let interval = collapseInterval {
            signposter.endInterval(Signposts.toolbarCollapse, interval)
            collapseInterval = nil
        }
        pageInset.barRested(collapsed: target >= 1)
        applyPendingInset()
    }

    // MARK: UIScrollViewDelegate

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === pageScrollView else { return }
        // A drag during a snap takes the bar from where it is on screen, with no jump.
        if snap.isRunning || crossfadeTarget != nil {
            cancelCrossfade()
            collapse.settle(at: snap.stop())
            if let interval = snapInterval {
                Signposts.signposter.endInterval(Signposts.toolbarSnap, interval, "grabbed")
                snapInterval = nil
            }
        }
        collapse.resetTracking()
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === pageScrollView, !isEditingAddress else { return }
        let (top, bottom) = scrollRange(scrollView)
        let offset = scrollView.contentOffset.y

        // A resting state that waited for a bounce applies once the page is back in range.
        if pageInset.pending != nil { applyPendingInset() }

        guard scrollView.isTracking else {
            // Coasting into the top brings the bar back, as reaching the top by hand does.
            let restingProgress = snap.isRunning ? snap.target : collapse.progress
            if scrollView.isDecelerating, offset <= top, restingProgress > 0 {
                expandChrome(animated: true)
            }
            return
        }
        trackPull(top - offset)
        // A page that barely scrolls keeps its bar.
        guard !snap.isRunning, bottom - top > collapse.distance * 2 else { return }
        if collapse.scrolled(to: offset, top: top, bottom: bottom) {
            if collapseInterval == nil {
                collapseInterval = Signposts.signposter.beginInterval(Signposts.toolbarCollapse)
            }
            applyCollapse(collapse.progress)
        }
    }

    public func scrollViewWillEndDragging(
        _ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard scrollView === pageScrollView else { return }
        if pullTracker.released() {
            refresh()
        } else {
            pullIndicator.hide()
        }
        defer { expandOnRelease = false }
        guard !isEditingAddress else { return }
        // The snap starts as the finger lifts, toward the release velocity when it is clear, and
        // runs alongside the page's deceleration instead of waiting for it to end.
        let (top, bottom) = scrollRange(scrollView)
        let collapsible = bottom - top > collapse.distance * 2
        let target: CGFloat
        if !collapsible || scrollView.contentOffset.y <= top || expandOnRelease {
            target = 0
        } else {
            target = collapse.settleTarget(velocity: velocity.y)
        }
        settleCollapse(
            at: target, animated: true, velocity: collapse.snapVelocity(scrollVelocity: velocity.y, toward: target)
        )
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === pageScrollView, !decelerate else { return }
        applyPendingInset()
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === pageScrollView else { return }
        applyPendingInset()
    }

    public func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        expandChrome(animated: true)
    }

    // MARK: Pull to refresh

    private func trackPull(_ distance: CGFloat) {
        // Off on Start, in the reader and on error pages, whose own button reloads (state rules §3).
        guard rules.pullToRefresh else { return }
        if distance > 0 { pullIndicator.follow(pull: distance, threshold: PullToRefreshTracker.threshold) }
        if distance > PullToRefreshTracker.threshold / 2 { Haptic.selection.prepare() }
        switch pullTracker.pulled(distance) {
        case .armed:
            Haptic.selection.play()
            Signposts.signposter.emitEvent(Signposts.pullToRefreshArm)
            pullIndicator.setArmed(true)
        case .disarmed:
            pullIndicator.setArmed(false)
        case nil:
            break
        }
    }

    private func refresh() {
        Signposts.signposter.emitEvent(Signposts.pullToRefresh)
        pullIndicator.hide()
        reloadPage()
    }

    // MARK: Buttons and page menu

    private func goBack() {
        guard canGoBack else { return Haptic.nothingThere.play() }
        Signposts.signposter.emitEvent(Signposts.navBack)
        performBack()
    }

    private func goForward() {
        guard let tab = currentTab, !isShowingReader, tab.canGoForward else { return Haptic.nothingThere.play() }
        Signposts.signposter.emitEvent(Signposts.navForward)
        tab.goForward()
    }

    /// The page menu (docs/ui-reference.md): built when it opens, with only the items that apply
    /// now, in the reference's order, then History and Settings in their own last section. Zoom,
    /// blocking and other pane arrive with their features.
    private func pageMenu(source: PageMenuSource) -> UIMenu {
        UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                Signposts.signposter.emitEvent(Signposts.pageMenu)
                guard let self else { return completion([]) }
                guard let url = self.currentTab?.url, LiveAddressBarData.isRecordable(url), self.currentRules().favorite else {
                    self.lastFavoriteAnswer = nil
                    return completion(self.pageMenuElements(isFavorite: nil, source: source))
                }
                // One indexed read off the main thread; the menu shows when it answers. If the
                // page changed meanwhile, the answer is for another page: leave the item out.
                Task { [weak self, data] in
                    let isFavorite = await data.isFavorite(url)
                    guard let self else { return completion([]) }
                    let answer = self.currentTab?.url == url ? isFavorite : nil
                    self.lastFavoriteAnswer = answer
                    completion(self.pageMenuElements(isFavorite: answer, source: source))
                }
            },
        ])
    }

    /// The menu's items. `isFavorite` is nil when there is no page that can be a favorite.
    func pageMenuElements(isFavorite: Bool?, source: PageMenuSource) -> [UIMenuElement] {
        let history = UIAction(title: "History", image: UIImage(systemName: "clock")) { [weak self] _ in
            self?.showHistory()
        }
        history.accessibilityIdentifier = "menu.history"
        let settings = UIAction(title: "Settings…", image: UIImage(systemName: "gearshape")) { [weak self] _ in
            self?.showSettings()
        }
        settings.accessibilityIdentifier = "menu.settings"
        // The menu way to what a long press on the favorites strip offers.
        let favorites = UIAction(title: "Edit Favorites", image: UIImage(systemName: "star.square.on.square")) { [weak self] _ in
            self?.showFavoritesEditor()
        }
        favorites.accessibilityIdentifier = "menu.editFavorites"
        if !sheets.isReady {
            // The database is still opening (the first moments after launch).
            for item in [history, favorites, settings] { item.attributes = .disabled }
        }
        let app = UIMenu(options: .displayInline, children: downloadsMenuItems() + [history, favorites, settings])
        // Every item below follows docs/state-rules.md §4 through ControlRules: items that never
        // apply to this page are left out, Stop takes Reload's place while loading.
        let rules = currentRules()
        // The tabs items first: New Private Tab, Reopen Closed Tab, Archived Tabs where they apply.
        let top = UIMenu(options: .displayInline, children: tabItemsForMore(rules))
        guard rules.shareAndCopy, let tab = currentTab, let url = pageAddress else {
            // An empty pane of a split can still be swapped or closed.
            let paneItems = paneMenuItems(for: nil)
            return [top] + (paneItems.isEmpty ? [] : [UIMenu(options: .displayInline, children: paneItems)]) + [app]
        }
        var pageItems: [UIMenuElement] = []
        switch rules.reload {
        case .reload:
            let reload = UIAction(title: "Reload", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                Signposts.signposter.emitEvent(Signposts.reload)
                self?.reloadPage()
            }
            reload.accessibilityIdentifier = "menu.reload"
            pageItems.append(reload)
        case .stop:
            let stop = UIAction(title: "Stop", image: UIImage(systemName: "xmark")) { [weak tab] _ in
                Signposts.signposter.emitEvent(Signposts.reload, "stop")
                tab?.stopLoading()
            }
            stop.accessibilityIdentifier = "menu.stop"
            pageItems.append(stop)
        case .hidden:
            break
        }
        if rules.findOnPage {
            let find = UIAction(title: "Find on Page", image: UIImage(systemName: "doc.text.magnifyingglass")) { [weak self] _ in
                self?.findOnPage()
            }
            find.accessibilityIdentifier = "menu.find"
            pageItems.append(find)
        }
        pageItems += readerMenuItems(rules.reader)
        if rules.savePDF { pageItems += pdfMenuItems(for: tab) }
        let share = UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
            guard let self else { return }
            let source: (any UIPopoverPresentationControllerSourceItem)? =
                self.usesVerticalBar ? self.barItems[.more] : self.buttonBar.button(.more)
            self.share(from: source)
        }
        let copy = UIAction(title: "Copy Link", image: UIImage(systemName: "link")) { _ in
            Signposts.signposter.emitEvent(Signposts.copyLink)
            UIPasteboard.general.url = url
            Haptic.success.play()
        }
        var siteItems = siteMenuItems(for: tab, url: url, desktop: rules.desktopSite, blocking: rules.blockingToggle)
            + paneMenuItems(for: tab)
        if rules.favorite, let isFavorite {
            let title = tab.title
            let favorite = UIAction(
                title: isFavorite ? "Remove from Favorites" : "Add to Favorites",
                image: UIImage(systemName: isFavorite ? "star.slash" : "star")
            ) { [weak self] _ in
                self?.setFavorite(!isFavorite, url: url, title: title)
            }
            favorite.accessibilityIdentifier = "menu.favorite"
            siteItems.append(favorite)
        }
        var sections: [UIMenuElement] = []
        if !pageItems.isEmpty { sections.append(UIMenu(options: .displayInline, children: pageItems)) }
        sections.append(UIMenu(options: .displayInline, children: [share, copy]))
        if rules.zoom { sections.append(zoomMenu(for: tab, source: source)) }
        if !siteItems.isEmpty { sections.append(UIMenu(options: .displayInline, children: siteItems)) }
        return [top] + sections + [app]
    }

    private func setFavorite(_ isFavorite: Bool, url: URL, title: String?) {
        Signposts.signposter.emitEvent(Signposts.favoriteToggle)
        Task { [data] in
            if await data.setFavorite(isFavorite, url: url, title: title) {
                Haptic.success.play()
            } else {
                Haptic.nothingThere.play()
            }
        }
    }

    // MARK: Feature sheets

    private func showSettings() {
        // Tab Layout applies only where a tab list fits; elsewhere its row says why (docs/plan.md, section 4b).
        let isTabLayoutAvailable = duo.layout?.tabLayoutAvailable ?? false
        present(
            sheets.settings(isTabLayoutAvailable: isTabLayoutAvailable) { [weak self] in self?.closeSheet() },
            signpost: Signposts.settingsOpen
        )
    }

    private func showHistory() {
        let history = sheets.history(
            onOpen: { [weak self] url in
                self?.closeSheet { self?.load(url) }
            },
            onDone: { [weak self] in self?.closeSheet() }
        )
        present(history, signpost: Signposts.historyShow)
    }

    /// From the favorites strip (the search field is open: it closes for the editor and opens
    /// again after, showing the edited favorites) or from the page menu.
    private func showFavoritesEditor() {
        guard let editor = sheets.favoritesEditor(onDone: { [weak self] in self?.closeSheet() }) else { return }
        let wasEditing = isEditingAddress
        if wasEditing { endEditing() }
        present(editor, signpost: Signposts.favoritesEditorOpen) { [weak self] in
            guard let self else { return }
            // Focusing reloads the favorites (textFieldDidBeginEditing).
            if !(wasEditing && self.pill.beginEditing()) { self.loadFavorites() }
        }
    }

    func present(_ controller: UIViewController?, signpost: StaticString, onClose: (() -> Void)? = nil) {
        guard let controller, presentedViewController == nil else { return }
        Signposts.signposter.emitEvent(signpost)
        controller.presentationController?.delegate = self
        sheetClosed = onClose
        present(controller, animated: true)
    }

    /// Dismisses the feature sheet, then runs `completion` and the sheet's close action.
    func closeSheet(then completion: (() -> Void)? = nil) {
        guard presentedViewController != nil else { return }
        let closed = sheetClosed
        sheetClosed = nil
        dismiss(animated: true) { [weak self] in
            completion?()
            closed?()
            self?.sheetDidClose()
        }
    }

    /// A sheet is gone: a toast that waited shows, the tabs tip may show, the archive may have
    /// changed.
    private func sheetDidClose() {
        showPendingToast()
        tabsUI.tip.showIfPossible(in: self)
        session.tabs.refreshArchiveState()
    }

    /// The sheet was swiped down.
    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        let closed = sheetClosed
        sheetClosed = nil
        closed?()
        sheetDidClose()
    }

    private func share(from source: (any UIPopoverPresentationControllerSourceItem)?) {
        // A failed page shares the address that was tried.
        guard let url = pageAddress else { return }
        Signposts.signposter.emitEvent(Signposts.share)
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceItem = source ?? pill
        present(sheet, animated: true)
    }
}
#endif
