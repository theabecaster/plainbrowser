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
    /// Lands once the page is visibly at rest (`Signposts.visualSettle`), so the hand-off to the new
    /// tab, and the page taking touches, does not wait out the spring's sub-point tail.
    private let driver = SpringDriver(spring: Motion.tabSwitchSpring, restDistance: CGFloat(Signposts.visualSettle))
    private var swipe: Swipe?
    private var galleryTransition: TabGalleryTransition?
    /// The swipe up's commit line (`FixedChoices.gallerySwipeCommit`), both ways.
    private var galleryLatch = ThresholdLatch(
        threshold: CGFloat(FixedChoices.gallerySwipeCommit), hysteresis: FixedChoices.hapticProgressHysteresis
    )
    private var mode = Mode.none
    private var startOffset: CGFloat = 0
    private var recognizers: [UIPanGestureRecognizer] = []

    private enum Mode { case none, tabs, gallery, bump }
    /// A gesture with nothing to do: the page follows the finger a little on this axis, rubber-
    /// banded, and springs back with the "nothing there" haptic (state rules, principle 4).
    private var bumpVertical = false
    /// The rules when the finger came down: one read of the tab list per gesture, not per frame.
    private var gestureRules: ControlRules?

    /// One swipe from a tab toward a neighbour, kept while the page settles so a finger can grab it.
    private final class Swipe {
        let current: Tab
        let interval: OSSignpostIntervalState
        /// From the finger lifting until the page settles (`tab.swipeSettle`): the part the app owns.
        var settleInterval: OSSignpostIntervalState?
        /// 1 toward the next tab (finger moving left), -1 toward the previous one, 0 not yet.
        var side = 0
        var neighbour: Tab?
        var isNewTabCard = false
        /// The neighbour's web view was attached into `preview` (else a picture or the card).
        var attachedLive = false
        let preview = UIView()
        var offset: CGFloat = 0
        /// The commit line (half the width toward a neighbour, `newTabSwipeThreshold` for the
        /// New Tab card): `.threshold` crossing in, `.selection` crossing back (docs/ui-reference.md,
        /// "Haptics", rules 3 and 4).
        var latch = ThresholdLatch(threshold: .infinity, hysteresis: FixedChoices.hapticThresholdHysteresis)
        /// The finger left and the page is settling toward `target`.
        var target: CGFloat?

        init(current: Tab) {
            self.current = current
            // Exclusive: one swipe at a time, and XCTOSSignpostMetric (perf gate) matches it.
            interval = Signposts.signposter.beginInterval(Signposts.tabSwipe)
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
            // Tab switching belongs to the pill; the glass bar takes the swipe up only.
            return view === browser.pill
        }
        // Up only, and not while a sideways swipe is settling. A top bar (the Duo's inner screen)
        // has no swipe up: it would pull away from the page, and Tabs and the strip are at hand.
        return velocity.y < 0 && swipe == nil && !browser.chromeOnTop
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard let browser, let view = browser.view else { return }
        let translation = pan.translation(in: view)
        let velocity = pan.velocity(in: view)
        switch pan.state {
        case .began:
            // One condition per gesture, from the state rules: the swipe up opens the gallery only
            // with another tab to switch to, a sideways swipe moves only with a tab on screen.
            let rules = browser.currentRules()
            gestureRules = rules
            if abs(velocity.x) > abs(velocity.y) || swipe != nil {
                if rules.barSwipeSwitchesTabs || swipe != nil {
                    beginTabSwipe()
                } else {
                    beginBump(vertical: false)
                }
            } else if rules.swipeUpOpensGallery {
                mode = .gallery
                galleryLatch.reset()
                Haptic.threshold.prepare(in: view)
                galleryTransition = browser.presentGallery(source: "swipe", interactive: true)
            } else {
                beginBump(vertical: true)
            }
        case .changed:
            switch mode {
            case .tabs: track(startOffset + translation.x)
            case .gallery: trackGallery(translation)
            case .bump: trackBump(translation)
            case .none: break
            }
        case .ended, .cancelled, .failed:
            switch mode {
            case .tabs: release(velocity: pan.state == .ended ? velocity.x : 0)
            case .gallery: releaseGallery(velocity: pan.state == .ended ? velocity : .zero)
            case .bump: releaseBump()
            case .none: break
            }
            mode = .none
            gestureRules = nil
        default:
            break
        }
    }

    // MARK: Swipe up: the gallery

    /// The page follows the finger as a card, like the swipe up into the app switcher; the
    /// transition decides the shape and, on release, where it lands.
    private func trackGallery(_ translation: CGPoint) {
        guard let browser, let transition = galleryTransition else { return }
        let progress = transition.track(translation: translation)
        browser.setChromeGalleryProgress(progress)
        // After the frame is applied: the haptic lands with the page reaching the commit size.
        // Under Reduce Motion nothing moves, and this is the only cue that release will open it.
        galleryLatch.update(progress)?.play(in: browser.view)
    }

    private func releaseGallery(velocity: CGPoint) {
        guard let browser, let transition = galleryTransition else { return }
        galleryTransition = nil
        let opens = transition.release(velocity: velocity) == .gallery
        // Already announced while the finger was down: silent. A flick that opened it without
        // ever arming commits with a tap as the spring starts; armed and flicked back, a tick.
        if opens != galleryLatch.isArmed { (opens ? Haptic.tap : Haptic.selection).play(in: browser.view) }
        galleryLatch.reset()
        browser.setChromeHiddenForGallery(opens, animated: true)
    }

    // MARK: Nothing there: the bump

    private func beginBump(vertical: Bool) {
        mode = .bump
        bumpVertical = vertical
        Haptic.nothingThere.prepare(in: browser?.view)
    }

    /// The page lifts (or slides) a few points with heavy resistance, never far.
    private func trackBump(_ translation: CGPoint) {
        guard let browser else { return }
        let travel = bumpVertical ? min(translation.y, 0) : translation.x
        let limit: CGFloat = 24
        let banded = limit * (1 - 1 / (abs(travel) / limit * 0.5 + 1)) * (travel < 0 ? -1 : 1)
        browser.webContainer.transform = bumpVertical
            ? CGAffineTransform(translationX: 0, y: banded)
            : CGAffineTransform(translationX: banded, y: 0)
    }

    private func releaseBump() {
        guard let browser else { return }
        Haptic.nothingThere.play(in: browser.view)
        Signposts.signposter.emitEvent(Signposts.tabSwipeEnd, "bump")
        let container = browser.webContainer
        Motion.animate(Motion.tabSwitch) { container.transform = .identity }
    }

    // MARK: Sideways: tabs

    private func beginTabSwipe() {
        mode = .tabs
        if let swipe {
            // A finger on a settling page takes it from where it is on screen. With nothing beside
            // it (the New Tab card, or nothing) the page is rubber-banded while a finger holds it,
            // so the spot on screen is turned back into the finger travel that shows it there.
            let shown = driver.stop()
            if swipe.neighbour == nil, let browser {
                startOffset = travel(showing: shown, width: browser.webContainer.bounds.width)
            } else {
                startOffset = shown
            }
            swipe.target = nil
            swipe.offset = startOffset
            // The latch takes the state the page is in, silently: a grab past the line plays no
            // threshold of its own, and a release from here judges against where it was grabbed.
            if let browser, let value = latchValue(swipe, browser: browser) { swipe.latch.sync(value) }
            return
        }
        guard let browser, let current = browser.currentTab else {
            mode = .none
            return
        }
        startOffset = 0
        let swipe = Swipe(current: current)
        swipe.preview.clipsToBounds = true
        Paper.apply(to: swipe.preview)
        swipe.preview.bounds = browser.webContainer.bounds
        swipe.preview.center = browser.webContainer.center
        // Hidden until the finger picks a side (`apply`): over the page and untransformed, the
        // empty preview would blank it for the frame or two before the first move arrives.
        swipe.preview.isHidden = true
        browser.pageClip.insertSubview(swipe.preview, aboveSubview: browser.webContainer)
        self.swipe = swipe
        Haptic.threshold.prepare(in: browser.view)
        Haptic.selection.prepare(in: browser.view)
    }

    /// Moves the page to `offset` (negative toward the next tab), preparing the neighbour on the
    /// side the finger went.
    private func track(_ offset: CGFloat) {
        guard let swipe, let browser else { return }
        let side = offset < 0 ? 1 : (offset > 0 ? -1 : swipe.side)
        if side != swipe.side { prepare(side: side) }
        swipe.offset = offset
        apply(swipe, browser: browser)
        // The threshold haptics, from what is on screen after the transform (never the raw
        // finger): `.threshold` crossing into the commit zone, `.selection` crossing back out.
        guard let value = latchValue(swipe, browser: browser) else { return swipe.latch.reset() }
        swipe.latch.update(value)?.play(in: browser.view)
    }

    /// How far into its commit zone the page is on screen, with the latch's line set for what is
    /// beside it: half the width toward a neighbour, `newTabSwipeThreshold` for the New Tab card.
    /// nil with nothing beside it.
    private func latchValue(_ swipe: Swipe, browser: BrowserViewController) -> CGFloat? {
        let width = browser.webContainer.bounds.width
        let shown = displayed(swipe.offset, swipe: swipe, width: width)
        if swipe.neighbour != nil {
            swipe.latch.threshold = width / 2
            return abs(shown)
        }
        if swipe.isNewTabCard {
            swipe.latch.threshold = CGFloat(FixedChoices.newTabSwipeThreshold)
            return -shown
        }
        return nil
    }

    /// The finger travel that `displayed` shows at `shown` where nothing is beside the page: the
    /// rubber band's inverse.
    private func travel(showing shown: CGFloat, width: CGFloat) -> CGFloat {
        let width = max(width, 1)
        let band = min(abs(shown) / width, 0.99)
        return (shown < 0 ? -1 : 1) * band / (1 - band) * width / 0.55
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
        // From bounds and center: the page container is already moved by a transform here.
        swipe.preview.transform = .identity
        swipe.preview.bounds = browser.webContainer.bounds
        swipe.preview.center = browser.webContainer.center
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
        } else if side > 0, (gestureRules ?? browser.currentRules()).offersNewTabCard {
            // Past the last tab, from a page only: past an empty tab it would make a second one.
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
        Paper.apply(to: view)
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
        // One haptic per outcome, as the spring starts (docs/ui-reference.md, "Haptics", rule 3):
        // armed and committing is already announced; a flick that commits without arming ticks
        // (a new tab: taps); armed and springing back crosses back out with a tick.
        let commits = target != 0
        if commits != swipe.latch.isArmed {
            (commits && swipe.isNewTabCard ? Haptic.tap : Haptic.selection).play(in: browser.view)
        } else if !commits, swipe.side != 0, swipe.neighbour == nil, !swipe.isNewTabCard {
            // Rubber-banded against nothing: the "nothing there" bump as the band springs back.
            Haptic.nothingThere.play(in: browser.view)
        }
        swipe.latch.reset()
        swipe.settleInterval = Signposts.signposter.beginInterval(Signposts.tabSwipeSettle)
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
            // No haptic here: the release played it as the spring started (or the menu's Next
            // Tab, whose result is on screen, plays none).
            let cover = swipe.attachedLive ? nil : swipe.preview.subviews.first
            // The neighbour's web view moves from the preview to the page container (no reload).
            let handoff = signposter.beginInterval(Signposts.tabSwipeHandoff)
            browser.completeTabSwipe(to: neighbour, cover: cover)
            reset(swipe, browser: browser, detachingNeighbour: false)
            signposter.endInterval(Signposts.tabSwipeHandoff, handoff)
            signposter.endInterval(Signposts.tabSwipe, swipe.interval)
            if let settle = swipe.settleInterval { signposter.endInterval(Signposts.tabSwipeSettle, settle) }
            signposter.emitEvent(Signposts.tabSwipeEnd, "switched")
        } else if target != 0, swipe.isNewTabCard {
            reset(swipe, browser: browser, detachingNeighbour: false)
            browser.openNewTabFromSwipe()
            signposter.endInterval(Signposts.tabSwipe, swipe.interval)
            if let settle = swipe.settleInterval { signposter.endInterval(Signposts.tabSwipeSettle, settle) }
            signposter.emitEvent(Signposts.tabSwipeEnd, "newTab")
        } else {
            // Against nothing, the release already played the "nothing there" bump.
            reset(swipe, browser: browser, detachingNeighbour: true)
            signposter.endInterval(Signposts.tabSwipe, swipe.interval)
            if let settle = swipe.settleInterval { signposter.endInterval(Signposts.tabSwipeSettle, settle) }
            signposter.emitEvent(Signposts.tabSwipeEnd, "stayed")
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
        Signposts.signposter.endInterval(Signposts.tabSwipe, swipe.interval)
        if let settle = swipe.settleInterval { Signposts.signposter.endInterval(Signposts.tabSwipeSettle, settle) }
        Signposts.signposter.emitEvent(Signposts.tabSwipeEnd, "cancelled")
    }
}

/// The card past the last tab: one symbol and one line, on the page background.
private final class NewTabCard: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        Paper.apply(to: self)
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
