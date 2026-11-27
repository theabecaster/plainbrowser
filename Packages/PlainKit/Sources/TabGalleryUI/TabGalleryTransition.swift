#if canImport(UIKit)
import DesignSystem
import os
import PerfSignposts
import UIKit

/// The custom snapshot animator between a page and its card (docs/plan.md, section 5: "Open tab
/// gallery" and "Open tab"). Not the system `.zoom` transition: tabs are re-parented web views,
/// not pushed view controllers.
///
/// The shell puts the gallery's view in `container` (laid out at its final size) with the page
/// above it, hides the live page, and hands over a snapshot of it. The transition moves that
/// snapshot between the page's frame and the card's preview frame with the gallery spring, keeps
/// the real card's preview hidden by tab id meanwhile, and calls `completion` with where it
/// ended. At `.page` the shell swaps the live web view back in.
///
/// Every run is interruptible: `reverse()` (or a tap on the moving page) retargets from where the
/// snapshot is on screen and keeps its velocity. `update(progress:)` and `finish(at:)` let a
/// gesture drive it (swipe up from the bar). Under Reduce Motion it is a 0.2 s crossfade.
@MainActor
public final class TabGalleryTransition {
    public enum End: Equatable, Sendable {
        case page
        case gallery
    }

    public let tabID: UUID
    /// Where the transition is heading now.
    public private(set) var destination: End
    public private(set) var isFinished = false

    private let gallery: TabGalleryViewController
    private let container: UIView
    private let snapshot: UIView
    private let pageFrame: CGRect
    private var cardFrame: CGRect
    private let wrapper = UIView()
    private let completion: (End) -> Void
    private var generation = 0
    private let signpostName: StaticString
    private let signpostState: OSSignpostIntervalState
    /// Where a finger has moved the page off its path (`track(translation:)`); springs back to
    /// zero when the transition runs to an end.
    private var offset: CGPoint = .zero
    private var lastProgress: CGFloat = 0

    /// - Parameters:
    ///   - container: the view both the gallery and the page sit in; the snapshot moves in it.
    ///   - snapshot: a picture of the page, sized like `pageFrame`.
    ///   - pageFrame: the page's frame in `container`.
    ///   - start: where it starts; it heads to the other end.
    public init(
        tabID: UUID, gallery: TabGalleryViewController, container: UIView, snapshot: UIView,
        pageFrame: CGRect, from start: End, completion: @escaping (End) -> Void
    ) {
        self.tabID = tabID
        self.gallery = gallery
        self.container = container
        self.snapshot = snapshot
        self.pageFrame = pageFrame
        self.completion = completion
        destination = start == .page ? .gallery : .page
        signpostName = start == .page ? Signposts.galleryShow : Signposts.galleryOpenTab
        signpostState = Signposts.signposter.beginInterval(signpostName)

        gallery.prepareForTransition(to: tabID, revealFully: start == .page)
        cardFrame = gallery.thumbnailFrame(for: tabID, in: container)
            ?? CGRect(x: pageFrame.midX - 1, y: pageFrame.midY - 1, width: 2, height: 2)
        gallery.setThumbnailHidden(for: tabID)
        // The New Tab card beside a lone card would cover the moving page's edge; it waits and
        // grows in once the page has landed. A crossfade moves nothing, so it stays.
        if !Motion.prefersCrossfade { gallery.setNewTabCardHeld(true, fades: start == .gallery) }

        wrapper.clipsToBounds = true
        wrapper.layer.cornerCurve = .continuous
        wrapper.layer.borderColor = Palette.coral.cgColor
        wrapper.backgroundColor = Palette.surface
        wrapper.accessibilityElementsHidden = true
        snapshot.layer.anchorPoint = CGPoint(x: 0.5, y: 0)
        snapshot.bounds = CGRect(origin: .zero, size: pageFrame.size)
        wrapper.addSubview(snapshot)
        container.addSubview(wrapper)
        wrapper.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))

        if Motion.prefersCrossfade {
            apply(progress: 1 - progress(of: start), crossfade: true)
        } else {
            apply(progress: progress(of: start), crossfade: false)
        }
    }

    /// Animates to the current destination.
    public func run() {
        animate(to: destination)
    }

    /// Turns around mid-flight, from where it is on screen.
    public func reverse() {
        guard !isFinished else { return }
        animate(to: destination == .page ? .gallery : .page)
    }

    /// Follows a gesture: 0 is the page, 1 is the card.
    public func update(progress: CGFloat) {
        guard !isFinished, !Motion.prefersCrossfade else { return }
        generation += 1
        let clamped = min(max(progress, -0.1), 1.1)
        lastProgress = clamped
        UIView.animate(Motion.tracking) { self.apply(progress: clamped, crossfade: false) }
    }

    /// Ends a gesture-driven run: springs to `end` with the gesture's velocity.
    public func finish(at end: End) {
        animate(to: end)
    }

    /// Follows a finger that drags the page up from the bar, the way the home-indicator swipe
    /// pulls an app into the app switcher: the page shrinks with the distance travelled, its
    /// bottom edge stays under the finger, it moves sideways with the finger, and the other cards
    /// slide in around it. `translation` is the finger's, in points, negative upward.
    /// - Returns: the progress shown, 0 (the page) to 1 (the card), for chrome that fades along.
    @discardableResult
    public func track(translation: CGPoint) -> CGFloat {
        guard !isFinished else { return progress(of: destination) }
        let progress = SwitcherSwipe.progress(translationY: translation.y, pageHeight: pageFrame.height)
        // Kept under Reduce Motion too: nothing moves, but the release still decides from it.
        lastProgress = progress
        guard !Motion.prefersCrossfade else { return progress }
        generation += 1
        // The bottom edge where the finger is; sideways 1:1.
        let bottom = lerp(pageFrame.maxY, cardFrame.maxY, progress)
        var offset = CGPoint(x: translation.x, y: pageFrame.maxY + min(0, translation.y) - bottom)
        // The page's top stays out of the status bar: past the page's own top edge it resists
        // like a rubber band, so the page's heading never slides under the clock and the island.
        let top = lerp(pageFrame.minY, cardFrame.minY, progress) + offset.y
        if top < pageFrame.minY {
            let overshoot = pageFrame.minY - top
            offset.y += overshoot - Self.rubberBand(overshoot, limit: Self.topOvershoot)
        }
        UIView.animate(Motion.tracking) {
            self.offset = offset
            self.apply(progress: progress, crossfade: false)
        }
        return progress
    }

    /// Ends a `track(translation:)` run. The release is projected the way a scroll view would
    /// carry it: past `SwitcherSwipe.commit` of the way, or any clear flick up, lands in the
    /// gallery; a release moving down, or short of the mark, goes back to the page. The spring
    /// continues from the finger's own motion.
    /// - Returns: where it is heading.
    @discardableResult
    public func release(velocity: CGPoint) -> End {
        let end: End = SwitcherSwipe.opensGallery(
            progress: lastProgress, velocityY: velocity.y, pageHeight: pageFrame.height
        ) ? .gallery : .page
        animate(to: end)
        return end
    }

    /// Ends at once where it is heading, with no animation (the gallery is going away).
    public func cancel() {
        guard !isFinished else { return }
        generation += 1
        complete(at: destination)
    }

    // MARK: Private

    @objc private func tapped() {
        reverse()
    }

    private func progress(of end: End) -> CGFloat {
        end == .page ? 0 : 1
    }

    private func animate(to end: End) {
        guard !isFinished else { return }
        destination = end
        generation += 1
        let current = generation
        let finish: () -> Void = { [weak self] in
            guard let self, generation == current else { return }
            complete(at: end)
        }
        if Motion.prefersCrossfade {
            // Nothing moves: the page fades over or off the gallery.
            UIView.animate(
                withDuration: Motion.crossfadeDuration, delay: 0,
                options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState],
                animations: { self.apply(progress: self.progress(of: end) == 0 ? 1 : 0, crossfade: true) },
                completion: { _ in finish() }
            )
        } else {
            animateRing(toward: end)
            lastProgress = progress(of: end)
            UIView.animate(Motion.galleryZoom, changes: {
                self.offset = .zero
                self.apply(progress: self.progress(of: end), crossfade: false, setsRing: false)
            }, completion: finish)
        }
    }

    /// Lays everything out for `progress` (0 = page, 1 = card). Under Reduce Motion `progress`
    /// is the page's opacity instead, and nothing moves.
    private func apply(progress: CGFloat, crossfade: Bool, setsRing: Bool = true) {
        let content = gallery.transitionContent
        if crossfade {
            setFrame(pageFrame)
            wrapper.layer.cornerRadius = 0
            wrapper.layer.borderWidth = 0
            wrapper.alpha = progress
            for view in content { view.transform = .identity; view.alpha = 1 }
            // The card shows under the fading page, so there is no gap.
            gallery.setThumbnailHidden(for: nil)
            gallery.setHeaderFade(1)
            return
        }
        let frame = CGRect(
            x: lerp(pageFrame.minX, cardFrame.minX, progress) + offset.x,
            y: lerp(pageFrame.minY, cardFrame.minY, progress) + offset.y,
            width: max(1, lerp(pageFrame.width, cardFrame.width, progress)),
            height: max(1, lerp(pageFrame.height, cardFrame.height, progress))
        )
        setFrame(frame)
        let t = min(max(progress, 0), 1)
        wrapper.layer.cornerRadius = lerp(0, Radius.large, t)
        // The tab being opened or left is the selected one: its card's ring grows in with the
        // zoom, so nothing pops when the real card takes over.
        // Only over the last stretch, so a page on its way to full screen never reads as a tile.
        // A spring would interpolate the width over the whole run, so `animateRing` times it then.
        if setsRing {
            wrapper.layer.removeAnimation(forKey: Self.ringKey)
            wrapper.layer.borderWidth = gallery.selectionRingWidth * max(0, (t - 0.7) / 0.3)
        }
        wrapper.alpha = 1
        if let cards = content.first {
            // The other cards move with the finger too: the stack is one surface.
            cards.transform = zoomTransform(for: cards, progress: progress)
                .concatenating(CGAffineTransform(translationX: offset.x, y: offset.y))
            cards.alpha = 1
        }
        // The gallery's bar comes in over the second half, after the page's bar has faded out over
        // the first third (the shell's `setChromeGalleryProgress`): two sets of controls never
        // share the bottom of the screen.
        for view in content.dropFirst() { view.alpha = min(1, max(0, (progress - 0.5) * 2)) }
        // Titles stay out of the status bar while the cards are zoomed in, or lifted by the finger
        // (a swipe up holds the card high): they fade in over the last part of the way down.
        let zoomFade = min(1, max(0, (progress - 0.6) / 0.4))
        let liftFade = min(1, max(0, 1 + offset.y / Self.liftFadeDistance))
        gallery.setHeaderFade(zoomFade * liftFade)
    }

    private static let ringKey = "selectionRing"
    /// The most a held page's top goes above its resting top (into the status bar), in points.
    private static let topOvershoot: CGFloat = 12

    /// UIScrollView's rubber band: `distance` past an edge shows as at most `limit`.
    static func rubberBand(_ distance: CGFloat, limit: CGFloat) -> CGFloat {
        guard distance > 0, limit > 0 else { return 0 }
        return limit * (1 - 1 / (distance * 0.55 / limit + 1))
    }
    /// Lifted this far above its resting place, a card's title is gone.
    private static let liftFadeDistance: CGFloat = 60

    /// The whole gallery zooms with the card, as the app switcher does: at the page end, the cards
    /// are scaled up around the card so that it covers the page, and its neighbors sit just off
    /// its sides. Every card moves along with the one being opened, so they leave and return as
    /// one surface. Scale and position follow the same interpolation as the moving page, so the
    /// card under it stays exactly beneath it.
    private func zoomTransform(for cards: UIView, progress: CGFloat) -> CGAffineTransform {
        guard cardFrame.width > 1, let parent = cards.superview else { return .identity }
        let full = pageFrame.width / cardFrame.width
        let scale = lerp(full, 1, progress)
        let cardCenter = CGPoint(x: cardFrame.midX, y: cardFrame.midY)
        // Where the card's center is heading on screen at this progress, in the container.
        let target = CGPoint(
            x: lerp(pageFrame.minX + pageFrame.width / 2, cardCenter.x, progress),
            y: lerp(pageFrame.minY + cardFrame.height * full / 2, cardCenter.y, progress)
        )
        // The view scales about its own center.
        let center = parent.convert(cards.center, to: container)
        let dx = target.x - center.x - scale * (cardCenter.x - center.x)
        let dy = target.y - center.y - scale * (cardCenter.y - center.y)
        return CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)
    }

    /// The selection ring grows in only as the page lands on its card, and leaves at once when a
    /// card starts growing into its page.
    private func animateRing(toward end: End) {
        let layer = wrapper.layer
        let from = layer.presentation()?.borderWidth ?? layer.borderWidth
        let to: CGFloat = end == .gallery ? gallery.selectionRingWidth : 0
        let animation = CABasicAnimation(keyPath: "borderWidth")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = end == .gallery ? 0.14 : 0.08
        if end == .gallery {
            animation.beginTime = CACurrentMediaTime() + 0.24
            animation.fillMode = .backwards
        }
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.borderWidth = to
        layer.add(animation, forKey: Self.ringKey)
    }

    /// The snapshot keeps the page's shape, scaled to the wrapper's width and pinned to its top:
    /// a card shows the top of its page.
    private func setFrame(_ frame: CGRect) {
        wrapper.frame = frame
        let scale = pageFrame.width > 0 ? frame.width / pageFrame.width : 1
        snapshot.transform = CGAffineTransform(scaleX: scale, y: scale)
        snapshot.center = CGPoint(x: frame.width / 2, y: 0)
    }

    private func complete(at end: End) {
        isFinished = true
        wrapper.removeFromSuperview()
        for view in gallery.transitionContent {
            view.transform = .identity
            view.alpha = 1
        }
        gallery.setThumbnailHidden(for: nil)
        gallery.setHeaderFade(1)
        gallery.setNewTabCardHeld(false, grows: end == .gallery)
        Signposts.signposter.endInterval(signpostName, signpostState)
        completion(end)
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }
}
#endif
