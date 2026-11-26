#if canImport(UIKit)
import BrowserCore
import DesignSystem
import PerfSignposts
import UIKit

/// Tab Layout: Above. A compact strip of tabs across the top of the page area, Safari-on-iPad
/// style: one row that scrolls sideways, the focused pane's tab marked, New Tab (+) at the end
/// (a long press offers New Private Tab). Tap a tab to show it, long press for Open in Other Pane
/// and Close Tab, drag to reorder; the focused tab also has a close button. Private tabs follow the
/// regular ones, tinted.
///
/// It reads the same `SideTabsDataSource` as the sidebar (the shell's `TabStore`), and never owns
/// tab state. Height and tab width are `FixedChoices.tabStripHeight` and `tabStripItemWidth`.
public final class TabStripViewController: UIViewController, UICollectionViewDelegate,
    UICollectionViewDragDelegate, UICollectionViewDropDelegate {
    private let dataSource: any SideTabsDataSource
    private var collectionView: UICollectionView!
    private var diffable: UICollectionViewDiffableDataSource<Int, UUID>!
    private let newTabButton = UIButton(type: .system)
    private var items: [UUID: TabGalleryItem] = [:]
    private var focusedID: UUID?
    private var otherID: UUID?

    private static let regularSection = 0
    private static let privateSection = 1

    public init(dataSource: any SideTabsDataSource) {
        self.dataSource = dataSource
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.background
        view.accessibilityIdentifier = "tabStrip"

        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = Spacing.xs
        layout.sectionInset = UIEdgeInsets(top: 0, left: Spacing.s, bottom: 0, right: 0)
        layout.itemSize = CGSize(width: CGFloat(FixedChoices.tabStripItemWidth), height: Metrics.tapTarget - Spacing.xs)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.alwaysBounceHorizontal = true
        collectionView.delegate = self
        collectionView.dragDelegate = self
        collectionView.dropDelegate = self
        collectionView.dragInteractionEnabled = true
        collectionView.register(TabStripCell.self, forCellWithReuseIdentifier: TabStripCell.reuseID)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        newTabButton.setImage(
            UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(textStyle: .headline)), for: .normal
        )
        newTabButton.tintColor = Palette.accent
        newTabButton.accessibilityIdentifier = "tabStrip.newTab"
        newTabButton.accessibilityLabel = "New Tab"
        newTabButton.addAction(UIAction { [weak self] _ in self?.dataSource.newTab(private: false) }, for: .primaryActionTriggered)
        newTabButton.menu = UIMenu(children: [
            UIAction(title: "New Private Tab", image: UIImage(systemName: "hand.raised")) { [weak self] _ in
                self?.dataSource.newTab(private: true)
            },
        ])
        newTabButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(newTabButton)

        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(separator)

        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: newTabButton.leadingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: separator.topAnchor),
            newTabButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Spacing.xs),
            newTabButton.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor),
            newTabButton.widthAnchor.constraint(equalToConstant: Metrics.tapTarget),
            newTabButton.heightAnchor.constraint(equalToConstant: Metrics.tapTarget),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)),
        ])

        diffable = UICollectionViewDiffableDataSource<Int, UUID>(collectionView: collectionView) { [weak self] collectionView, indexPath, id in
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TabStripCell.reuseID, for: indexPath)
            if let self, let cell = cell as? TabStripCell, let item = items[id] {
                cell.configure(item: item, isFocused: id == focusedID, isInOtherPane: id == otherID && id != focusedID)
                cell.onClose = { [weak self] in self?.close(id) }
            }
            return cell
        }
        diffable.reorderingHandlers.canReorderItem = { _ in true }
        diffable.reorderingHandlers.didReorder = { [weak self] transaction in
            guard let self else { return }
            for change in transaction.difference {
                guard case let .insert(_, id, _) = change,
                      let section = transaction.finalSnapshot.sectionIdentifier(containingItem: id),
                      let index = transaction.finalSnapshot.itemIdentifiers(inSection: section).firstIndex(of: id) else { continue }
                Signposts.signposter.emitEvent(Signposts.galleryReorder, "strip")
                dataSource.moveTab(id, to: index)
            }
            reloadTabs()
        }
        reloadTabs()
    }

    /// Reads the tabs again and shows what changed; the focused tab scrolls into view when the
    /// focus moved.
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
        snapshot.reconfigureItems(next.keys.filter { old.indexOfItem($0) != nil && (items[$0] != next[$0] || marked.contains($0)) })
        let focusMoved = focused != focusedID
        items = next
        focusedID = focused
        otherID = other
        diffable.apply(snapshot, animatingDifferences: old.numberOfItems > 0 && view.window != nil)
        if focusMoved, let focused, let indexPath = diffable.indexPath(for: focused) {
            collectionView.scrollToItem(at: indexPath, at: .centeredHorizontally, animated: view.window != nil)
        }
    }

    private func close(_ id: UUID) {
        Haptic.close.play()
        dataSource.closeTab(id)
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
                top.append(UIAction(title: "Open in Other Pane", image: UIImage(systemName: "rectangle.split.2x1")) { [weak self] _ in
                    self?.dataSource.openInOtherPane(id)
                    self?.reloadTabs()
                })
            }
            let close = UIAction(title: "Close Tab", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
                self?.close(id)
            }
            return UIMenu(children: top + [UIMenu(options: .displayInline, children: [close])])
        }
    }

    // MARK: Drag to reorder (within a list)

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
        guard let id = session.localDragSession?.items.first?.localObject as? UUID,
              let source = diffable.snapshot().sectionIdentifier(containingItem: id),
              let destination = destinationIndexPath, destination.section == source
        else { return UICollectionViewDropProposal(operation: .forbidden) }
        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    /// The diffable data source performs local moves itself (`reorderingHandlers`).
    public func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: any UICollectionViewDropCoordinator) {}
}

/// One tab in the strip: the site tile, the title, and a close button on the focused tab.
final class TabStripCell: UICollectionViewCell {
    static let reuseID = "TabStripCell"
    var onClose: (() -> Void)?

    private let highlight = UIView()
    private let tile = UIView()
    private let letter = UILabel()
    private let symbol = UIImageView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private var isInOtherPane = false
    private static let tileSize: CGFloat = 24

    override init(frame: CGRect) {
        super.init(frame: frame)
        highlight.layer.cornerRadius = Radius.large
        highlight.layer.cornerCurve = .continuous
        contentView.addSubview(highlight)
        tile.layer.cornerRadius = Radius.small
        tile.layer.cornerCurve = .continuous
        contentView.addSubview(tile)
        letter.font = UIFont.preferredFont(forTextStyle: .caption1).withSize(13)
        letter.textAlignment = .center
        letter.textColor = Palette.textSecondary
        tile.addSubview(letter)
        symbol.contentMode = .center
        symbol.tintColor = Palette.textSecondary
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
        tile.addSubview(symbol)
        titleLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        titleLabel.textColor = Palette.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(titleLabel)
        closeButton.setImage(
            UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption2, scale: .small)),
            for: .normal
        )
        closeButton.tintColor = Palette.textSecondary
        closeButton.accessibilityLabel = "Close Tab"
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .primaryActionTriggered)
        contentView.addSubview(closeButton)
        isAccessibilityElement = true
        accessibilityIdentifier = "stripTab"
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: TabStripCell, _) in cell.resolveBorder() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(item: TabGalleryItem, isFocused: Bool, isInOtherPane: Bool) {
        titleLabel.text = item.displayTitle
        if let first = SideTabCell.siteName(of: item.host)?.first {
            letter.text = String(first).uppercased()
            symbol.image = nil
        } else {
            letter.text = nil
            symbol.image = UIImage(systemName: item.isPrivate ? "hand.raised" : "globe")
        }
        tile.backgroundColor = item.isPrivate ? Palette.privateBackground : Palette.surface
        highlight.backgroundColor = isFocused ? Palette.pressed : (item.isPrivate ? Palette.privateBackground : Palette.surface)
        highlight.layer.borderWidth = isFocused ? 1.5 : (isInOtherPane ? 1 : 0)
        self.isInOtherPane = isInOtherPane
        resolveBorder()
        closeButton.isHidden = !isFocused
        accessibilityLabel = item.displayTitle
        accessibilityValue = isFocused ? "Selected" : (isInOtherPane ? "In other pane" : nil)
        accessibilityTraits = isFocused ? [.button, .selected] : .button
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Close Tab") { [weak self] _ in
                self?.onClose?()
                return true
            },
        ]
        setNeedsLayout()
    }

    private func resolveBorder() {
        let color = isInOtherPane ? UIColor.separator : Palette.accentOnGlass
        highlight.layer.borderColor = color.resolvedColor(with: traitCollection).cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        highlight.frame = bounds
        let size = Self.tileSize
        tile.frame = CGRect(x: Spacing.s, y: (bounds.height - size) / 2, width: size, height: size)
        letter.frame = tile.bounds
        symbol.frame = tile.bounds
        let closeWidth: CGFloat = closeButton.isHidden ? 0 : 32
        closeButton.frame = CGRect(x: bounds.width - closeWidth, y: 0, width: closeWidth, height: bounds.height)
        let titleX = tile.frame.maxX + Spacing.s
        titleLabel.frame = CGRect(
            x: titleX, y: 0, width: max(0, bounds.width - titleX - max(closeWidth, Spacing.s)), height: bounds.height
        )
    }
}
#endif
