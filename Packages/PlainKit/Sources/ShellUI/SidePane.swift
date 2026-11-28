#if canImport(UIKit)
import BrowserCore
import DesignSystem
import PerfSignposts
import Reader
import UIKit
import WebEngine
import WebKit

/// What the side pane shows next to the page (docs/plan.md, section 6, item 4).
enum SidePaneSection: String, CaseIterable {
    case reader, find, history

    var title: String {
        switch self {
        case .reader: String(localized: "Reader")
        case .find: String(localized: "Find")
        case .history: String(localized: "History")
        }
    }

    var symbol: String {
        switch self {
        case .reader: "doc.plaintext"
        case .find: "text.magnifyingglass"
        case .history: "clock"
        }
    }
}

/// The side pane: a column beside the page on a wide screen (the Duo's inner screen) with the
/// page's article, Find's list of matches, or History, picked from a segmented control at its top.
/// It acts on the focused page: a link in the article or a History row opens there, a match scrolls
/// it. Its column comes from `DuoLayout.sidePaneColumn`; the browser places and slides it
/// (`+SidePane`). Each section is built the first time it shows.
final class SidePaneController: UIViewController {
    weak var browser: BrowserViewController?
    private(set) var section: SidePaneSection = .reader
    private let picker = UISegmentedControl()
    private let closeButton = UIButton(type: .system)
    /// Full Width / Show Page: the visible way to the pane taking the whole width and back, beside
    /// the divider's drag (docs/ui-reference.md: a gesture is never the only way).
    private let expandButton = UIButton(type: .system)
    private let header = UIView()
    private let content = UIView()
    private let separator = UIView()
    private var sections: [SidePaneSection: UIViewController & SidePaneContent] = [:]
    /// The header's top: under the status corner and the top bar's row (set by the browser).
    private var headerTop: NSLayoutConstraint!
    /// The content's trailing edge, swapped for a fixed width while the divider moves
    /// (`freezeContent`), so Reader, Find and History lay out once per settle, not per frame.
    private var contentTrailing: NSLayoutConstraint!
    private var contentWidth: NSLayoutConstraint!
    /// The header's trailing edge, swapped for its width while the divider moves: the pane is then
    /// a card the width of the pages, slid by a transform, and nothing in it lays out per frame.
    private var headerTrailing: NSLayoutConstraint!
    private var headerWidth: NSLayoutConstraint!
    /// The content's top: under the header at rest; held where it is while the divider moves (the
    /// header may step under the top bar mid-drag), so the content's height never changes then.
    private var contentUnderHeader: NSLayoutConstraint!
    private var contentTop: NSLayoutConstraint!
    private var expandShown: NSLayoutConstraint!
    /// The expand button reads Show Page (a plain button: a selected system button draws a plate).
    private var showsTakeOver = false
    private var expandHidden: NSLayoutConstraint!

    override func viewDidLoad() {
        super.viewDidLoad()
        Paper.apply(to: view)
        view.accessibilityIdentifier = "sidePane"
        view.clipsToBounds = true
        for item in SidePaneSection.allCases {
            let image = UIImage(systemName: item.symbol)
            image?.accessibilityLabel = item.title
            picker.insertSegment(with: image, at: picker.numberOfSegments, animated: false)
        }
        // The selected segment is wider: it carries its word.
        picker.apportionsSegmentWidthsByContent = true
        picker.accessibilityIdentifier = "sidePane.picker"
        picker.addAction(UIAction { [weak self] _ in
            guard let self, SidePaneSection.allCases.indices.contains(picker.selectedSegmentIndex) else { return }
            applySegmentFaces()
            browser?.showSidePaneSection(SidePaneSection.allCases[picker.selectedSegmentIndex])
        }, for: .valueChanged)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitDisplayScale.self]) {
            (pane: SidePaneController, _) in pane.applySegmentFaces()
        }
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(weight: .semibold)), for: .normal)
        closeButton.tintColor = .secondaryLabel
        closeButton.accessibilityLabel = String(localized: "Hide Side Pane")
        closeButton.accessibilityIdentifier = "sidePane.close"
        closeButton.addAction(UIAction { [weak self] _ in self?.browser?.closeSidePane(animated: true) }, for: .primaryActionTriggered)
        separator.backgroundColor = .separator
        expandButton.tintColor = .secondaryLabel
        expandButton.accessibilityIdentifier = "sidePane.expand"
        expandButton.addAction(UIAction { [weak self] _ in self?.browser?.toggleSidePaneTakeOver() }, for: .primaryActionTriggered)
        expandButton.isHidden = true
        setExpandLook(takesOver: false)

        for subview in [header, content, separator] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        // The header over the content, on the pane's paper: while the divider moves the content
        // holds its top and the header may step down under the top bar, over it.
        Paper.apply(to: header)
        view.bringSubviewToFront(header)
        for subview in [picker, expandButton, closeButton] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(subview)
        }
        headerTop = header.topAnchor.constraint(equalTo: view.topAnchor)
        let pixel = 1 / max(traitCollection.displayScale, 1)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: view.topAnchor),
            separator.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.widthAnchor.constraint(equalToConstant: pixel),

            headerTop,
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Spacing.m),
            // Never narrower than the pane at its minimum: a divider dragged past it clips the header
            // instead of breaking its constraints.
            header.widthAnchor.constraint(greaterThanOrEqualToConstant: CGFloat(FixedChoices.sidePaneMinimumWidth) - Spacing.m - Spacing.s),
            header.heightAnchor.constraint(equalToConstant: Metrics.tapTarget),
            picker.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            picker.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            expandButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor),
            expandButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            expandButton.widthAnchor.constraint(equalToConstant: Metrics.tapTarget),
            expandButton.heightAnchor.constraint(equalToConstant: Metrics.tapTarget),
            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: Metrics.tapTarget),
            closeButton.heightAnchor.constraint(equalToConstant: Metrics.tapTarget),

            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: pixel),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        contentTrailing = content.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        contentTrailing.isActive = true
        contentUnderHeader = content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Spacing.s)
        contentUnderHeader.isActive = true
        contentTop = content.topAnchor.constraint(equalTo: view.topAnchor)
        contentWidth = content.widthAnchor.constraint(equalToConstant: 0)
        headerTrailing = header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Spacing.s)
            .withPriority(.required - 1)
        headerTrailing.isActive = true
        headerWidth = header.widthAnchor.constraint(equalToConstant: 0)
        expandShown = picker.trailingAnchor.constraint(equalTo: expandButton.leadingAnchor, constant: -Spacing.xs)
        expandHidden = picker.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -Spacing.s)
        expandHidden.isActive = true
    }

    /// The divider is moving: the content keeps its width (clipped by the column, or with paper
    /// beside it) until `unfreezeContent`, so no section lays out per frame. The header follows.
    func freezeContent() {
        loadViewIfNeeded()
        guard !contentWidth.isActive else { return }
        contentWidth.constant = content.bounds.width
        contentTop.constant = content.frame.minY
        headerWidth.constant = header.bounds.width
        contentTrailing.isActive = false
        contentUnderHeader.isActive = false
        headerTrailing.isActive = false
        contentWidth.isActive = true
        contentTop.isActive = true
        headerWidth.isActive = true
    }

    /// While frozen, the content takes `width` now (a settle that widens the pane: one layout pass,
    /// at the start, and the column uncovers it as it moves).
    func setFrozenContentWidth(_ width: CGFloat) {
        guard isViewLoaded, contentWidth.isActive, contentWidth.constant != width else { return }
        headerWidth.constant += width - contentWidth.constant
        contentWidth.constant = width
    }

    /// The content takes the column again: under the header, to its trailing edge.
    func unfreezeContent() {
        guard isViewLoaded, contentWidth.isActive else { return }
        contentWidth.isActive = false
        contentTop.isActive = false
        headerWidth.isActive = false
        contentTrailing.isActive = true
        contentUnderHeader.isActive = true
        headerTrailing.isActive = true
    }

    /// The content's width now (frozen or not).
    var contentWidthNow: CGFloat { content.bounds.width }

    /// The expand button shows where the divider can move (not partly folded); it reads Full
    /// Width beside the page and Show Page while the pane has the whole width.
    func setTakeOver(available: Bool, active: Bool) {
        loadViewIfNeeded()
        if expandButton.isHidden == available {
            expandButton.isHidden = !available
            expandHidden.isActive = !available
            expandShown.isActive = available
        }
        if showsTakeOver != active { setExpandLook(takesOver: active) }
    }

    private func setExpandLook(takesOver: Bool) {
        showsTakeOver = takesOver
        let symbol = takesOver ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(weight: .semibold))
        expandButton.setImage(image, for: .normal)
        expandButton.accessibilityLabel = takesOver ? String(localized: "Show Page") : String(localized: "Full Width")
    }

    /// The header sits this far from the column's top: clear of the status items and level with
    /// the page's first line under the top bar.
    func setHeaderTop(_ top: CGFloat) {
        loadViewIfNeeded()
        if headerTop.constant != top { headerTop.constant = top }
    }

    /// The hairline at the leading edge shows only where the pane meets the page; across the
    /// fold's gap (book pose) the paper runs on without a seam.
    func setSeparatorHidden(_ hidden: Bool) {
        loadViewIfNeeded()
        if separator.isHidden != hidden { separator.isHidden = hidden }
    }

    /// The selected segment says its name beside its symbol ("Reader"); the others keep the
    /// symbol alone, so the picker stays one short row (clarity audit 26: three bare symbols left
    /// people guessing which was which). VoiceOver hears every segment's name.
    private func applySegmentFaces() {
        for (index, item) in SidePaneSection.allCases.enumerated() {
            let image = index == picker.selectedSegmentIndex
                ? Self.labelledSymbol(item, traits: traitCollection) : UIImage(systemName: item.symbol)
            image?.accessibilityLabel = item.title
            picker.setImage(image, forSegmentAt: index)
        }
    }

    /// The symbol and the word in one template image, as a segment holds one or the other.
    private static func labelledSymbol(_ section: SidePaneSection, traits: UITraitCollection) -> UIImage? {
        // The segmented control's own title size, growing with Dynamic Type to the pill's cap.
        let size = min(traits.preferredContentSizeCategory, .extraExtraExtraLarge)
        let font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .systemFont(ofSize: 13, weight: .semibold), compatibleWith: UITraitCollection(preferredContentSizeCategory: size)
        )
        guard let symbol = UIImage(systemName: section.symbol, withConfiguration: UIImage.SymbolConfiguration(font: font))?
            .withTintColor(.black, renderingMode: .alwaysOriginal) else { return nil }
        let attachment = NSTextAttachment(image: symbol)
        attachment.bounds = CGRect(
            x: 0, y: ((font.capHeight - symbol.size.height) / 2).rounded(), width: symbol.size.width, height: symbol.size.height
        )
        let text = NSMutableAttributedString(attachment: attachment)
        text.append(NSAttributedString(string: " " + section.title, attributes: [.font: font, .foregroundColor: UIColor.black]))
        let bounds = text.boundingRect(with: CGSize(width: 400, height: 100), options: [.usesLineFragmentOrigin], context: nil)
        let format = UIGraphicsImageRendererFormat(for: traits)
        let image = UIGraphicsImageRenderer(size: CGSize(width: ceil(bounds.width), height: ceil(bounds.height)), format: format)
            .image { _ in text.draw(with: CGRect(origin: .zero, size: bounds.size), options: [.usesLineFragmentOrigin], context: nil) }
        return image.withRenderingMode(.alwaysTemplate)
    }

    /// Shows `section`, building it the first time.
    func show(_ section: SidePaneSection) {
        loadViewIfNeeded()
        picker.selectedSegmentIndex = SidePaneSection.allCases.firstIndex(of: section) ?? 0
        applySegmentFaces()
        let previous = sections[self.section]
        self.section = section
        let controller = sections[section] ?? makeSection(section)
        sections[section] = controller
        if controller.parent == nil {
            addChild(controller)
            controller.view.frame = content.bounds
            controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            content.addSubview(controller.view)
            controller.didMove(toParent: self)
        }
        if previous !== controller { previous?.view.isHidden = true }
        controller.view.isHidden = false
        controller.sectionDidShow()
    }

    /// The focused page changed (another tab, a new address, a load finished): the shown section
    /// follows it.
    func pageDidChange() {
        guard isViewLoaded, view.window != nil else { return }
        sections[section]?.pageDidChange()
    }

    /// The pane is leaving the screen: Find's marks come off the page, the keyboard goes.
    func paneWillHide() {
        for controller in sections.values { controller.paneWillHide() }
    }

    #if DEBUG
    /// Types `query` into Find (captures).
    func debugFind(_ query: String) {
        (sections[.find] as? SidePaneFind)?.debugSearch(query)
    }
    #endif

    /// The first responder in the pane (Find's field), for moving focus in.
    func focusSection() {
        sections[section]?.focus()
    }

    private func makeSection(_ section: SidePaneSection) -> UIViewController & SidePaneContent {
        switch section {
        case .reader: SidePaneReader(browser: browser)
        case .find: SidePaneFind(browser: browser)
        case .history: SidePaneHistory(browser: browser)
        }
    }
}

/// One section of the side pane.
@MainActor
protocol SidePaneContent: AnyObject {
    /// The section came on screen (picked, or the pane opened on it).
    func sectionDidShow()
    func pageDidChange()
    func paneWillHide()
    func focus()
}

extension SidePaneContent {
    func paneWillHide() {}
    func focus() {}
}

// MARK: - Reader

/// The focused page's article beside it, in its own reader web view from the pool (the same
/// renderer as Show Reader). A tapped link opens in the page. Pages with no article say so.
final class SidePaneReader: UIViewController, SidePaneContent, UIScrollViewDelegate {
    private weak var browser: BrowserViewController?
    private let presenter = ReaderPresenter()
    private let message = UILabel()
    private var task: Task<Void, Never>?
    /// The page the article on screen came from.
    private var shownPage: (webView: WKWebView, url: URL?)?

    init(browser: BrowserViewController?) {
        self.browser = browser
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        message.font = .preferredFont(forTextStyle: .body)
        message.adjustsFontForContentSizeCategory = true
        message.textColor = .secondaryLabel
        message.numberOfLines = 0
        message.textAlignment = .center
        message.accessibilityIdentifier = "sidePane.reader.message"
        message.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(message)
        NSLayoutConstraint.activate([
            message.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -Spacing.xl),
            message.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Spacing.l),
            message.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Spacing.l),
        ])
        presenter.onOpenLink = { [weak self] url in self?.browser?.openFromSidePane(url) }
        // The message stays until the article is on screen, so the pane is never blank paper.
        presenter.onShown = { [weak self] in self?.message.isHidden = true }
    }

    func sectionDidShow() { refresh() }
    func pageDidChange() { refresh() }

    /// Shows the focused page's article once the page has said it has one; a page still loading
    /// keeps what shows until it has.
    private func refresh() {
        guard let browser else { return }
        guard let tab = browser.currentTab, tab.url != nil,
              let page = browser.session.pool.webView(for: tab) else {
            return showMessage(String(localized: "Open a page to read it here."))
        }
        if let shownPage, shownPage.webView === page, shownPage.url == page.url, presenter.isShowing { return }
        switch browser.session.reader.isAvailable(in: page) {
        case nil:
            // The check reports when the page has loaded (`onAvailability`).
            if !presenter.isShowing { showWaiting() }
        case false?:
            showMessage(String(localized: "This page has no article to read."))
        case true?:
            load(from: page, isPrivate: tab.isPrivate, profile: tab.profileID)
        }
    }

    private func load(from page: WKWebView, isPrivate: Bool, profile: ProfileID) {
        guard let browser else { return }
        task?.cancel()
        let url = page.url
        if !presenter.isShowing { showWaiting() }
        task = Task { [weak self, session = browser.session] in
            let article = try? await session.reader.article(in: page)
            guard let self, !Task.isCancelled else { return }
            guard let article else { return showMessage(String(localized: "This page has no article to read.")) }
            presenter.close(animated: false)
            presenter.prepare(pool: session.pool, isPrivate: isPrivate, profile: profile, in: view, scrollDelegate: self)
            presenter.webView?.accessibilityIdentifier = "sidePane.readerView"
            shownPage = (page, url)
            try? await presenter.show(article)
        }
    }

    /// "Looking for an article…" while the page's check or the article is on its way.
    private func showWaiting() {
        message.text = String(localized: "Looking for an article…")
        message.isHidden = false
    }

    private func showMessage(_ text: String) {
        task?.cancel()
        presenter.close(animated: false)
        shownPage = nil
        message.text = text
        message.isHidden = false
    }

    /// Off screen, the reader web view (and the page it read) goes; showing again reads anew.
    func paneWillHide() {
        task?.cancel()
        presenter.close(animated: false)
        shownPage = nil
    }
}

// MARK: - Find

/// Find on Page as a list: every match with the words around it; a tap scrolls the page to it
/// and marks it. The field searches as you type (`FixedChoices.findDebounce`), and again when the
/// page changes. Marks come off when the pane closes or the section changes.
final class SidePaneFind: UIViewController, SidePaneContent, UITableViewDataSource, UITableViewDelegate,
    UISearchTextFieldDelegate {
    private weak var browser: BrowserViewController?
    private let field = UISearchTextField()
    private let count = UILabel()
    private let table = UITableView(frame: .zero, style: .plain)
    private var result = PageFindResult.none
    private var task: Task<Void, Never>?
    /// The page the matches belong to.
    private weak var searchedPage: WKWebView?
    private var current: Int?
    /// The query the shown results are for: a Return before a newer search lands stays silent.
    private var shownQuery: String?

    init(browser: BrowserViewController?) {
        self.browser = browser
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        field.placeholder = String(localized: "Find on Page")
        field.accessibilityIdentifier = "sidePane.findField"
        field.returnKeyType = .search
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.delegate = self
        field.addAction(UIAction { [weak self] _ in self?.queryChanged() }, for: .editingChanged)
        count.font = .preferredFont(forTextStyle: .footnote)
        count.adjustsFontForContentSizeCategory = true
        count.textColor = .secondaryLabel
        count.accessibilityIdentifier = "sidePane.findCount"
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.keyboardDismissMode = .onDrag
        table.register(UITableViewCell.self, forCellReuseIdentifier: "match")
        table.accessibilityIdentifier = "sidePane.findResults"
        for subview in [field, count, table] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: view.topAnchor),
            field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Spacing.m),
            field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Spacing.m),
            count.topAnchor.constraint(equalTo: field.bottomAnchor, constant: Spacing.s),
            count.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: Spacing.xs),
            count.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            table.topAnchor.constraint(equalTo: count.bottomAnchor, constant: Spacing.xs),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        updateCount()
    }

    func sectionDidShow() {
        if searchedPage !== pageWebView { search() }
    }

    func pageDidChange() {
        // A new page (another tab, or this one navigated) gets the same query.
        guard let page = pageWebView, page !== searchedPage || browser?.currentTab?.isLoading == false else { return }
        search()
    }

    func focus() {
        field.becomeFirstResponder()
    }

    #if DEBUG
    func debugSearch(_ query: String) {
        field.text = query
        search()
    }
    #endif

    /// The marks come off the page; the list is searched again when Find shows next.
    func paneWillHide() {
        task?.cancel()
        if let searchedPage { PageFind.clear(in: searchedPage) }
        searchedPage = nil
        field.resignFirstResponder()
    }

    /// The focused page's web view, or the reader over it while that shows.
    private var pageWebView: WKWebView? {
        guard let browser, let tab = browser.currentTab else { return nil }
        return browser.engineUI.reader.webView ?? browser.session.pool.webView(for: tab)
    }

    private func queryChanged() {
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: FixedChoices.findDebounce)
            guard !Task.isCancelled else { return }
            self?.search()
        }
    }

    private func search() {
        task?.cancel()
        let query = field.text ?? ""
        guard let page = pageWebView else {
            show(.none, for: nil)
            return
        }
        if let searchedPage, searchedPage !== page { PageFind.clear(in: searchedPage) }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            PageFind.clear(in: page)
            show(.none, for: page)
            return
        }
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.sidePaneFind, id: signposter.makeSignpostID())
        task = Task { [weak self] in
            let found = await PageFind.find(query, in: page)
            signposter.endInterval(Signposts.sidePaneFind, interval, "\(found.total)")
            guard let self, !Task.isCancelled else { return }
            show(found, for: page)
        }
    }

    private func show(_ found: PageFindResult, for page: WKWebView?) {
        result = found
        shownQuery = field.text
        searchedPage = page
        current = nil
        table.reloadData()
        updateCount()
    }

    private func updateCount() {
        let query = field.text ?? ""
        if query.isEmpty {
            count.text = String(localized: "Type to find on this page.")
        } else if result.total == 0 {
            count.text = String(localized: "No matches")
        } else if result.total == 1 {
            count.text = String(localized: "1 match")
        } else if result.hasMore {
            count.text = String(localized: "More than \(result.matches.count) matches, the first listed")
        } else {
            count.text = String(localized: "\(result.total) matches")
        }
    }

    /// Return goes to the next match. Past the last it wraps to the first with a tick; with no
    /// matches for what is typed it bumps (docs/ui-reference.md, "Haptics"). A search still on its
    /// way stays silent.
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let query = field.text ?? ""
        let isCurrent = query == shownQuery
        guard !result.matches.isEmpty else {
            if isCurrent, !query.trimmingCharacters(in: .whitespaces).isEmpty { Haptic.nothingThere.play(in: field) }
            return false
        }
        let next = (current ?? -1) + 1
        reveal(next % result.matches.count)
        if isCurrent, next == result.matches.count { Haptic.selection.play(in: table) }
        return false
    }

    private func reveal(_ index: Int) {
        guard let page = searchedPage else { return }
        // A match is on the page: with the whole width, the page comes back beside the pane.
        browser?.showPageBesideSidePane()
        current = index
        table.selectRow(at: IndexPath(row: index, section: 0), animated: true, scrollPosition: .middle)
        Task { [weak self] in
            guard await PageFind.reveal(index, in: page) else {
                Haptic.nothingThere.play(in: self?.view)
                self?.search()
                return
            }
        }
    }

    // MARK: Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        result.matches.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "match", for: indexPath)
        let match = result.matches[indexPath.row]
        var content = UIListContentConfiguration.cell()
        let body = UIFont.preferredFont(forTextStyle: .subheadline)
        let text = NSMutableAttributedString(
            string: (match.before.isEmpty ? "" : "…" + match.before),
            attributes: [.font: body, .foregroundColor: UIColor.secondaryLabel]
        )
        let bold = UIFont.systemFont(ofSize: body.pointSize, weight: .semibold)
        text.append(NSAttributedString(string: match.match, attributes: [.font: bold, .foregroundColor: UIColor.label]))
        text.append(NSAttributedString(
            string: match.after + (match.after.isEmpty ? "" : "…"),
            attributes: [.font: body, .foregroundColor: UIColor.secondaryLabel]
        ))
        content.attributedText = text
        content.textProperties.numberOfLines = 3
        cell.contentConfiguration = content
        cell.backgroundColor = .clear
        cell.accessibilityIdentifier = "sidePane.match.\(indexPath.row)"
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        field.resignFirstResponder()
        reveal(indexPath.row)
    }
}

// MARK: - History

/// History beside the page (the History sheet's screen without its Done button): a row opens in
/// the page, and the pane stays.
final class SidePaneHistory: UIViewController, SidePaneContent {
    private weak var browser: BrowserViewController?
    private var host: UIViewController?
    /// The profile whose history shows: the window's when it was built.
    private var shownProfile: ProfileID?

    init(browser: BrowserViewController?) {
        self.browser = browser
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    func sectionDidShow() { buildIfNeeded() }

    /// The window moved to another profile's tab: its history shows instead.
    func pageDidChange() { buildIfNeeded() }

    private func buildIfNeeded() {
        guard let browser else { return }
        let profile = browser.session.tabs.activeProfile
        guard host == nil || shownProfile != profile else { return }
        guard let history = browser.sheets.historyPane(onOpen: { [weak browser] url in browser?.openFromSidePane(url) }) else { return }
        if let host {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
        addChild(history)
        history.view.frame = view.bounds
        history.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(history.view)
        history.didMove(toParent: self)
        host = history
        shownProfile = profile
    }
}
private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
#endif
