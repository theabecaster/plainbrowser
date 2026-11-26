#if canImport(UIKit)
import DesignSystem
import os
import PerfSignposts
import UIKit

/// The tab gallery: every open tab as a card (docs/plan.md, sections 5 and 6).
///
/// Compact width shows one column of large cards; regular width shows an even-column grid. Tap a
/// card to open it, flick it sideways to close it, long-press to reorder or for its menu. The
/// gallery reads tabs from its `TabGalleryDataSource` and sends every change back to it.
///
/// The shell runs the open and close animations with `TabGalleryTransition`, which uses
/// `prepareForTransition(to:)`, `thumbnailFrame(for:in:)` and `setThumbnailHidden(for:)`.
public final class TabGalleryViewController: UIViewController {
    public let dataSource: any TabGalleryDataSource

    /// The last tab closed from the gallery. The shell goes straight to the search field
    /// (docs/ui-reference.md: no empty screen in between).
    public var onLastTabClosed: (() -> Void)?

    private(set) var collectionView: UICollectionView!
    private var diffable: UICollectionViewDiffableDataSource<Int, UUID>!
    /// The list last applied, by id.
    private var items: [UUID: TabGalleryItem] = [:]
    private var selectedID: UUID?
    /// The card whose preview the transition stands in for.
    private var hiddenThumbnailID: UUID?
    private let pipeline = ThumbnailPipeline()
    private(set) var metrics = TabGalleryMetrics(width: 0, height: 0, isCompactWidth: true, titleLineHeight: 20)

    private let bottomBar = GalleryBottomBar()
    private let toast = ReopenToast()
    private let emptyView = GalleryEmptyView()
    private var scrollInterval: OSSignpostIntervalState?
    private var didScrollToSelection = false

    public init(dataSource: any TabGalleryDataSource) {
        self.dataSource = dataSource
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: View

    override public func loadView() {
        let root = UIView()
        root.backgroundColor = Palette.background
        view = root

        let layout = UICollectionViewCompositionalLayout { [unowned self] _, environment in
            makeSection(environment)
        }
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = Palette.background
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.dragDelegate = self
        collectionView.dropDelegate = self
        collectionView.dragInteractionEnabled = true
        collectionView.reorderingCadence = .fast
        collectionView.accessibilityIdentifier = "tabGallery"
        root.addSubview(collectionView)

        let registration = UICollectionView.CellRegistration<TabCardCell, UUID> { [unowned self] cell, _, id in
            configure(cell, id: id)
        }
        diffable = UICollectionViewDiffableDataSource(collectionView: collectionView) { collection, indexPath, id in
            collection.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }

        emptyView.button.addAction(UIAction { [weak self] _ in self?.newTab() }, for: .primaryActionTriggered)
        root.addSubview(emptyView)

        bottomBar.newTabButton.addAction(UIAction { [weak self] _ in self?.newTab() }, for: .primaryActionTriggered)
        bottomBar.privateButton.addAction(UIAction { [weak self] _ in self?.togglePrivate() }, for: .primaryActionTriggered)
        bottomBar.showsPrivateButton = dataSource.supportsPrivateTabs
        bottomBar.doneButton.addAction(UIAction { [weak self] _ in self?.done() }, for: .primaryActionTriggered)
        bottomBar.menuButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.galleryMenuItems() ?? [])
        }])
        bottomBar.menuButton.showsMenuAsPrimaryAction = true
        root.addSubview(bottomBar)
        // The system's scroll edge effect softens the cards passing under the floating bar.
        let edge = UIScrollEdgeElementContainerInteraction()
        edge.scrollView = collectionView
        edge.edge = .bottom
        bottomBar.addInteraction(edge)

        toast.button.addAction(UIAction { [weak self] _ in self?.reopenClosedTab() }, for: .primaryActionTriggered)
        root.addSubview(toast)
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitHorizontalSizeClass.self]) {
            (gallery: TabGalleryViewController, _) in
            gallery.reconfigureAll()
        }
        reloadTabs(animated: false)
    }

    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        didScrollToSelection = false
    }

    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        if collectionView.frame != bounds { collectionView.frame = bounds }
        let safe = view.safeAreaInsets

        // Floating controls center on the safe area: on the Duo's outer screen the system's
        // vertical bar takes one side.
        let midX = (safe.left + (bounds.width - safe.right)) / 2
        let barSize = bottomBar.sizeThatFits(bounds.size)
        let barBottom = bounds.height - max(safe.bottom, Spacing.l)
        bottomBar.frame = CGRect(
            x: (midX - barSize.width / 2).rounded(), y: barBottom - barSize.height,
            width: barSize.width, height: barSize.height
        )
        let toastSize = toast.sizeThatFits(bounds.size)
        toast.frame = CGRect(
            x: (midX - toastSize.width / 2).rounded(), y: bottomBar.frame.minY - Spacing.m - toastSize.height,
            width: toastSize.width, height: toastSize.height
        )
        let emptySize = emptyView.sizeThatFits(CGSize(width: min(bounds.width - Spacing.xl * 2, 360), height: bounds.height))
        emptyView.frame = CGRect(
            x: (midX - emptySize.width / 2).rounded(), y: ((bounds.height - emptySize.height) / 2).rounded(),
            width: emptySize.width, height: emptySize.height
        )
        // The cards scroll under the floating bar and end above it.
        let bottomInset = bounds.height - bottomBar.frame.minY + Spacing.s - safe.bottom
        if collectionView.contentInset.bottom != bottomInset {
            collectionView.contentInset.bottom = bottomInset
            collectionView.verticalScrollIndicatorInsets.bottom = bottomInset
        }
        if !didScrollToSelection, bounds.width > 0, let selectedID {
            didScrollToSelection = true
            collectionView.layoutIfNeeded()
            scrollToTab(selectedID, animated: false)
        }
    }

    private func makeSection(_ environment: any NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let traits = environment.traitCollection
        let insets = collectionView.safeAreaInsets
        let next = TabGalleryMetrics(
            width: environment.container.contentSize.width - insets.left - insets.right,
            height: view.bounds.height,
            isCompactWidth: traits.horizontalSizeClass != .regular,
            titleLineHeight: TabCardCell.titleFont(for: traits).lineHeight
        )
        if next != metrics {
            let resized = metrics.cardSize != next.cardSize && metrics.width > 0
            metrics = next
            // Cards already on screen keep their old preview height until configured again.
            // Not inside this layout pass: on the next turn of the main loop.
            if resized { Task { @MainActor [weak self] in self?.reconfigureAll() } }
        }
        let size = next.cardSize
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(size.width), heightDimension: .absolute(size.height)))
        let rowWidth = size.width * CGFloat(next.columns) + TabGalleryMetrics.spacing * CGFloat(next.columns - 1)
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .absolute(rowWidth), heightDimension: .absolute(size.height)),
            repeatingSubitem: item, count: next.columns
        )
        group.interItemSpacing = .fixed(TabGalleryMetrics.spacing)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = TabGalleryMetrics.spacing
        section.contentInsetsReference = .safeArea
        section.contentInsets = .init(
            top: TabGalleryMetrics.margin, leading: next.sideInset,
            bottom: TabGalleryMetrics.margin, trailing: next.sideInset
        )
        return section
    }

    // MARK: Data

    /// Reads the tabs again and applies the difference. Call it when tabs change outside the
    /// gallery (a title, a thumbnail, a tab opened elsewhere).
    public func reloadTabs(animated: Bool) {
        reloadTabs(animated: animated, completion: nil)
    }

    private func reloadTabs(animated: Bool, completion: (() -> Void)?) {
        guard isViewLoaded else { completion?(); return }
        let state = Signposts.signposter.beginInterval(Signposts.galleryReload)
        let tabs = dataSource.tabs
        let previous = items
        var next: [UUID: TabGalleryItem] = [:]
        next.reserveCapacity(tabs.count)
        for tab in tabs { next[tab.id] = tab }
        items = next
        let oldSelection = selectedID
        selectedID = dataSource.selectedTabID

        var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        snapshot.appendSections([0])
        snapshot.appendItems(tabs.map(\.id))
        // Cards whose content changed keep their cell and get configured again.
        let changed = tabs.filter { tab in
            guard let old = previous[tab.id] else { return false }
            return old != tab || tab.id == oldSelection || tab.id == selectedID
        }.map(\.id)
        snapshot.reconfigureItems(changed)

        let apply = { [diffable] in diffable!.apply(snapshot, animatingDifferences: animated) {
            Signposts.signposter.endInterval(Signposts.galleryReload, state)
            completion?()
        } }
        if animated, !Motion.prefersCrossfade {
            UIView.animate(Motion.reflow, changes: apply)
        } else if animated {
            Motion.animate(Motion.reflow, crossfading: collectionView, changes: apply)
        } else {
            apply()
        }
        updateChrome(animated: animated)
    }

    private func reconfigureAll() {
        var snapshot = diffable.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        diffable.apply(snapshot, animatingDifferences: false)
    }

    private func updateChrome(animated: Bool) {
        let isPrivate = dataSource.isShowingPrivateTabs
        let background = isPrivate ? Palette.privateBackground : Palette.background
        if view.backgroundColor != background {
            view.backgroundColor = background
            collectionView.backgroundColor = background
            bottomBar.setPrivate(isPrivate)
            emptyView.setPrivate(isPrivate)
        }
        let isEmpty = items.isEmpty
        // VoiceOver hears how many tabs there are, cards off screen included.
        collectionView.accessibilityValue = items.count == 1 ? "1 tab" : "\(items.count) tabs"
        emptyView.isHidden = !isEmpty
        // With the private toggle, the bar stays: it is the way between regular and private tabs.
        bottomBar.isHidden = isEmpty && !dataSource.supportsPrivateTabs
        bottomBar.doneButton.isEnabled = selectedID != nil
        if isEmpty { toast.hide(animated: false) }
    }

    private func configure(_ cell: TabCardCell, id: UUID) {
        guard let item = items[id] else { return }
        cell.configure(
            item: item, isSelected: id == selectedID,
            thumbnailHeight: metrics.thumbnailHeight, hidesThumbnail: id == hiddenThumbnailID
        )
        cell.onClose = { [weak self] interval in self?.closeTab(id, flick: interval) }

        let thumbKey = thumbnailKey(for: item)
        if cell.thumbnailKey != thumbKey {
            cell.thumbnailKey = thumbKey
            if let image = pipeline.cached(thumbKey) {
                cell.setThumbnail(image)
            } else {
                Task { [weak self, weak cell] in
                    guard let self else { return }
                    let image = await pipeline.image(for: thumbKey) { [dataSource] in await dataSource.thumbnail(for: id) }
                    guard let cell, cell.thumbnailKey == thumbKey else { return }
                    // Nothing yet: forget the request, so the next configure asks again.
                    if image == nil { cell.thumbnailKey = nil }
                    cell.setThumbnail(image)
                }
            }
        }
        let iconKey = faviconKey(for: item)
        if cell.faviconKey != iconKey {
            cell.faviconKey = iconKey
            if let image = pipeline.cached(iconKey) {
                cell.setFavicon(image)
            } else {
                Task { [weak self, weak cell] in
                    guard let self else { return }
                    let image = await pipeline.image(for: iconKey) { [dataSource] in await dataSource.favicon(for: id) }
                    guard let cell, cell.faviconKey == iconKey else { return }
                    if image == nil { cell.faviconKey = nil }
                    cell.setFavicon(image)
                }
            }
        }
    }

    private func thumbnailKey(for item: TabGalleryItem) -> ThumbnailPipeline.Key {
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        let aspect = Int((metrics.thumbnailAspect * 1000).rounded(.up))
        return .init(
            id: item.id, revision: item.thumbnailRevision, pixelWidth: Int(metrics.cardWidth * scale),
            maxAspectPermille: aspect, kind: .thumbnail
        )
    }

    private func faviconKey(for item: TabGalleryItem) -> ThumbnailPipeline.Key {
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        // A tab that moves to another site, or whose icon arrives, gets the new icon.
        var hasher = Hasher()
        hasher.combine(item.host)
        hasher.combine(item.faviconRevision)
        return .init(id: item.id, revision: hasher.finalize(), pixelWidth: Int(18 * scale), maxAspectPermille: 0, kind: .favicon)
    }

    // MARK: Actions

    private func open(_ id: UUID) {
        toast.hide(animated: true)
        dataSource.selectTab(id)
        // Move the selection ring now; the shell has already hidden the card it zooms.
        reloadTabs(animated: false)
    }

    private func done() {
        guard let selectedID else { return }
        open(selectedID)
    }

    private func newTab() {
        Signposts.signposter.emitEvent(Signposts.galleryNewTab)
        toast.hide(animated: false)
        dataSource.newTab()
    }

    /// Regular or private tabs: the cards cross-fade to the other list.
    private func togglePrivate() {
        let isPrivate = !dataSource.isShowingPrivateTabs
        Signposts.signposter.emitEvent(Signposts.privateMode, "\(isPrivate ? "on" : "off")")
        Haptic.selection.play()
        toast.hide(animated: true)
        dataSource.setShowingPrivateTabs(isPrivate)
        didScrollToSelection = false
        Motion.crossfade(view, changes: { [weak self] in
            self?.reloadTabs(animated: false)
            self?.view.setNeedsLayout()
            self?.view.layoutIfNeeded()
        })
    }

    /// - Parameter flick: the interval a flicked card already began; nil for a button or menu.
    private func closeTab(_ id: UUID, flick: OSSignpostIntervalState? = nil) {
        let state = flick ?? Signposts.signposter.beginInterval(Signposts.galleryCardClose)
        if flick == nil { Haptic.close.play() }
        dataSource.closeTab(id)
        if dataSource.tabs.isEmpty {
            reloadTabs(animated: false)
            Signposts.signposter.endInterval(Signposts.galleryCardClose, state)
            onLastTabClosed?()
            return
        }
        reloadTabs(animated: true) {
            Signposts.signposter.endInterval(Signposts.galleryCardClose, state)
        }
        toast.show(animated: true)
    }

    private func reopenClosedTab() {
        Signposts.signposter.emitEvent(Signposts.galleryReopen)
        toast.hide(animated: true)
        guard let id = dataSource.reopenClosedTab() else { return }
        reloadTabs(animated: true)
        scrollToTab(id, animated: true)
    }

    private func confirmCloseAll(from source: UIView) {
        let count = items.count
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        let title = count == 1 ? "Close 1 Tab" : "Close All \(count) Tabs"
        sheet.addAction(UIAlertAction(title: title, style: .destructive) { [weak self] _ in
            guard let self else { return }
            Signposts.signposter.emitEvent(Signposts.galleryCloseAll)
            dataSource.closeAllTabs()
            reloadTabs(animated: false)
            if dataSource.tabs.isEmpty { onLastTabClosed?() }
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = source
        present(sheet, animated: true)
    }

    private func galleryMenuItems() -> [UIMenuElement] {
        Signposts.signposter.emitEvent(Signposts.galleryMenu)
        var elements: [UIMenuElement] = []
        if dataSource.canReopenClosedTab {
            elements.append(UIAction(title: "Reopen Closed Tab", image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in
                self?.reopenClosedTab()
            })
        }
        if dataSource.canShowArchive {
            let archive = UIAction(title: "Archived Tabs", image: UIImage(systemName: "archivebox")) { [weak self] _ in
                self?.toast.hide(animated: false)
                self?.dataSource.showArchive()
            }
            archive.accessibilityIdentifier = "gallery.archive"
            elements.append(archive)
        }
        guard !items.isEmpty else { return elements }
        let closeAll = UIAction(title: "Close All Tabs", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
            guard let self else { return }
            confirmCloseAll(from: bottomBar.menuButton)
        }
        elements.append(UIMenu(options: .displayInline, children: [closeAll]))
        return elements
    }

    private func share(_ item: TabGalleryItem, from view: UIView) {
        guard let url = item.url else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = view
        present(sheet, animated: true)
    }

    // MARK: Scrolling and transitions

    /// Scrolls so the tab's card is fully on screen. A card already visible does not move.
    public func scrollToTab(_ id: UUID, animated: Bool) {
        guard let indexPath = diffable.indexPath(for: id),
              let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return }
        let visible = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        guard !visible.contains(attributes.frame) else { return }
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: animated)
    }

    /// Gets the tab's card on screen and laid out before a transition measures it.
    /// - Parameter revealFully: scroll a partly hidden card fully into view. True when the gallery
    ///   is about to appear; false when the user just tapped a card, which must not jump.
    public func prepareForTransition(to id: UUID, revealFully: Bool = true) {
        loadViewIfNeeded()
        view.layoutIfNeeded()
        if revealFully {
            scrollToTab(id, animated: false)
        } else if let indexPath = diffable.indexPath(for: id),
                  let attributes = collectionView.layoutAttributesForItem(at: indexPath),
                  !collectionView.bounds.intersects(attributes.frame) {
            collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        }
        collectionView.layoutIfNeeded()
    }

    /// The card's page preview, in `view`'s coordinates.
    public func thumbnailFrame(for id: UUID, in target: UIView) -> CGRect? {
        guard let indexPath = diffable.indexPath(for: id),
              let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return nil }
        let frame = CGRect(origin: attributes.frame.origin, size: CGSize(width: attributes.frame.width, height: metrics.thumbnailHeight))
        return collectionView.convert(frame, to: target)
    }

    /// Hides the preview of `id`'s card (and shows every other) while a transition stands in for
    /// it. `nil` shows them all.
    public func setThumbnailHidden(for id: UUID?) {
        hiddenThumbnailID = id
        for case let cell as TabCardCell in collectionView.visibleCells {
            cell.setThumbnailHidden(cell.tabID != nil && cell.tabID == id)
        }
    }

    /// The views a transition fades and scales with the zoom: the cards and the floating bar.
    var transitionContent: [UIView] { [collectionView, bottomBar, toast] }
}

// MARK: - Collection view delegate

extension TabGalleryViewController: UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let id = diffable.itemIdentifier(for: indexPath) else { return }
        open(id)
    }

    public func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let id = diffable.itemIdentifier(for: indexPath), let item = items[id] else { continue }
            pipeline.warm(thumbnailKey(for: item)) { [dataSource] in await dataSource.thumbnail(for: id) }
            pipeline.warm(faviconKey(for: item)) { [dataSource] in await dataSource.favicon(for: id) }
        }
    }

    public func collectionView(
        _ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let indexPath = indexPaths.first,
              let id = diffable.itemIdentifier(for: indexPath), let item = items[id] else { return nil }
        Signposts.signposter.emitEvent(Signposts.galleryMenu)
        return UIContextMenuConfiguration(identifier: id as NSUUID, previewProvider: nil) { [weak self] _ in
            self?.cardMenu(for: item)
        }
    }

    public func collectionView(
        _ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration,
        highlightPreviewForItemAt indexPath: IndexPath
    ) -> UITargetedPreview? {
        cardPreview(at: indexPath)
    }

    public func collectionView(
        _ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration,
        dismissalPreviewForItemAt indexPath: IndexPath
    ) -> UITargetedPreview? {
        cardPreview(at: indexPath)
    }

    private func cardPreview(at indexPath: IndexPath) -> UITargetedPreview? {
        guard let cell = collectionView.cellForItem(at: indexPath) as? TabCardCell else { return nil }
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: cell.thumbnailContainer.bounds, cornerRadius: Radius.large)
        return UITargetedPreview(view: cell.thumbnailContainer, parameters: parameters)
    }

    private func cardMenu(for item: TabGalleryItem) -> UIMenu {
        let id = item.id
        var top: [UIMenuElement] = []
        if dataSource.canOpenInOtherPane {
            top.append(UIAction(title: "Open in Other Pane", image: UIImage(systemName: "rectangle.split.2x1")) { [weak self] _ in
                Signposts.signposter.emitEvent(Signposts.galleryOtherPane)
                self?.dataSource.openInOtherPane(id)
            })
        }
        if let url = item.url {
            top.append(UIAction(title: "Copy Link", image: UIImage(systemName: "link")) { _ in
                Signposts.signposter.emitEvent(Signposts.galleryCopyLink)
                UIPasteboard.general.url = url
                Haptic.success.play()
            })
            top.append(UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                guard let self else { return }
                let source = diffable.indexPath(for: id).flatMap { self.collectionView.cellForItem(at: $0) } ?? view
                Signposts.signposter.emitEvent(Signposts.galleryShare)
                share(item, from: source ?? view)
            })
        }
        let close = UIAction(title: "Close Tab", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
            self?.closeTab(id)
        }
        return UIMenu(children: top + [UIMenu(options: .displayInline, children: [close])])
    }

    // Scroll signposts: one interval per scroll, finger down to rest.
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if scrollInterval == nil { scrollInterval = Signposts.signposter.beginInterval(Signposts.galleryScroll) }
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { endScrollInterval() }
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        endScrollInterval()
    }

    private func endScrollInterval() {
        guard let state = scrollInterval else { return }
        Signposts.signposter.endInterval(Signposts.galleryScroll, state)
        scrollInterval = nil
    }
}

// MARK: - Reorder by drag

extension TabGalleryViewController: UICollectionViewDragDelegate, UICollectionViewDropDelegate {
    public func collectionView(
        _ collectionView: UICollectionView, itemsForBeginning session: any UIDragSession, at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard let id = diffable.itemIdentifier(for: indexPath), let item = items[id] else { return [] }
        toast.hide(animated: true)
        let provider = item.url.map { NSItemProvider(object: $0 as NSURL) } ?? NSItemProvider()
        let dragItem = UIDragItem(itemProvider: provider)
        dragItem.localObject = id
        return [dragItem]
    }

    public func collectionView(
        _ collectionView: UICollectionView, dragPreviewParametersForItemAt indexPath: IndexPath
    ) -> UIDragPreviewParameters? {
        guard let cell = collectionView.cellForItem(at: indexPath) as? TabCardCell else { return nil }
        let parameters = UIDragPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: cell.thumbnailContainer.frame, cornerRadius: Radius.large)
        return parameters
    }

    public func collectionView(
        _ collectionView: UICollectionView, dragSessionIsRestrictedToDraggingApplication session: any UIDragSession
    ) -> Bool {
        true
    }

    public func collectionView(
        _ collectionView: UICollectionView, dropSessionDidUpdate session: any UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UICollectionViewDropProposal {
        guard session.localDragSession != nil else { return UICollectionViewDropProposal(operation: .forbidden) }
        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    public func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: any UICollectionViewDropCoordinator) {
        guard let drop = coordinator.items.first, let id = drop.dragItem.localObject as? UUID,
              let destination = coordinator.destinationIndexPath else { return }
        let count = diffable.snapshot().numberOfItems
        let index = min(destination.item, count - 1)
        Signposts.signposter.emitEvent(Signposts.galleryReorder)
        dataSource.moveTab(id, to: index)
        reloadTabs(animated: false)
        coordinator.drop(drop.dragItem, toItemAt: IndexPath(item: index, section: 0))
    }
}
#endif
