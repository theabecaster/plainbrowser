#if canImport(UIKit)
import BrowserCore
import DesignSystem
import os
import PerfSignposts
import TabGalleryUI
import UIKit
import WebEngine

/// Gestures on the expanded address bar (docs/plan.md, section 5): a sideways swipe moves between
/// neighbouring tabs, a swipe up opens the gallery. The collapsed pill takes taps only, so none of
/// this starts there.
///
/// A sideways swipe tracks the finger 1:1. The neighbour shows as its live web view when it has
/// one, else as a 2x full-screen picture kept for the two neighbours only (`TabsUIState.previews`).
/// The glass never moves: the pill's host slides inside it. On release the page springs
/// (`Motion.tabSwitchSpring`, frame by frame) toward the neighbour when the projected travel
/// passes half the width, with the release velocity; a finger can grab it mid-flight. Past the
/// last tab a New Tab card rubber-bands in; pulled `FixedChoices.newTabSwipeThreshold` far, it opens a
/// new tab with the search field.
final class TabSwipe: NSObject, UIGestureRecognizerDelegate {
    weak var browser: BrowserViewController?
    private let driver = SpringDriver(spring: Motion.tabSwitchSpring)
    private var swipe: Swipe?
    private var galleryTransition: TabGalleryTransition?
    private var mode = Mode.none
    private var startOffset: CGFloat = 0
    private var recognizers: [UIPanGestureRecognizer] = []

    private enum Mode { case none, tabs, gallery }

    /// One swipe from a tab toward a neighbour, kept while the page settles so a finger can grab it.
    private final class Swipe {
        let current: Tab
        let interval: OSSignpostIntervalState
        /// 1 toward the next tab (finger moving left), -1 toward the previous one, 0 not yet.
        var side = 0
        var neighbour: Tab?
        var isNewTabCard = false
        /// The neighbour's web view was attached into `preview` (else a picture or the card).
        var attachedLive = false
        let preview = UIView()
        var offset: CGFloat = 0
        /// Past the commit point, for the threshold haptic.
        var isArmed = false
        /// The finger left and the page is settling toward `target`.
        var target: CGFloat?

        init(current: Tab) {
            self.current = current
            interval = Signposts.signposter.beginInterval(Signposts.tabSwipe, id: Signposts.signposter.makeSignpostID())
        }
    }

    /// Adds the swipe to the expanded bar's views (the pill and the button bar).
    func install(on views: [UIView]) {
        for view in views {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
            pan.delegate = self
            pan.maximumNumberOfTouches = 1
            view.addGestureRecognizer(pan)
            recognizers.append(pan)
        }
    }

    var isActive: Bool { swipe != nil || mode != .none }

    // MARK: Gesture

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let browser, browser.acceptsBarGestures,
              let view = pan.view else { return false }
        let velocity = pan.velocity(in: view)
        if abs(velocity.x) > abs(velocity.y) {
            return browser.currentTab != nil || swipe != nil
        }
        // Up only, and not while a sideways swipe is settling.
        return velocity.y < 0 && swipe == nil
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard let browser, let view = browser.view else { return }
        let translation = pan.translation(in: view)
        let velocity = pan.velocity(in: view)
        switch pan.state {
        case .began:
            if abs(velocity.x) > abs(velocity.y) || swipe != nil {
                beginTabSwipe()
            } else {
                mode = .gallery
                galleryTransition = browser.presentGallery(source: "swipe", interactive: true)
            }
        case .changed:
            switch mode {
            case .tabs: track(startOffset + translation.x)
            case .gallery: trackGallery(translation.y)
            case .none: break
            }
        case .ended, .cancelled, .failed:
            switch mode {
            case .tabs: release(velocity: pan.state == .ended ? velocity.x : 0)
            case .gallery: releaseGallery(translation: translation.y, velocity: pan.state == .ended ? velocity.y : 0)
            case .none: break
            }
            mode = .none
        default:
            break
        }
    }

    // MARK: Swipe up: the gallery

    private func trackGallery(_ translationY: CGFloat) {
        guard let browser, let transition = galleryTransition else { return }
        let progress = -translationY / max(1, browser.view.bounds.height * 0.5)
        transition.update(progress: progress)
        browser.setChromeGalleryProgress(progress)
    }

    private func releaseGallery(translation: CGFloat, velocity: CGFloat) {
        guard let browser, let transition = galleryTransition else { return }
        galleryTransition = nil
        let progress = -translation / max(1, browser.view.bounds.height * 0.5)
        let opens = velocity < -FixedChoices.galleryFlickSpeed
            || (progress > FixedChoices.gallerySwipeCommit && velocity < FixedChoices.galleryFlickSpeed / 2)
        transition.finish(at: opens ? .gallery : .page)
        browser.setChromeHiddenForGallery(opens, animated: true)
    }

    // MARK: Sideways: tabs

    private func beginTabSwipe() {
        mode = .tabs
        if let swipe {
            // A finger on a settling page takes it from where it is on screen.
            startOffset = driver.stop()
            swipe.target = nil
            swipe.offset = startOffset
            return
        }
        guard let browser, let current = browser.currentTab else {
            mode = .none
            return
        }
        startOffset = 0
        let swipe = Swipe(current: current)
        swipe.preview.clipsToBounds = true
        swipe.preview.backgroundColor = Palette.background
        swipe.preview.frame = browser.webContainer.frame
        browser.view.insertSubview(swipe.preview, aboveSubview: browser.webContainer)
        self.swipe = swipe
        Haptic.selection.prepare()
    }

    /// Moves the page to `offset` (negative toward the next tab), preparing the neighbour on the
    /// side the finger went.
    private func track(_ offset: CGFloat) {
        guard let swipe, let browser else { return }
        let side = offset < 0 ? 1 : (offset > 0 ? -1 : swipe.side)
        if side != swipe.side { prepare(side: side) }
        swipe.offset = offset
        apply(swipe, browser: browser)
        // The threshold haptic: crossing into (not back out of) the commit zone.
        let width = browser.webContainer.bounds.width
        let armed: Bool
        if swipe.neighbour != nil {
            armed = abs(offset) > width / 2
        } else if swipe.isNewTabCard {
            armed = -displayed(offset, swipe: swipe, width: width) >= FixedChoices.newTabSwipeThreshold
        } else {
            armed = false
        }
        if armed, !swipe.isArmed { Haptic.selection.play() }
        swipe.isArmed = armed
    }

    /// The page's on-screen offset: 1:1 toward a neighbour, rubber-banded where there is none.
    private func displayed(_ offset: CGFloat, swipe: Swipe, width: CGFloat) -> CGFloat {
        if swipe.neighbour != nil { return min(max(offset, -width), width) }
        let sign: CGFloat = offset < 0 ? -1 : 1
        let distance = abs(offset)
        // UIScrollView's rubber band: resistance grows with distance, never past the width.
        let banded = (1 - 1 / (distance * 0.55 / max(width, 1) + 1)) * width
        return sign * banded
    }

    private func apply(_ swipe: Swipe, browser: BrowserViewController) {
        let width = browser.webContainer.bounds.width
        let shown = displayed(swipe.offset, swipe: swipe, width: width)
        browser.webContainer.transform = CGAffineTransform(translationX: shown, y: 0)
        let previewX = shown + CGFloat(swipe.side) * width
        swipe.preview.transform = CGAffineTransform(translationX: previewX, y: 0)
        swipe.preview.isHidden = swipe.side == 0 || (swipe.neighbour == nil && !swipe.isNewTabCard)
        browser.pill.slideHost(progress: (swipe.neighbour != nil || swipe.isNewTabCard) ? shown / max(width, 1) : 0)
    }

    /// Sets up the neighbour on `side`: its live web view, its picture, or the New Tab card.
    private func prepare(side: Int) {
        guard let swipe, let browser else { return }
        clearPreview(swipe, browser: browser)
        swipe.side = side
        let neighbours = browser.session.tabs.neighbours(of: swipe.current.id)
        let id = side > 0 ? neighbours.next : neighbours.previous
        swipe.preview.transform = .identity
        swipe.preview.frame = browser.webContainer.frame
        if let id {
            let tab = browser.session.tabs.tab(id)
            swipe.neighbour = tab
            if tab.tier != .discarded {
                // Live: the real page, re-parented into the preview (no reload).
                browser.session.pool.attach(tab, to: swipe.preview)
                swipe.attachedLive = true
            } else {
                swipe.preview.addSubview(picture(for: id, size: swipe.preview.bounds.size))
            }
            browser.pill.beginHostSlide(to: tab.url)
        } else if side > 0 {
            swipe.isNewTabCard = true
            swipe.preview.addSubview(NewTabCard(frame: swipe.preview.bounds))
            browser.pill.beginHostSlide(to: nil)
        }
    }

    private func clearPreview(_ swipe: Swipe, browser: BrowserViewController) {
        if swipe.attachedLive, let neighbour = swipe.neighbour {
            browser.session.pool.detach(neighbour)
        }
        swipe.attachedLive = false
        swipe.neighbour = nil
        swipe.isNewTabCard = false
        swipe.preview.subviews.forEach { $0.removeFromSuperview() }
        browser.pill.endHostSlide()
    }

    /// A picture of a tab without a web view: the 2x snapshot or thumbnail the browser keeps for
    /// neighbours, pinned to the top; the background where there is none.
    private func picture(for id: TabID, size: CGSize) -> UIView {
        let view = UIView(frame: CGRect(origin: .zero, size: size))
        view.backgroundColor = Palette.background
        guard let browser else { return view }
        if let image = browser.tabsUI.previews[id] ?? browser.session.pool.thumbnails.cachedThumbnail(for: id),
           image.size.width > 0 {
            let imageView = UIImageView(image: image)
            imageView.frame = CGRect(x: 0, y: 0, width: size.width, height: size.width * image.size.height / image.size.width)
            view.addSubview(imageView)
        }
        return view
    }

    private func release(velocity: CGFloat) {
        guard let swipe, let browser else { return }
        let width = browser.webContainer.bounds.width
        // Where a flick would carry the page with UIScrollView's normal deceleration.
        let rate = UIScrollView.DecelerationRate.normal.rawValue
        let projected = swipe.offset + velocity / 1000 * rate / (1 - rate)
        var target: CGFloat = 0
        if swipe.neighbour != nil, swipe.side != 0, abs(projected) > width / 2,
           (projected < 0) == (swipe.side > 0) {
            target = -CGFloat(swipe.side) * width
        } else if swipe.isNewTabCard, -displayed(swipe.offset, swipe: swipe, width: width) >= FixedChoices.newTabSwipeThreshold,
                  velocity < FixedChoices.galleryFlickSpeed {
            target = -width
        }
        settle(to: target, velocity: velocity)
    }

    /// Springs the page to `target` (0 back, ±width onto the neighbour or card), from where it is.
    private func settle(to target: CGFloat, velocity: CGFloat) {
        guard let swipe, let browser else { return }
        let width = browser.webContainer.bounds.width
        swipe.target = target
        // The rubber band is undone first, so the spring runs in on-screen points.
        if swipe.neighbour == nil { swipe.offset = displayed(swipe.offset, swipe: swipe, width: width) }
        if swipe.isNewTabCard {
            // The card no longer banding: it follows the spring 1:1 from here.
            swipe.neighbour = nil
        }
        driver.jump(to: swipe.offset)
        let isCard = swipe.isNewTabCard
        driver.animate(to: target, velocity: velocity, in: browser.view, onFrame: { [weak self] value in
            guard let self, let swipe = self.swipe, let browser = self.browser else { return }
            swipe.offset = value
            if isCard {
                // 1:1 now: the card follows the spring, not the band.
                browser.webContainer.transform = CGAffineTransform(translationX: value, y: 0)
                swipe.preview.transform = CGAffineTransform(translationX: value + width, y: 0)
                browser.pill.slideHost(progress: value / max(width, 1))
            } else {
                self.apply(swipe, browser: browser)
            }
        }, completion: { [weak self] in
            self?.finish(at: target)
        })
    }

    private func finish(at target: CGFloat) {
        guard let swipe, let browser else { return }
        self.swipe = nil
        let signposter = Signposts.signposter
        if target != 0, let neighbour = swipe.neighbour {
            Haptic.selection.play()
            let cover = swipe.attachedLive ? nil : swipe.preview.subviews.first
            // The neighbour's web view moves from the preview to the page container (no reload).
            browser.completeTabSwipe(to: neighbour, cover: cover)
            reset(swipe, browser: browser, detachingNeighbour: false)
            signposter.endInterval(Signposts.tabSwipe, swipe.interval, "switched")
        } else if target != 0, swipe.isNewTabCard {
            Haptic.tap.play()
            reset(swipe, browser: browser, detachingNeighbour: false)
            browser.openNewTabFromSwipe()
            signposter.endInterval(Signposts.tabSwipe, swipe.interval, "newTab")
        } else {
            reset(swipe, browser: browser, detachingNeighbour: true)
            signposter.endInterval(Signposts.tabSwipe, swipe.interval, "stayed")
        }
    }

    private func reset(_ swipe: Swipe, browser: BrowserViewController, detachingNeighbour: Bool) {
        if detachingNeighbour {
            clearPreview(swipe, browser: browser)
        } else {
            browser.pill.endHostSlide()
        }
        browser.webContainer.transform = .identity
        swipe.preview.removeFromSuperview()
    }

    /// Next Tab / Previous Tab from the tabs menu: the same motion as a swipe, with no finger.
    func switchTab(side: Int) {
        guard swipe == nil, let browser, browser.currentTab != nil else { return }
        beginTabSwipe()
        mode = .none
        guard let swipe else { return }
        prepare(side: side)
        guard swipe.neighbour != nil else {
            finish(at: 0)
            return
        }
        apply(swipe, browser: browser)
        settle(to: -CGFloat(side) * browser.webContainer.bounds.width, velocity: 0)
    }

    /// Ends any swipe at once, where it would go back (the page is about to change under it).
    func cancel() {
        guard let swipe, let browser else { return }
        driver.stop()
        self.swipe = nil
        mode = .none
        reset(swipe, browser: browser, detachingNeighbour: true)
        Signposts.signposter.endInterval(Signposts.tabSwipe, swipe.interval, "cancelled")
    }
}

/// The card past the last tab: one symbol and one line, on the page background.
private final class NewTabCard: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = Palette.background
        let symbol = UIImageView(image: UIImage(systemName: "plus.circle", withConfiguration: UIImage.SymbolConfiguration(textStyle: .largeTitle)))
        symbol.tintColor = Palette.accent
        let label = UILabel()
        label.text = "New Tab"
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Palette.textSecondary
        let stack = UIStackView(arrangedSubviews: [symbol, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Spacing.s
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            // Toward the leading edge of the card, so it reads while only part of it shows.
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.xl),
        ])
        accessibilityIdentifier = "newTabCard"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
#endif
