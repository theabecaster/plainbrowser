#if canImport(UIKit)
import DesignSystem
import PerfSignposts
import UIKit

/// Drag a card to a new place: long-press it (its menu opens), then move. The cards make room
/// under the finger as it goes, with the same springs as a close, and the gallery scrolls on its
/// own near the edges.
extension TabGalleryViewController: UIDragInteractionDelegate, UIDropInteractionDelegate {
    private func dragCard(_ interaction: UIDragInteraction) -> (UUID, TabCardView)? {
        guard let card = interaction.view?.superview as? TabCardView, let id = card.tabID, cards[id] === card else { return nil }
        return (id, card)
    }

    public func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession) -> [UIDragItem] {
        guard let (id, _) = dragCard(interaction), let item = tabItem(id) else { return [] }
        let provider = item.url.map { NSItemProvider(object: $0 as NSURL) } ?? NSItemProvider()
        let dragItem = UIDragItem(itemProvider: provider)
        dragItem.localObject = id as NSUUID
        return [dragItem]
    }

    public func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: any UIDragSession) -> UITargetedDragPreview? {
        guard let (_, card) = dragCard(interaction) else { return nil }
        let parameters = UIDragPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: card.thumbnailContainer.bounds, cornerRadius: Radius.large)
        return UITargetedDragPreview(view: card.thumbnailContainer, parameters: parameters)
    }

    public func dragInteraction(_ interaction: UIDragInteraction, sessionIsRestrictedToDraggingApplication session: any UIDragSession) -> Bool {
        true
    }

    public func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: any UIDragSession) {
        guard let (id, card) = dragCard(interaction), let slot = slotOf(id) else { return }
        // The lifted preview stands in for the card while it moves.
        reorder = (id, slot)
        hideDraggedCard(card, hidden: true)
        dismissToastForReorder()
    }

    public func dragInteraction(_ interaction: UIDragInteraction, session: any UIDragSession, didEndWith operation: UIDropOperation) {
        autoScroll?.stop()
        autoScroll = nil
        guard operation != .move, let reorder else { return }
        // Cancelled: every card goes back to its place; the lifted preview flies back to its card.
        self.reorder = nil
        restoreSlots()
        if let card = cards[reorder.id] { hideDraggedCard(card, hidden: false) }
    }

    public func dragInteraction(_ interaction: UIDragInteraction, item: UIDragItem, willAnimateCancelWith animator: any UIDragAnimating) {
        guard let (_, card) = dragCard(interaction) else { return }
        animator.addCompletion { _ in self.hideDraggedCard(card, hidden: false) }
    }

    // MARK: Drop

    public func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        session.localDragSession != nil && reorder != nil
    }

    public func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        guard reorder != nil else { return UIDropProposal(operation: .forbidden) }
        let location = session.location(in: view)
        moveReorder(toward: location)
        updateAutoScroll(for: location)
        return UIDropProposal(operation: .move)
    }

    public func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: any UIDropSession) {
        autoScroll?.stop()
        autoScroll = nil
    }

    public func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        autoScroll?.stop()
        autoScroll = nil
        guard let reorder else { return }
        Signposts.signposter.emitEvent(Signposts.galleryReorder)
        self.reorder = nil
        dataSource.moveTab(reorder.id, to: reorder.slot)
        // The cards already stand in their new places, so nothing moves again.
        keepDraggedCardHidden(reorder.id)
        reloadTabs(animated: true)
    }

    public func dropInteraction(
        _ interaction: UIDropInteraction, previewForDropping item: UIDragItem, withDefault defaultPreview: UITargetedDragPreview
    ) -> UITargetedDragPreview? {
        guard let id = (item.localObject as? NSUUID).map({ $0 as UUID }), let card = cards[id] else { return nil }
        let preview = card.thumbnailContainer
        let center = preview.convert(CGPoint(x: preview.bounds.midX, y: preview.bounds.midY), to: scrollView)
        let scale = card.transform.a
        return defaultPreview.retargetedPreview(
            with: UIDragPreviewTarget(container: scrollView, center: center, transform: CGAffineTransform(scaleX: scale, y: scale))
        )
    }

    public func dropInteraction(_ interaction: UIDropInteraction, item: UIDragItem, willAnimateDropWith animator: any UIDragAnimating) {
        guard let id = (item.localObject as? NSUUID).map({ $0 as UUID }) else { return }
        animator.addCompletion { _ in
            self.keepDraggedCardHidden(nil)
            if let card = self.cards[id] { self.hideDraggedCard(card, hidden: false) }
        }
    }

    // MARK: Moving cards out of the way

    /// The slot under `location` (in the gallery's view): the card whose uncovered part is under
    /// the finger in the cascade, the nearest card in the grid.
    func slot(at location: CGPoint) -> Int? {
        let count = order.count
        guard count > 0, metrics.width > 0 else { return nil }
        let offset = scrollView.contentOffset.x + motion.scrollShift
        guard let range = metrics.candidateRange(offset: offset, count: count) else { return nil }
        switch metrics.style {
        case .cascade:
            var found = range.lowerBound
            for slot in range {
                let placement = metrics.placement(slot: CGFloat(slot), offset: offset)
                let left = placement.center.x - metrics.cardWidth * placement.scale / 2
                if left <= location.x { found = slot }
            }
            return found
        case .grid:
            var best: (distance: CGFloat, slot: Int)?
            for slot in range {
                let center = metrics.placement(slot: CGFloat(slot), offset: offset).center
                let distance = hypot(center.x - location.x, center.y - location.y)
                if best == nil || distance < best!.distance { best = (distance, slot) }
            }
            return best?.slot
        }
    }

    private func moveReorder(toward location: CGPoint) {
        guard let current = reorder, let target = slot(at: location), target != current.slot else { return }
        Haptic.selection.play()
        reorder = (current.id, target)
        // Everyone else keeps their order around the dragged card's new place.
        var arranged = order.filter { $0 != current.id }
        arranged.insert(current.id, at: min(target, arranged.count))
        applyArrangement(arranged)
    }

    /// Puts every card back at its index.
    func restoreSlots() {
        applyArrangement(order)
    }

    private func applyArrangement(_ arranged: [UUID]) {
        for (slot, id) in arranged.enumerated() {
            guard let old = slotOf(id), old != slot else { continue }
            if id != reorder?.id { motion.displace(id, by: CGFloat(old - slot)) }
            setSlot(slot, for: id)
        }
        layoutCards()
        motion.run(in: view)
    }

    private func updateAutoScroll(for location: CGPoint) {
        let zone: CGFloat = 56
        let width = view.bounds.width
        let depth: CGFloat
        if location.x < zone {
            depth = -(zone - location.x) / zone
        } else if location.x > width - zone {
            depth = (location.x - (width - zone)) / zone
        } else {
            depth = 0
        }
        guard depth != 0 else {
            autoScroll?.stop()
            autoScroll = nil
            return
        }
        if autoScroll == nil {
            autoScroll = AutoScroller(view: view) { [weak self] delta in
                guard let self else { return }
                let maxOffset = metrics.maxOffset(for: order.count)
                let x = min(max(scrollView.contentOffset.x + delta, 0), maxOffset)
                scrollView.contentOffset.x = x
                if let location = autoScroll?.location { moveReorder(toward: location) }
            }
        }
        autoScroll?.location = location
        autoScroll?.speed = depth * AutoScroller.maxSpeed
    }
}

/// Scrolls the gallery while a dragged card waits at an edge.
@MainActor
final class AutoScroller {
    /// Points per second at the very edge.
    static let maxSpeed: CGFloat = 900
    var speed: CGFloat = 0
    var location: CGPoint?
    private var link: UIUpdateLink?
    private var lastTime: TimeInterval?

    init(view: UIView, onStep: @escaping (CGFloat) -> Void) {
        let link = UIUpdateLink(view: view)
        link.addAction { [weak self] _, info in
            guard let self else { return }
            let delta = lastTime.map { min(info.modelTime - $0, 1.0 / 30) } ?? 0
            lastTime = info.modelTime
            if delta > 0 { onStep(speed * delta) }
        }
        link.preferredFrameRateRange = SpringDriver.frameRateRange
        link.requiresContinuousUpdates = true
        link.isEnabled = true
        self.link = link
    }

    func stop() {
        link?.isEnabled = false
        link = nil
    }
}
#endif
