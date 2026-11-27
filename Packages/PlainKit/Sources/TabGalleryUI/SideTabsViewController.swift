#if canImport(UIKit)
import DesignSystem
import os
import PerfSignposts
import UIKit

/// Side tabs: the window's tabs in a leading sidebar (docs/plan.md, section 6, "Side tabs design").
///
/// The content is always laid out at the expanded width and the host sizes the view: at the rail's
/// width the view clips it to the site tiles, so resizing between Hidden, Rail and Expanded moves
/// one edge and never lays the rows out again. The host owns the width: a horizontal drag anywhere
/// on the sidebar reports through `onResize`, and the host springs it to a state.
///
/// Rows come from `SideTabsDataSource` (the shell's `TabStore`): tap to show a tab in the focused
/// pane, drag to reorder, close from the row (Expanded) or its menu, New Tab on top (a long press
/// offers New Private Tab), private tabs in their own section.
public final class SideTabsViewController: UIViewController, UICollectionViewDelegate,
    UICollectionViewDragDelegate, UICollectionViewDropDelegate, UIGestureRecognizerDelegate {
    public enum ResizePhase {
        case began, changed, ended
    }

    private let dataSource: any SideTabsDataSource
    /// A horizontal drag on the sidebar: its phase, the finger's travel since it began and its
    /// velocity (points per second, positive widens).
    public var onResize: ((ResizePhase, CGFloat, CGFloat) -> Void)?

    private var collectionView: UICollectionView!
    private var diffable: UICollectionViewDiffableDataSource<Int, UUID>!
    private let header = UIView()
    private let newTabButton = UIButton(type: .system)
    private let separator = UIView()
    private var items: [UUID: TabGalleryItem] = [:]
    private var focusedID: UUID?
    private var otherID: UUID?

    private static let regularSection = 0
    private static let privateSection = 1
    private static let privateHeaderKind = "privateHeader"

    /// Titles and close buttons show (Expanded); the rail shows tiles only.
    public var showsTitles = false {
        didSet {
            guard showsTitles != oldValue else { return }
            configureVisibleCells()
            newTabButton.configuration?.title = showsTitles ? "New Tab" : nil
        }
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
            let top = center - SideTabCell.height / 2 - Spacing.xs
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

        var button = UIButton.Configuration.plain()
        button.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(textStyle: .headline))
        button.imagePadding = SidebarState.rail.width - SideTabCell.tileSize - Spacing.m
        button.contentInsets = NSDirectionalEdgeInsets(
            top: 0, leading: (SidebarState.rail.width - 20) / 2, bottom: 0, trailing: Spacing.m
        )
        button.baseForegroundColor = Palette.accent
        newTabButton.configuration = button
        newTabButton.contentHorizontalAlignment = .leading
        newTabButton.accessibilityIdentifier = "sideTabs.newTab"
        newTabButton.accessibilityLabel = "New Tab"
        newTabButton.addAction(UIAction { [weak self] _ in self?.dataSource.newTab(private: false) }, for: .primaryActionTriggered)
        newTabButton.menu = UIMenu(children: [
            UIAction(title: "New Private Tab", image: UIImage(systemName: "hand.raised")) { [weak self] _ in
                self?.dataSource.newTab(private: true)
            },
        ])
        newTabButton.showsMenuAsPrimaryAction = false
        newTabButton.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(newTabButton)
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
        collectionView.register(
            PrivateHeaderView.self, forSupplementaryViewOfKind: Self.privateHeaderKind, withReuseIdentifier: PrivateHeaderView.reuseID
        )
        content.addSubview(collectionView)

        separator.backgroundColor = UIColor.separator
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
            header.heightAnchor.constraint(equalToConstant: SideTabCell.height),
            newTabButton.topAnchor.constraint(equalTo: header.topAnchor),
            newTabButton.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            newTabButton.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            newTabButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: header.bottomAnchor),
            collectionView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
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
        diffable.supplementaryViewProvider = { collectionView, kind, indexPath in
            collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: PrivateHeaderView.reuseID, for: indexPath)
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
    }

    private static func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { section, _ in
            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(SideTabCell.height))
            )
            let group = NSCollectionLayoutGroup.vertical(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(SideTabCell.height)),
                subitems: [item]
            )
            let layoutSection = NSCollectionLayoutSection(group: group)
            if section == privateSection {
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(32)),
                    elementKind: privateHeaderKind, alignment: .top
                )
                layoutSection.boundarySupplementaryItems = [header]
            }
            return layoutSection
        }
    }

    // MARK: Tabs

    /// Reads the tabs again (a title, a selection, a close elsewhere) and shows what changed.
    /// The header's New Tab: hidden on an empty tab, which New Tab would only repeat
    /// (docs/state-rules.md, principle 8). The shell decides from its state rules.
    public func setNewTabShown(_ shown: Bool) {
        loadViewIfNeeded()
        newTabButton.isHidden = !shown
    }

    public func reloadTabs() {
        guard isViewLoaded else { return }
        let regular = dataSource.regularTabs
        let privateTabs = dataSource.privateTabs
        var next: [UUID: TabGalleryItem] = [:]
        for item in regular + privateTabs { next[item.id] = item }
        let focused = dataSource.focusedTabID
        let other = dataSource.otherPaneTabID

        var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        snapshot.appendSections([Self.regularSection])
        snapshot.appendItems(regular.map(\.id), toSection: Self.regularSection)
        if !privateTabs.isEmpty {
            snapshot.appendSections([Self.privateSection])
            snapshot.appendItems(privateTabs.map(\.id), toSection: Self.privateSection)
        }
        let old = diffable.snapshot()
        let marked = Set([focusedID, otherID, focused, other].compactMap { $0 })
        let changed = next.keys.filter { id in
            old.indexOfItem(id) != nil && (items[id] != next[id] || marked.contains(id))
        }
        snapshot.reconfigureItems(changed)
        items = next
        focusedID = focused
        otherID = other
        diffable.apply(snapshot, animatingDifferences: old.numberOfItems > 0 && view.window != nil)
    }

    private func configure(_ cell: SideTabCell, id: UUID) {
        guard let item = items[id] else { return }
        cell.configure(item: item, isFocused: id == focusedID, isInOtherPane: id == otherID, showsTitle: showsTitles)
        cell.onClose = { [weak self] in self?.close(id) }
    }

    private func configureVisibleCells() {
        guard isViewLoaded else { return }
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let id = diffable.itemIdentifier(for: indexPath),
                  let cell = collectionView.cellForItem(at: indexPath) as? SideTabCell else { continue }
            configure(cell, id: id)
        }
    }

    private func close(_ id: UUID) {
        Haptic.close.play()
        dataSource.closeTab(id)
        reloadTabs()
    }

    private func didReorder(_ transaction: NSDiffableDataSourceTransaction<Int, UUID>) {
        for change in transaction.difference {
            guard case let .insert(_, id, _) = change,
                  let section = transaction.finalSnapshot.sectionIdentifier(containingItem: id),
                  let index = transaction.finalSnapshot.itemIdentifiers(inSection: section).firstIndex(of: id) else { continue }
            Signposts.signposter.emitEvent(Signposts.galleryReorder, "sidebar")
            dataSource.moveTab(id, to: index)
        }
        // The store may keep pinned tabs first: show its order.
        reloadTabs()
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
        return [item]
    }

    public func collectionView(
        _ collectionView: UICollectionView, dropSessionDidUpdate session: any UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UICollectionViewDropProposal {
        // Local moves within a list only: a regular tab never becomes private.
        guard let id = session.localDragSession?.items.first?.localObject as? UUID,
              let source = diffable.snapshot().sectionIdentifier(containingItem: id),
              let destination = destinationIndexPath, destination.section == source
        else { return UICollectionViewDropProposal(operation: .forbidden) }
        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

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

/// The private section's header: an icon on the rail, "Private" beside it.
private final class PrivateHeaderView: UICollectionReusableView {
    static let reuseID = "PrivateHeader"

    override init(frame: CGRect) {
        super.init(frame: frame)
        let icon = UIImageView(image: UIImage(systemName: "hand.raised.fill"))
        icon.tintColor = Palette.textSecondary
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
        icon.contentMode = .center
        let label = UILabel()
        label.text = "Private"
        label.font = UIFont.preferredFont(forTextStyle: .caption1)
        label.textColor = Palette.textSecondary
        for subview in [icon, label] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        let rail = SidebarState.rail.width
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: leadingAnchor, constant: rail / 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: rail),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isAccessibilityElement = true
        accessibilityLabel = "Private Tabs"
        accessibilityTraits = .header
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
#endif
