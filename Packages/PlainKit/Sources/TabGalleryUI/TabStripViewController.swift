#if canImport(UIKit)
import BrowserCore
import DesignSystem
import PerfSignposts
import UIKit

/// Tab Layout: Above. A compact strip of tabs under the top bar, as Safari has on the Duo's inner
/// screen and on iPad: the tabs share the row's width (`FixedChoices.tabStripItemWidth`), and past
/// the narrowest it scrolls sideways; the focused pane's tab is marked, New Tab (+) at the end
/// (a long press offers New Private Tab). Tap a tab to show it, long press for Open in Other Pane
/// and Close Tab, drag to reorder; the focused tab also has a close button. Private tabs follow the
/// regular ones, tinted. It floats over the page with the bar; the host hides it with the bar.
///
/// It reads the same `SideTabsDataSource` as the sidebar (the shell's `TabStore`), and never owns
/// tab state.
public final class TabStripViewController: UIViewController, UICollectionViewDelegate,
    UICollectionViewDragDelegate, UICollectionViewDropDelegate {
    private let dataSource: any SideTabsDataSource
    private(set) var collectionView: UICollectionView!
    private var diffable: UICollectionViewDiffableDataSource<Int, UUID>!
    private let newTabButton = UIButton(type: .system)
    private var items: [UUID: TabGalleryItem] = [:]
    private var focusedID: UUID?
    private var otherID: UUID?
    private var flow: UICollectionViewFlowLayout!
    /// Holds the tabs and fades the edge a scrolled tab leaves under, so a cut-off tab reads as
    /// "more this way" rather than a broken fragment.
    private let fade = UIView()
    private let fadeMask = CAGradientLayer()
    private var fadedEdges: (leading: Bool, trailing: Bool) = (false, false)
    private static let fadeLength: CGFloat = 40
    /// The focused tab has not been scrolled into view since the strip was laid out.
    private var needsFocusScroll = true

    private static let regularSection = 0
    /// A tab's visible height: Safari's compact tab.
    static let tabHeight: CGFloat = 30
    /// The tabs' touch height: their cells are a full 44 pt target, reaching 5 pt past the
    /// strip's 34 pt glass above and below (`StripView`).
    static var touchHeight: CGFloat { Metrics.tapTarget }
    static var touchOutset: CGFloat { max(0, (touchHeight - CGFloat(FixedChoices.tabStripHeight)) / 2) }
    private static let privateSection = 1
    /// The gap between two tabs' plates: clear glass, so each plate reads as one tab.
    static let tabGap: CGFloat = Spacing.xs + Spacing.xxs
    private static let sectionInset = UIEdgeInsets(top: 0, left: Spacing.xxs, bottom: 0, right: Spacing.xs)

    /// The strip's width with its tabs at their resting width
    /// (`FixedChoices.tabStripRestingItemWidth`) and New Tab at the end: the host makes the strip
    /// this wide, up to its lane, so the bar grows with its tabs.
    public var preferredWidth: CGFloat {
        let sections = CGFloat(hasPrivateTabs ? 2 : 1)
        let inset = Self.sectionInset.left + Self.sectionInset.right
        return sections * inset + CGFloat(max(1, items.count)) * (CGFloat(FixedChoices.tabStripRestingItemWidth) + Self.tabGap)
            + Metrics.tapTarget
    }

    /// The number of tabs changed, so `preferredWidth` did: the host resizes the strip (inside
    /// its spring) before the tabs' own change is shown.
    public var onPreferredWidthChange: (() -> Void)?
    private var hasPrivateTabs = false

    public init(dataSource: any SideTabsDataSource) {
        self.dataSource = dataSource
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func loadView() {
        view = StripView()
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "tabStrip"
        // One glass surface under the tabs: it floats over the page with the top bar.
        let glass = Glass.makeView(shape: .rounded(Radius.large))
        glass.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: view.topAnchor),
            glass.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = Self.tabGap
        layout.minimumInteritemSpacing = Self.tabGap
        layout.sectionInset = Self.sectionInset
        layout.itemSize = CGSize(width: CGFloat(FixedChoices.tabStripItemWidth.minimum), height: Self.touchHeight)
        flow = layout
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
        fade.translatesAutoresizingMaskIntoConstraints = false
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        // Solid until the first layout says which edges fade: a gradient with no colors hides all.
        fadeMask.colors = [UIColor.black.cgColor, UIColor.black.cgColor]
        fade.layer.mask = fadeMask
        view.addSubview(fade)
        fade.addSubview(collectionView)

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

        NSLayoutConstraint.activate([
            fade.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            fade.trailingAnchor.constraint(equalTo: newTabButton.leadingAnchor),
            fade.topAnchor.constraint(equalTo: view.topAnchor, constant: -Self.touchOutset),
            fade.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: Self.touchOutset),
            collectionView.leadingAnchor.constraint(equalTo: fade.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: fade.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: fade.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: fade.bottomAnchor),
            newTabButton.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            newTabButton.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor),
            newTabButton.widthAnchor.constraint(equalToConstant: Metrics.tapTarget),
            newTabButton.heightAnchor.constraint(equalToConstant: Metrics.tapTarget),
        ])

        diffable = UICollectionViewDiffableDataSource<Int, UUID>(collectionView: collectionView) { [weak self] collectionView, indexPath, id in
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TabStripCell.reuseID, for: indexPath)
            if let self, let cell = cell as? TabStripCell, let item = items[id] {
                cell.configure(
                    item: item, isFocused: id == focusedID, isInOtherPane: id == otherID && id != focusedID, icons: dataSource
                )
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
                Haptic.drop.play()
                dataSource.moveTab(id, to: index)
            }
            // After the reorder has been committed: a snapshot applied inside this handler
            // raises in UIKit (a crash on TestFlight while dragging a tab in the strip).
            DispatchQueue.main.async { [weak self] in self?.reloadTabs() }
        }
        reloadTabs()
    }

    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateItemWidth()
        if fadeMask.frame != fade.bounds {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fadeMask.frame = fade.bounds
            CATransaction.commit()
            updateFade(force: true)
        } else {
            // The tabs' width may have changed (a tab opened or closed).
            updateFade(force: false)
        }
        // The first layout with tabs: the focused one comes into view (a strip built while the
        // twentieth tab is on screen shows it, not the first).
        if needsFocusScroll, collectionView.bounds.width > 0, let focusedID, let indexPath = diffable.indexPath(for: focusedID) {
            needsFocusScroll = false
            collectionView.layoutIfNeeded()
            collectionView.scrollToItem(at: indexPath, at: .centeredHorizontally, animated: false)
        }
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateFade(force: false)
    }

    /// Fades an edge only while tabs continue past it. Changes the mask's colors only when an
    /// edge flips, not per scroll frame.
    private func updateFade(force: Bool) {
        let width = fade.bounds.width
        guard width > 0 else { return }
        let offset = collectionView.contentOffset.x
        let edges = (leading: offset > 1, trailing: offset + width < collectionView.contentSize.width - 1)
        guard force || edges != fadedEdges else { return }
        fadedEdges = edges
        let stop = min(0.5, Self.fadeLength / width)
        let clear = UIColor.clear.cgColor
        let solid = UIColor.black.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.colors = [edges.leading ? clear : solid, solid, solid, edges.trailing ? clear : solid]
        fadeMask.locations = [0, NSNumber(value: Double(stop)), NSNumber(value: Double(1 - stop)), 1]
        CATransaction.commit()
    }

    /// The tabs share the strip's width, between the narrowest and the widest a tab may be.
    private func updateItemWidth() {
        let count = max(1, items.count)
        let sections = CGFloat(hasPrivateTabs ? 2 : 1)
        // From the strip's own width: the tabs' view is laid out a pass later than the strip, so
        // its bounds are still the old ones when the strip has just grown.
        let available = view.bounds.width - Metrics.tapTarget - sections * (Self.sectionInset.left + Self.sectionInset.right)
        guard available > 0 else { return }
        let share = (available - CGFloat(count) * Self.tabGap) / CGFloat(count)
        let limits = FixedChoices.tabStripItemWidth
        let width = floor(min(max(share, CGFloat(limits.minimum)), CGFloat(limits.maximum)))
        let size = CGSize(width: width, height: Self.touchHeight)
        guard flow.itemSize != size else { return }
        flow.itemSize = size
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
        let countChanged = next.count != items.count
        items = next
        focusedID = focused
        otherID = other
        let sectionsChanged = hasPrivateTabs == privateTabs.isEmpty
        hasPrivateTabs = !privateTabs.isEmpty
        if countChanged || sectionsChanged {
            // The bar takes its new width first (the host lays it out), so the tabs keep theirs.
            onPreferredWidthChange?()
            updateItemWidth()
        }
        let animated = old.numberOfItems > 0 && view.window != nil
        // Once the new tabs are laid out: before that the focused tab has no place to scroll to
        // (a restored session arrives after the strip's first layout).
        diffable.apply(snapshot, animatingDifferences: animated) { [weak self] in
            guard let self, focusMoved || countChanged else { return }
            scrollFocusedIntoViewIfNeeded(animated: animated)
        }
    }

    /// Brings the focused tab into view when any of it is outside the strip.
    private func scrollFocusedIntoViewIfNeeded(animated: Bool) {
        guard let focusedID, let indexPath = diffable.indexPath(for: focusedID), collectionView.bounds.width > 0 else {
            needsFocusScroll = true
            return
        }
        collectionView.layoutIfNeeded()
        if let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame, collectionView.bounds.contains(frame) { return }
        collectionView.scrollToItem(at: indexPath, at: .centeredHorizontally, animated: animated)
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
        dragDestination = nil
        Haptic.selection.prepare()
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
}

/// The strip's view: 34 pt high, it takes touches 5 pt above and below too, so each tab and New
/// Tab is a 44 pt target. A touch there goes to what is at the same x inside the strip.
private final class StripView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: 0, dy: -TabStripViewController.touchOutset).contains(point)
    }
}

/// One tab in the strip: the site tile, the title, and a close button on the focused tab.
final class TabStripCell: UICollectionViewCell {
    static let reuseID = "TabStripCell"
    var onClose: (() -> Void)?

    private let highlight = UIView()
    private let tile = SiteIconView(side: TabStripCell.tileSize, iconSide: TabStripCell.iconSize, radius: Radius.small)
    private let titleLabel = UILabel()
    /// A private tab's hand, before its title: the strip has no section header to say so, and
    /// the tab on screen is a white card like any other (design review, round 2).
    private let privateMark = UIImageView(image: UIImage(
        systemName: "hand.raised.fill", withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption2, scale: .small)
    ))
    private let closeButton = UIButton(type: .system)
    private var isInOtherPane = false
    private var isOnScreen = false
    /// The tab the cell shows: a change of its mark animates only for the same tab.
    private var shownID: UUID?
    private static let tileSize: CGFloat = 22
    private static let iconSize: CGFloat = 16
    /// The hairline around a tab that is not on screen.
    private static let hairline: CGFloat = 0.5

    override init(frame: CGRect) {
        super.init(frame: frame)
        highlight.layer.cornerRadius = Radius.large
        highlight.layer.cornerCurve = .continuous
        contentView.addSubview(highlight)
        contentView.addSubview(tile)
        titleLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        titleLabel.textColor = Palette.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(titleLabel)
        privateMark.tintColor = Palette.textSecondary
        privateMark.contentMode = .center
        privateMark.isHidden = true
        contentView.addSubview(privateMark)
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

    override func prepareForReuse() {
        super.prepareForReuse()
        shownID = nil
    }

    func configure(item: TabGalleryItem, isFocused: Bool, isInOtherPane: Bool, icons: any SideTabsDataSource) {
        let sameTab = shownID == item.id
        shownID = item.id
        titleLabel.text = item.compactTitle
        titleLabel.font = UIFont.preferredFont(forTextStyle: .footnote).withWeight(isFocused ? .semibold : .regular)
        tile.show(item, from: icons)
        let changes = {
            // Every tab is its own plate on the strip's glass, a gap of glass between two: the
            // one on screen a solid card ringed in Lagoon, the others a veil with a hairline (a
            // private tab on its dusk tint).
            self.highlight.backgroundColor = isFocused
                ? Palette.surface : (item.isPrivate ? Palette.privateTabPlate : Palette.tabPlate)
            self.highlight.layer.borderWidth = isFocused ? 1.5 : (isInOtherPane ? 1 : Self.hairline)
            self.closeButton.alpha = isFocused ? 1 : 0
        }
        // The card fades from the tab left to the tab chosen; nothing moves.
        if sameTab, isFocused != isOnScreen, window != nil {
            Motion.animate(Motion.quick, changes: changes)
        } else {
            UIView.performWithoutAnimation(changes)
        }
        isOnScreen = isFocused
        self.isInOtherPane = isInOtherPane
        titleLabel.textColor = isFocused ? Palette.textPrimary : Palette.textSecondary
        resolveBorder()
        closeButton.isHidden = !isFocused
        privateMark.isHidden = !item.isPrivate
        accessibilityLabel = item.isPrivate ? "Private, \(item.displayTitle)" : item.displayTitle
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
        let color = isOnScreen ? Palette.accentOnGlass : (isInOtherPane ? UIColor.separator : Palette.tabPlateEdge)
        highlight.layer.borderColor = color.resolvedColor(with: traitCollection).cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        // The cell is the 44 pt touch target; the tab shows 30 pt high in its middle.
        let visible = bounds.insetBy(dx: 0, dy: max(0, (bounds.height - TabStripViewController.tabHeight) / 2))
        highlight.frame = visible
        let size = Self.tileSize
        tile.frame = CGRect(x: Spacing.s, y: (bounds.height - size) / 2, width: size, height: size)
        let closeWidth: CGFloat = closeButton.isHidden ? 0 : Metrics.tapTarget
        closeButton.frame = CGRect(x: bounds.width - closeWidth, y: 0, width: closeWidth, height: bounds.height)
        var titleX = tile.frame.maxX + Spacing.s
        if !privateMark.isHidden {
            let side: CGFloat = 12
            privateMark.frame = CGRect(x: titleX, y: (bounds.height - side) / 2, width: side, height: side)
            titleX = privateMark.frame.maxX + Spacing.xs
        }
        titleLabel.frame = CGRect(
            x: titleX, y: 0, width: max(0, bounds.width - titleX - max(closeWidth, Spacing.s)), height: bounds.height
        )
    }
}
#endif
