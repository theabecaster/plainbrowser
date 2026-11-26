#if canImport(UIKit)
import BrowserCore
import DesignSystem
import os
import PerfSignposts
import UIKit
import WebEngine
import WebKit

/// The browser's root screen (one tab for now): the page, the URL pill at the bottom, the page's
/// buttons, and the search sheet the pill grows into.
///
/// Launch order (docs/plan.md, "Engine rules"):
/// 1. The first frame shows the search sheet with the field already first responder, keyboard up.
/// 2. After that frame, the pool warms one offscreen web view with `about:blank`.
/// 3. The first submitted address gets that warm web view.
///
/// Embed it in a `UINavigationController` with a hidden navigation bar: where the system has a
/// vertical bar (iPhone Duo), the page buttons are the navigation controller's toolbar items and
/// go into that bar.
public final class BrowserViewController: UIViewController, UITextFieldDelegate, UIScrollViewDelegate {
    private let pool: WebViewPool
    private let data: any AddressBarData
    private let onSearchFieldReady: () -> Void
    private let navigationSignposter = NavigationSignposter()

    private let webContainer = UIView()
    private let pill = AddressPill()
    private let buttonBar = ButtonBar()
    private let sheet = SearchSheet()
    private let pullIndicator = PullIndicator()
    private var barItems: [PageButton: UIBarButtonItem] = [:]

    private var webView: WKWebView?
    private var observations: [NSKeyValueObservation] = []

    // Layout.
    private var pillOnBar: NSLayoutConstraint!
    private var pillOnEdge: NSLayoutConstraint!
    private var pillOnKeyboard: NSLayoutConstraint!
    private var geometry = ChromeGeometry(viewHeight: 0, safeBottom: 0, hasButtonBar: true)
    private var usesVerticalBar = false

    // State.
    private var isEditingAddress = true
    private var didFocusAtLaunch = false
    private var didWarmUp = false
    /// Hosts this session asked for their desktop site (Desktop Site in the page menu).
    private var desktopHosts: Set<String> = []
    private var collapse = ChromeCollapse()
    private var collapseInterval: OSSignpostIntervalState?
    private var pullTracker = PullToRefreshTracker()
    private var suggestionTask: Task<Void, Never>?
    private var favoritesTask: Task<Void, Never>?

    /// - Parameters:
    ///   - data: history, favorites, settings and engine suggestions for the address bar.
    ///   - onSearchFieldReady: called once, when the field first becomes first responder.
    public init(pool: WebViewPool, data: any AddressBarData, onSearchFieldReady: @escaping () -> Void) {
        self.pool = pool
        self.data = data
        self.onSearchFieldReady = onSearchFieldReady
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Building

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.background
        view.tintColor = Palette.accent

        for subview in [webContainer, pullIndicator, sheet, buttonBar, pill] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        webContainer.clipsToBounds = true

        pill.textField.delegate = self
        pill.textField.addTarget(self, action: #selector(queryChanged), for: .editingChanged)
        pill.onTap = { [weak self] in self?.pillTapped() }
        pill.menuProvider = { [weak self] in self?.webView?.url == nil ? nil : self?.pageMenu() }

        sheet.onPick = { [weak self] pick in self?.open(pick) }
        sheet.onDismiss = { [weak self] in self?.endEditing() }

        buildButtons()
        layOut()
        updateBarMode()
        // The first frame is the search sheet, focused (viewIsAppearing makes it first responder).
        applyEditingLayout(true, animated: false)

        var traits: [UITrait] = [UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]
        traits += UITraitCollection.systemTraitsAffectingVerticalBarEdge
        registerForTraitChanges(traits) { (controller: BrowserViewController, _) in
            controller.updateBarMode()
        }
    }

    private func layOut() {
        let safe = view.safeAreaLayoutGuide
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

        func capWidth(_ item: UIView) -> [NSLayoutConstraint] {
            let fill = item.widthAnchor.constraint(equalTo: safe.widthAnchor, constant: -2 * margin)
            fill.priority = .defaultHigh
            return [
                item.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
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

            // The page fills the view below the status bar and beside a vertical bar. Its bottom
            // runs under the chrome; obscuredContentInsets tells WebKit what the chrome covers.
            webContainer.topAnchor.constraint(equalTo: safe.topAnchor),
            webContainer.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            pullIndicator.topAnchor.constraint(equalTo: webContainer.topAnchor, constant: Spacing.s),
            pullIndicator.centerXAnchor.constraint(equalTo: webContainer.centerXAnchor),
            pullIndicator.widthAnchor.constraint(equalToConstant: PullIndicator.size),
            pullIndicator.heightAnchor.constraint(equalToConstant: PullIndicator.size),

            sheet.topAnchor.constraint(equalTo: view.topAnchor),
            sheet.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sheet.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sheet.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sheet.content.topAnchor.constraint(greaterThanOrEqualTo: safe.topAnchor, constant: Spacing.s),
            sheet.content.bottomAnchor.constraint(equalTo: pill.topAnchor, constant: -Spacing.s),

            buttonBar.heightAnchor.constraint(equalToConstant: ChromeGeometry.barHeight),
            buttonBar.bottomAnchor.constraint(equalTo: rest.topAnchor),
            pill.heightAnchor.constraint(equalToConstant: ChromeGeometry.pillHeight),
        ] + capWidth(pill) + capWidth(buttonBar) + capWidth(sheet.content))
    }

    private func buildButtons() {
        for kind in PageButton.allCases {
            let button = buttonBar.button(kind)
            let item: UIBarButtonItem
            switch kind {
            case .more:
                button.menu = pageMenu()
                button.showsMenuAsPrimaryAction = true
                item = UIBarButtonItem(
                    title: kind.title, image: UIImage(systemName: kind.symbol), primaryAction: nil, menu: pageMenu()
                )
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
        buttonBar.isHidden = vertical
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

    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let next = ChromeGeometry(
            viewHeight: view.bounds.height, safeBottom: view.safeAreaInsets.bottom, hasButtonBar: !usesVerticalBar
        )
        guard next != geometry else { return }
        geometry = next
        applyCollapse(collapse.progress)
        updatePageInsets()
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
        pool.warmUp()
    }

    /// Call when the address bar's data changed outside the shell (the database opened), so an
    /// open search sheet shows the favorites.
    public func addressBarDataDidChange() {
        guard isEditingAddress else { return }
        loadFavorites()
    }

    // MARK: Address bar

    private func pillTapped() {
        // A collapsed bar first comes back, as Safari's does; the next tap edits.
        if collapse.progress > 0 {
            expandChrome(animated: true)
            return
        }
        let interval = Signposts.signposter.beginInterval(Signposts.urlBarFocus)
        pill.textField.text = webView?.url?.absoluteString ?? ""
        // The layout switches before the keyboard starts, so the keyboard's own animation carries
        // the pill up (keyboardLayoutGuide) and it never falls behind the rising keyboard.
        applyEditingLayout(true, animated: true)
        if !pill.beginEditing() { applyEditingLayout(false, animated: false) }
        Signposts.signposter.endInterval(Signposts.urlBarFocus, interval)
    }

    public func textFieldDidBeginEditing(_ textField: UITextField) {
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
        load(url)
        signposter.endInterval(Signposts.addressSubmit, state, "loaded")
        return false
    }

    @objc private func queryChanged() {
        let query = pill.textField.text ?? ""
        suggestionTask?.cancel()
        // The current page's address, untouched, is not a query: show favorites, as for an
        // empty field, until the user types.
        let isCurrentAddress = !query.isEmpty && query == webView?.url?.absoluteString
        sheet.setFavoritesAllowed(query.isEmpty || isCurrentAddress)
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
        case .page(let page): url = page
        case .search(let query): url = data.searchEngine.resultsURL(for: query)
        }
        guard let url else { return }
        let state = Signposts.signposter.beginInterval(Signposts.addressSubmit)
        load(url)
        Signposts.signposter.endInterval(Signposts.addressSubmit, state, "picked")
    }

    /// Closes the search sheet: the layout switches first, so the pill rides the keyboard down.
    private func endEditing() {
        applyEditingLayout(false, animated: true)
        pill.textField.resignFirstResponder()
    }

    /// Moves between the resting pill and the open search sheet. The pill itself grows into the
    /// field above the keyboard (`.snappy(0.3)`, bounce 0, following `keyboardLayoutGuide`).
    ///
    /// The pill's move is laid out inside the keyboard's animation, which UIKit runs for views
    /// tied to `keyboardLayoutGuide`, so it tracks the keyboard frame by frame. The sheet's
    /// fade, the field's rim and the bar use the spring.
    private func applyEditingLayout(_ editing: Bool, animated: Bool) {
        let changed = editing != isEditingAddress || pillOnKeyboard.isActive != editing
        isEditingAddress = editing
        guard changed || !animated else { return }
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

    private func load(_ url: URL) {
        let webView = self.webView ?? installWebView()
        applyUserAgent(for: url)
        webView.load(URLRequest(url: url))
        pill.display(url: url)
        pill.textField.text = url.absoluteString
        if isEditingAddress { endEditing() }
    }

    private func installWebView() -> WKWebView {
        let webView = pool.dequeueWebView()
        webView.navigationDelegate = navigationSignposter
        webView.allowsBackForwardNavigationGestures = true
        webView.isFindInteractionEnabled = true
        webView.scrollView.delegate = self
        webView.scrollView.alwaysBounceVertical = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        webContainer.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
        ])
        self.webView = webView
        observe(webView)
        view.layoutIfNeeded()
        updatePageInsets()
        return webView
    }

    /// Page state the chrome shows. Key-value observation is fine for these: they change a few
    /// times per load. The toolbar's scroll tracking uses the scroll delegate instead.
    private func observe(_ webView: WKWebView) {
        func on<Value>(_ keyPath: KeyPath<WKWebView, Value>, _ handler: @escaping @MainActor (BrowserViewController, WKWebView) -> Void) {
            observations.append(webView.observe(keyPath, options: []) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    handler(self, webView)
                }
            })
        }
        on(\.estimatedProgress) { controller, webView in
            guard webView.isLoading else { return }
            controller.pill.progressBar.setProgress(webView.estimatedProgress)
        }
        on(\.isLoading) { controller, webView in
            if webView.isLoading {
                // A new load brings the bar back. Same-document URL changes (pushState) do not.
                controller.expandChrome(animated: true)
                controller.pill.progressBar.begin()
                controller.pill.progressBar.setProgress(max(0.1, webView.estimatedProgress))
            } else {
                controller.pill.progressBar.finish()
                if let url = webView.url { controller.data.pageVisited(url: url, title: webView.title) }
            }
        }
        on(\.url) { controller, webView in
            controller.pill.display(url: webView.url)
            if let url = webView.url { controller.applyUserAgent(for: url) }
            if !controller.isEditingAddress { controller.pill.textField.text = webView.url?.absoluteString }
            controller.updateButtons()
        }
        on(\.title) { controller, webView in
            guard let url = webView.url, let title = webView.title else { return }
            controller.data.pageTitleChanged(url: url, title: title)
        }
        on(\.canGoBack) { controller, _ in controller.updateButtons() }
        on(\.canGoForward) { controller, _ in controller.updateButtons() }
    }

    private func updateButtons() {
        let hasPage = webView?.url != nil
        let enabled: [PageButton: Bool] = [
            .back: webView?.canGoBack ?? false,
            .forward: webView?.canGoForward ?? false,
            .share: hasPage,
            .more: hasPage,
        ]
        for (kind, isEnabled) in enabled {
            buttonBar.button(kind).isEnabled = isEnabled
            barItems[kind]?.isEnabled = isEnabled
        }
    }

    /// Tells WebKit what the chrome covers, without relayouting the page as the bar moves
    /// (docs/plan.md, engine rule 4): the obscured inset is the collapsed chrome and changes only
    /// when the geometry does (rotation, fold, bar mode), never while scrolling.
    private func updatePageInsets() {
        guard let webView, view.bounds.height > 0 else { return }
        let pageBottom = webContainer.frame.maxY
        let collapsed = geometry.obscuredBottom(pageBottom: pageBottom)
        let expanded = max(geometry.expandedBottom(pageBottom: pageBottom), collapsed + 1)
        if webView.obscuredContentInsets.bottom != collapsed {
            webView.obscuredContentInsets = UIEdgeInsets(top: 0, left: 0, bottom: collapsed, right: 0)
        }
        if webView.minimumViewportInset.bottom != collapsed || webView.maximumViewportInset.bottom != expanded {
            webView.setMinimumViewportInset(
                UIEdgeInsets(top: 0, left: 0, bottom: collapsed, right: 0),
                maximumViewportInset: UIEdgeInsets(top: 0, left: 0, bottom: expanded, right: 0)
            )
        }
    }

    // MARK: Toolbar collapse

    /// Places the pill and button bar for collapse `progress` with transform and alpha only.
    private func applyCollapse(_ progress: CGFloat) {
        let pillMove = geometry.pillTransform(progress: progress)
        pill.transform = CGAffineTransform(translationX: 0, y: pillMove.translationY)
            .scaledBy(x: pillMove.scale, y: pillMove.scale)
        guard !usesVerticalBar else { return }
        buttonBar.transform = CGAffineTransform(translationX: 0, y: geometry.barTranslation(progress: progress))
        if !isEditingAddress { buttonBar.alpha = ChromeGeometry.barAlpha(progress: progress) }
    }

    private func expandChrome(animated: Bool) {
        settleCollapse(at: 0, animated: animated)
    }

    /// Snaps the bar to `target` (0 or 1) with `.smooth(0.25)`.
    private func settleCollapse(at target: CGFloat, animated: Bool) {
        let moving = collapse.progress != target
        collapse.settle(at: target)
        guard moving || collapseInterval != nil else { return }
        if collapseInterval == nil { collapseInterval = Signposts.signposter.beginInterval(Signposts.toolbarCollapse) }
        let finish = { [weak self] in
            guard let self, let interval = self.collapseInterval else { return }
            Signposts.signposter.endInterval(Signposts.toolbarCollapse, interval)
            self.collapseInterval = nil
        }
        guard animated else {
            applyCollapse(target)
            finish()
            return
        }
        // Small moves of two floating controls: no crossfade of the whole screen.
        Motion.animate(Motion.toolbarSnap, changes: { self.applyCollapse(target) }, completion: finish)
    }

    // MARK: UIScrollViewDelegate

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        collapse.resetTracking()
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === webView?.scrollView, !isEditingAddress else { return }
        let top = -scrollView.adjustedContentInset.top
        let offset = scrollView.contentOffset.y

        if scrollView.isTracking {
            trackPull(top - offset)
        }
        guard scrollView.isTracking || scrollView.isDecelerating else { return }
        let bottom = scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        // A page that barely scrolls keeps its bar.
        guard bottom - top > collapse.distance * 2 else { return }
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
        guard scrollView === webView?.scrollView else { return }
        if pullTracker.released() {
            refresh()
        } else {
            pullIndicator.hide()
        }
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === webView?.scrollView, !decelerate, !isEditingAddress else { return }
        settleCollapse(at: collapse.settleTarget(), animated: true)
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === webView?.scrollView, !isEditingAddress else { return }
        settleCollapse(at: collapse.settleTarget(), animated: true)
    }

    public func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        expandChrome(animated: true)
    }

    // MARK: Pull to refresh

    private func trackPull(_ distance: CGFloat) {
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
        webView?.reload()
    }

    // MARK: Buttons and page menu

    private func goBack() {
        guard let webView, webView.canGoBack else { return Haptic.nothingThere.play() }
        Signposts.signposter.emitEvent(Signposts.navBack)
        webView.goBack()
    }

    private func goForward() {
        guard let webView, webView.canGoForward else { return Haptic.nothingThere.play() }
        Signposts.signposter.emitEvent(Signposts.navForward)
        webView.goForward()
    }

    /// The page menu (docs/ui-reference.md): built when it opens, with only the items that apply
    /// now. Zoom, blocking, other pane and favorites arrive with their features.
    private func pageMenu() -> UIMenu {
        UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                Signposts.signposter.emitEvent(Signposts.pageMenu)
                completion(self?.pageMenuElements() ?? [])
            },
        ])
    }

    private func pageMenuElements() -> [UIMenuElement] {
        guard let webView, let url = webView.url else { return [] }
        let reload = UIAction(title: "Reload", image: UIImage(systemName: "arrow.clockwise")) { _ in
            Signposts.signposter.emitEvent(Signposts.reload)
            webView.reload()
        }
        let find = UIAction(title: "Find on Page", image: UIImage(systemName: "doc.text.magnifyingglass")) { _ in
            Signposts.signposter.emitEvent(Signposts.findOnPage)
            webView.findInteraction?.presentFindNavigator(showingReplace: false)
        }
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
        let desktop = UIAction(
            title: "Desktop Site", image: UIImage(systemName: "desktopcomputer"), state: isDesktopSite ? .on : .off
        ) { [weak self] _ in
            self?.toggleDesktopSite()
        }
        return [
            UIMenu(options: .displayInline, children: [reload, find]),
            UIMenu(options: .displayInline, children: [share, copy]),
            UIMenu(options: .displayInline, children: [desktop]),
        ]
    }

    private func share(from source: (any UIPopoverPresentationControllerSourceItem)?) {
        guard let url = webView?.url else { return }
        Signposts.signposter.emitEvent(Signposts.share)
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceItem = source ?? pill
        present(sheet, animated: true)
    }

    private var isDesktopSite: Bool {
        guard let host = webView?.url?.host() else { return false }
        return desktopHosts.contains(host)
    }

    /// Asks this site for its desktop layout, or back for the mobile one, and reloads.
    ///
    /// Stopgap until WebEngine's navigation delegate sets `preferredContentMode` per navigation
    /// and Storage remembers the choice per site: a desktop Safari user agent, remembered per
    /// host for this session. A link to another host uses the old agent for that one load.
    private func toggleDesktopSite() {
        guard let webView, let url = webView.url, let host = url.host() else { return }
        Signposts.signposter.emitEvent(Signposts.desktopSite)
        if desktopHosts.remove(host) == nil { desktopHosts.insert(host) }
        applyUserAgent(for: url)
        webView.reload()
    }

    private func applyUserAgent(for url: URL) {
        guard let webView else { return }
        let agent = url.host().map(desktopHosts.contains) == true ? Self.desktopUserAgent : nil
        if webView.customUserAgent != agent { webView.customUserAgent = agent }
    }

    /// Safari on a Mac, which sites answer with their desktop layout.
    static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
}
#endif
