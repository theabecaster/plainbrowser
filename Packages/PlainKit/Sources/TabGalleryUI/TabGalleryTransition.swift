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
    /// How much the gallery's cards are zoomed in while the page covers them.
    private static let galleryZoom: CGFloat = 0.06

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

        wrapper.clipsToBounds = true
        wrapper.layer.cornerCurve = .continuous
        wrapper.layer.borderColor = Palette.accent.cgColor
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
        UIView.animate(Motion.tracking) { self.apply(progress: clamped, crossfade: false) }
    }

    /// Ends a gesture-driven run: springs to `end` with the gesture's velocity.
    public func finish(at end: End) {
        animate(to: end)
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
            UIView.animate(Motion.galleryZoom, changes: { self.apply(progress: self.progress(of: end), crossfade: false) }, completion: finish)
        }
    }

    /// Lays everything out for `progress` (0 = page, 1 = card). Under Reduce Motion `progress`
    /// is the page's opacity instead, and nothing moves.
    private func apply(progress: CGFloat, crossfade: Bool) {
        let content = gallery.transitionContent
        if crossfade {
            setFrame(pageFrame)
            wrapper.layer.cornerRadius = 0
            wrapper.layer.borderWidth = 0
            wrapper.alpha = progress
            for view in content { view.transform = .identity; view.alpha = 1 }
            // The card shows under the fading page, so there is no gap.
            gallery.setThumbnailHidden(for: nil)
            return
        }
        let frame = CGRect(
            x: lerp(pageFrame.minX, cardFrame.minX, progress),
            y: lerp(pageFrame.minY, cardFrame.minY, progress),
            width: max(1, lerp(pageFrame.width, cardFrame.width, progress)),
            height: max(1, lerp(pageFrame.height, cardFrame.height, progress))
        )
        setFrame(frame)
        let t = min(max(progress, 0), 1)
        wrapper.layer.cornerRadius = lerp(0, Radius.large, t)
        // The tab being opened or left is the selected one: its card's ring grows in with the
        // zoom, so nothing pops when the real card takes over.
        // Only over the last stretch, so a page on its way to full screen never reads as a tile.
        wrapper.layer.borderWidth = TabCardCell.selectionWidth * max(0, (t - 0.7) / 0.3)
        wrapper.alpha = 1
        let zoom = 1 + Self.galleryZoom * (1 - progress)
        if let cards = content.first {
            cards.transform = CGAffineTransform(scaleX: zoom, y: zoom)
            cards.alpha = min(1, max(0, 0.3 + 0.7 * progress))
        }
        for view in content.dropFirst() { view.alpha = min(1, max(0, progress)) }
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
        Signposts.signposter.endInterval(signpostName, signpostState)
        completion(end)
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }
}
#endif
