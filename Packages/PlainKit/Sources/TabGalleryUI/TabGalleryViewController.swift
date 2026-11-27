#if canImport(UIKit)
import BrowserCore
import DesignSystem
import os
import PerfSignposts
import UIKit

/// The tab gallery: every open tab as a card (docs/plan.md, sections 5 and 6;
/// docs/research/arc-tab-switcher.md).
///
/// Compact width shows the app-switcher cascade: one row of page-shaped cards, later tabs on top,
/// scrolling sideways and resting with a card in the middle. Regular width shows pages of an
/// even-column grid that also scroll sideways. Everywhere: tap a card to open it, swipe it up to
/// close it, long-press it for its menu or to drag it to a new place. The gallery reads tabs from
/// its `TabGalleryDataSource` and sends every change back to it.
///
/// A plain scroll view supplies the physics (deceleration, rubber band, the system's projected
/// stop). The cards are its subviews, placed from the scroll offset on every frame with `center`
/// and `transform` only, so scrolling never runs a layout pass (docs/decisions.md).
///
/// The shell runs the open and close animations with `TabGalleryTransition`, which uses
/// `prepareForTransition(to:)`, `thumbnailFrame(for:in:)` and `setThumbnailHidden(for:)`.
public final class TabGalleryViewController: UIViewController {
    public let dataSource: any TabGalleryDataSource

    /// The last tab closed from the gallery. The shell goes straight to the search field
    /// (docs/ui-reference.md: no empty screen in between).
    public var onLastTabClosed: (() -> Void)?

    private(set) var scrollView: GalleryScrollView!
    /// The tabs in order, as last read from the data source.
    private(set) var order: [UUID] = []
    private var items: [UUID: TabGalleryItem] = [:]
    /// Where each tab shows: its index, or its place in a reorder that is being dragged.
    private var slots: [UUID: Int] = [:]
    private var selectedID: UUID?
    /// The card whose preview the transition stands in for.
    private var hiddenThumbnailID: UUID?
    private let pipeline = ThumbnailPipeline()
    private(set) var metrics = TabGalleryMetrics(width: 0, height: 0, isCompactWidth: true, titleLineHeight: 20)

    /// Cards on screen, by tab.
    private(set) var cards: [UUID: TabCardView] = [:]
    /// Hidden cards ready for reuse.
    private var pool: [TabCardView] = []
    let motion = CardMotion()
    private var warmedRange: ClosedRange<Int>?
    private var dragStartOffset: CGFloat = 0
    /// Where the scroll is heading after a release, so a release with no speed still snaps.
    private var snapTarget: CGFloat?
    /// The tab being dragged to a new place, and where it would land.
    var reorder: (id: UUID, slot: Int)?
    var autoScroll: AutoScroller?
    /// The card a drag lifted: hidden until its preview lands.
    private var liftedID: UUID?
    /// The blurred, dimmed page behind the cards.
    private let backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private var isShowingPrivate = false
    /// The last tab just closed and the shell is taking the gallery away: no empty state meanwhile.
    private var isLeavingEmpty = false
    /// A swipe up on the empty space: back to the page.
    private var backgroundSwipe: UIPanGestureRecognizer?
    /// Cards rising away after a close, with where they sit on screen.
    private var departing: [ObjectIdentifier: (card: TabCardView, screenX: CGFloat)] = [:]

    private let bottomBar = GalleryBottomBar()
    private let toast = ReopenToast()
    private let emptyView = GalleryEmptyView()
    private var scrollInterval: OSSignpostIntervalState?
    private var didFocusSelection = false

    public init(dataSource: any TabGalleryDataSource) {
        self.dataSource = dataSource
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: View

    override public func loadView() {
        let root = UIView()
        // Like the app switcher (and Arc): the cards float over the page they came from, blurred
        // and dimmed, so the gallery reads as a layer over the browser. Always dark: the titles
        // and the bar read the same in either appearance.
        root.backgroundColor = .clear
        root.overrideUserInterfaceStyle = .dark
        backdrop.frame = root.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backdrop.contentView.backgroundColor = Palette.galleryDim
        root.addSubview(backdrop)
        view = root

        let scroll = GalleryScrollView()
        scroll.backgroundColor = .clear
        scroll.delegate = self
        scroll.decelerationRate = .normal
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.alwaysBounceVertical = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delaysContentTouches = false
        scroll.accessibilityIdentifier = "tabGallery"
        scroll.accessibilityProvider = self
        root.addSubview(scroll)
        scrollView = scroll
        root.addInteraction(UIDropInteraction(delegate: self))
        // Like the app switcher: a tap or a swipe up on the space around the cards goes back to
        // the tab on screen.
        let backgroundTap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        backgroundTap.delegate = self
        scroll.addGestureRecognizer(backgroundTap)
        let backgroundSwipe = UIPanGestureRecognizer(target: self, action: #selector(backgroundSwiped(_:)))
        backgroundSwipe.delegate = self
        scroll.addGestureRecognizer(backgroundSwipe)
        self.backgroundSwipe = backgroundSwipe

        motion.onFrame = { [weak self] in self?.layoutCards() }

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

        toast.button.addAction(UIAction { [weak self] _ in self?.reopenClosedTab(offered: true) }, for: .primaryActionTriggered)
        root.addSubview(toast)
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitHorizontalSizeClass.self]) {
            (gallery: TabGalleryViewController, _) in
            gallery.view.setNeedsLayout()
        }
        reloadTabs(animated: false)
    }

    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        didFocusSelection = false
    }

    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        // Size and center, not the frame: the open and close transitions zoom the scroll view
        // with a transform, and a layout pass mid-zoom must not undo it.
        if scrollView.bounds.size != bounds.size { scrollView.bounds.size = bounds.size }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        if scrollView.center != center { scrollView.center = center }
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

        let next = TabGalleryMetrics(
            width: bounds.width, height: bounds.height,
            safeTop: safe.top, safeLeft: safe.left, safeBottom: safe.bottom, safeRight: safe.right,
            isCompactWidth: traitCollection.horizontalSizeClass != .regular,
            titleLineHeight: TabCardView.titleFont(for: traitCollection).lineHeight,
            bottomChrome: max(0, bounds.height - safe.bottom - bottomBar.frame.minY)
        )
        if next != metrics { apply(next) }
        if !didFocusSelection, bounds.width > 0 {
            didFocusSelection = true
            if let selectedID, let slot = slots[selectedID] { scroll(to: metrics.restingOffset(for: slot), animated: false) }
        }
        layoutCards()
    }

    /// New bounds, size class or text size: same tab in focus, every card resized.
    private func apply(_ next: TabGalleryMetrics) {
        let anchor = metrics.width > 0 ? focusedSlot() : nil
        let oldThumbnail = CGSize(width: metrics.cardWidth, height: metrics.thumbnailHeight)
        metrics = next
        motion.reset()
        updateContentSize()
        if let anchor { scroll(to: metrics.restingOffset(for: anchor), animated: false) }
        for card in Array(cards.values) + pool {
            card.setSize(metrics.cardSize, headerHeight: metrics.headerHeight)
        }
        if oldThumbnail != CGSize(width: metrics.cardWidth, height: metrics.thumbnailHeight) {
            for (id, card) in cards { configure(card, id: id) }
        }
    }

    private func updateContentSize() {
        let size = CGSize(width: metrics.contentWidth(for: order.count), height: max(1, metrics.height))
        if scrollView.contentSize != size { scrollView.contentSize = size }
    }

    /// The slot at rest in the middle (cascade) or first on the page (grid).
    private func focusedSlot() -> Int {
        guard !order.isEmpty else { return 0 }
        let stop = Int((scrollView.contentOffset.x / metrics.snapUnit).rounded())
        let slot = metrics.style == .cascade ? stop : stop * metrics.cardsPerPage
        return min(max(slot, 0), order.count - 1)
    }

    /// Jumps or scrolls to `offset`, stopping any scroll in flight.
    private func scroll(to offset: CGFloat, animated: Bool) {
        let clamped = min(max(offset, 0), metrics.maxOffset(for: order.count))
        snapTarget = nil
        // Under Reduce Motion a jump the user did not drive lands at once.
        scrollView.setContentOffset(CGPoint(x: clamped, y: 0), animated: animated && !Motion.prefersCrossfade)
    }

    // MARK: Placing cards

    /// Places every card that shows at the current scroll offset, from its slot and the motion
    /// still running. Runs on every scroll frame: position, transform, z order, a title's alpha
    /// and a mask width only, and only for the few cards on screen.
    func layoutCards() {
        guard metrics.width > 0, isViewLoaded else { return }
        let offset = scrollView.contentOffset.x + motion.scrollShift
        let contentX = scrollView.contentOffset.x
        var shown = Set<UUID>()
        shown.reserveCapacity(12)

        func place(_ id: UUID) {
            guard !shown.contains(id), let index = slots[id] else { return }
            let slot = CGFloat(index) + motion.slotOffset(id)
            let placement = metrics.placement(slot: slot, offset: offset)
            let appear = motion.appearance(id)
            let scale = placement.scale * (0.92 + 0.08 * appear)
            let halfWidth = metrics.cardWidth * scale / 2
            guard placement.center.x + halfWidth > -1, placement.center.x - halfWidth < metrics.width + 1 else { return }
            if metrics.style == .cascade, !CascadeCurve.visibleRange.contains(placement.r) { return }
            shown.insert(id)
            let card = cards[id] ?? dequeueCard(for: id)
            let center = CGPoint(x: (placement.center.x + contentX).rounded(toScale: 3), y: placement.center.y)
            if card.center != center { card.center = center }
            let transform = scale == 1 ? CGAffineTransform.identity : CGAffineTransform(scaleX: scale, y: scale)
            if card.transform != transform { card.transform = transform }
            if card.alpha != appear { card.alpha = appear }
            let bodyAlpha: CGFloat = liftedID == id ? 0 : 1
            if card.body.alpha != bodyAlpha { card.body.alpha = bodyAlpha }
            // Later tabs lie on top; a card being dragged rides above everything.
            let z = reorder?.id == id ? 10_000 : slot
            if card.layer.zPosition != z { card.layer.zPosition = z }

            if metrics.style == .cascade {
                // The part of the card not under the next one, and on screen.
                let left = placement.center.x - halfWidth
                var right = min(placement.center.x + halfWidth, metrics.width - metrics.safeRight)
                if index + 1 < order.count {
                    let next = metrics.placement(slot: slot + 1, offset: offset)
                    right = min(right, next.center.x - metrics.cardWidth * next.scale / 2)
                }
                let visible = max(0, right - max(left, metrics.safeLeft))
                let fraction = visible / max(1, halfWidth * 2)
                card.setHeader(titleAlpha: CardTitle.alpha(visibleFraction: fraction), visibleWidth: visible / scale)
            } else {
                card.setHeader(titleAlpha: 1, visibleWidth: metrics.cardWidth)
            }
        }

        let range = metrics.candidateRange(offset: offset, count: order.count)
        if let range {
            for index in range { place(order[index]) }
        }
        if reorder != nil || motion.hasMovingCards {
            // Cards moving between places, and every card while a reorder shuffles slots: their
            // slot can be far from their index.
            motion.forEachMovingCard { id, _ in place(id) }
            if let reorder { place(reorder.id) }
        }
        for (id, card) in cards where !shown.contains(id) && !card.isSwiping {
            recycle(card, id: id)
        }
        for (_, leaving) in departing {
            let x = contentX + leaving.screenX
            if leaving.card.center.x != x { leaving.card.center.x = x }
        }
        if let range { warm(around: range) }
    }

    private func dequeueCard(for id: UUID) -> TabCardView {
        let card: TabCardView
        if let reused = pool.popLast() {
            card = reused
            card.isHidden = false
        } else {
            card = TabCardView()
            card.body.addInteraction(UIContextMenuInteraction(delegate: self))
            let drag = UIDragInteraction(delegate: self)
            drag.isEnabled = true
            card.body.addInteraction(drag)
            scrollView.addSubview(card)
        }
        card.setSize(metrics.cardSize, headerHeight: metrics.headerHeight)
        card.setHeaderFade(headerFade)
        cards[id] = card
        configure(card, id: id)
        return card
    }

    private func recycle(_ card: TabCardView, id: UUID) {
        cards[id] = nil
        card.prepareForReuse()
        card.isHidden = true
        pool.append(card)
    }

    /// Starts decoding the previews a scroll is about to reach.
    private func warm(around range: ClosedRange<Int>) {
        guard warmedRange != range else { return }
        warmedRange = range
        let lo = max(0, range.lowerBound - 4), hi = min(order.count - 1, range.upperBound + 4)
        guard lo <= hi else { return }
        for index in lo...hi {
            let id = order[index]
            guard let item = items[id] else { continue }
            pipeline.warm(thumbnailKey(for: item)) { [dataSource] in await dataSource.thumbnail(for: id) }
            pipeline.warm(faviconKey(for: item)) { [dataSource] in await dataSource.favicon(for: id) }
        }
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
        let previousSlots = slots
        let oldSelection = selectedID
        order = tabs.map(\.id)
        var nextItems: [UUID: TabGalleryItem] = [:]
        nextItems.reserveCapacity(tabs.count)
        var nextSlots: [UUID: Int] = [:]
        nextSlots.reserveCapacity(tabs.count)
        for (index, tab) in tabs.enumerated() {
            nextItems[tab.id] = tab
            nextSlots[tab.id] = index
        }
        if let current = reorder {
            if nextItems[current.id] != nil {
                // A drag is under way (a title changed meanwhile): the cards keep making room.
                var arranged = order.filter { $0 != current.id }
                let slot = min(current.slot, arranged.count)
                arranged.insert(current.id, at: slot)
                for (index, id) in arranged.enumerated() { nextSlots[id] = index }
                reorder = (current.id, slot)
            } else {
                cancelReorder()
            }
        }
        items = nextItems
        slots = nextSlots
        selectedID = dataSource.selectedTabID

        let oldOffset = scrollView.contentOffset.x
        updateContentSize()
        let maxOffset = metrics.maxOffset(for: order.count)
        let moves = animated && !Motion.prefersCrossfade && metrics.width > 0

        // Cards whose tab left the list: they rise away when animated (a close from elsewhere).
        for (id, card) in cards where nextItems[id] == nil {
            cards[id] = nil
            motion.forget(id)
            depart(card, animated: moves)
        }

        if moves {
            // Each card near the screen shows where it was and springs to its new place. Cards
            // far off screen just take their place: nobody sees them move.
            let near = metrics.candidateRange(offset: min(oldOffset, maxOffset), count: order.count)
                .map { ($0.lowerBound - 6)...($0.upperBound + 6) }
            for (id, slot) in nextSlots {
                if let old = previousSlots[id] {
                    guard old != slot, let near, near.contains(slot) || near.contains(old) else { continue }
                    motion.displace(id, by: CGFloat(old - slot))
                } else if !previousSlots.isEmpty {
                    motion.grow(id)
                }
            }
            if oldOffset > maxOffset {
                // The content got shorter under the scroll position: the cards stay where they
                // are and ease into the new resting place.
                scroll(to: maxOffset, animated: false)
                motion.shiftScroll(by: oldOffset - maxOffset)
            }
        } else {
            // Only a change of order lands at once; a new title or selection leaves running
            // motion alone (a card tapped mid-reflow opens from where it is on screen).
            if previousSlots != nextSlots { motion.reset() }
            if oldOffset > maxOffset { scroll(to: maxOffset, animated: false) }
        }

        // Cards whose content changed are configured again.
        for (id, card) in cards {
            guard let item = nextItems[id] else { continue }
            if previous[id] != item || id == oldSelection || id == selectedID { configure(card, id: id) }
        }
        let finish = {
            Signposts.signposter.endInterval(Signposts.galleryReload, state)
            completion?()
        }
        if animated, Motion.prefersCrossfade {
            Motion.crossfade(scrollView, changes: { self.layoutCards() }, completion: finish)
        } else {
            layoutCards()
            motion.run(in: view, completion: finish)
        }
        updateChrome()
    }

    /// A card whose tab is gone rises off the screen, then goes back to the pool. While it flies
    /// it keeps its place on screen, even when the scroll offset moves under it.
    private func depart(_ card: TabCardView, animated: Bool) {
        guard animated else {
            retire(card)
            return
        }
        departing[ObjectIdentifier(card)] = (card, card.center.x - scrollView.contentOffset.x)
        card.throwAway { [weak self, weak card] in
            guard let self, let card else { return }
            departing[ObjectIdentifier(card)] = nil
            retire(card)
        }
    }

    /// A card that left for good goes back to the pool.
    private func retire(_ card: TabCardView) {
        card.prepareForReuse()
        card.isHidden = true
        pool.append(card)
    }

    private func updateChrome() {
        let isPrivate = dataSource.isShowingPrivateTabs
        // Private tabs: the same blur, tinted with the private dusk.
        let dim = isPrivate ? Palette.privateBackground.withAlphaComponent(0.7) : Palette.galleryDim
        if backdrop.contentView.backgroundColor != dim || isShowingPrivate != isPrivate {
            isShowingPrivate = isPrivate
            backdrop.contentView.backgroundColor = dim
            bottomBar.setPrivate(isPrivate)
            emptyView.setPrivate(isPrivate)
        }
        let isEmpty = items.isEmpty
        // VoiceOver hears how many tabs there are, cards off screen included.
        scrollView.accessibilityValue = items.count == 1 ? "1 tab" : "\(items.count) tabs"
        if !isEmpty { isLeavingEmpty = false }
        emptyView.isHidden = !isEmpty || isLeavingEmpty
        // With the private toggle, the bar stays: it is the way between regular and private tabs.
        bottomBar.isHidden = isEmpty && !dataSource.supportsPrivateTabs
        // Each control by docs/state-rules.md §6, hidden in place (the bar keeps its shape).
        let rules = GalleryRules(galleryState)
        bottomBar.newTabButton.isHidden = !rules.newTabButton
        bottomBar.doneButton.isHidden = !rules.done
        bottomBar.menuButton.isHidden = !rules.more
        if isEmpty { toast.hide(animated: false) }
    }

    /// The shown list in the terms of the state rules.
    private var galleryState: GalleryState {
        var state = GalleryState()
        state.listCount = items.count
        state.closableCount = items.values.count { !$0.isPinned }
        state.isPrivateList = dataSource.isShowingPrivateTabs
        state.selectionInList = selectedID.map { items[$0] != nil } ?? false
        state.hasClosed = dataSource.canReopenClosedTab
        state.hasArchived = dataSource.canShowArchive
        return state
    }

    private func configure(_ card: TabCardView, id: UUID) {
        guard let item = items[id] else { return }
        card.configure(
            item: item, isSelected: id == selectedID, hidesThumbnail: id == hiddenThumbnailID,
            showsPrivateBadge: !dataSource.isShowingPrivateTabs, marksSelection: selectionRingWidth > 0
        )
        card.onOpen = { [weak self] in self?.open(id) }
        card.onClose = { [weak self] in self?.closeTab(id) }
        card.onSwipeAway = { [weak self] in self?.closeTab(id) }

        let thumbKey = thumbnailKey(for: item)
        if card.thumbnailKey != thumbKey {
            card.thumbnailKey = thumbKey
            if let image = pipeline.cached(thumbKey) {
                card.setThumbnail(image)
            } else {
                Task { [weak self, weak card] in
                    guard let self else { return }
                    let image = await pipeline.image(for: thumbKey) { [dataSource] in await dataSource.thumbnail(for: id) }
                    guard let card, card.thumbnailKey == thumbKey else { return }
                    // Nothing yet: forget the request, so the next configure asks again.
                    if image == nil { card.thumbnailKey = nil }
                    card.setThumbnail(image)
                }
            }
        }
        let iconKey = faviconKey(for: item)
        if card.faviconKey != iconKey {
            card.faviconKey = iconKey
            if let image = pipeline.cached(iconKey) {
                card.setFavicon(image)
            } else {
                card.setFavicon(nil)
                Task { [weak self, weak card] in
                    guard let self else { return }
                    let image = await pipeline.image(for: iconKey) { [dataSource] in await dataSource.favicon(for: id) }
                    guard let card, card.faviconKey == iconKey else { return }
                    if image == nil { card.faviconKey = nil }
                    card.setFavicon(image)
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
        return .init(
            id: item.id, revision: hasher.finalize(), pixelWidth: Int(TabGalleryMetrics.faviconSize * scale),
            maxAspectPermille: 0, kind: .favicon
        )
    }

    // MARK: Actions

    private func open(_ id: UUID) {
        toast.hide(animated: true)
        dataSource.selectTab(id)
        // Move the selection ring now; the shell has already hidden the card it zooms.
        reloadTabs(animated: false)
    }

    /// Done, or the empty space: back to the tab on screen, by its card when it has one here.
    private func done() {
        guard let selectedID, items[selectedID] != nil else { return dataSource.returnToPage() }
        open(selectedID)
    }

    private func newTab() {
        Signposts.signposter.emitEvent(Signposts.galleryNewTab)
        toast.hide(animated: false)
        dataSource.newTab()
    }

    /// Regular or private tabs: the cards cross-fade to the other list, which opens on its
    /// selected tab.
    private func togglePrivate() {
        let isPrivate = !dataSource.isShowingPrivateTabs
        Signposts.signposter.emitEvent(Signposts.privateMode, "\(isPrivate ? "on" : "off")")
        Haptic.selection.play()
        toast.hide(animated: true)
        dataSource.setShowingPrivateTabs(isPrivate)
        Motion.crossfade(view, changes: { [weak self] in
            guard let self else { return }
            reloadTabs(animated: false)
            if let selectedID, let slot = slots[selectedID] {
                scroll(to: metrics.restingOffset(for: slot), animated: false)
            } else {
                scroll(to: 0, animated: false)
            }
            layoutCards()
        })
    }

    /// Closes a tab: its card rises away (keeping the swipe's velocity when swiped), the cards
    /// after it slide into the gap, and the Reopen toast shows.
    func closeTab(_ id: UUID) {
        let state = Signposts.signposter.beginInterval(Signposts.galleryCardClose)
        Haptic.close.play()
        if let card = cards[id] {
            // The card leaves on its own; the gallery no longer places it.
            cards[id] = nil
            motion.forget(id)
            depart(card, animated: true)
        }
        // Read before the close: private tabs never come back, so they get no Reopen offer.
        let offersReopen = GalleryRules(galleryState).reopenToastAfterClose
        dataSource.closeTab(id)
        if dataSource.tabs.isEmpty {
            reloadTabs(animated: false)
            Signposts.signposter.endInterval(Signposts.galleryCardClose, state)
            leaveEmpty()
            return
        }
        reloadTabs(animated: true) {
            Signposts.signposter.endInterval(Signposts.galleryCardClose, state)
        }
        if offersReopen { toast.show(animated: true) } else { toast.hide(animated: true) }
    }

    /// The shell switched lists after the last card of the other one closed: the Reopen offer
    /// moves with it.
    public func showReopenToast() {
        toast.show(animated: true)
    }

    /// The list just emptied: the shell takes over (search, or the other list). The gallery never
    /// shows its empty state on the way out (Arc: closing the last tab goes straight to search).
    private func leaveEmpty() {
        isLeavingEmpty = true
        emptyView.isHidden = true
        onLastTabClosed?()
    }

    /// Reopen from the menu (the last close) or the toast (`offered`: the close it was shown for).
    private func reopenClosedTab(offered: Bool = false) {
        Signposts.signposter.emitEvent(Signposts.galleryReopen)
        toast.hide(animated: true)
        guard let id = offered ? dataSource.reopenOfferedTab() : dataSource.reopenClosedTab() else { return }
        reloadTabs(animated: true)
        scrollToTab(id, animated: true)
    }

    private func confirmCloseAll(from source: UIView) {
        // Only the tabs it closes: pinned ones stay.
        let count = galleryState.closableCount
        let offersReopen = GalleryRules(galleryState).reopenToastAfterClose
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        let title = count == 1 ? "Close 1 Tab" : "Close All \(count) Tabs"
        sheet.addAction(UIAlertAction(title: title, style: .destructive) { [weak self] _ in
            guard let self else { return }
            Signposts.signposter.emitEvent(Signposts.galleryCloseAll)
            dataSource.closeAllTabs()
            reloadTabs(animated: false)
            if dataSource.tabs.isEmpty {
                leaveEmpty()
            } else if offersReopen {
                toast.show(animated: true)
            }
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = source
        present(sheet, animated: true)
    }

    private func galleryMenuItems() -> [UIMenuElement] {
        Signposts.signposter.emitEvent(Signposts.galleryMenu)
        var elements: [UIMenuElement] = []
        let rules = GalleryRules(galleryState)
        if rules.reopenClosedTab {
            elements.append(UIAction(title: "Reopen Closed Tab", image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in
                self?.reopenClosedTab()
            })
        }
        if rules.archivedTabs {
            let archive = UIAction(title: "Archived Tabs", image: UIImage(systemName: "archivebox")) { [weak self] _ in
                self?.toast.hide(animated: false)
                self?.dataSource.showArchive()
            }
            archive.accessibilityIdentifier = "gallery.archive"
            elements.append(archive)
        }
        guard rules.closeAllTabs else { return elements }
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

    /// Brings the tab's card to rest on screen: in the middle of the cascade, or its grid page. A
    /// grid card already on screen does not move.
    public func scrollToTab(_ id: UUID, animated: Bool) {
        guard let slot = slots[id] else { return }
        if metrics.style == .grid, let card = cards[id], scrollView.bounds.contains(card.frame) { return }
        scroll(to: metrics.restingOffset(for: slot), animated: animated)
    }

    /// Gets the tab's card on screen and placed before a transition measures it.
    /// - Parameter revealFully: bring the card to its resting place. True when the gallery is about
    ///   to appear (the current tab sits in the middle, as in the app switcher); false when the
    ///   user just tapped a card, which must not jump.
    public func prepareForTransition(to id: UUID, revealFully: Bool = true) {
        loadViewIfNeeded()
        view.layoutIfNeeded()
        if revealFully || cards[id] == nil {
            motion.reset()
            if let slot = slots[id] { scroll(to: metrics.restingOffset(for: slot), animated: false) }
        }
        layoutCards()
    }

    /// The card's page preview, in `target`'s coordinates.
    public func thumbnailFrame(for id: UUID, in target: UIView) -> CGRect? {
        guard let card = cards[id] else { return nil }
        let preview = card.thumbnailContainer
        return preview.convert(preview.bounds, to: target)
    }

    /// Hides the preview of `id`'s card (and shows every other) while a transition stands in for
    /// it. `nil` shows them all.
    public func setThumbnailHidden(for id: UUID?) {
        hiddenThumbnailID = id
        for (cardID, card) in cards {
            card.setThumbnailHidden(cardID == id)
        }
    }

    /// The active tab's ring: only in the grid. In the cascade the tab on screen rests in the
    /// middle, as in the app switcher, which marks nothing.
    var selectionRingWidth: CGFloat { metrics.style == .grid ? TabCardView.selectionWidth : 0 }

    /// How visible the cards' title rows are, 0...1: a transition fades them while the cards are
    /// zoomed in, so they never cross the status bar.
    private(set) var headerFade: CGFloat = 1

    func setHeaderFade(_ fade: CGFloat) {
        headerFade = fade
        for card in cards.values { card.setHeaderFade(fade) }
    }

    /// The views a transition zooms and fades: the cards, then the floating controls.
    var transitionContent: [UIView] { [scrollView, bottomBar, toast] }

    // MARK: Reorder support

    func tabItem(_ id: UUID) -> TabGalleryItem? { items[id] }
    func slotOf(_ id: UUID) -> Int? { slots[id] }
    func setSlot(_ slot: Int, for id: UUID) { slots[id] = slot }

    func hideDraggedCard(_ card: TabCardView, hidden: Bool) {
        if hidden {
            liftedID = card.tabID
        } else if liftedID == card.tabID {
            liftedID = nil
        }
        card.body.alpha = hidden ? 0 : 1
    }

    /// Keeps the dropped card hidden through the reload, until the drop preview lands on it.
    func keepDraggedCardHidden(_ id: UUID?) {
        liftedID = id
    }

    /// The dragged tab left the list (closed elsewhere): the drag's state goes with it.
    func cancelReorder() {
        reorder = nil
        liftedID = nil
        autoScroll?.stop()
        autoScroll = nil
    }

    func dismissToastForReorder() {
        toast.hide(animated: true)
    }

    // MARK: VoiceOver

    /// Cards on screen in tab order, for VoiceOver.
    func accessibilityCards() -> [TabCardView] {
        cards.compactMap { id, card in slots[id].map { ($0, card) } }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// A three-finger swipe moves a screenful of cards.
    func accessibilityScroll(forward: Bool) -> Bool {
        guard !order.isEmpty else { return false }
        let perScreen = metrics.style == .cascade ? 2 : metrics.cardsPerPage
        let current = focusedSlot()
        let next = min(max(current + (forward ? perScreen : -perScreen), 0), order.count - 1)
        let target = min(metrics.restingOffset(for: next), metrics.maxOffset(for: order.count))
        // The last grid page can be part full: moving within it is no scroll.
        guard abs(target - scrollView.contentOffset.x) > 0.5 else { return false }
        scroll(to: target, animated: false)
        layoutCards()
        UIAccessibility.post(notification: .pageScrolled, argument: "Tab \(next + 1) of \(order.count)")
        return true
    }
}

// MARK: - Scroll physics

// MARK: - Back to the page from the empty space

extension TabGalleryViewController: UIGestureRecognizerDelegate {
    /// Only touches on the space between and around cards; a card handles its own.
    public func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touch.view === scrollView
    }

    public func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === backgroundSwipe, let pan = gesture as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        return velocity.y < 0 && abs(velocity.y) > abs(velocity.x)
    }

    @objc func backgroundTapped() {
        guard reorder == nil else { return }
        Signposts.signposter.emitEvent(Signposts.galleryBack)
        done()
    }

    @objc func backgroundSwiped(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .ended else { return }
        let travel = pan.translation(in: view).y
        let velocity = pan.velocity(in: view).y
        if travel < -SwitcherSwipe.backTravel || velocity < -SwitcherSwipe.flickSpeed { backgroundTapped() }
    }
}

extension TabGalleryViewController: UIScrollViewDelegate {
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        layoutCards()
    }

    // Scroll signposts: one interval per scroll, finger down to rest.
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if scrollInterval == nil { scrollInterval = Signposts.signposter.beginInterval(Signposts.galleryScroll) }
        dragStartOffset = scrollView.contentOffset.x
        snapTarget = nil
        toast.hide(animated: true)
    }

    /// Lets the system project where the flick stops (its normal deceleration), then rounds that
    /// to a card or a page. The scroll view decelerates onto it with the flick's own speed.
    public func scrollViewWillEndDragging(
        _ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        let target = metrics.snappedOffset(
            projected: targetContentOffset.pointee.x, current: dragStartOffset, velocity: velocity.x, count: order.count
        )
        targetContentOffset.pointee.x = target
        snapTarget = target
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            // Released without speed: the system does not move to the target on its own.
            if let snapTarget, abs(snapTarget - scrollView.contentOffset.x) > 0.5 {
                scrollView.setContentOffset(CGPoint(x: snapTarget, y: 0), animated: true)
            } else {
                endScrollInterval()
            }
        }
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        endScrollInterval()
    }

    public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        endScrollInterval()
    }

    private func endScrollInterval() {
        snapTarget = nil
        guard let state = scrollInterval else { return }
        Signposts.signposter.endInterval(Signposts.galleryScroll, state)
        scrollInterval = nil
    }
}

// MARK: - Card menu

extension TabGalleryViewController: UIContextMenuInteractionDelegate {
    private func card(for interaction: UIContextMenuInteraction) -> (UUID, TabCardView)? {
        guard let card = interaction.view?.superview as? TabCardView, let id = card.tabID, cards[id] === card else { return nil }
        return (id, card)
    }

    public func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let (id, _) = card(for: interaction), let item = items[id] else { return nil }
        Signposts.signposter.emitEvent(Signposts.galleryMenu)
        return UIContextMenuConfiguration(identifier: id as NSUUID, previewProvider: nil) { [weak self] _ in
            self?.cardMenu(for: item)
        }
    }

    public func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
        highlightPreviewForItemWithIdentifier identifier: any NSCopying
    ) -> UITargetedPreview? {
        card(for: interaction).map { cardPreview($0.1) }
    }

    public func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
        dismissalPreviewForItemWithIdentifier identifier: any NSCopying
    ) -> UITargetedPreview? {
        card(for: interaction).map { cardPreview($0.1) }
    }

    private func cardPreview(_ card: TabCardView) -> UITargetedPreview {
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: card.thumbnailContainer.bounds, cornerRadius: Radius.large)
        return UITargetedPreview(view: card.thumbnailContainer, parameters: parameters)
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
                Signposts.signposter.emitEvent(Signposts.galleryShare)
                share(item, from: cards[id] ?? view)
            })
        }
        // Names the gesture: menus teach the shortcut (docs/ui-reference.md).
        let close = UIAction(
            title: "Close Tab", subtitle: "Or swipe the card up", image: UIImage(systemName: "xmark"), attributes: .destructive
        ) { [weak self] _ in
            self?.closeTab(id)
        }
        return UIMenu(children: top + [UIMenu(options: .displayInline, children: [close])])
    }
}

// MARK: - Scroll view

/// What the scroll view asks the gallery for.
@MainActor
protocol GalleryAccessibilityProvider: AnyObject {
    func accessibilityCards() -> [TabCardView]
    func accessibilityScroll(forward: Bool) -> Bool
}

extension TabGalleryViewController: GalleryAccessibilityProvider {}

/// The gallery's scroll view: sideways only, leaving vertical swipes to the cards, and touches
/// to the card on top where cards overlap.
final class GalleryScrollView: UIScrollView {
    weak var accessibilityProvider: (any GalleryAccessibilityProvider)?

    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        if gesture === panGestureRecognizer {
            let velocity = panGestureRecognizer.velocity(in: self)
            // A mostly vertical move belongs to the card under the finger (swipe up to close).
            if abs(velocity.y) > abs(velocity.x) { return false }
        }
        return super.gestureRecognizerShouldBegin(gesture)
    }

    /// Cards overlap in the cascade; the one drawn on top (highest z) takes the touch, whatever
    /// the order of the subviews.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, self.point(inside: point, with: event) else { return nil }
        var best: (z: CGFloat, view: UIView)?
        for case let card as TabCardView in subviews where !card.isHidden && card.isUserInteractionEnabled {
            let local = card.convert(point, from: self)
            guard let hit = card.hitTest(local, with: event) else { continue }
            if best == nil || card.layer.zPosition > best!.z { best = (card.layer.zPosition, hit) }
        }
        return best?.view ?? self
    }

    override var accessibilityElements: [Any]? {
        get { accessibilityProvider?.accessibilityCards() }
        set {}
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        switch direction {
        case .left, .next: return accessibilityProvider?.accessibilityScroll(forward: true) ?? false
        case .right, .previous: return accessibilityProvider?.accessibilityScroll(forward: false) ?? false
        default: return false
        }
    }
}

extension CGFloat {
    /// Rounded to the nearest pixel at `scale`, so cards never land between pixels and blur.
    func rounded(toScale scale: CGFloat) -> CGFloat {
        (self * scale).rounded() / scale
    }
}
#endif
