#if canImport(UIKit)
import DesignSystem
import UIKit

/// Browse for Me in the search sheet: the row right under the field, over the suggestions and
/// apart from them (docs/state-rules.md §6). A tap reads the top results for what is typed and
/// writes a summary on the phone.
///
/// Its place is kept for as long as the field is open, so the suggestions under it never move when
/// it comes and goes: it fades in place, shown while the text would search, gone (and not
/// tappable) while it is an address.
final class BrowseForMeRow: UIControl {
    private let icon = UIImageView()
    private let title = UILabel()
    private let detail = UILabel()
    private let hairline = UIView()
    private(set) var query: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "browseForMe"
        layer.cornerRadius = Radius.large
        layer.cornerCurve = .continuous

        icon.image = UIImage(systemName: "binoculars")
        icon.tintColor = Palette.accentOnPaper
        icon.contentMode = .center
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body, scale: .medium)
        title.text = String(localized: "Browse for Me")
        title.font = UIFont.preferredFont(forTextStyle: .body).withWeight(.semibold)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = Palette.accentOnPaper
        detail.font = .preferredFont(forTextStyle: .footnote)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = Palette.textSecondary
        detail.text = String(localized: "Read the top results and summarize them")
        hairline.backgroundColor = Palette.paperHairline

        let text = UIStackView(arrangedSubviews: [title, detail])
        text.axis = .vertical
        text.spacing = Spacing.xxs
        for view in [icon, text, hairline] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.rowHeight),
            {
                let natural = heightAnchor.constraint(equalToConstant: Metrics.rowHeight)
                natural.priority = .defaultLow + 1
                return natural
            }(),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.m),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Spacing.m),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.m),
            text.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: SearchSheet.rowTextInset),
            text.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -SearchSheet.rowTextInset),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            // The line that sets it apart from the suggestions under it.
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.m),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.m),
            hairline.heightAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = title.text
        alpha = 0
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? Palette.pressed : nil }
    }

    /// Shows the row for `query`, or hides it in place (nil). Fades, never moves.
    func show(_ query: String?, animated: Bool) {
        guard query != self.query else { return }
        let wasShown = self.query != nil
        self.query = query
        accessibilityValue = query
        let shown = query != nil
        isUserInteractionEnabled = shown
        accessibilityElementsHidden = !shown
        guard shown != wasShown else { return }
        let change = { self.alpha = shown ? 1 : 0 }
        if animated, window != nil {
            UIView.animate(withDuration: Motion.suggestionFade, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: change)
        } else {
            change()
        }
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: 0)
    }
}
#endif
