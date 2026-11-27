#if canImport(UIKit)
import DesignSystem
import UIKit

/// The profile switcher over the cards (docs/state-rules.md §6): the shown profile's name and a
/// chevron on a glass capsule, a menu of the profiles under it. Shown only with a second profile.
final class GalleryProfileButton: UIView {
    let button = UIButton(type: .system)
    private let glass = Glass.makeView(shape: .capsule, interactive: true, tint: Palette.glassTintOnPaper)

    static let height: CGFloat = 36
    /// The room it takes over the cards: its height and a gap under the safe area's top.
    static let reserve: CGFloat = height + Spacing.s

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(glass)
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "chevron.down")
        configuration.imagePlacement = .trailing
        configuration.imagePadding = Spacing.xs
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .caption1, scale: .small)
            .applying(UIImage.SymbolConfiguration(weight: .semibold))
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
            return attributes
        }
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.contentInsets = .init(top: 0, leading: Spacing.l, bottom: 0, trailing: Spacing.m)
        configuration.baseForegroundColor = Palette.textPrimary
        button.configuration = configuration
        button.tintColor = Palette.textPrimary
        button.showsMenuAsPrimaryAction = true
        button.accessibilityIdentifier = "galleryProfile"
        button.accessibilityHint = String(localized: "Switches between profiles.")
        glass.contentView.addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The shown profile's name.
    var title: String? {
        get { button.configuration?.title }
        set {
            guard newValue != title else { return }
            button.configuration?.title = newValue
            button.accessibilityLabel = newValue.map { String(localized: "Profile: \($0)") }
            setNeedsLayout()
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let fit = button.sizeThatFits(CGSize(width: size.width, height: Self.height))
        return CGSize(width: min(size.width, max(Metrics.tapTarget * 2, ceil(fit.width))), height: Self.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        button.frame = bounds
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // A 44 pt touch on a 36 pt capsule.
        bounds.insetBy(dx: 0, dy: -(Metrics.tapTarget - Self.height) / 2).contains(point)
    }
}
#endif
