#if canImport(UIKit)
import BrowserCore
import DesignSystem
import os
import PerfSignposts
import Reader
import Storage
import UIKit
import WebEngine
import WebKit

/// The browser's root screen: the page, the URL pill at the bottom, the page's buttons, and the
/// search sheet the pill grows into.
///
/// Launch order (docs/plan.md, "Engine rules"; docs/state-rules.md, "Launch and return"):
/// 1. The first frame shows what `LaunchPlan` says: with no tab, the search sheet with the field
///    already first responder, keyboard up; with a last tab, its picture and the resting bar; after
///    a long time away, a fresh search over that picture (`+Launch`).
/// 2. After that frame, the pool warms one offscreen web view with `about:blank`
///    (`BrowserSession.start()`), and the last session's tab, if any, comes back under the picture
///    or the sheet; the picture fades once its live page has loaded.
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
    private let onLaunchReady: () -> Void

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
    let pill = AddressPill()
    let buttonBar = ButtonBar()
    let sheet = SearchSheet()
    let pullIndicator = PullIndicator()
    /// The bottom-edge strip a hidden bar leaves behind (the home-indicator zone over the focused
    /// pane): a tap there brings the bar back. It takes touches only while the bar is hidden.
    private let revealEdge = UIView()
    var barItems: [PageButton: UIBarButtonItem] = [:]

    /// The tab on screen (BrowserCore's `TabStore` owns the list; `EngineTabs` keeps it in step).
    var currentTab: Tab?
    /// The tab's observation, the reader view, the page's error state and the prompt queue.
    let engineUI = EngineUIState()
    /// The gallery, the bar swipe, neighbour previews and the toast.
    let tabsUI = TabsUIState()
    /// What launch opened to: the last tab's picture and the fresh search's frost (`+Launch`).
    let launchUI = LaunchUIState()
    /// The page menu's last favorite and reading list answer, for rebuilding the open menu.
    var lastPageMarks: PageMarks?
    /// Show Tabs asked for before the saved tabs were in (a cold launch from Siri); it runs once
    /// they are (`+System`).
    var showTabsAwaitingSession = false
    /// docs/state-rules.md for the state last applied (`updateButtons`), for hot paths such as
    /// pull to refresh that must not walk the tab list on every scroll callback.
    var rules = ControlRules(ChromeState())

    // Layout.
    private var pillOnBar: NSLayoutConstraint!
    private var pillOnEdge: NSLayoutConstraint!
    private var pillOnKeyboard: NSLayoutConstraint!
    /// The button bar's own constraints, activated again when it comes back after a vertical bar.
    private var buttonBarConstraints: [NSLayoutConstraint] = []
    /// The chrome's row: the lane less its margins, at most 640 pt, centered. The pill and the bar
    /// span it on a page; on the start screen the bar shrinks to its trailing end, beside the pill.
    private var pillSpansRow: NSLayoutConstraint!
    private var pillBesideBar: NSLayoutConstraint!
    private var barSpansRow: NSLayoutConstraint!
    /// The pill's leading edge on the bottom row (off while the top bar holds it, `+TopBar`).
    private var pillOnRowLeading: NSLayoutConstraint!
    /// Set while `applyEditingLayout` runs, which lays out the bar's shape in its own animation.
    private var isApplyingEditingLayout = false
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
    /// The resting state the page's insets follow now (a split's other pane follows it too).
    var pageInsetRest: ChromeRest { pageInset.rest }
    /// A page started loading under the finger: the bar comes back when the finger lifts.
    private var expandOnRelease = false
    /// The bar came back at the page's end while the finger was down: the page's end (before the
    /// inset grew) to rise from once it lifts.
    private var riseFromEnd: CGFloat?
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
    ///   - launch: what the first frame opens to (`LaunchRules.opening`).
    ///   - onLaunchReady: called once, when the first screen is ready: the field first responder,
    ///     or the last tab's picture and resting bar in place.
    public init(
        session: BrowserSession, data: any AddressBarData, sheets: FeatureSheets, launch: LaunchPlan = .search,
        onLaunchReady: @escaping () -> Void
    ) {
        self.session = session
        self.data = data
        self.sheets = sheets
        self.onLaunchReady = onLaunchReady
        super.init(nibName: nil, bundle: nil)
        launchUI.plan = launch
        session.pool.host = self
        (session.translator as? AppleTranslator)?.presenter = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Building

    override public func viewDidLoad() {
        super.viewDidLoad()
        Paper.apply(to: view)
        view.tintColor = Palette.accent
        defer { updateStartScreen() }

        panes.install(in: self)
        for subview in [panes.view, pullIndicator, revealEdge, sheet, chromeGlass, tabsUI.toast] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        for subview in [buttonBar, pill] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            chromeGlass.contentView.addSubview(subview)
        }
        installPanes()
        prepareLaunch()

        revealEdge.isUserInteractionEnabled = false
        revealEdge.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(revealEdgeTapped)))
        pill.textField.delegate = self
        pill.textField.addTarget(self, action: #selector(queryChanged), for: .editingChanged)
        pill.onTap = { [weak self] in self?.pillTapped() }
        pill.menuProvider = { [weak self] in self?.pageMenu(source: .pill) }

        sheet.onPick = { [weak self] pick in self?.open(pick) }
        sheet.onDismiss = { [weak self] in self?.endEditing() }
        sheet.onEditFavorites = { [weak self] in self?.showFavoritesEditor() }
        // A swipe down closes the search, as a sheet closes (Arc Search's way back to the tab).
        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(sheetSwipedDown))
        swipeDown.direction = .down
        sheet.addGestureRecognizer(swipeDown)

        buildButtons()
        updateButtons()
        layOut()
        updateBarMode()
        // The first frame is the search sheet, focused (viewIsAppearing makes it first responder),
        // or the last tab with the bar resting (`LaunchPlan`).
        applyEditingLayout(launchOpensSearch, animated: false)

        var traits: [UITrait] = [UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]
        traits += UITraitCollection.systemTraitsAffectingVerticalBarEdge
        registerForTraitChanges(traits) { (controller: BrowserViewController, _) in
            controller.setNeedsUpdateOfVerticalBarConfiguration()
            controller.updateBarMode()
            controller.view.setNeedsLayout()
        }
        data.onSettingsChange = { [weak self] in self?.settingsDidChange() }
        observeAppearance()

        tabsUI.swipe.browser = self
        tabsUI.swipe.install(on: [pill, buttonBar])
        tabsUI.openerSwipe.install(on: view, browser: self)
        session.tabs.onChange = { [weak self] in self?.tabsDidChange() }
        session.pool.onTranslationFailed = { [weak self] tab in
            guard let self, tab === self.currentTab else { return }
            Haptic.nothingThere.play()
            self.showToastWhenFree { [weak self] in self?.tabsUI.toast.show("This page couldn't be translated") }
        }
        session.pool.onMemoryWarning = { [weak self] in
            self?.tabsUI.previews = [:]
            self?.tabsUI.fullPreviews = []
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(willEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil
        )
        // A page's form taking the keyboard brings the whole bar back, so it is there when the
        // keyboard leaves (state rules §7, item 8).
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillShowNotification, object: nil
        )
        // VoiceOver and Switch Control keep the bar in reach (`ControlRules.chromeMayHide`).
        for name in [UIAccessibility.voiceOverStatusDidChangeNotification, UIAccessibility.switchControlStatusDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(assistiveTechChanged), name: name, object: nil)
        }
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
        makeTopBarConstraints()
        // The resting chrome's bottom: above the home indicator, or 8 pt above a plain edge.
        let rest = UILayoutGuide()
        view.addLayoutGuide(rest)
        let restOverIndicator = rest.topAnchor.constraint(equalTo: safe.bottomAnchor)
        restOverIndicator.priority = .defaultLow
        let restOverEdge = rest.topAnchor.constraint(equalTo: view.bottomAnchor, constant: -ChromeGeometry.edgeMargin)
        restOverEdge.priority = .defaultLow

        let revealEdgeOverIndicator = revealEdge.topAnchor.constraint(equalTo: safe.bottomAnchor)
        revealEdgeOverIndicator.priority = .defaultLow
        let revealEdgeOverEdge = revealEdge.topAnchor.constraint(
            equalTo: view.bottomAnchor, constant: -ChromeGeometry.revealEdgeMinimum
        )
        revealEdgeOverEdge.priority = .defaultLow

        pillOnBar = pill.bottomAnchor.constraint(equalTo: buttonBar.topAnchor, constant: -ChromeGeometry.gap)
        pillOnEdge = pill.bottomAnchor.constraint(equalTo: rest.topAnchor)
        pillOnKeyboard = pill.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -Spacing.s)

        // The chrome's lane: the focused pane, off an active fold and the camera (`DuoLayout`).
        let lane = duo.chromeLane
        view.addLayoutGuide(lane)
        duo.laneLeading = lane.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        // Set before every layout pass (`updateDuoLayout`, from `viewWillLayoutSubviews`).
        duo.laneWidth = lane.widthAnchor.constraint(equalToConstant: 0)

        let row = UILayoutGuide()
        view.addLayoutGuide(row)

        func capWidth(centerX: NSLayoutXAxisAnchor, width: NSLayoutDimension) -> [NSLayoutConstraint] {
            let fill = width.constraint(equalTo: lane.widthAnchor, constant: -2 * margin)
            // Just under required: only the 640 pt cap may override it, never content size.
            fill.priority = .required - 1
            return [
                centerX.constraint(equalTo: lane.centerXAnchor),
                fill,
                width.constraint(lessThanOrEqualToConstant: 640),
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

            // The reveal edge: the home-indicator zone (at least 16 pt) under the focused pane.
            revealEdge.leadingAnchor.constraint(equalTo: lane.leadingAnchor),
            revealEdge.trailingAnchor.constraint(equalTo: lane.trailingAnchor),
            revealEdge.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            revealEdge.topAnchor.constraint(lessThanOrEqualTo: safe.bottomAnchor),
            revealEdge.topAnchor.constraint(
                lessThanOrEqualTo: view.bottomAnchor, constant: -ChromeGeometry.revealEdgeMinimum
            ),
            revealEdgeOverIndicator,
            revealEdgeOverEdge,

            duo.top.pullIndicatorTop as NSLayoutConstraint,
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
            duo.top.sheetOverPill as NSLayoutConstraint,

            duo.top.pillHeight as NSLayoutConstraint,

            // The toast floats just above the pill, centered on it (under a top bar: low on the
            // page, `+TopBar`).
            duo.top.toastOverPill as NSLayoutConstraint,
            tabsUI.toast.centerXAnchor.constraint(equalTo: pill.centerXAnchor),
            tabsUI.toast.heightAnchor.constraint(equalToConstant: Metrics.tapTarget),
            tabsUI.toast.widthAnchor.constraint(lessThanOrEqualTo: pill.widthAnchor),
        ] + capWidth(centerX: row.centerXAnchor, width: row.widthAnchor)
            + capWidth(centerX: sheet.content.centerXAnchor, width: sheet.content.widthAnchor))

        pillSpansRow = pill.trailingAnchor.constraint(equalTo: row.trailingAnchor)
        pillBesideBar = pill.trailingAnchor.constraint(equalTo: buttonBar.leadingAnchor, constant: -ChromeGeometry.gap)
        barSpansRow = buttonBar.leadingAnchor.constraint(equalTo: row.leadingAnchor)
        pillOnRowLeading = pill.leadingAnchor.constraint(equalTo: row.leadingAnchor)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: lane.topAnchor),
            row.bottomAnchor.constraint(equalTo: lane.bottomAnchor),
            pillOnRowLeading,
            pillSpansRow,
        ])
        buttonBarConstraints = [
            buttonBar.heightAnchor.constraint(equalToConstant: ChromeGeometry.barHeight),
            buttonBar.bottomAnchor.constraint(equalTo: rest.topAnchor),
            buttonBar.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            barSpansRow,
        ]
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
                // The same top-to-bottom order wherever the menu opens: Close Tab last, on its own.
                button.preferredMenuElementOrder = .fixed
                item = UIBarButtonItem(primaryAction: action, menu: tabsMenu())
                item.preferredMenuElementOrder = .fixed
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
        // `verticalBarEdge` keeps the system's edge while the vertical bar is disabled (a wide
        // screen's top bar, `+TopBar`): it is in use only where Plain leaves it on.
        let vertical = traitCollection.verticalBarEdge != .unspecified && preferredVerticalBarBehavior == .automatic
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
        if changed || buttonBar.superview != nil { updatePillRestConstraint() }
        view.setNeedsLayout()
        // The rules depend on the bar (the vertical bar dims instead of hiding).
        if changed { updateButtons() }
    }

    func updatePillRestConstraint() {
        let onTop = chromeOnTop
        let hasBar = buttonBar.superview != nil
        let beside = !onTop && rules.barBesidePill && hasBar
        // Under a top bar the pill leaves it only to edit, above the keyboard.
        let pillOnTop = onTop && !isEditingAddress
        pillOnKeyboard.isActive = false
        pillOnBar.isActive = false
        pillOnEdge.isActive = false
        pillOnRowLeading.isActive = false
        pillSpansRow.isActive = false
        pillBesideBar.isActive = false
        if hasBar { NSLayoutConstraint.deactivate(buttonBarConstraints) }
        setTopBarConstraints(pill: pillOnTop, bar: onTop && hasBar)
        if isEditingAddress {
            pillOnKeyboard.isActive = true
        } else if pillOnTop {
            // The top bar places it.
        } else if usesVerticalBar || beside {
            pillOnEdge.isActive = true
        } else {
            pillOnBar.isActive = true
        }
        // The start screen's bar: a round glass button at the row's end, the pill beside it.
        // Under a top bar: two capsules at the row's ends.
        buttonBar.setSplit(onTop && hasBar)
        buttonBar.setBesidePill(beside)
        if !pillOnTop {
            pillOnRowLeading.isActive = true
            if beside { pillBesideBar.isActive = true } else { pillSpansRow.isActive = true }
        }
        if hasBar, !onTop {
            NSLayoutConstraint.activate(buttonBarConstraints.filter { $0 !== barSpansRow })
            barSpansRow.isActive = !beside
        }
    }

    /// Start and Page are different modes (state rules, principle 5): on the start screen the bar
    /// sits beside the pill, on a page under it. Called whenever the rules change; the editing
    /// layout moves the bar itself, inside the keyboard's animation.
    func updateBarShapeIfNeeded() {
        let beside = !chromeOnTop && rules.barBesidePill && buttonBar.superview != nil
        guard pillOnBar != nil, beside != buttonBar.isBesidePill, !isApplyingEditingLayout else { return }
        updatePillRestConstraint()
        guard view.window != nil else { return }
        Motion.animate(Motion.reflow) { self.view.layoutIfNeeded() }
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
        let top = duo.layout?.chromeOnTop == true
            ? makeTopGeometry(stripHeight: duo.layout?.stripHeight ?? 0) : nil
        guard next != geometry || top != duo.topGeometry else { return }
        geometry = next
        duo.topGeometry = top
        applyCollapse(collapse.progress)
        // During a fold or rotation the insets wait for the transition's completion.
        if !duo.isResizing { updatePageInsets() }
    }

    /// Off where the top bar holds the buttons (`+TopBar`): the Duo's inner screen, as Safari.
    override public var preferredVerticalBarBehavior: UIVerticalBarBehavior {
        wantsHorizontalBars ? .disabled : .automatic
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
        guard !didFocusAtLaunch else { return }
        if launchOpensSearch {
            guard pill.beginEditing() else { return }
            Signposts.signposter.emitEvent(Signposts.searchFieldReady)
        }
        didFocusAtLaunch = true
        showLaunchPicture()
        onLaunchReady()
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
        pill.textField.text = pageAddress?.absoluteString ?? ""
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
        let isCurrentAddress = !query.isEmpty && query == pageAddress?.absoluteString
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
            if input != pageAddress?.absoluteString, currentTab?.isPrivate != true {
                data.suggestionPicked(input: input, url: page)
            }
        case .search(let query): url = data.searchEngine.resultsURL(for: query)
        }
        guard let url else { return }
        let state = Signposts.signposter.beginInterval(Signposts.addressSubmit)
        load(url, kind: .typed)
        Signposts.signposter.endInterval(Signposts.addressSubmit, state, "picked")
    }

    @objc private func sheetSwipedDown() {
        endAddressEditing()
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
        pill.textField.text = pageAddress?.absoluteString ?? ""
        applyEditingLayout(true, animated: true)
        if !pill.beginEditing() { applyEditingLayout(false, animated: false) }
    }

    /// How collapsed the bar is now (0 expanded, 1 collapsed).
    var collapseProgress: CGFloat { collapse.progress }

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
        // A fresh search lasts as long as its field: closing it uncovers the page.
        if !editing { launchUI.isFreshSearch = false }
        let frostAlpha: CGFloat = editing && launchUI.isFreshSearch ? 1 : 0
        guard changed || !animated else { return }
        // Editing is a mode: the bar's controls and gestures follow the rules for it, and the start
        // screen's button and shortcuts step aside for the field.
        isApplyingEditingLayout = true
        updateButtons()
        isApplyingEditingLayout = false
        tabsUI.start.isSearchFieldActive = editing
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
            self.launchUI.frost.alpha = frostAlpha
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
        // A new address replaces the page the launch picture shows.
        dropLaunchCover(animated: true)
        let tab = tabForSubmittedAddress()
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
        if let top = duo.topGeometry {
            applyTopBarInsets(top, rest: pageInset.rest)
            return
        }
        // Back from a top bar (a fold to the outer screen): the page's top rests at the top again.
        setPageTopStart(0, for: pageScrollView)
        // The reader's bottom inset was the top bar's own (`pageBottomInset`); the safe area is
        // back in its adjustment.
        engineUI.reader.webView?.scrollView.followObscuredBottom(0)
        for slot in panes.slots { slot.setRingTopInset(0) }
        let pageBottom = panes.view.frame.maxY
        let hidden = geometry.hiddenInset(pageBottom: pageBottom)
        let expanded = geometry.expandedInset(pageBottom: pageBottom)
        let obscured = geometry.obscuredInset(pageBottom: pageBottom, rest: pageInset.rest)
        applyPageInsets(obscuredBottom: obscured, minimumBottom: hidden, expandedBottom: expanded)
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
        switch pageInset.rest {
        case .expanded: Signposts.signposter.emitEvent(Signposts.pageInset, "expanded")
        case .pill: Signposts.signposter.emitEvent(Signposts.pageInset, "collapsed")
        case .hidden: Signposts.signposter.emitEvent(Signposts.pageInset, "hidden")
        }
        let scrollView = pageScrollView
        let endBefore = scrollView.map { scrollRange($0).bottom }
        updatePageInsets()
        // The bar came back at the page's end: the page rises with it, so its last lines are not
        // left under the bar. Under the finger, it waits for the finger to lift.
        guard let scrollView, let endBefore, pageInset.rest == .expanded,
              scrollView.contentOffset.y >= endBefore - 1 else { return }
        if scrollView.isTracking {
            riseFromEnd = endBefore
        } else {
            riseToEnd(scrollView)
        }
    }

    /// Scrolls the page to its end, which the grown inset moved down. A scroll, not a relayout;
    /// under Reduce Motion it jumps.
    private func riseToEnd(_ scrollView: UIScrollView) {
        riseFromEnd = nil
        let bottom = scrollRange(scrollView).bottom
        guard bottom > scrollView.contentOffset.y + 1 else { return }
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: bottom), animated: !Motion.prefersCrossfade
        )
    }

    /// The rules changed (`updateButtons`): a hidden bar the state no longer allows comes back.
    func chromeRulesChanged() {
        guard collapse.rest == .hidden, !rules.chromeMayHide else { return }
        revealChrome(rules.state.usesAssistiveTech ? .accessibility : .state)
    }

    /// The smallest and largest content offsets of the page at rest.
    private func scrollRange(_ scrollView: UIScrollView) -> (top: CGFloat, bottom: CGFloat) {
        let top = -scrollView.adjustedContentInset.top
        let bottom = scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        return (top, bottom)
    }

    // MARK: Toolbar collapse

    /// Places the pill and button bar for collapse `progress` with transform and alpha only.
    func applyCollapse(_ progress: CGFloat) {
        if let top = duo.topGeometry {
            applyTopBarCollapse(progress, geometry: top)
            return
        }
        let pillMove = geometry.pillTransform(progress: progress)
        pill.transform = CGAffineTransform(translationX: 0, y: pillMove.translationY)
            .scaledBy(x: pillMove.scale, y: pillMove.scale)
        pill.alpha = ChromeGeometry.pillAlpha(progress: progress)
        pill.isCompact = progress > 0
        let isGone = progress >= ChromeRest.hidden.progress
        if pill.accessibilityElementsHidden != isGone { pill.accessibilityElementsHidden = isGone }
        guard !usesVerticalBar else { return }
        buttonBar.transform = CGAffineTransform(translationX: 0, y: geometry.barTranslation(progress: progress))
        if !isEditingAddress { buttonBar.alpha = ChromeGeometry.barAlpha(progress: progress) }
    }

    func expandChrome(animated: Bool) {
        settleCollapse(at: 0, animated: animated)
    }

    /// Brings a collapsed or hidden bar back whole, and says why (signpost). A bar already
    /// expanded, or on its way there, is left alone.
    func revealChrome(_ reason: ChromeRevealReason) {
        let resting = snap.isRunning ? snap.target : crossfadeTarget ?? collapse.progress
        guard resting > 0 else { return }
        Signposts.signposter.emitEvent(Signposts.toolbarReveal, "\(reason.rawValue, privacy: .public)")
        expandChrome(animated: true)
    }

    /// Lets the pill sink away while the user reads.
    private func hideChrome(_ reason: String) {
        let resting = snap.isRunning ? snap.target : crossfadeTarget ?? collapse.progress
        guard resting < ChromeRest.hidden.progress else { return }
        Signposts.signposter.emitEvent(Signposts.toolbarHide, "\(reason, privacy: .public)")
        settleCollapse(at: ChromeRest.hidden.progress, animated: true)
    }

    @objc private func revealEdgeTapped() {
        revealChrome(.edgeTap)
    }

    @objc private func keyboardWillShow() {
        guard !isEditingAddress else { return }
        revealChrome(.keyboard)
    }

    @objc private func assistiveTechChanged() {
        // `updateButtons` reads VoiceOver and Switch Control and brings a hidden bar back.
        updateButtons()
    }

    /// The page is long enough for the bar to hide: at least two screens, so the hidden bar has
    /// a page to give back, and the page's end (where the bar returns) is not already in sight.
    /// Measured on the content, not the scroll range, which the resting bar's inset changes.
    private func pageAllowsHiding(_ scrollView: UIScrollView) -> Bool {
        rules.chromeMayHide && scrollView.contentSize.height >= 2 * scrollView.bounds.height
    }

    /// The offset at which the page's end reaches the screen's bottom edge: from there on the bar
    /// is out (`ChromeCollapse.scrolled`).
    private func pageEnd(_ scrollView: UIScrollView) -> CGFloat {
        scrollView.contentSize.height - scrollView.bounds.height
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
        // A rest that waited for a bounce is stale now that the bar moves again. A bar coming back
        // takes its inset now, so a fixed page footer rises with it, in one motion; a bar going
        // away keeps the inset until it rests (`snapEnded`).
        let rest = ChromeRest(progress: target)
        pageInset.barHeading(to: rest)
        applyPendingInset()
        cancelCrossfade()
        collapse.head(to: rest)
        // The edge takes taps only while the bar rests hidden.
        revealEdge.isUserInteractionEnabled = false
        if animated, Motion.prefersCrossfade {
            // Reduce Motion: the bar crossfades to its place instead of sliding.
            snap.jump(to: target)
            let crossfade = crossfades
            crossfadeTarget = target
            Motion.crossfade(chromeGlass, changes: {
                self.collapse.place(at: target)
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
        // Hiding is the calmer spring; everything else (coming back, the snap) the snap's.
        let spring = target >= ChromeRest.hidden.progress ? Motion.toolbarHide : Motion.toolbarSnap
        snap.animate(to: target, velocity: velocity, spring: spring, in: view, onFrame: { [weak self] progress in
            guard let self else { return }
            self.collapse.place(at: progress)
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
        let rest = ChromeRest(progress: target)
        collapse.settle(at: target)
        revealEdge.isUserInteractionEnabled = rest == .hidden
        pageInset.barRested(rest)
        applyPendingInset()
    }

    // MARK: UIScrollViewDelegate

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === pageScrollView else { return }
        // The page is moving under the launch picture: the live page takes over now.
        dropLaunchCover(animated: true)
        riseFromEnd = nil
        // A drag during a snap between expanded and the pill takes the bar from where it is on
        // screen, with no jump. Hiding and coming back are not the finger's: they finish, and the
        // drag can still turn them around (`ChromeCollapse.scrolled`).
        let runningTarget = snap.isRunning ? snap.target : crossfadeTarget
        if let runningTarget, runningTarget <= 1, collapse.progress <= 1 {
            cancelCrossfade()
            // A reveal's inset still waiting for a bounce is the finger's call now.
            pageInset.barMoved()
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
        let signposter = Signposts.signposter
        let step = signposter.isEnabled ? signposter.beginInterval(Signposts.scrollStep) : nil
        defer { if let step { signposter.endInterval(Signposts.scrollStep, step) } }
        let (top, bottom) = scrollRange(scrollView)
        let offset = scrollView.contentOffset.y

        // A resting state that waited for a bounce applies once the page is back in range.
        if pageInset.pending != nil { applyPendingInset() }

        let tracking = scrollView.isTracking
        if tracking { trackPull(top - offset) }
        // Only the user's scrolling moves the bar: a page's own scroll, a zoom or the rise at the
        // end (`applyPendingInset`) leave it alone.
        guard tracking || scrollView.isDecelerating else { return }
        let mayHide = pageAllowsHiding(scrollView)
        // A hidden bar on a page that became too short (or a state that no longer allows it) comes
        // back; a page that barely scrolls keeps its bar.
        if collapse.rest == .hidden, !mayHide { return revealChrome(.shortPage) }
        guard bottom - top > collapse.distance * 2 else { return }
        let isHidden = collapse.rest == .hidden
        // The finger's speed matters only to bring a hidden bar back.
        let velocity = tracking && isHidden ? -scrollView.panGestureRecognizer.velocity(in: scrollView).y / 1000 : 0
        let change = collapse.scrolled(
            to: offset, top: top, bottom: bottom, pageEnd: pageEnd(scrollView),
            tracking: tracking, snapping: snap.isRunning || crossfadeTarget != nil, velocity: velocity,
            canHide: !isHidden && mayHide
        )
        switch change {
        case .none:
            break
        case .moved:
            if collapseInterval == nil {
                collapseInterval = signposter.beginInterval(Signposts.toolbarCollapse)
            }
            applyCollapse(collapse.progress)
        case .hide:
            hideChrome(tracking ? "reading" : "coast")
        case .reveal:
            revealChrome(offset <= top ? .pageTop : offset >= pageEnd(scrollView) ? .pageEnd : .scrollUp)
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
        // A reveal under way (a move up brought the bar back mid-drag) finishes as it is.
        let runningTarget = snap.isRunning ? snap.target : crossfadeTarget
        if runningTarget == 0, collapse.rest == .expanded { return }
        let (top, bottom) = scrollRange(scrollView)
        let offset = scrollView.contentOffset.y
        let collapsible = bottom - top > collapse.distance * 2
        let rest: ChromeRest
        if !collapsible || offset <= top || expandOnRelease {
            rest = .expanded
        } else {
            let coastEnd = targetContentOffset.pointee.y
            let nearEnd = pageEnd(scrollView) - collapse.distance
            rest = collapse.settleTarget(
                velocity: velocity.y, coast: coastEnd - offset,
                canHide: pageAllowsHiding(scrollView),
                coastReachesEnd: coastEnd >= nearEnd, atEnd: offset >= nearEnd
            )
        }
        let target = rest.progress
        switch rest {
        case .hidden:
            // A hide already under way keeps going; a flick that will carry the reader past the
            // hide travel goes straight there, in one motion.
            if collapse.rest != .hidden { hideChrome("flick") }
        case .expanded where collapse.rest == .hidden:
            revealChrome(.scrollUp)
        default:
            settleCollapse(
                at: target, animated: true, velocity: collapse.snapVelocity(scrollVelocity: velocity.y, toward: target)
            )
        }
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === pageScrollView else { return }
        // The bar came back at the end under the finger: the page rises now, unless the finger
        // left the end.
        if let riseFromEnd {
            if scrollView.contentOffset.y >= riseFromEnd - 1 { riseToEnd(scrollView) } else { self.riseFromEnd = nil }
        }
        guard !decelerate else { return }
        applyPendingInset()
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === pageScrollView else { return }
        applyPendingInset()
    }

    public func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        expandChrome(animated: true)
    }

    /// A status bar tap while the bar is hidden brings the bar back and keeps the reader's place;
    /// the next tap scrolls to the top (as in DuckDuckGo and Brave).
    public func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        guard scrollView === pageScrollView, collapse.rest == .hidden else { return true }
        revealChrome(.statusBar)
        return false
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
        dropLaunchCover(animated: true)
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
                    self.lastPageMarks = nil
                    return completion(self.pageMenuElements(marks: nil, source: source))
                }
                // One indexed read off the main thread; the menu shows when it answers. If the
                // page changed meanwhile, the answer is for another page: leave the items out.
                Task { [weak self, data] in
                    let marks = await data.pageMarks(for: url)
                    guard let self else { return completion([]) }
                    let answer = self.currentTab?.url == url ? marks : nil
                    self.lastPageMarks = answer
                    completion(self.pageMenuElements(marks: answer, source: source))
                }
            },
        ])
    }

    /// The menu's items. `marks` is nil when there is no page that can be a favorite or saved.
    func pageMenuElements(marks: PageMarks?, source: PageMenuSource) -> [UIMenuElement] {
        let history = UIAction(title: "History", image: UIImage(systemName: "clock")) { [weak self] _ in
            self?.showHistory()
        }
        history.accessibilityIdentifier = "menu.history"
        let readingList = UIAction(title: "Reading List", image: UIImage(systemName: "eyeglasses")) { [weak self] _ in
            self?.showReadingList()
        }
        readingList.accessibilityIdentifier = "menu.readingList"
        let settings = UIAction(title: "Settings", image: UIImage(systemName: "gearshape")) { [weak self] _ in
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
            for item in [history, readingList, favorites, settings] { item.attributes = .disabled }
        }
        // The app's own places, always there and rarely needed mid-page: one row of four symbols
        // (a captioned row holds only three), with Downloads (and its progress) above it while
        // there are any. Safari's symbols for each; VoiceOver reads the names.
        favorites.title = "Favorites"
        favorites.accessibilityLabel = "Edit Favorites"
        let appRow = UIMenu(options: .displayInline, children: [history, readingList, favorites, settings])
        appRow.preferredElementSize = .small
        let downloads = downloadsMenuItems()
        let app = UIMenu(options: .displayInline, children: downloads.isEmpty ? [appRow] : downloads + [appRow])
        // Every item below follows docs/state-rules.md §4 through ControlRules: items that never
        // apply to this page are left out, Stop takes Reload's place while loading.
        let rules = currentRules()
        // The tabs items first: New Private Tab, Reopen Closed Tab, Archived Tabs where they apply.
        let tabItems = tabItemsForMore(rules)
        let top = UIMenu(options: .displayInline, children: tabItems)
        if tabItems.count > 1 {
            for case let action as UIAction in tabItems { Self.caption(action) }
            top.preferredElementSize = .medium
        }
        guard rules.shareAndCopy, let tab = currentTab, let url = pageAddress else {
            // An empty pane of a split can still be swapped or closed.
            let paneItems = paneMenuItems(for: nil, rules: rules)
            return [top] + (paneItems.isEmpty ? [] : [UIMenu(options: .displayInline, children: paneItems)]) + [app]
        }
        var pageItems: [UIMenuElement] = []
        var reload: UIAction?
        switch rules.reload {
        case .reload:
            let action = UIAction(title: "Reload", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                Signposts.signposter.emitEvent(Signposts.reload)
                self?.reloadPage()
            }
            action.accessibilityIdentifier = "menu.reload"
            reload = action
        case .stop:
            let action = UIAction(title: "Stop", image: UIImage(systemName: "xmark")) { [weak tab] _ in
                Signposts.signposter.emitEvent(Signposts.reload, "stop")
                tab?.stopLoading()
            }
            action.accessibilityIdentifier = "menu.stop"
            reload = action
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
        pageItems += translateMenuItems(for: tab, item: rules.translate)
        // Find on Page, Show Reader and Translate Page share one captioned row when two or more
        // apply, so the menu fits the Duo's outer screen on an article in another language
        // (Print and Save as PDF are in the share sheet). The full names stay for VoiceOver.
        if pageItems.count > 1 {
            for case let action as UIAction in pageItems { Self.caption(action) }
            let row = UIMenu(options: .displayInline, children: pageItems)
            row.preferredElementSize = .medium
            pageItems = [row]
        }
        if rules.savePDF { pageItems += pdfMenuItems(for: tab) }
        let share = UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
            guard let self else { return }
            let source: (any UIPopoverPresentationControllerSourceItem)? =
                self.usesVerticalBar ? self.barItems[.more] : self.buttonBar.button(.more)
            self.share(from: source)
        }
        share.accessibilityIdentifier = "menu.share"
        let copy = UIAction(title: "Copy Link", image: UIImage(systemName: "link")) { _ in
            Signposts.signposter.emitEvent(Signposts.copyLink)
            UIPasteboard.plain.url = url
            Haptic.success.play()
        }
        copy.accessibilityIdentifier = "menu.copyLink"
        let siteItems = siteMenuItems(
            for: tab, url: url, desktop: rules.desktopSite, blocking: rules.blockingToggle, darkPages: rules.darkPages
        )
        let paneItems = paneMenuItems(for: tab, rules: rules)
        var keepItems: [UIMenuElement] = []
        if rules.favorite, let isFavorite = marks?.isFavorite {
            let title = tab.title
            let favorite = UIAction(
                title: isFavorite ? "Remove from Favorites" : "Add to Favorites",
                image: UIImage(systemName: isFavorite ? "star.slash" : "star")
            ) { [weak self] _ in
                self?.setFavorite(!isFavorite, url: url, title: title)
            }
            favorite.accessibilityIdentifier = "menu.favorite"
            keepItems.append(favorite)
        }
        if rules.readLater, let isSaved = marks?.isSaved {
            let readLater = UIAction(
                title: isSaved ? "Remove from Reading List" : "Read Later",
                image: UIImage(systemName: isSaved ? "eyeglasses.slash" : "eyeglasses")
            ) { [weak self, weak tab] _ in
                guard let self, let tab else { return }
                if isSaved { self.removeFromReadingList(url) } else { self.saveForLater(tab, url: url) }
            }
            readLater.accessibilityIdentifier = "menu.readLater"
            keepItems.append(readLater)
        }
        // The menu fits the Duo's outer screen (docs/ui-reference.md, page menu): the most used
        // actions are one row, the per-site choices one submenu, the app's places one row.
        var sections: [UIMenuElement] = []
        let actions = UIMenu(options: .displayInline, children: (reload.map { [$0] } ?? []) + [share, copy])
        actions.preferredElementSize = .medium
        sections.append(actions)
        if !pageItems.isEmpty { sections.append(UIMenu(options: .displayInline, children: pageItems)) }
        if rules.zoom { sections.append(zoomMenu(for: tab, source: source)) }
        // What the user keeps or sets for this page, Add to Favorites, Read Later and Site
        // Settings, share one captioned row when two or more apply ("Favorite", "Read Later",
        // "Site"), so keeping a page costs the menu no extra line on the Duo's outer screen.
        // VoiceOver reads the full names and the site.
        let siteMenu = siteItems.count > 1 ? url.host() : nil
        let inRow = keepItems.count + (siteMenu == nil ? 0 : 1) > 1
        var placeItems: [UIMenuElement] = keepItems
        if let host = siteMenu {
            // Desktop Site, blocking and dark pages: set once per site, then remembered.
            let site = UIMenu(
                title: inRow ? String(localized: "Site") : "Site Settings", subtitle: inRow ? nil : Self.siteName(host),
                image: UIImage(systemName: "slider.horizontal.3"), children: siteItems
            )
            site.accessibilityIdentifier = "menu.siteSettings"
            site.accessibilityLabel = "Site Settings, " + Self.siteName(host)
            placeItems.append(site)
        } else {
            placeItems += siteItems
        }
        if inRow {
            for case let action as UIAction in keepItems { Self.caption(action) }
            let row = UIMenu(options: .displayInline, children: placeItems)
            row.preferredElementSize = .medium
            placeItems = [row]
        }
        placeItems += paneItems
        if !placeItems.isEmpty { sections.append(UIMenu(options: .displayInline, children: placeItems)) }
        return [top] + sections + [app]
    }

    /// Shortens a page item to its one-line caption for a row of three ("Find on Page" reads
    /// "Find", "Translate Page" "Translate"); VoiceOver keeps the full name and the subtitle.
    static func caption(_ action: UIAction) {
        let captions = [
            "Find on Page": String(localized: "Find"), "Translate Page": String(localized: "Translate"),
            "Show Original": String(localized: "Original"), "Show Reader": String(localized: "Reader"),
            "New Private Tab": String(localized: "Private Tab"), "Reopen Closed Tab": String(localized: "Reopen Tab"),
            "Archived Tabs": String(localized: "Archive"),
            "Add to Favorites": String(localized: "Favorite"), "Remove from Favorites": String(localized: "Unfavorite"),
            "Remove from Reading List": String(localized: "Unsave"),
        ]
        action.accessibilityLabel = [action.title, action.subtitle].compactMap { $0 }.joined(separator: ", ")
        action.title = captions[action.title] ?? action.title
        action.subtitle = nil
    }

    /// A site's name as the pill shows it: the host without `www.`.
    static func siteName(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
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

    /// Read Later: saves the page with its article as a reader copy when it has one (the reader's
    /// own extraction, already done when the reader is open), else as a link. The extraction runs
    /// in the page's web content process and the encoding off the main thread.
    private func saveForLater(_ tab: Tab, url: URL) {
        let signposter = Signposts.signposter
        let state = signposter.beginInterval(Signposts.readingListSave)
        // Only a page whose readerable check said yes is parsed: no 90 KB Readability run on a page
        // with no article.
        let page = currentRules().reader != .hidden ? session.pool.webView(for: tab) : nil
        let title = tab.title
        Haptic.success.prepare()
        Task { [weak self, session, data] in
            var article: ReaderArticle?
            if let page { article = try? await session.reader.article(in: page) }
            let saved = await Self.savedPage(url: url, title: title, article: article)
            let ok = await data.saveForLater(saved)
            if saved.copy == nil {
                signposter.endInterval(Signposts.readingListSave, state, "link")
            } else {
                signposter.endInterval(Signposts.readingListSave, state, "copy")
            }
            if ok { Haptic.success.play() } else { Haptic.nothingThere.play() }
            if ok, self?.currentTab?.url == url { self?.lastPageMarks?.isSaved = true }
        }
    }

    /// The page to save, with `article` encoded as its reader copy. Encoding a long article takes
    /// a few milliseconds, so it runs off the main thread.
    @concurrent
    nonisolated private static func savedPage(url: URL, title: String, article: ReaderArticle?) async -> SavedPage {
        guard let article, let copy = try? JSONEncoder().encode(article) else {
            return SavedPage(url: url, title: title.isEmpty ? nil : title)
        }
        return SavedPage(
            url: url, title: title.isEmpty ? article.title : title, siteName: article.siteName,
            excerpt: article.excerpt, copy: copy, copyLength: article.textLength
        )
    }

    private func removeFromReadingList(_ url: URL) {
        Signposts.signposter.emitEvent(Signposts.readingListRemove)
        Task { [weak self, data] in
            if await data.removeFromReadingList(url: url) {
                Haptic.success.play()
                if self?.currentTab?.url == url { self?.lastPageMarks?.isSaved = false }
            } else {
                Haptic.nothingThere.play()
            }
        }
    }

    // MARK: Feature sheets

    private func showReadingList() {
        let list = sheets.readingList(
            onOpen: { [weak self] url in
                self?.closeSheet { self?.load(url) }
            },
            onDone: { [weak self] in self?.closeSheet() }
        )
        present(list, signpost: Signposts.readingListShow)
    }

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
        // The page's title heads the sheet, as in Safari; a failed page has only the address tried.
        let title = currentTab.flatMap { $0.loadError == nil && !$0.title.isEmpty ? $0.title : nil }
        let item = PageShareItem(url: url, title: title)
        // Print and Save as PDF live here, where Safari and Chrome keep them (state rules §4).
        let sheet = UIActivityViewController(activityItems: [item], applicationActivities: exportActivities(currentRules()))
        sheet.completionWithItemsHandler = { [weak self, weak sheet] type, completed, _, _ in
            guard completed, let type, let sheet else { return }
            self?.runExportActivity(type, after: sheet)
        }
        sheet.popoverPresentationController?.sourceItem = source ?? pill
        present(sheet, animated: true)
    }
}
#endif
