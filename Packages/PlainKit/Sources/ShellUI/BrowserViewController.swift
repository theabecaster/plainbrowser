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
/// search sheet the pill grows into (`+SearchSheet`).
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
    /// The window moved to another profile and its history database is open: the app points
    /// Spotlight, the widgets and Shortcuts at that profile's favorites.
    public var onProfileDatabaseChange: ((AppDatabase) -> Void)?
    private let onLaunchReady: () -> Void

    /// The page panes: one, or two in a split on the Duo's inner screen (`+Panes`).
    let panes = PanesController()
    /// The Duo layout: panes, sidebar, the chrome's lane, folds (`+Panes`, `+SideTabs`).
    let duo = DuoUIState()
    /// The side pane beside the page on a wide screen (`+SidePane`).
    let sidePaneUI = SidePaneUIState()
    /// The keyboard shortcuts' focus, the system's undo for a close, the pinch to the overview
    /// and the history menus (`+KeyCommands`, `+Gestures`).
    let gestureUI = GestureUIState()
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
    let summaryUI = SummaryUIState()
    /// The gallery, the bar swipe, neighbour previews and the toast.
    let tabsUI = TabsUIState()
    /// Dark Pages' suggestion and crossfades (`+DarkPages`).
    let darkPagesUI = DarkPagesUIState()
    /// What launch opened to: the last tab's picture and the fresh search's frost (`+Launch`).
    let launchUI = LaunchUIState()
    /// What the focused address bar offers before typing, and whether it edits the page's
    /// address (`+AddressFocus`).
    let focusUI = AddressFocusState()
    /// The page sheet's last favorite and reading list answer, for rebuilding the open sheet.
    var lastPageMarks: PageMarks?
    /// The page sheet while it is up, so a change under it (zoom) shows at once.
    weak var pageSheet: PageSheetController?
    /// Show Tabs asked for before the saved tabs were in (a cold launch from Siri); it runs once
    /// they are (`+System`).
    var showTabsAwaitingSession = false
    /// docs/state-rules.md for the state last applied (`updateButtons`), for hot paths such as
    /// pull to refresh that must not walk the tab list on every scroll callback.
    var rules = ControlRules(ChromeState())

    // Layout.
    private var pillOnBar: NSLayoutConstraint!
    private var pillOnEdge: NSLayoutConstraint!
    /// The pill as the open sheet's field: its top from the root view's top (`+SearchSheet`).
    private var pillOpenTop: NSLayoutConstraint!
    /// The chrome's row: the lane less its margins, at most 640 pt, centered.
    let chromeRow = UILayoutGuide()
    /// The pill's frame as the root view's layout has it. The pill sits two levels down (inside
    /// the glass container), where a frame is applied only after the root view's own pass; a
    /// guide of the root view answers from the layout itself, in `viewDidLayoutSubviews` too.
    let pillFrameGuide = UILayoutGuide()
    /// The button bar's own constraints, activated again when it comes back after a vertical bar.
    private var buttonBarConstraints: [NSLayoutConstraint] = []
    /// The chrome's row: the lane less its margins, at most 640 pt, centered. The pill and the bar
    /// span it on a page; on the start screen the bar shrinks to its trailing end, beside the pill.
    private var pillSpansRow: NSLayoutConstraint!
    private var pillBesideBar: NSLayoutConstraint!
    private var barSpansRow: NSLayoutConstraint!
    /// The pill's leading edge on the bottom row (off while the top bar holds it, `+TopBar`).
    private var pillOnRowLeading: NSLayoutConstraint!
    /// The pill between the split bar's capsules in the single bottom row (compact height).
    private var pillInSingleRow: [NSLayoutConstraint] = []
    /// Set while `applyEditingLayout` runs, which lays out the bar's shape in its own animation.
    private var isApplyingEditingLayout = false
    private(set) var geometry = ChromeGeometry(viewHeight: 0, safeBottom: 0, hasButtonBar: true)
    private(set) var usesVerticalBar = false

    // State.
    private(set) var isEditingAddress = true
    private var didFocusAtLaunch = false
    private var didWarmUp = false
    /// The search sheet's open and close: one progress value, driven frame by frame (`+SearchSheet`).
    let sheetUI = SearchSheetUIState()
    private var collapse = ChromeCollapse()
    private var collapseInterval: OSSignpostIntervalState?
    /// Runs the toolbar snap frame by frame, so a drag can take the bar from where it is on screen.
    private let snap = SpringDriver(spring: Motion.toolbarSnap)
    private var snapInterval: OSSignpostIntervalState?
    /// Which resting state the page's bottom inset follows, and a change waiting for a bounce.
    private var pageInset = PageInsetState()
    /// Each page scroll view's vertical offset at its last scroll callback under the top bar, so
    /// `keepPageTopUnderBar` acts only on a move to WebKit's top, not on a page left there. Weak
    /// keys: a web view's scroll view leaves with it.
    private let lastPageOffsetY = NSMapTable<UIScrollView, NSNumber>.weakToStrongObjects()
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
    /// The pull's haptics are readied for this pull (once, past half the threshold).
    private var pullHapticPrepared = false
    private var suggestionTask: Task<Void, Never>?
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
        installSidePane()
        prepareLaunch()

        revealEdge.isUserInteractionEnabled = false
        revealEdge.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(revealEdgeTapped)))
        pill.textField.delegate = self
        pill.textField.addTarget(self, action: #selector(queryChanged), for: .editingChanged)
        pill.onTap = { [weak self] in self?.pillTapped() }
        pill.onDarkPagesTap = { [weak self] in
            guard let self, let tab = self.currentTab else { return }
            self.toggleDarkPages(for: tab, source: "indicator")
        }
        pill.onCopy = { [weak self] in self?.copyFieldAddress() }
        pill.onBrowse = { [weak self] in self?.toggleBrowseArmed() }
        pill.onMic = { [weak self] in self?.toggleDictation() }
        pill.onEscape = { [weak self] in self?.dismissSearchSheet(.escape) }
        pill.searchQuery = { [weak self] url in self?.data.searchEngine.query(inResults: url) }
        pill.onLongPress = { [weak self] in
            guard let self else { return }
            self.showPageSheet(from: self.pill)
        }

        sheet.onPick = { [weak self] pick in
            guard let self, !self.handleFocusPick(pick) else { return }
            self.open(pick)
        }
        sheet.onBrowse = { [weak self] query in self?.browseForMe(query) }
        sheet.onDismiss = { [weak self] how in self?.dismissSearchSheet(how) }
        sheet.onPan = { [weak self] pan in self?.searchSheetPanned(pan) }
        installSearchSheetGestures()
        sheet.onEditFavorites = { [weak self] in self?.showFavoritesEditor(editing: true) }

        buildButtons()
        installGestures()
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
        data.observeSettings { [weak self] in self?.settingsDidChange() }
        observeAppearance()

        tabsUI.swipe.browser = self
        tabsUI.swipe.install(on: [pill, buttonBar])
        tabsUI.openerSwipe.install(on: view, browser: self)
        session.tabs.onChange = { [weak self] in self?.tabsDidChange() }
        wireProfiles()
        // Which private sites were told a feature is off ends with the private session.
        session.privateSessionDidEnd = { [weak self] in self?.engineUI.privateAccessNotices = SystemAccessNoticeMemory() }
        session.summaries.onAvailabilityChange = { [weak self] in self?.summaryAvailabilityChanged() }
        session.pool.onTranslationFailed = { [weak self] tab in
            guard let self, tab === self.currentTab else { return }
            Haptic.nothingThere.play()
            self.showToastWhenFree { [weak self] in self?.tabsUI.toast.show("This page couldn't be translated") }
        }
        session.pool.onMemoryWarning = { [weak self] in
            self?.tabsUI.previews = [:]
            self?.tabsUI.fullPreviews = []
            self?.dropSpareGallery()
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
        // Another app may have copied a link (checked without reading it).
        refreshCopiedLink()
    }

    private func layOut() {
        let safe = view.safeAreaLayoutGuide
        // Their constants make room for the sidebar (either side) and the tab strip (`+Panes`).
        duo.panesLeading = panes.view.leadingAnchor.constraint(equalTo: safe.leadingAnchor)
        duo.panesTrailing = panes.view.trailingAnchor.constraint(equalTo: safe.trailingAnchor)
        // The panes run under the status bar on every screen: the page goes to the top edge, as in
        // Safari, and the status bar floats over it (docs/decisions.md, "The page's top inset
        // never follows the bar").
        duo.panesTop = panes.view.topAnchor.constraint(equalTo: view.topAnchor)
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
        pillOpenTop = pill.topAnchor.constraint(equalTo: view.topAnchor)

        // The chrome's lane: the focused pane, off an active fold and the camera (`DuoLayout`).
        let lane = duo.chromeLane
        view.addLayoutGuide(lane)
        duo.laneLeading = lane.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        // Set before every layout pass (`updateDuoLayout`, from `viewWillLayoutSubviews`).
        duo.laneWidth = lane.widthAnchor.constraint(equalToConstant: 0)

        let row = chromeRow
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

            // The panes fill the view from its top edge, under the status bar, and beside a
            // vertical bar and the sidebar. Their bottom runs under the chrome; obscuredContentInsets tells WebKit what
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

            duo.top.pillHeight as NSLayoutConstraint,

            // The toast floats just above the pill, centered on it (under a top bar: low on the
            // page, `+TopBar`).
            duo.top.toastOverPill as NSLayoutConstraint,
            tabsUI.toast.centerXAnchor.constraint(equalTo: pill.centerXAnchor),
            tabsUI.toast.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.tapTarget),
            tabsUI.toast.widthAnchor.constraint(lessThanOrEqualTo: pill.widthAnchor),
        ] + capWidth(centerX: row.centerXAnchor, width: row.widthAnchor))

        view.addLayoutGuide(pillFrameGuide)
        NSLayoutConstraint.activate([
            pillFrameGuide.topAnchor.constraint(equalTo: pill.topAnchor),
            pillFrameGuide.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            pillFrameGuide.widthAnchor.constraint(equalTo: pill.widthAnchor),
            pillFrameGuide.heightAnchor.constraint(equalTo: pill.heightAnchor),
        ])
        pillSpansRow = pill.trailingAnchor.constraint(equalTo: row.trailingAnchor)
        pillBesideBar = pill.trailingAnchor.constraint(equalTo: buttonBar.leadingAnchor, constant: -ChromeGeometry.gap)
        barSpansRow = buttonBar.leadingAnchor.constraint(equalTo: row.leadingAnchor)
        pillOnRowLeading = pill.leadingAnchor.constraint(equalTo: row.leadingAnchor)
        // A fixed place, room for both of Back and Forward, so the pill never moves when Forward
        // comes and goes (state rules, principle 5).
        pillInSingleRow = [
            pill.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: ButtonBar.splitLeadingWidth + ChromeGeometry.gap),
            pill.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -(ButtonBar.splitTrailingWidth + ChromeGeometry.gap)),
        ]
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
                // The page sheet: the address row, the page's actions, then the app's places.
                button.addAction(UIAction { [weak self, weak button] _ in
                    self?.showPageSheet(from: button)
                }, for: .primaryActionTriggered)
                let action = UIAction(title: kind.title, image: UIImage(systemName: kind.symbol)) { [weak self] _ in
                    self?.showPageSheet()
                }
                item = UIBarButtonItem(primaryAction: action)
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
            case .newTab:
                // A tap opens a tab of the kind on screen, as the swipe past the last tab does; a
                // long press offers the other kind (docs/research/new-tab.md).
                let action = UIAction(title: kind.title, image: UIImage(systemName: kind.symbol)) { [weak self] _ in
                    self?.newTabButtonTapped()
                }
                button.addAction(action, for: .primaryActionTriggered)
                button.menu = newTabButtonMenu()
                button.showsMenuAsPrimaryAction = false
                item = UIBarButtonItem(primaryAction: action, menu: newTabButtonMenu())
            case .back, .forward:
                let action = UIAction(title: kind.title, image: UIImage(systemName: kind.symbol)) { [weak self] _ in
                    kind == .back ? self?.goBack() : self?.goForward()
                }
                button.addAction(action, for: .primaryActionTriggered)
                item = UIBarButtonItem(primaryAction: action)
            }
            item.axisBehavior = .verticalPreferred
            // Back, Forward and Tabs overflow last (docs/research/design-audit.md, Duo).
            item.visibilityPriority = kind == .more ? .standard : .high
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
        if changed { updateStatusBarForStart() }
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

    /// Compact height (an iPhone on its side): one bottom row, Back and Forward, the pill, then
    /// Tabs, Share and More, as Safari keeps one row there; the two rows took about 40% of the
    /// height (ux-audit item 12). The start screen keeps its own one-row shape, More beside the
    /// pill.
    var usesSingleRow: Bool {
        !usesVerticalBar && !chromeOnTop && traitCollection.verticalSizeClass == .compact && buttonBar.superview != nil
    }

    func updatePillRestConstraint() {
        let onTop = chromeOnTop
        let hasBar = buttonBar.superview != nil
        let beside = sheetUI.barBeside.map { $0 && !onTop && hasBar } ?? restingBarBeside
        let singleRow = usesSingleRow && !beside
        // The open sheet's field: the pill at the sheet's top. Under a top bar the pill stays in
        // the bar's row, widens to the field's size, and the sheet grows down from it.
        let open = sheetUI.isLaidOutOpen
        let pillOnTop = onTop
        pillOpenTop.isActive = false
        pillOnBar.isActive = false
        pillOnEdge.isActive = false
        pillOnRowLeading.isActive = false
        pillSpansRow.isActive = false
        pillBesideBar.isActive = false
        NSLayoutConstraint.deactivate(pillInSingleRow)
        if hasBar { NSLayoutConstraint.deactivate(buttonBarConstraints) }
        setTopBarConstraints(pill: pillOnTop, bar: onTop && hasBar, open: open)
        if pillOnTop {
            // The top bar places it.
        } else if open {
            pillOpenTop.isActive = true
        } else if usesVerticalBar || beside || singleRow {
            pillOnEdge.isActive = true
        } else {
            pillOnBar.isActive = true
        }
        // The start screen's bar: a round glass button at the row's end, the pill beside it.
        // Under a top bar: two capsules at the row's ends.
        // Compact height: the same two capsules at the bottom row's ends, the pill between them.
        buttonBar.setSplit((onTop || singleRow) && hasBar, packsLeading: !singleRow)
        buttonBar.setBesidePill(beside)
        if singleRow, !open {
            NSLayoutConstraint.activate(pillInSingleRow)
        } else if !pillOnTop {
            pillOnRowLeading.isActive = true
            if beside, !open { pillBesideBar.isActive = true } else { pillSpansRow.isActive = true }
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
        let beside = restingBarBeside
        guard pillOnBar != nil, beside != buttonBar.isBesidePill, !isApplyingEditingLayout, !sheetUI.isLaidOutOpen else { return }
        updatePillRestConstraint()
        guard view.window != nil else { return }
        Motion.animate(Motion.reflow) { self.view.layoutIfNeeded() }
    }

    override public func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // Every Duo state comes from the bounds, size classes and the fold's regions here.
        updateDuoLayout()
        // The open sheet's field, before the pass that places it.
        let fieldTop = searchFieldTop
        if pillOpenTop.constant != fieldTop { pillOpenTop.constant = fieldTop }
    }

    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let next = ChromeGeometry(
            viewHeight: view.bounds.height, safeBottom: view.safeAreaInsets.bottom,
            hasButtonBar: !usesVerticalBar && !usesSingleRow
        )
        let top = duo.layout?.chromeOnTop == true
            ? makeTopGeometry(stripHeight: duo.layout?.stripHeight ?? 0) : nil
        // The open sheet follows every pass: the bounds, the lane, the keyboard's layout.
        layOutSearchSheet()
        guard next != geometry || top != duo.topGeometry else { return }
        geometry = next
        duo.topGeometry = top
        if let top { logTopChrome(top) }
        applyCollapse(collapse.progress)
        // During a fold or rotation the insets wait for the transition's completion.
        if !duo.isResizing { updatePageInsets() }
    }

    /// Off where the top bar holds the buttons (`+TopBar`): the Duo's inner screen, as Safari.
    override public var preferredVerticalBarBehavior: UIVerticalBarBehavior {
        wantsHorizontalBars ? .disabled : .automatic
    }

    /// Light over the private start screen, which is always drawn dark; otherwise the system's.
    override public var preferredStatusBarStyle: UIStatusBarStyle {
        tabsUI.prefersLightStatusBar ? .lightContent : .default
    }

    /// Every sheet, menu and alert the browser presents: the suggestion gives way to it.
    override public func present(_ viewController: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {
        hideDarkPagesSuggestion()
        super.present(viewController, animated: animated, completion: completion)
    }

    override public func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        // A fold, unfold or rotation: the suggestion would point at the wrong place, and a
        // crossfade's picture would no longer fit the page.
        hideDarkPagesSuggestion()
        removeDarkPagesFades()
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
        // After the first frame: whether the field's microphone can run here.
        prepareDictation()
        // The keys (and the system's undo) have a home from launch on, unless the field has them.
        claimKeyFocusIfFree()
    }

    /// Call when the address bar's data changed outside the shell (the database opened), so an
    /// open search sheet shows the favorites.
    public func addressBarDataDidChange() {
        // The settings are in: idle tabs can move to the archive.
        archiveIdleTabs()
        // Favorites and recent pages for the next focus (an open field takes them at once).
        refreshFocusContent()
    }

    // MARK: Address bar

    func pillTapped() {
        // A collapsed bar first comes back, as Safari's does; the next tap edits. A bar already
        // springing back out takes the tap as an edit.
        let restingProgress = snap.isRunning ? snap.target : collapse.progress
        if restingProgress > 0 {
            expandChrome(animated: true)
            return
        }
        let interval = Signposts.signposter.beginInterval(Signposts.urlBarFocus)
        OpenIntervals.begin(Signposts.urlBarReady, until: UIResponder.keyboardDidShowNotification)
        OpenIntervals.begin(Signposts.urlBarKeyboardStart, until: UIResponder.keyboardWillShowNotification)
        // On a page the field opens with its address, all selected, Copy inside it: typing over
        // it goes somewhere new, in a new tab (Arc); editing part of it changes this page, in the
        // same tab (docs/decisions.md, "The page's address in the field"). On the start screen
        // it opens empty and loads in place.
        let overPage = currentTab.map { !session.tabs.isEmpty($0.id) } ?? false
        focusUI.selectsAllOnOpen = true
        launchUI.isFreshSearch = false
        if overPage, let address = pageAddress, let query = data.searchEngine.query(inResults: address) {
            // On the engine's results page the search comes back, selected, to refine in place
            // (Safari): a new query replaces the results rather than stacking tabs of them.
            focusUI.intent = nil
            pill.textField.text = query
        } else if overPage, let address = pageAddress {
            focusUI.intent = .pageAddress
            focusUI.openedAddress = address.absoluteString
            pill.textField.text = address.absoluteString
        } else {
            focusUI.intent = nil
            pill.textField.text = ""
        }
        updateFieldAccessory()
        updateStartScreen()
        // The sheet is laid out open and starts to grow in this frame; the keyboard follows on
        // its own.
        applyEditingLayout(true, animated: true)
        if !pill.beginEditing() { applyEditingLayout(false, animated: false) }
        Signposts.signposter.endInterval(Signposts.urlBarFocus, interval)
    }

    public func textFieldDidBeginEditing(_ textField: UITextField) {
        // The address bar's data is the app's: this window's private state wins while it types.
        data.isPrivate = pill.isPrivateTint
        // First, so a preconnect to the suggestion host overlaps the sheet opening.
        data.prepareForTyping()
        sheet.session += 1
        applyEditingLayout(true, animated: didFocusAtLaunch)
        if let text = textField.text, !text.isEmpty, focusUI.selectsAllOnOpen {
            // A keyboard that composes (Japanese, Chinese, Korean) needs UIKit's own replacement
            // of a real selection, so its text is selected at once.
            let language = textField.textInputMode?.primaryLanguage ?? ""
            let composes = ["ja", "zh", "ko"].contains { language.hasPrefix($0) }
            if sheetUI.driver.value < 1, !composes {
                // Selected once the field is at rest (`searchSheetDidSettleOpen`); until then a
                // keystroke replaces it all the same, and no caret rides along.
                focusUI.pendingSelection = text
                pill.holdSelectionHighlight(true)
            } else {
                textField.selectAll(nil)
            }
        } else if !focusUI.selectsAllOnOpen {
            // The page sheet's Edit: the caret at the end, whatever the field kept from before.
            let end = textField.endOfDocument
            textField.selectedTextRange = textField.textRange(from: end, to: end)
        }
        // The content is already in memory (`refreshFocusContent`); only the pasteboard is asked
        // again, without reading it.
        refreshCopiedLink()
        queryChanged()
        // The rows are in place on the sheet's first frame.
        sheet.applyPendingNow()
    }

    public func textFieldDidEndEditing(_ textField: UITextField) {
        suggestionTask?.cancel()
        data.cancelSuggestions()
        sheet.session += 1
        focusUI.intent = nil
        focusUI.pendingSelection = nil
        pill.holdSelectionHighlight(false)
        focusUI.browseArmed = false
        focusUI.dictation.stop()
        updateFieldAccessory()
        updateStartForTyping(query: "")
        applyEditingLayout(false, animated: true)
        // Any end of editing settles the new tab; only the user's own close goes back first
        // (`dismissSearchSheet`, which reads it before ending).
        tabsUI.newTabReturn = nil
        claimKeyFocusIfFree()
    }

    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let signposter = Signposts.signposter
        let state = signposter.beginInterval(Signposts.addressSubmit)
        // Browse for Me armed from the field: Return browses for what would search.
        if focusUI.browseArmed, session.summaries.isAvailable,
           let query = textField.text?.trimmingCharacters(in: .whitespacesAndNewlines), Self.isSearch(query) {
            signposter.endInterval(Signposts.addressSubmit, state, "browse")
            browseForMe(query)
            return false
        }
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

    /// The first change to the page's address decides whether the field is a new query or an
    /// edit of this page (`AddressFieldIntent`), from the span the change replaces: the opening
    /// selection, the user's own, or a caret.
    public func textField(
        _ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String
    ) -> Bool {
        if let opened = focusUI.pendingSelection {
            focusUI.pendingSelection = nil
            if textField.text == opened, textField.markedTextRange == nil {
                // Typed before the selection was drawn: it replaces the whole text, as it would
                // have over the selection.
                let length = (opened as NSString).length
                if let intent = focusUI.intent, let address = focusUI.openedAddress {
                    setFieldIntent(intent.after(replacing: 0..<length, of: length, result: string, pageAddress: address))
                }
                pill.holdSelectionHighlight(false)
                textField.text = string
                queryChanged()
                return false
            }
        }
        guard let intent = focusUI.intent, let address = focusUI.openedAddress else { return true }
        let text = (textField.text ?? "") as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length else { return true }
        let result = text.replacingCharacters(in: range, with: string)
        setFieldIntent(intent.after(
            replacing: range.location..<NSMaxRange(range), of: text.length, result: result, pageAddress: address
        ))
        return true
    }

    public func textFieldDidChangeSelection(_ textField: UITextField) {
        // The user put the caret somewhere during the open: their choice, not the selection
        // Plain was about to make. (Opening leaves the caret at the end; only a move counts.)
        guard focusUI.pendingSelection != nil, let range = textField.selectedTextRange else { return }
        let end = textField.endOfDocument
        guard textField.compare(range.start, to: end) != .orderedSame || !range.isEmpty else { return }
        focusUI.pendingSelection = nil
        pill.holdSelectionHighlight(false)
    }

    public func textFieldShouldClear(_ textField: UITextField) -> Bool {
        // Cleared: a new query.
        if focusUI.intent != nil { setFieldIntent(.newQuery) }
        return true
    }

    @objc func queryChanged() {
        let query = pill.textField.text ?? ""
        suggestionTask?.cancel()
        // Emptied without a keystroke the delegate saw: a new query too.
        if query.isEmpty, focusUI.intent != nil { setFieldIntent(.newQuery) }
        // The current page's address, untouched, is not a query: show favorites, as for an
        // empty field, until the user types.
        let isCurrentAddress = !query.isEmpty && query == pageAddress?.absoluteString
        sheet.setFavoritesAllowed(query.isEmpty || isCurrentAddress)
        // Copy sits in the field while it still shows the page's own address; an empty field
        // offers its options; a typed one, the clear button.
        updateFieldAccessory()
        updateBrowseForMe(query: isCurrentAddress ? "" : query)
        guard !isCurrentAddress, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Before typing: never empty (docs/decisions.md, "Address focus").
            let items = focusItems()
            // The sheet covers the start screen's mark whatever it holds: the mark steps back.
            updateStartForTyping(query: query, showsRows: true)
            sheet.show(items: items)
            return
        }
        updateStartForTyping(query: query)
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.suggestionsShown)
        // The address bar's data is the app's: each query carries this window's private state, so
        // another window's tab never decides whether a private query leaves the device.
        let isPrivate = pill.isPrivateTint
        // Immediate: the body runs now, inside this keystroke's handling, up to the database
        // read, so the read overlaps the rest of UIKit's work on the keystroke instead of waiting
        // for it in the main queue first. Only the rows' arrival waits for the main thread.
        suggestionTask = Task.immediate { [weak self, data] in
            var shown = false
            await data.suggestions(for: query, isPrivate: isPrivate) { suggestions in
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

    func loadFavorites() {
        refreshFocusContent()
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
        default: return
        }
        guard let url else { return }
        let state = Signposts.signposter.beginInterval(Signposts.addressSubmit)
        goingSomewhereNew()
        load(url, kind: .typed)
        Signposts.signposter.endInterval(Signposts.addressSubmit, state, "picked")
    }

    /// A hardware keyboard: Command-L opens the search sheet (every browser's Open Location).
    /// Escape closes it (the field's own key, `AddressPill.onEscape`, and a key command for
    /// when the text system passes it on), and so does Command-period, iOS's other Cancel.
    /// `keyCommands` (`+KeyCommands`) adds these to the browser's other shortcuts.
    var searchKeyCommands: [UIKeyCommand]? {
        if isEditingAddress {
            let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelPressed))
            escape.wantsPriorityOverSystemBehavior = true
            let period = UIKeyCommand(
                title: String(localized: "Cancel"), action: #selector(cancelPressed), input: ".", modifierFlags: .command
            )
            period.wantsPriorityOverSystemBehavior = true
            return [escape, period]
        }
        guard canOpenLocation else { return nil }
        let open = UIKeyCommand(
            title: String(localized: "Open Location"), action: #selector(openLocationPressed), input: "l",
            modifierFlags: .command
        )
        return [open]
    }

    /// The bar is on screen to open from: not the gallery, a sheet, or Find on Page.
    private var canOpenLocation: Bool {
        !isEditingAddress && !sheetUI.isLaidOutOpen && !isShowingGallery && presentedViewController == nil
            && !currentRules().state.isFindOpen
    }

    @objc private func cancelPressed() {
        dismissSearchSheet(.escape)
    }

    @objc private func openLocationPressed() {
        guard canOpenLocation else { return }
        // A collapsed bar comes back at once: the key asked for the field, not for the bar.
        if collapse.progress > 0 || snap.isRunning { settleCollapse(at: 0, animated: false) }
        pillTapped()
    }

    /// Closes the search sheet: it shrinks back into the pill while the keyboard leaves.
    func endEditing() {
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
        focusUI.intent = nil
        focusUI.selectsAllOnOpen = true
        updateFieldAccessory()
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

    /// Moves between the resting pill and the open search sheet: the mode changes at once (the
    /// rules, the field's text and options), and the sheet grows from the pill or shrinks back
    /// into it (`+SearchSheet`).
    func applyEditingLayout(_ editing: Bool, animated: Bool) {
        let changed = editing != isEditingAddress
        isEditingAddress = editing
        // A fresh search lasts as long as its field: closing it uncovers the page.
        if !editing {
            launchUI.isFreshSearch = false
            focusUI.intent = nil
        }
        guard changed || !animated else { return }
        // Editing is a mode: the bar's controls and gestures follow the rules for it, and the start
        // screen's button and shortcuts step aside for the field.
        isApplyingEditingLayout = true
        updateButtons()
        isApplyingEditingLayout = false
        tabsUI.start.isSearchFieldActive = editing
        pill.setEditing(editing)
        if editing {
            settleCollapse(at: 0, animated: false)
            openSearchSheet(animated: animated)
        } else {
            closeSearchSheet(animated: animated)
        }
    }

    /// The chrome's place for the bar's own collapse, after the sheet let go of it.
    func restoreChromePlacement() {
        applyCollapse(collapse.progress)
    }

    // MARK: Page

    /// Loads `url` in the tab on screen. `.typed` when the address bar asked for it: that visit
    /// then weighs more in ranking.
    func load(_ url: URL, kind: VisitKind = .link) {
        // The new tab is being used: its field closing no longer goes back.
        tabsUI.newTabReturn = nil
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
            applyTopBarInsets(top)
            return
        }
        // Back from a top bar (a fold to the outer screen): the page's top rests at the top again.
        setPageTopStart(0, for: pageScrollView)
        // The reader's bottom inset was the top bar's own (`pageBottomInset`); the safe area is
        // back in its adjustment.
        engineUI.reader.webView?.scrollView.followObscuredBottom(0)
        for slot in panes.slots { slot.setRingTopInset(pageStatusInset) }
        duo.top.pullIndicatorTop.constant = pageStatusInset + Spacing.s
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
        // The suggestion sits by the whole bar; a bar on its way down takes it away.
        if progress > 0 { hideDarkPagesSuggestion() }
        // While the search sheet holds the pill and the bar, their place is its progress.
        guard !sheetUI.isLaidOutOpen else { return applyFocusProgress(sheetUI.driver.value) }
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
        hideDarkPagesSuggestion()
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
        // Any page under the top bar, a split's other pane and the reader too: WebKit's own move
        // to a page's top goes on to under the bar (its move back calls this again).
        if let top = duo.topGeometry {
            let previousY = lastPageOffsetY.object(forKey: scrollView)?.doubleValue
            lastPageOffsetY.setObject(NSNumber(value: Double(scrollView.contentOffset.y)), forKey: scrollView)
            if scrollView.keepPageTopUnderBar(webKitTop: top.obscuredInset, previousY: previousY.map { CGFloat($0) }) { return }
        }
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
        pullHapticPrepared = false
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
        guard scrollView === pageScrollView else { return }
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
        // Readied once per pull, when it passes half the threshold (haptics plan, §4).
        if distance > PullToRefreshTracker.threshold / 2, !pullHapticPrepared {
            pullHapticPrepared = true
            Haptic.threshold.prepare(in: view)
            Haptic.selection.prepare(in: view)
        } else if distance <= 0 {
            pullHapticPrepared = false
        }
        switch pullTracker.pulled(distance) {
        case .armed:
            // Into the outcome: the threshold; back out of it: a tick (haptics plan, rule 4).
            Haptic.threshold.play(in: view)
            Signposts.signposter.emitEvent(Signposts.pullToRefreshArm)
            pullIndicator.setArmed(true)
        case .disarmed:
            Haptic.selection.play(in: view)
            pullIndicator.setArmed(false)
        case nil:
            break
        }
    }

    private func refresh() {
        Signposts.signposter.emitEvent(Signposts.pullToRefresh)
        // It spins in its one color until the load ends (`+Tab`, `tabChanged`).
        pullIndicator.beginRefreshing()
        reloadPage()
    }

    // MARK: Buttons and page menu

    func goBack() {
        guard canGoBack else { return Haptic.nothingThere.play() }
        Signposts.signposter.emitEvent(Signposts.navBack)
        performBack()
    }

    func goForward() {
        guard let tab = currentTab, !isShowingReader, tab.canGoForward else { return Haptic.nothingThere.play() }
        Signposts.signposter.emitEvent(Signposts.navForward)
        dropLaunchCover(animated: true)
        tab.goForward()
    }

    /// The page sheet (docs/decisions.md, "Address focus and the page sheet"): from More, a long
    /// press on the pill or the Duo's top bar. It reads whether the page is a favorite first (one
    /// indexed read off the main thread), so the sheet opens complete.
    func showPageSheet(from source: (any UIPopoverPresentationControllerSourceItem)? = nil) {
        guard presentedViewController == nil else { return }
        if isEditingAddress { endAddressEditing() }
        Signposts.signposter.emitEvent(Signposts.pageMenu)
        Signposts.signposter.emitEvent(Signposts.pageSheet)
        // The address the items act on (`pageAddress`): under a saved copy over a failed load,
        // that is the page that failed, not the one the tab last showed.
        guard let url = pageAddress, LiveAddressBarData.isRecordable(url), currentRules().favorite else {
            lastPageMarks = nil
            return presentPageSheet(from: source)
        }
        Task { [weak self, data] in
            let marks = await data.pageMarks(for: url)
            guard let self else { return }
            // The page changed meanwhile: the answer is for another page.
            self.lastPageMarks = self.pageAddress == url ? marks : nil
            self.presentPageSheet(from: source)
        }
    }

    /// Where the sheet points from on a wide screen: More in the bar, or the pill.
    private var moreSource: any UIPopoverPresentationControllerSourceItem {
        if usesVerticalBar || chromeOnTop, let item = barItems[.more] { return item }
        let button = buttonBar.button(.more)
        return button.window == nil ? pill : button
    }

    private func presentPageSheet(from source: (any UIPopoverPresentationControllerSourceItem)?) {
        guard presentedViewController == nil else { return }
        let controller = PageSheetController { [weak self] in
            self?.pageSheetModel(marks: self?.lastPageMarks) ?? PageSheetModel()
        }
        controller.onEditAddress = { [weak self, weak controller] in
            // The field rises as the sheet goes down: one hand-over, no pause between.
            controller?.dismiss(animated: true)
            self?.beginEditingPageAddress()
        }
        // A wide screen (the Duo's inner screen): a popover under More, as Safari's page menu
        // there. Otherwise a bottom sheet over the dimmed page, sized to its content.
        if traitCollection.horizontalSizeClass == .regular {
            controller.modalPresentationStyle = .popover
            controller.popoverPresentationController?.sourceItem = source ?? moreSource
            controller.popoverPresentationController?.permittedArrowDirections = [.up, .down]
        } else {
            controller.modalPresentationStyle = .pageSheet
            if let sheet = controller.sheetPresentationController {
                sheet.prefersGrabberVisible = true
                sheet.preferredCornerRadius = Radius.large * 2
                sheet.detents = [.custom(identifier: .init("fitted")) { [weak controller] context in
                    guard let controller else { return context.maximumDetentValue }
                    return min(controller.fittingHeight(width: controller.view.bounds.width), context.maximumDetentValue)
                }]
                sheet.prefersScrollingExpandsWhenScrolledToEdge = false
            }
        }
        controller.onDismissed = { [weak self] in self?.sheetDidClose() }
        pageSheet = controller
        present(controller, animated: true)
    }

    /// The sheet's content: every item follows docs/state-rules.md §4 through ControlRules, built
    /// from the same actions the page menu had.
    func pageSheetModel(marks: PageMarks?) -> PageSheetModel {
        let rules = currentRules()
        var model = PageSheetModel()
        let history = UIAction(title: "History", image: UIImage(systemName: "clock")) { [weak self] _ in
            self?.showHistory()
        }
        history.accessibilityIdentifier = "menu.history"
        let readingList = readingListMenuItem()
        let settings = UIAction(title: "Settings", image: UIImage(systemName: "gearshape")) { [weak self] _ in
            self?.showSettings()
        }
        settings.accessibilityIdentifier = "menu.settings"
        // "Favorites": the sheet opens them (clarity audit 7); editing is inside it.
        let favorites = UIAction(title: "Favorites", image: UIImage(systemName: "star.square.on.square")) { [weak self] _ in
            self?.showFavoritesEditor()
        }
        favorites.accessibilityIdentifier = "menu.editFavorites"
        if !sheets.isReady {
            // The database is still opening (the first moments after launch).
            for item in [history, readingList, favorites, settings] { item.attributes = .disabled }
        }
        let tabItems = tabItemsForMore(rules).compactMap { $0 as? UIAction }
        let downloads: [PageSheetModel.Row] = downloadsMenuItems().compactMap { element in
            if let action = element as? UIAction { return .action(action) }
            if let menu = element as? UIMenu { return .menu(menu) }
            return nil
        }
        // The app's places close the sheet, under the tabs' places and the other windows.
        var tail: [PageSheetModel.Row] = downloads
        for case let inline as UIMenu in otherWindowsMenu() {
            for case let windows as UIMenu in inline.children { tail.append(.menu(windows)) }
        }
        if !tabItems.isEmpty { tail.append(tabItems.count > 1 ? .chips(tabItems) : .action(tabItems[0])) }
        tail.append(.chips([history, readingList, favorites, settings]))

        guard rules.shareAndCopy, let tab = currentTab, let url = pageAddress else {
            // An empty pane of a split can still be swapped or closed, and the side pane opened.
            let paneItems = paneMenuItems(for: nil, rules: rules) + sidePaneMenuItems(rules)
            model.rows = paneItems.compactMap { ($0 as? UIAction).map { .action($0) } } + tail
            return model
        }

        // The address row: Back, Forward, the host, Copy Link, Reload or Stop.
        var back: UIAction?
        if rules.back.isVisible {
            let action = UIAction(title: "Back", image: UIImage(systemName: "chevron.backward")) { [weak self] _ in self?.goBack() }
            if !rules.back.isEnabled { action.attributes = .disabled }
            action.accessibilityIdentifier = "pageSheet.back"
            back = action
        }
        var forward: UIAction?
        if rules.forward.isVisible {
            let action = UIAction(title: "Forward", image: UIImage(systemName: "chevron.forward")) { [weak self] _ in self?.goForward() }
            if !rules.forward.isEnabled { action.attributes = .disabled }
            action.accessibilityIdentifier = "pageSheet.forward"
            forward = action
        }
        let copy = UIAction(title: "Copy Link", image: UIImage(systemName: "link")) { [weak self] _ in self?.copyPageAddress() }
        copy.accessibilityIdentifier = "menu.copyLink"
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
            // Not an X: in a sheet's top corner an X reads as "close the sheet" (clarity audit 8).
            let action = UIAction(title: "Stop", image: UIImage(systemName: "stop.circle")) { [weak tab] _ in
                Signposts.signposter.emitEvent(Signposts.reload, "stop")
                tab?.stopLoading()
            }
            action.accessibilityIdentifier = "menu.stop"
            reload = action
        case .hidden:
            break
        }
        let host = url.host().map(Self.siteName) ?? url.absoluteString
        let notSecure = tab.security == .notSecure || tab.security == .certificateBypassed
        model.address = .init(
            host: host, notSecure: notSecure, profile: shownProfileName, back: back, forward: forward, copy: copy, reload: reload
        )

        // Tiles: the page actions people reach for most, at most four, Share always last.
        var tiles: [UIAction] = []
        if rules.findOnPage {
            let find = UIAction(title: "Find on Page", image: UIImage(systemName: "doc.text.magnifyingglass")) { [weak self] _ in
                self?.findOnPage()
            }
            find.accessibilityIdentifier = "menu.find"
            tiles.append(find)
        }
        tiles += readerMenuItems(rules.reader).compactMap { $0 as? UIAction }
        tiles += summarizeMenuItems(rules).compactMap { $0 as? UIAction }
        tiles += translateMenuItems(for: tab, item: rules.translate).compactMap { $0 as? UIAction }
        let share = UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
            guard let self else { return }
            self.share(from: self.moreSource)
        }
        share.accessibilityIdentifier = "menu.share"
        model.tiles = Array(tiles.prefix(3)) + [share]

        // Keeping the page: Favorite, Read Later and Site Settings, one captioned row (the
        // reading list lane's measured layout), so the sheet fits the Duo's outer screen.
        var keep: [UIMenuElement] = []
        if rules.favorite, let isFavorite = marks?.isFavorite {
            let title = tab.title
            let favorite = UIAction(
                title: isFavorite ? "Remove from Favorites" : "Add to Favorites",
                image: UIImage(systemName: isFavorite ? "star.fill" : "star")
            ) { [weak self] _ in
                self?.setFavorite(!isFavorite, url: url, title: title)
            }
            favorite.accessibilityIdentifier = "menu.favorite"
            // On: the sheet shows the filled star in the accent; a tap removes it.
            if isFavorite { favorite.state = .on }
            keep.append(favorite)
        }
        if rules.readLater, let isSaved = marks?.isSaved {
            keep.append(readLaterMenuItem(for: tab, url: url, isSaved: isSaved))
        }
        var siteItems = siteMenuItems(
            for: tab, url: url, desktop: rules.desktopSite, blocking: rules.blockingToggle, darkPages: rules.darkPages
        )
        // The permissions the site asked for, with what iOS allows (Off in Settings).
        if !siteItems.isEmpty { siteItems += sitePermissionMenuItems(for: tab) }
        if siteItems.count > 1, let host = url.host() {
            // Desktop Site, blocking, cookie banners and dark pages: set once per site, then remembered.
            let site = UIMenu(
                title: "Site Settings", subtitle: Self.siteName(host), image: UIImage(systemName: "slider.horizontal.3"),
                children: siteItems
            )
            site.accessibilityIdentifier = "menu.siteSettings"
            keep.append(site)
        } else {
            keep += siteItems
        }
        var rows: [PageSheetModel.Row] = []
        switch keep.count {
        case 0: break
        case 1:
            if let menu = keep[0] as? UIMenu {
                rows.append(.menu(menu))
            } else if let action = keep[0] as? UIAction {
                rows.append(.action(action))
            }
        default: rows.append(.chips(keep))
        }
        if rules.zoom { rows.append(.stepper(zoomActions(for: tab))) }
        if rules.savePDF { rows += pdfMenuItems(for: tab).compactMap { ($0 as? UIAction).map { .action($0) } } }
        let paneItems = paneMenuItems(for: tab, rules: rules) + sidePaneMenuItems(rules)
        rows += paneItems.compactMap { ($0 as? UIAction).map { .action($0) } }
        model.rows = rows + tail
        return model
    }

    /// A site's name as the pill shows it: the host without `www.`.
    static func siteName(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func setFavorite(_ isFavorite: Bool, url: URL, title: String?) {
        Signposts.signposter.emitEvent(Signposts.favoriteToggle)
        Task { [weak self, data] in
            if await data.setFavorite(isFavorite, url: url, title: title) {
                self?.refreshFocusContent()
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

    func showHistory() {
        // Beside the page where the side pane can show; a sheet elsewhere.
        if currentRules().historyInSidePane { return openSidePane(.history) }
        let history = sheets.history(
            onOpen: { [weak self] url in
                self?.closeSheet { self?.load(url) }
            },
            onDone: { [weak self] in self?.closeSheet() }
        )
        present(history, signpost: Signposts.historyShow)
    }

    /// From the favorites strip's Edit Favorites (the search field is open: it closes for the
    /// sheet, which opens editing, and opens again after, showing the edited favorites) or from
    /// the page sheet's Favorites chip. A favorite tapped there opens in the tab, as History's do.
    private func showFavoritesEditor(editing: Bool = false) {
        var opened = false
        let editor = sheets.favoritesEditor(
            startsEditing: editing,
            onOpen: { [weak self] url in
                opened = true
                self?.closeSheet { self?.load(url) }
            },
            onDone: { [weak self] in self?.closeSheet() }
        )
        guard let editor else { return }
        let wasEditing = isEditingAddress
        if wasEditing { endEditing() }
        present(editor, signpost: Signposts.favoritesEditorOpen) { [weak self] in
            guard let self, !opened else { return }
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
        // History may have been cleared, favorites edited: read them again.
        refreshFocusContent()
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
