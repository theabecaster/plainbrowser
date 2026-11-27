#if canImport(UIKit)
import DesignSystem
import UIKit

/// One page pane: a clip view holding the container the pool attaches a tab's web view to, and
/// the focus ring a split draws around the focused pane.
final class PaneSlot: UIViewController {
    /// Clips the page and the bar swipe's neighbour to the pane.
    let clip = UIView()
    /// Where the pool puts the tab's web view (`WebViewPool.attach(_:to:)`).
    let container = UIView()
    /// The focused pane's ring in a split (docs/research/design-audit.md: one focused pane).
    private let ring = UIView()
    /// A touch went down in the pane: it becomes the focused one. `onControl`: it landed on
    /// something that handles it itself (a button, the spinnable mark).
    var onTouch: (@MainActor @Sendable (_ onControl: Bool) -> Void)?

    /// Splits draw panes as rounded cards with a gutter; a single pane fills its area.
    private var isSplit = false
    private var clipInsets: [NSLayoutConstraint] = []
    private var ringTop: NSLayoutConstraint!

    override func loadView() {
        let root = TouchReportingView()
        root.onTouchDown = { [weak self] onControl in self?.onTouch?(onControl) }
        root.backgroundColor = .clear
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        clip.clipsToBounds = true
        clip.layer.cornerCurve = .continuous
        container.clipsToBounds = true
        for subview in [clip, container, ring] {
            subview.translatesAutoresizingMaskIntoConstraints = false
        }
        view.addSubview(clip)
        clip.addSubview(container)
        view.addSubview(ring)
        ring.isUserInteractionEnabled = false
        ring.layer.cornerCurve = .continuous
        ring.layer.borderWidth = PaneMetrics.ringWidth
        ring.alpha = 0
        clipInsets = [
            clip.topAnchor.constraint(equalTo: view.topAnchor),
            clip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
        ]
        ringTop = ring.topAnchor.constraint(equalTo: clip.topAnchor)
        NSLayoutConstraint.activate(clipInsets + [ringTop,
            container.topAnchor.constraint(equalTo: clip.topAnchor),
            container.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            ring.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            ring.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            ring.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
        ])
        resolveRingColor()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (slot: PaneSlot, _) in slot.resolveRingColor() }
    }

    /// The ring starts under a top bar (the Duo's inner screen): the bar is both panes', so the
    /// ring marks only the page it acts on.
    func setRingTopInset(_ inset: CGFloat) {
        loadViewIfNeeded()
        if ringTop.constant != inset { ringTop.constant = inset }
    }

    private func resolveRingColor() {
        ring.layer.borderColor = Palette.accentOnGlass.resolvedColor(with: traitCollection).cgColor
    }

    /// Split look (gutter, rounded corners, ring on the focused pane) or the plain full pane.
    /// `edges` says which sides face the other pane, so only those get the gutter.
    func setSplit(_ split: Bool, focused: Bool, gutterOnLeading: Bool, gutterOnTrailing: Bool) {
        loadViewIfNeeded()
        isSplit = split
        let half = split ? PaneMetrics.gutter / 2 : 0
        clipInsets[1].constant = gutterOnLeading ? half : 0
        clipInsets[2].constant = gutterOnTrailing ? half : 0
        let radius = split ? Radius.large : 0
        clip.layer.cornerRadius = radius
        ring.layer.cornerRadius = radius
        ring.alpha = split && focused ? 1 : 0
    }
}

/// The split's look. Fixed visual values; the split rules themselves live in `FixedChoices`.
enum PaneMetrics {
    /// Between two panes, so the focus ring and the rounded corners read as two pages.
    static let gutter: CGFloat = 6
    /// The focused pane's ring.
    static let ringWidth: CGFloat = 2
}

/// A view that reports each touch that lands in it (or in its subviews) before the touch is
/// delivered, without taking part in gesture recognition: the page keeps every gesture.
final class TouchReportingView: UIView {
    /// `onControl`: the touch landed on a control or a view with its own gestures (the start
    /// screen's buttons, the spinnable mark), which handles it.
    var onTouchDown: (@MainActor @Sendable (_ onControl: Bool) -> Void)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if let hit, event?.type == .touches, let onTouchDown {
            let onControl = Self.handlesTouches(hit, below: self)
            // Hit testing may run more than once per touch, and must not change the hierarchy:
            // report after it.
            DispatchQueue.main.async { onTouchDown(onControl) }
        }
        return hit
    }

    /// Whether `view`, or a view between it and `root`, is a control or has gestures of its own.
    private static func handlesTouches(_ view: UIView, below root: UIView) -> Bool {
        var current: UIView? = view
        while let candidate = current, candidate !== root {
            if candidate is UIControl || candidate.gestureRecognizers?.contains(where: \.isEnabled) == true { return true }
            current = candidate.superview
        }
        return false
    }
}

/// The page panes. A split's two panes live in one `UIArrangementViewController` (`.split`,
/// horizontal axis), which places them on either side of a partly folded crease. A lone pane lives
/// beside it in a plain container that fills the area: the arrangement never lets a view cross an
/// active fold (it shrinks it to one side, or hides it), and a single page keeps spanning the
/// screen in book pose (docs/plan.md, section 6).
///
/// Slot `i` always shows the window's pane `i`. Where only one pane can show (the outer screen,
/// inner portrait), the focused pane's slot shows alone, so its web view keeps its parent (the
/// slot's container) through a fold; only the slot moves between the two hosts.
final class PanesController {
    let arrangement = UIArrangementViewController()
    /// Holds a lone pane, filling `view`.
    private let single = UIViewController()
    let slots = [PaneSlot(), PaneSlot()]
    /// Which slots are on screen, in arrangement order.
    private(set) var shown: [Int] = []
    private var primaryWidth: CGFloat?
    /// The panes' area, laid out by the browser.
    let view = UIView()

    func install(in parent: UIViewController) {
        view.backgroundColor = .clear
        for host in [arrangement, single] {
            parent.addChild(host)
            host.view.frame = view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.view.backgroundColor = .clear
            view.addSubview(host.view)
            host.didMove(toParent: parent)
        }
    }

    /// Shows `slotsToShow` (one or two slot indices), a split's primary `primaryWidth` wide (nil:
    /// the arrangement decides, beside the fold when it is active). Does nothing when nothing
    /// changed.
    func show(_ slotsToShow: [Int], primaryWidth: CGFloat?) {
        guard slotsToShow != shown || (slotsToShow.count == 2 && primaryWidth != self.primaryWidth) else { return }
        let previous = shown
        shown = slotsToShow
        self.primaryWidth = primaryWidth

        guard slotsToShow.count == 2 else {
            // Alone: out of the arrangement, into the full-size container.
            if previous.count == 2 {
                arrangement.setViewController(nil, for: .secondary)
                arrangement.setViewController(nil, for: .primary)
            }
            let slot = slots[slotsToShow[0]]
            if slot.parent !== single {
                for other in slots where other.parent === single { remove(other) }
                single.addChild(slot)
                slot.view.frame = single.view.bounds
                slot.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                single.view.addSubview(slot.view)
                slot.didMove(toParent: single)
            }
            arrangement.view.isHidden = true
            single.view.isHidden = false
            return
        }

        var arrangementValue = UISplitArrangement.split.axes(.horizontal)
        var primary = arrangementValue.defaultViewProperties
        var secondary = arrangementValue.defaultViewProperties
        if let primaryWidth {
            primary.width.minimum = .absolute(primaryWidth)
            primary.width.preferred = .absolute(primaryWidth)
            primary.width.maximum = .absolute(primaryWidth)
        } else {
            primary.width.preferred = .fractional(0.5)
            secondary.width.preferred = .fractional(0.5)
        }
        arrangementValue.setViewProperties(primary, for: .primary)
        arrangementValue.setViewProperties(secondary, for: .secondary)
        if previous != slotsToShow {
            for slot in slots where slot.parent === single { remove(slot) }
            arrangement.setViewController(nil, for: .secondary)
            arrangement.setViewController(slots[slotsToShow[0]], for: .primary)
            arrangement.setViewController(slots[slotsToShow[1]], for: .secondary)
        }
        arrangement.updateArrangement(arrangementValue, animated: false)
        arrangement.view.isHidden = false
        single.view.isHidden = true
    }

    private func remove(_ slot: PaneSlot) {
        slot.willMove(toParent: nil)
        slot.view.removeFromSuperview()
        slot.removeFromParent()
    }
}
#endif
