#if canImport(UIKit)
import DesignSystem
import UIKit

/// The page's buttons: Back, Forward, Share and More (the page menu).
///
/// Where the system has a vertical bar (the iPhone Duo's outer screen), they are the navigation
/// controller's toolbar items with `.verticalPreferred`, so the system places them in its side
/// column (docs/plan.md, section 6). Elsewhere they are this glass bar under the URL pill, which
/// collapses with the pill as the page scrolls. A system toolbar would change the page's safe
/// area as it hides, which relayouts the page; this bar moves by transform only.
enum PageButton: CaseIterable {
    case back, forward, share, more

    var symbol: String {
        switch self {
        case .back: "chevron.backward"
        case .forward: "chevron.forward"
        case .share: "square.and.arrow.up"
        case .more: "ellipsis.circle"
        }
    }

    var title: String {
        switch self {
        case .back: "Back"
        case .forward: "Forward"
        case .share: "Share"
        case .more: "More"
        }
    }

    var identifier: String {
        switch self {
        case .back: "back"
        case .forward: "forward"
        case .share: "share"
        case .more: "more"
        }
    }
}

/// The glass button bar under the pill on iPhones without a vertical bar.
final class ButtonBar: UIView {
    private let glass = Glass.makeView(shape: .capsule)
    private(set) var buttons: [PageButton: UIButton] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        let stack = UIStackView()
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
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: Spacing.s),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -Spacing.s),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func button(_ kind: PageButton) -> UIButton { buttons[kind]! }
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
