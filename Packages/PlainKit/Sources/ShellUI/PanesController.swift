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
    /// A touch went down in the pane: it becomes the focused one.
    var onTouch: (@MainActor @Sendable () -> Void)?

    /// Splits draw panes as rounded cards with a gutter; a single pane fills its area.
    private var isSplit = false
    private var clipInsets: [NSLayoutConstraint] = []

    override func loadView() {
        let root = TouchReportingView()
        root.onTouchDown = { [weak self] in self?.onTouch?() }
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
        NSLayoutConstraint.activate(clipInsets + [
            container.topAnchor.constraint(equalTo: clip.topAnchor),
            container.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            ring.topAnchor.constraint(equalTo: clip.topAnchor),
            ring.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            ring.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            ring.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
        ])
        resolveRingColor()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (slot: PaneSlot, _) in slot.resolveRingColor() }
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
    var onTouchDown: (@MainActor @Sendable () -> Void)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit != nil, event?.type == .touches, let onTouchDown {
            // Hit testing may run more than once per touch, and must not change the hierarchy:
            // report after it.
            DispatchQueue.main.async(execute: onTouchDown)
        }
        return hit
    }
}

/// The page panes, in one `UIArrangementViewController` (`.split`, horizontal axis): one pane, or
/// two side by side in a split. Slot `i` always shows the window's pane `i`; when only one pane
/// can show (the outer screen), the focused pane's slot takes the primary place on its own, so its
/// web view never changes parent through a fold.
final class PanesController {
    let arrangement = UIArrangementViewController()
    let slots = [PaneSlot(), PaneSlot()]
    /// Which slots are on screen, in arrangement order.
    private(set) var shown: [Int] = []
    private var primaryWidth: CGFloat?

    /// The arrangement's view, laid out by the browser.
    var view: UIView { arrangement.view }

    func install(in parent: UIViewController) {
        parent.addChild(arrangement)
        arrangement.view.translatesAutoresizingMaskIntoConstraints = false
        arrangement.view.backgroundColor = .clear
        arrangement.didMove(toParent: parent)
    }

    /// Shows `slotsToShow` (one or two slot indices) with the first `primaryWidth` wide (nil: an
    /// even split). Does nothing when nothing changed.
    func show(_ slotsToShow: [Int], primaryWidth: CGFloat?) {
        guard slotsToShow != shown || (slotsToShow.count == 2 && primaryWidth != self.primaryWidth) else { return }
        let previous = shown
        shown = slotsToShow
        self.primaryWidth = primaryWidth
        var arrangementValue = UISplitArrangement.split.axes(.horizontal)
        if slotsToShow.count == 2 {
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
        } else {
            // Alone, the primary pane takes the whole width (by default it keeps half).
            var primary = arrangementValue.defaultViewProperties
            primary.width.preferred = .fractional(1)
            arrangementValue.setViewProperties(primary, for: .primary)
        }
        // Only places whose slot changes are touched, so a pane that stays keeps its view in the
        // window (its web view never leaves it).
        let newSecondary = slotsToShow.count == 2 ? slotsToShow[1] : nil
        let oldSecondary = previous.count == 2 ? previous[1] : nil
        if previous.first != slotsToShow[0] || oldSecondary != newSecondary {
            if oldSecondary != newSecondary { arrangement.setViewController(nil, for: .secondary) }
            if previous.first != slotsToShow[0] {
                arrangement.setViewController(slots[slotsToShow[0]], for: .primary)
            }
            if let newSecondary, oldSecondary != newSecondary {
                arrangement.setViewController(slots[newSecondary], for: .secondary)
            }
        }
        arrangement.updateArrangement(arrangementValue, animated: false)
    }
}
#endif
