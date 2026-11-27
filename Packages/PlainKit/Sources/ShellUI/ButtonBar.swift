#if canImport(UIKit)
import BrowserCore
import DesignSystem
import UIKit

/// The page's buttons: Back, Forward, Tabs (the gallery; a long press for the tab menu), Share and
/// More (the page menu).
///
/// Where the system has a vertical bar (the iPhone Duo's outer screen), they are the navigation
/// controller's toolbar items with `.verticalPreferred`, so the system places them in its side
/// column (docs/plan.md, section 6). Elsewhere they are this glass bar under the URL pill, which
/// collapses with the pill as the page scrolls. A system toolbar would change the page's safe
/// area as it hides, which relayouts the page; this bar moves by transform only.
enum PageButton: CaseIterable {
    case back, forward, tabs, share, more

    var symbol: String {
        switch self {
        case .back: "chevron.backward"
        case .forward: "chevron.forward"
        case .tabs: "square.on.square"
        case .share: "square.and.arrow.up"
        case .more: "line.3.horizontal.circle"
        }
    }

    var title: String {
        switch self {
        case .back: "Back"
        case .forward: "Forward"
        case .tabs: "Tabs"
        case .share: "Share"
        case .more: "More"
        }
    }

    var identifier: String {
        switch self {
        case .back: "back"
        case .forward: "forward"
        case .tabs: "tabs"
        case .share: "share"
        case .more: "more"
        }
    }
}

/// The glass button bar under the pill on iPhones without a vertical bar.
final class ButtonBar: UIView {
    private let glass = Glass.makeView(shape: .capsule)
    /// The soft paper glow under the glass shapes, so the symbols read over any page.
    private let scrim = ChromeScrim()
    private(set) var stack = UIStackView()
    private(set) var buttons: [PageButton: UIButton] = [:]
    /// Beside the pill on the start screen: only the buttons that show, each a round glass slot.
    private(set) var isBesidePill = false
    private var stackLeading: NSLayoutConstraint!
    private var stackTrailing: NSLayoutConstraint!
    /// The bar's width while beside the pill: one `ChromeGeometry.barHeight` per button.
    private(set) var besideWidth: NSLayoutConstraint!

    /// The top bar's shape (a wide screen): Back and Forward in a capsule at the row's leading
    /// end, Tabs, Share and More in one at its trailing end, the pill between them, where Safari
    /// has them on the Duo's inner screen and on iPad. The leading capsule holds only what shows
    /// and grows away from Back (Forward comes in to its right), so Back never moves; the trailing
    /// capsule keeps every slot. The pill keeps its place either way.
    private(set) var isSplit = false
    private let trailingGlass = Glass.makeView(shape: .capsule)
    private let trailingStack = UIStackView()
    private var glassTrailing: NSLayoutConstraint!
    private var splitConstraints: [NSLayoutConstraint] = []
    private var leadingWidth: NSLayoutConstraint?
    /// The buttons in the trailing capsule of the split shape.
    static let trailingKinds: [PageButton] = [.tabs, .share, .more]
    /// The width of each capsule of the split shape: one 44 pt slot per button.
    static var splitLeadingWidth: CGFloat { slot * CGFloat(PageButton.allCases.count - trailingKinds.count) }
    static var splitTrailingWidth: CGFloat { slot * CGFloat(trailingKinds.count) }
    private static var slot: CGFloat { CGFloat(FixedChoices.topBarHeight) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrim.frame = bounds
        scrim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(scrim)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(stack)
        for kind in PageButton.allCases {
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: kind.symbol)
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 19, weight: .medium)
            let button = UIButton(configuration: configuration)
            button.accessibilityLabel = kind.title
            button.accessibilityIdentifier = kind.identifier
            button.isEnabled = false
            buttons[kind] = button
            stack.addArrangedSubview(button)
        }
        // A long press shows a button large at the biggest text sizes, as a toolbar does.
        addInteraction(UILargeContentViewerInteraction())
        stackLeading = stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: Spacing.s)
        stackTrailing = stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -Spacing.s)
        besideWidth = widthAnchor.constraint(equalToConstant: ChromeGeometry.barHeight)
        glassTrailing = glass.trailingAnchor.constraint(equalTo: trailingAnchor)
        NSLayoutConstraint.activate([
            stackLeading, stackTrailing,
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassTrailing,
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
        ])

        // The split shape's trailing capsule: built once, in the view only while split.
        trailingStack.axis = .horizontal
        trailingStack.distribution = .fillEqually
        trailingStack.translatesAutoresizingMaskIntoConstraints = false
        trailingGlass.translatesAutoresizingMaskIntoConstraints = false
        trailingGlass.contentView.addSubview(trailingStack)
        trailingStack.topAnchor.constraint(equalTo: trailingGlass.contentView.topAnchor).isActive = true
        trailingStack.bottomAnchor.constraint(equalTo: trailingGlass.contentView.bottomAnchor).isActive = true
        trailingStack.leadingAnchor.constraint(equalTo: trailingGlass.contentView.leadingAnchor).isActive = true
        trailingStack.trailingAnchor.constraint(equalTo: trailingGlass.contentView.trailingAnchor).isActive = true
    }

    /// Between the bar under the pill (or beside it) and the top bar's two capsules. The buttons
    /// move between the capsules and keep their actions and menus. The caller owns the constraints
    /// that place the bar: in the split shape it spans the row, and the pill sits between the
    /// capsules. Call inside the layout's animation.
    func setSplit(_ split: Bool) {
        guard split != isSplit else { return }
        if split { setBesidePill(false) }
        isSplit = split
        if split {
            addSubview(trailingGlass)
            for kind in Self.trailingKinds {
                let button = button(kind)
                stack.removeArrangedSubview(button)
                trailingStack.addArrangedSubview(button)
            }
            glassTrailing.isActive = false
            stackLeading.constant = 0
            stackTrailing.constant = 0
            let leading = glass.widthAnchor.constraint(equalToConstant: Self.splitLeadingWidth)
            leadingWidth = leading
            splitConstraints = [
                leading,
                trailingGlass.topAnchor.constraint(equalTo: topAnchor),
                trailingGlass.bottomAnchor.constraint(equalTo: bottomAnchor),
                trailingGlass.trailingAnchor.constraint(equalTo: trailingAnchor),
                trailingGlass.widthAnchor.constraint(equalToConstant: Self.splitTrailingWidth),
            ]
            NSLayoutConstraint.activate(splitConstraints)
        } else {
            NSLayoutConstraint.deactivate(splitConstraints)
            splitConstraints = []
            leadingWidth = nil
            for case let button as UIButton in stack.arrangedSubviews {
                let removed = isBesidePill && !button.isUserInteractionEnabled
                if button.isHidden != removed { button.isHidden = removed }
            }
            for kind in Self.trailingKinds {
                let button = button(kind)
                trailingStack.removeArrangedSubview(button)
                stack.addArrangedSubview(button)
            }
            trailingGlass.removeFromSuperview()
            glassTrailing.isActive = true
            stackLeading.constant = Spacing.s
            stackTrailing.constant = -Spacing.s
        }
        updateCapsules()
    }

    /// A capsule of the split shape with no button showing (Back and Forward on the start screen)
    /// leaves no empty glass behind.
    private func updateCapsules() {
        let leadingShown = stack.arrangedSubviews.filter { $0.isUserInteractionEnabled }
        if isSplit {
            // Back and Forward: only what shows, packed from Back.
            for view in stack.arrangedSubviews where view.isHidden == view.isUserInteractionEnabled {
                view.isHidden = !view.isUserInteractionEnabled
            }
            let width = Self.slot * CGFloat(max(1, leadingShown.count))
            if leadingWidth?.constant != width { leadingWidth?.constant = width }
        }
        let showsLeading = !isSplit || !leadingShown.isEmpty
        if glass.isHidden == showsLeading { glass.isHidden = !showsLeading }
        let showsTrailing = trailingStack.arrangedSubviews.contains { $0.isUserInteractionEnabled }
        if trailingGlass.isHidden == showsTrailing { trailingGlass.isHidden = !showsTrailing }
        setNeedsLayout()
    }

    /// In the split shape only the two capsules take touches: the pill sits in the gap.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isSplit else { return super.point(inside: point, with: event) }
        return glass.frame.contains(point) || trailingGlass.frame.contains(point)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func button(_ kind: PageButton) -> UIButton { buttons[kind]! }

    /// Shows, dims or hides a button in place (docs/state-rules.md, principle 5). A hidden button
    /// keeps its slot, so the others never move under the thumb, and leaves the accessibility tree.
    func setVisibility(_ visibility: ControlVisibility, for kind: PageButton) {
        let button = button(kind)
        button.isEnabled = visibility.isEnabled
        let alpha: CGFloat = visibility.isVisible ? 1 : 0
        button.isUserInteractionEnabled = visibility.isVisible
        button.accessibilityElementsHidden = !visibility.isVisible
        button.isAccessibilityElement = visibility.isVisible
        // Beside the pill a hidden button gives up its slot: the bar is only what it shows. So
        // does Back or Forward in the top bar's leading capsule.
        let packs = isBesidePill || (isSplit && button.superview === stack)
        let removed = packs && !visibility.isVisible
        if button.isHidden != removed { button.isHidden = removed }
        if isBesidePill { updateBesideWidth() }
        if isSplit { updateCapsules() }
        guard button.alpha != alpha else { return }
        if window == nil || UIView.inheritedAnimationDuration > 0 {
            button.alpha = alpha
        } else {
            Motion.animate(Motion.quick) { button.alpha = alpha }
        }
    }

    /// Between the full-width bar (a page) and the round glass button beside the pill (the start
    /// screen, `ControlRules.barBesidePill`). The caller owns the constraints that place the bar;
    /// this sets its own width and packs the buttons that show. Call inside the layout's animation.
    func setBesidePill(_ beside: Bool) {
        guard beside != isBesidePill, !(beside && isSplit) else { return }
        isBesidePill = beside
        for button in buttons.values {
            let removed = beside && !button.isUserInteractionEnabled
            if button.isHidden != removed { button.isHidden = removed }
        }
        let inset = beside ? 0 : Spacing.s
        stackLeading.constant = inset
        stackTrailing.constant = -inset
        updateBesideWidth()
        besideWidth.isActive = beside
    }

    private func updateBesideWidth() {
        let shown = buttons.values.count { !$0.isHidden }
        let width = ChromeGeometry.barHeight * CGFloat(max(1, shown))
        if besideWidth.constant != width { besideWidth.constant = width }
    }

    /// What VoiceOver reads as a button's value (the tabs slot: how many tabs are open).
    func setAccessibilityValue(_ value: String?, for kind: PageButton) {
        button(kind).accessibilityValue = value
    }

    /// The glass tint: Paper, or the quiet private tint while a private tab is on screen.
    func setPrivate(_ isPrivate: Bool) {
        let effect = UIGlassEffect(style: .regular)
        effect.tintColor = isPrivate ? Palette.privateGlassTint : Palette.glassTint
        glass.effect = effect
        trailingGlass.effect = effect
        scrim.isPrivate = isPrivate
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateScrim()
    }

    /// The glow follows the glass shapes that show: one capsule, the round slot beside the pill,
    /// or the split shape's two.
    private func updateScrim() {
        let shown = [glass, trailingGlass].filter { $0.superview === self && !$0.isHidden }
        scrim.shapes = shown.map(\.frame)
    }
}

/// The pull-to-refresh indicator: an arrow that turns as the page is pulled and fills with the
/// accent once the pull is far enough to reload on release.
final class PullIndicator: UIView {
    static let size: CGFloat = 36
    private let symbol = UIImageView(image: UIImage(systemName: "arrow.clockwise"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = Palette.surface
        layer.cornerRadius = Self.size / 2
        layer.cornerCurve = .continuous
        symbol.tintColor = Palette.textSecondary
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        symbol.translatesAutoresizingMaskIntoConstraints = false
        addSubview(symbol)
        NSLayoutConstraint.activate([
            symbol.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        alpha = 0
        accessibilityIdentifier = "pullToRefresh"
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Follows a pull of `distance` points; `threshold` is where it arms.
    func follow(pull distance: CGFloat, threshold: CGFloat) {
        let fraction = min(max(distance / threshold, 0), 1)
        alpha = fraction
        // Halfway down the pulled gap, never above its resting spot.
        let drop = max(0, distance / 2 - Self.size / 2)
        transform = CGAffineTransform(translationX: 0, y: drop).rotated(by: fraction * .pi)
    }

    func setArmed(_ armed: Bool) {
        Motion.animate(Motion.quick, changes: {
            self.symbol.tintColor = armed ? .white : Palette.textSecondary
            self.backgroundColor = armed ? Palette.accent : Palette.surface
        })
        accessibilityValue = armed ? "armed" : nil
    }

    func hide() {
        Motion.animate(Motion.quick, changes: {
            self.alpha = 0
        }) {
            self.symbol.tintColor = Palette.textSecondary
            self.backgroundColor = Palette.surface
        }
    }
}
#endif
