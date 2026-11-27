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
    private(set) var stack = UIStackView()
    private(set) var buttons: [PageButton: UIButton] = [:]
    /// Beside the pill on the start screen: only the buttons that show, each a round glass slot.
    private(set) var isBesidePill = false
    private var stackLeading: NSLayoutConstraint!
    private var stackTrailing: NSLayoutConstraint!
    /// The bar's width while beside the pill: one `ChromeGeometry.barHeight` per button.
    private(set) var besideWidth: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
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
        NSLayoutConstraint.activate([
            stackLeading, stackTrailing,
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
        ])
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
        // Beside the pill a hidden button gives up its slot: the bar is only what it shows.
        let removed = isBesidePill && !visibility.isVisible
        if button.isHidden != removed { button.isHidden = removed }
        if isBesidePill { updateBesideWidth() }
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
        guard beside != isBesidePill else { return }
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

    /// A button's symbol and label (the tabs slot's faces: Tabs or New Tab).
    func setFace(of kind: PageButton, symbol: String, title: String, value: String?) {
        let button = button(kind)
        button.accessibilityValue = value
        guard button.accessibilityLabel != title else { return }
        button.accessibilityLabel = title
        button.configuration?.image = UIImage(systemName: symbol)
    }

    /// The glass tint: Paper, or the quiet private tint while a private tab is on screen.
    func setPrivate(_ isPrivate: Bool) {
        let effect = UIGlassEffect(style: .regular)
        effect.tintColor = isPrivate ? Palette.privateGlassTint : Palette.glassTint
        glass.effect = effect
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
