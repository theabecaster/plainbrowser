#if canImport(UIKit)
import DesignSystem
import os
import PerfSignposts
import UIKit

/// Side tabs: the window's tabs in a sidebar (docs/decisions.md, "Duo inner screen: the sidebar").
///
/// A rail of site icons that widens to show titles: New Tab on top, the tabs, and Show Titles at
/// the bottom. The content is always laid out at the expanded width and the host sizes the view:
/// at the rail's width the view clips it to the tiles, so resizing between Hidden, Rail and
/// Expanded moves one edge and never lays the rows out again; the selection mark and the titles'
/// opacity follow the width (`visibleWidth`). The host owns the width: a horizontal drag anywhere
/// on the sidebar reports through `onResize`, the bottom row through `onToggleTitles`, and the
/// host springs it to a state.
///
/// Rows come from `SideTabsDataSource` (the shell's `TabStore`): tap to show a tab in the focused
/// pane, drag to reorder, close from the row (Expanded) or its menu, New Tab on top (a long press
/// offers the other kind).
///
/// Private is a mode (docs/decisions.md, "Private as a clear mode on wide screens"): the head's two
/// rows, Private and Tabs, are the Private | Tabs switch, one tap each way, and the list shows the
/// shown mode's tabs only. While private the whole column is Night, drawn dark.
public final class SideTabsViewController: UIViewController, UICollectionViewDelegate,
    UICollectionViewDragDelegate, UICollectionViewDropDelegate, UIGestureRecognizerDelegate {
    public enum ResizePhase {
        case began, changed, ended
    }

    private let dataSource: any SideTabsDataSource
    /// A horizontal drag on the sidebar: its phase, the finger's travel since it began and its
    /// velocity (points per second, positive widens).
    public var onResize: ((ResizePhase, CGFloat, CGFloat) -> Void)?

    private(set) var collectionView: UICollectionView!
    private var diffable: UICollectionViewDiffableDataSource<Int, UUID>!
    private let header = UIStackView()
    private let privateRow = SideActionRow(symbolName: "hand.raised", title: String(localized: "Private"), prominent: false)
    private let tabsRow = SideActionRow(symbolName: "square.on.square", title: String(localized: "Tabs"), prominent: false)
    /// The hairline between the switch and the list.
    private let headRule = UIView()
    private let newTabButton = SideActionRow(symbolName: "plus", title: String(localized: "New Tab"), prominent: true)
    private let titlesButton = SideActionRow(symbolName: "sidebar.left", title: String(localized: "Show Titles"), prominent: false)
    private let separator = UIView()
    /// Show Titles (or Hide Titles) was tapped: the host widens the rail or brings it back.
    public var onToggleTitles: (() -> Void)?
    private var items: [UUID: TabGalleryItem] = [:]
    private var focusedID: UUID?
    private var otherID: UUID?
    /// The mode the rows shown belong to.
    private(set) var showsPrivate = false

    private static let regularSection = 0

    /// How much of the rows the host shows now (the sidebar's width): the rail's shows tiles
    /// only, more brings the titles and close buttons in. Set inside an animation, the selection
    /// mark and the titles follow the sidebar's spring; under a finger they follow it 1:1. Sets
    /// frames and opacities on the rows on screen; nothing is laid out again.
    public var visibleWidth: CGFloat = SidebarState.rail.width {
        didSet {
            guard visibleWidth != oldValue, isViewLoaded else { return }
            applyVisibleWidth()
        }
    }

    /// The sidebar rests showing titles (Expanded): the bottom row offers to hide them.
    public var showsTitles = false {
        didSet {
            guard showsTitles != oldValue, isViewLoaded else { return }
            updateTitlesButton()
        }
    }

    /// The rail may widen here (not during a split or a book pose): the bottom row shows.
    public var canShowTitles = true {
        didSet {
            guard canShowTitles != oldValue, isViewLoaded else { return }
            titlesButton.isHidden = !canShowTitles
        }
    }

    private func applyVisibleWidth() {
        let width = visibleWidth
        for case let cell as SideTabCell in collectionView.visibleCells { cell.setVisibleWidth(width) }
        newTabButton.setVisibleWidth(width)
        titlesButton.setVisibleWidth(width)
        privateRow.setVisibleWidth(width)
        tabsRow.setVisibleWidth(width)
    }

    private func updateTitlesButton() {
        titlesButton.set(
            symbolName: isOnRight ? "sidebar.right" : "sidebar.left",
            title: showsTitles ? String(localized: "Hide Titles") : String(localized: "Show Titles")
        )
    }

    /// Expanded floats over the page (the page would be too narrow beside it): it casts a shadow.
    public var floats = false {
        didSet { view.layer.shadowOpacity = floats ? 0.18 : 0 }
    }

    /// Tab Layout: Right. The sidebar sits on the trailing side: its edge with the page (and the
    /// hairline) is its leading one, and it widens toward the page. Rows keep the tile first.
    public var isOnRight = false {
        didSet {
            guard isViewLoaded, isOnRight != oldValue else { return }
            updateTitlesButton()
            // The outgoing edge lets go first.
            (isOnRight ? separatorOnTrailing : separatorOnLeading)?.isActive = false
            (isOnRight ? separatorOnLeading : separatorOnTrailing)?.isActive = true
        }
    }
    private var separatorOnTrailing: NSLayoutConstraint!
    private var separatorOnLeading: NSLayoutConstraint!
    /// The tabs start under the safe area, or with the first row centered on `firstRowCenter`.
    private var contentUnderSafeArea: NSLayoutConstraint!
    private var contentFromTop: NSLayoutConstraint!

    /// Where the first row (New Tab) is centered, from this view's top, or nil for just under the
    /// safe area. The column runs from the screen's top edge; beside an empty status zone (the
    /// Duo's inner screen, status items in the other corner) its first row sits on the top bar's
    /// row, so no empty paper stands above it.
    public func setFirstRowCenter(_ center: CGFloat?) {
        loadViewIfNeeded()
        if let center {
            let top = center - SideTabMetrics.rowHeight / 2 - Spacing.xs
            if contentFromTop.constant != top { contentFromTop.constant = top }
        }
        let fromTop = center != nil
        guard contentFromTop.isActive != fromTop else { return }
        // The outgoing one lets go first.
        if fromTop {
            contentUnderSafeArea.isActive = false
            contentFromTop.isActive = true
        } else {
            contentFromTop.isActive = false
            contentUnderSafeArea.isActive = true
        }
    }

    public init(dataSource: any SideTabsDataSource) {
        self.dataSource = dataSource
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func viewDidLoad() {
        super.viewDidLoad()
        Paper.apply(to: view)
        view.clipsToBounds = false
        view.layer.shadowColor = Palette.floatingShadow.cgColor
        view.layer.shadowRadius = 12
        view.layer.shadowOffset = .zero
        view.accessibilityIdentifier = "sideTabs"

        // The content keeps the expanded width; this view clips it.
        let content = UIView()
        content.clipsToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)

        newTabButton.accessibilityIdentifier = "sideTabs.newTab"
        newTabButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            dataSource.newTab(private: showsPrivate)
        }, for: .primaryActionTriggered)
        // The other kind, which a tap does not open.
        newTabButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self else { return completion([]) }
                let toPrivate = !showsPrivate
                completion([UIAction(
                    title: toPrivate ? String(localized: "New Private Tab") : String(localized: "New Tab"),
                    image: UIImage(systemName: toPrivate ? "hand.raised" : "plus")
                ) { [weak self] _ in self?.dataSource.newTab(private: toPrivate) }])
            },
        ])
        privateRow.accessibilityIdentifier = "sideTabs.private"
        tabsRow.accessibilityIdentifier = "sideTabs.regular"
        for (row, isPrivate) in [(privateRow, true), (tabsRow, false)] {
            row.addAction(UIAction { [weak self] _ in self?.modeTapped(isPrivate) }, for: .primaryActionTriggered)
        }
        privateRow.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in completion(self?.privateMenu() ?? []) },
        ])
        headRule.backgroundColor = Palette.paperHairline
        headRule.translatesAutoresizingMaskIntoConstraints = false
        let ruleRow = UIView()
        ruleRow.addSubview(headRule)
        titlesButton.accessibilityIdentifier = "sideTabs.titles"
        titlesButton.addAction(UIAction { [weak self] _ in self?.onToggleTitles?() }, for: .primaryActionTriggered)
        titlesButton.translatesAutoresizingMaskIntoConstraints = false
        titlesButton.isHidden = !canShowTitles
        content.addSubview(titlesButton)
        updateTitlesButton()
        header.axis = .vertical
        header.translatesAutoresizingMaskIntoConstraints = false
        for row in [privateRow, tabsRow, ruleRow, newTabButton] { header.addArrangedSubview(row) }
        content.addSubview(header)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: Self.makeLayout())
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.dragDelegate = self
        collectionView.dropDelegate = self
        collectionView.dragInteractionEnabled = true
        collectionView.alwaysBounceVertical = true
        collectionView.showsVerticalScrollIndicator = false
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.register(SideTabCell.self, forCellWithReuseIdentifier: SideTabCell.reuseID)
        content.addSubview(collectionView)

        separator.backgroundColor = Palette.paperHairline
        separator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(separator)

        let width = SidebarState.expanded.width
        contentUnderSafeArea = content.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        contentFromTop = content.topAnchor.constraint(equalTo: view.topAnchor)
        NSLayoutConstraint.activate([
            // The column (its paper, separator and shadow) runs to the screen's top edge; the
            // tabs start under the status bar, the safe area this view gets from its parent, or on
            // the top bar's row (`setFirstRowCenter`).
            contentUnderSafeArea,
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: Spacing.xs),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.widthAnchor.constraint(equalToConstant: width),
            privateRow.heightAnchor.constraint(equalToConstant: SideTabMetrics.rowHeight),
            tabsRow.heightAnchor.constraint(equalToConstant: SideTabMetrics.rowHeight),
            // Below required: the stack collapses the row to zero while it is hidden.
            newTabButton.heightAnchor.constraint(equalToConstant: SideTabMetrics.rowHeight).withPriority(.required - 1),
            // A hairline under the switch, as wide as the rail's tiles in the rail and the
            // titled rows' plates past it (it is clipped with them).
            ruleRow.heightAnchor.constraint(equalToConstant: Spacing.s + 1),
            headRule.heightAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)),
            headRule.centerYAnchor.constraint(equalTo: ruleRow.centerYAnchor),
            headRule.leadingAnchor.constraint(equalTo: ruleRow.leadingAnchor, constant: Spacing.s),
            headRule.trailingAnchor.constraint(equalTo: ruleRow.trailingAnchor, constant: -Spacing.s),
            collectionView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Spacing.xs),
            collectionView.bottomAnchor.constraint(equalTo: titlesButton.topAnchor),
            // The bottom row stands clear of the home indicator.
            titlesButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Spacing.xs),
            titlesButton.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            titlesButton.widthAnchor.constraint(equalToConstant: width),
            titlesButton.heightAnchor.constraint(equalToConstant: SideTabMetrics.rowHeight),
            collectionView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            collectionView.widthAnchor.constraint(equalToConstant: width),
            separator.topAnchor.constraint(equalTo: view.topAnchor),
            separator.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)),
        ])
        separatorOnTrailing = separator.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        separatorOnLeading = separator.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        separatorOnTrailing.isActive = !isOnRight
        separatorOnLeading.isActive = isOnRight

        diffable = UICollectionViewDiffableDataSource<Int, UUID>(collectionView: collectionView) { [weak self] collectionView, indexPath, id in
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: SideTabCell.reuseID, for: indexPath)
            if let self, let cell = cell as? SideTabCell { self.configure(cell, id: id) }
            return cell
        }
        diffable.reorderingHandlers.canReorderItem = { _ in true }
        diffable.reorderingHandlers.didReorder = { [weak self] transaction in
            self?.didReorder(transaction)
        }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)

        reloadTabs()
        applyVisibleWidth()
    }

    private static func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, _ in
            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(SideTabMetrics.rowHeight))
            )
            let group = NSCollectionLayoutGroup.vertical(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(SideTabMetrics.rowHeight)),
                subitems: [item]
            )
            return NSCollectionLayoutSection(group: group)
        }
    }

    // MARK: Tabs

    /// The header's New Tab: hidden on an empty tab, which New Tab would only repeat
    /// (docs/state-rules.md, principle 8). The shell decides from its state rules.
    public func setNewTabShown(_ shown: Bool) {
        loadViewIfNeeded()
        newTabButton.isHidden = !shown
    }

    /// The column's look: Paper, or Night drawn dark while private, as the top bar's glass, so the
    /// whole screen says which mode it is in. Set inside the chrome's mode change (`Motion.quick`).
    public func setPrivate(_ isPrivate: Bool) {
        loadViewIfNeeded()
        let style: UIUserInterfaceStyle = isPrivate ? .dark : .unspecified
        guard view.overrideUserInterfaceStyle != style else { return }
        view.overrideUserInterfaceStyle = style
        if isPrivate {
            view.backgroundColor = Palette.privateBackground
        } else {
            Paper.apply(to: view)
        }
    }

    /// A row of the switch was tapped: the other mode comes on screen; the shown one does nothing.
    private func modeTapped(_ isPrivate: Bool) {
        guard isPrivate != showsPrivate else { return }
        Haptic.selection.play()
        dataSource.showMode(private: isPrivate)
        reloadTabs()
    }

    /// The Private row's long press: a new private tab, and Close All Private Tabs while there
    /// are any.
    private func privateMenu() -> [UIMenuElement] {
        let new = UIAction(title: String(localized: "New Private Tab"), image: UIImage(systemName: "hand.raised")) { [weak self] _ in
            self?.dataSource.newTab(private: true)
            self?.reloadTabs()
        }
        new.accessibilityIdentifier = "sideTabs.newPrivateTab"
        guard dataSource.privateCount > 0 else { return [new] }
        let closeAll = UIAction(
            title: String(localized: "Close All Private Tabs"), image: UIImage(systemName: "hand.raised.slash"), attributes: .destructive
        ) { [weak self] _ in
            self?.dataSource.closeAllPrivateTabs()
            self?.reloadTabs()
        }
        closeAll.accessibilityIdentifier = "sideTabs.closeAllPrivate"
        return [new, UIMenu(options: .displayInline, children: [closeAll])]
    }

    /// Reads the tabs again (a title, a selection, a close elsewhere) and shows what changed. A
    /// change of mode swaps the whole list in one crossfade.
    public func reloadTabs() {
        guard isViewLoaded else { return }
        let modeChanged = dataSource.showsPrivate != showsPrivate
        showsPrivate = dataSource.showsPrivate
        let shown = dataSource.tabs
        var next: [UUID: TabGalleryItem] = [:]
        for item in shown { next[item.id] = item }
        let focused = dataSource.focusedTabID
        let other = dataSource.otherPaneTabID

        privateRow.set(symbolName: showsPrivate ? "hand.raised.fill" : "hand.raised", title: String(localized: "Private"))
        privateRow.setMode(selected: showsPrivate, isPrivateRow: true, count: dataSource.privateCount)
        tabsRow.setMode(selected: !showsPrivate, isPrivateRow: false, count: dataSource.regularCount)
        newTabButton.set(
            symbolName: "plus", title: showsPrivate ? String(localized: "New Private Tab") : String(localized: "New Tab")
        )

        var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        snapshot.appendSections([Self.regularSection])
        snapshot.appendItems(shown.map(\.id), toSection: Self.regularSection)
        let old = diffable.snapshot()
        let marked = Set([focusedID, otherID, focused, other].compactMap { $0 })
        let changed = next.keys.filter { id in
            old.indexOfItem(id) != nil && (items[id] != next[id] || marked.contains(id))
        }
        snapshot.reconfigureItems(changed)
        let focusMoved = focused != focusedID || modeChanged
        items = next
        focusedID = focused
        otherID = other
        let animated = old.numberOfItems > 0 && view.window != nil
        if focusMoved { needsFocusScroll = true }
        if modeChanged, view.window != nil {
            // The rows of the mode left go in one quick fade, the new ones come in with it.
            Motion.crossfadeMode(collectionView) {
                self.diffable.apply(snapshot, animatingDifferences: false)
            }
        } else {
            diffable.apply(snapshot, animatingDifferences: animated)
        }
        scrollFocusedIntoViewIfNeeded(animated: animated && !modeChanged)
    }

    /// The tab on screen has not been brought into view since the focus moved (or the list was
    /// built: a rail made while the twentieth tab shows starts on it, not on the first).
    private var needsFocusScroll = true

    /// Brings the focused tab's row into view when it is not fully there; a row already in view
    /// stays where it is, so picking a tab never moves the list under the finger.
    private func scrollFocusedIntoViewIfNeeded(animated: Bool) {
        guard needsFocusScroll, collectionView.bounds.height > 0, let focusedID,
              let indexPath = diffable.indexPath(for: focusedID) else { return }
        collectionView.layoutIfNeeded()
        // No geometry yet (a row just inserted): the next layout pass tries again.
        guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame, frame.height > 0 else {
            view.setNeedsLayout()
            return
        }
        needsFocusScroll = false
        guard !collectionView.bounds.contains(frame) else { return }
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: animated)
    }

    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollFocusedIntoViewIfNeeded(animated: false)
    }

    private func configure(_ cell: SideTabCell, id: UUID) {
        guard let item = items[id] else { return }
        cell.configure(
            item: item, isFocused: id == focusedID, isInOtherPane: id == otherID, visibleWidth: visibleWidth, icons: dataSource
        )
        cell.onClose = { [weak self] in self?.close(id) }
    }

    private func close(_ id: UUID) {
        Haptic.close.play()
        dataSource.closeTab(id)
        reloadTabs()
    }

    private func didReorder(_ transaction: NSDiffableDataSourceTransaction<Int, UUID>) {
        for move in TabListReorder.moves(in: transaction) {
            Signposts.signposter.emitEvent(Signposts.galleryReorder, "sidebar")
            Haptic.drop.play()
            dataSource.moveTab(move.id, to: move.index)
        }
        // The store may keep pinned tabs first: show its order. After the reorder has been
        // committed: a snapshot applied inside the handler raises in UIKit (the strip crashed so
        // on TestFlight).
        DispatchQueue.main.async { [weak self] in self?.reloadTabs() }
    }

    // MARK: UICollectionViewDelegate

    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let id = diffable.itemIdentifier(for: indexPath) else { return }
        dataSource.selectTab(id)
        reloadTabs()
    }

    public func collectionView(
        _ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let indexPath = indexPaths.first, let id = diffable.itemIdentifier(for: indexPath)
        else { return nil }
        return UIContextMenuConfiguration(identifier: id as NSUUID, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            var top: [UIMenuElement] = []
            if dataSource.canOpenInOtherPane, id != focusedID || otherID != nil {
                let other = UIAction(title: "Open in Other Pane", image: UIImage(systemName: "rectangle.split.2x1")) { [weak self] _ in
                    self?.dataSource.openInOtherPane(id)
                    self?.reloadTabs()
                }
                other.accessibilityIdentifier = "sideTabs.otherPane"
                top.append(other)
            }
            let close = UIAction(title: "Close Tab", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
                self?.close(id)
            }
            return UIMenu(children: top + [UIMenu(options: .displayInline, children: [close])])
        }
    }

    // MARK: Drag to reorder

    public func collectionView(
        _ collectionView: UICollectionView, itemsForBeginning session: any UIDragSession, at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard let id = diffable.itemIdentifier(for: indexPath) else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider())
        item.localObject = id
        dragDestination = nil
        Haptic.selection.prepare()
        return [item]
    }

    public func collectionView(
        _ collectionView: UICollectionView, dropSessionDidUpdate session: any UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UICollectionViewDropProposal {
        // Local moves within the shown list only: the other mode's tabs are never in it, so a
        // regular tab never becomes private.
        guard let id = session.localDragSession?.items.first?.localObject as? UUID,
              let source = diffable.snapshot().sectionIdentifier(containingItem: id),
              let destination = destinationIndexPath, destination.section == source
        else { return UICollectionViewDropProposal(operation: .forbidden) }
        // A tick as the dragged tab reaches each new place (not the one it started from).
        if destination != dragDestination {
            if dragDestination != nil { Haptic.selection.play() }
            dragDestination = destination
        }
        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    /// Where the tab being dragged would land now, to tick once per new place.
    private var dragDestination: IndexPath?

    /// The diffable data source performs local moves itself (`reorderingHandlers`).
    public func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: any UICollectionViewDropCoordinator) {}

    // MARK: Resize

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        return abs(velocity.x) > abs(velocity.y) * 1.2
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let travel = pan.translation(in: view.superview).x
        let velocity = pan.velocity(in: view.superview).x
        switch pan.state {
        case .began: onResize?(.began, travel, velocity)
        case .changed: onResize?(.changed, travel, velocity)
        case .ended, .cancelled, .failed: onResize?(.ended, travel, pan.state == .ended ? velocity : 0)
        default: break
        }
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
#endif
