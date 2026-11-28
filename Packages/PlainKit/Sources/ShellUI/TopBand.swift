#if canImport(UIKit)
import BrowserCore
import DesignSystem
import UIKit

/// The glass band across the top of a wide screen (the Duo's inner screen), behind the top bar.
///
/// Safari's model there (docs/research/safari-duo-top.md): expanded, a glass band holds the row
/// and the strip and the page starts under it; while reading it shrinks to a slim band holding only
/// the site's host, and the page's top boundary is its bottom edge, never the controls. Plain keeps
/// its floating capsules on it.
///
/// It moves by transform and alpha only: the glass rises from the expanded chrome's bottom to the
/// collapsed band's (`TopChromeGeometry.bandTranslation`), and the host fades in on the status row
/// as the pill's text shrinks into it. A tap on the collapsed band brings the bar back
/// (`onTap`); expanded, the band takes the taps between the controls so they never reach the page
/// under the glass. Taps below the glass's current bottom go to the page.
final class TopBand: UIView {
    /// One rectangle of Liquid Glass, the page's width (`Glass.makeView`).
    let glass = Glass.makeView(shape: .rounded(0), tint: Palette.bandGlassTint)
    /// The site's host while reading, without "www." ("apple.com").
    let hostLabel = UILabel()
    /// A tap on the collapsed band.
    var onTap: () -> Void = {}
    /// The bar is collapsed: a tap brings it back, and VoiceOver reads the band as the address.
    private(set) var isCollapsed = false
    private var host: String?

    /// The host's center from the band's top (`TopChromeGeometry.hostCenterY`), and its center X
    /// on the pill's (set with the layout).
    var hostCenterY: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        hostLabel.translatesAutoresizingMaskIntoConstraints = false
        hostLabel.textAlignment = .center
        hostLabel.lineBreakMode = .byTruncatingHead
        hostLabel.adjustsFontForContentSizeCategory = false
        hostLabel.textColor = Palette.textPrimary
        hostLabel.isAccessibilityElement = false
        hostLabel.alpha = 0
        // In the glass, so it takes the glass's light or dark look over the page.
        glass.contentView.addSubview(hostLabel)
        hostCenterY = hostLabel.centerYAnchor.constraint(equalTo: topAnchor)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostCenterY,
            hostLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Spacing.l),
            hostLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Spacing.l),
        ])
        updateFont()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (band: TopBand, _) in band.updateFont() }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        accessibilityIdentifier = "topBand"
        accessibilityTraits = .button
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The host's font: the pill's (Body, capped like it at the largest non-accessibility size)
    /// times `TopChromeGeometry.compactScale`, so the pill's text shrinks exactly into it.
    private func updateFont() {
        let traits = UITraitCollection(preferredContentSizeCategory: min(
            traitCollection.preferredContentSizeCategory, .extraExtraExtraLarge
        ))
        let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        let size = (body.pointSize * TopChromeGeometry.compactScale).rounded()
        hostLabel.font = .systemFont(ofSize: size, weight: .semibold)
    }

    /// Shows `url`'s host while reading (`TopBandHost.baseDomain`), "Not Secure — " before it
    /// when the page is not secure.
    func display(url: URL?, notSecure: Bool) {
        let domain = url?.host().map(TopBandHost.baseDomain) ?? url?.absoluteString
        host = domain
        guard let domain, !domain.isEmpty else {
            hostLabel.attributedText = nil
            accessibilityValue = nil
            return
        }
        let text = NSMutableAttributedString()
        if notSecure {
            text.append(NSAttributedString(string: "Not Secure — ", attributes: [.foregroundColor: Palette.textSecondary]))
        }
        text.append(NSAttributedString(string: domain, attributes: [.foregroundColor: Palette.textPrimary]))
        hostLabel.attributedText = text
        accessibilityValue = hostLabel.text
    }

    /// The glass tint: Paper, or the private tint while a private tab is on screen.
    func setPrivate(_ isPrivate: Bool) {
        let effect = UIGlassEffect(style: .regular)
        effect.tintColor = isPrivate ? Palette.privateBandGlassTint : Palette.bandGlassTint
        glass.effect = effect
        accessibilityLabel = isPrivate ? "Private Address" : "Address"
    }

    /// Places the band for collapse `progress` (transform and alpha only): the glass rises by
    /// `translation`, the host stays on its row (it is inside the glass, so it moves back down by
    /// as much) and fades in at its size.
    func apply(progress: CGFloat, translation: CGFloat) {
        glass.transform = CGAffineTransform(translationX: 0, y: translation)
        let scale = TopChromeGeometry.hostScale(progress: progress)
        hostLabel.transform = CGAffineTransform(translationX: 0, y: -translation).scaledBy(x: scale, y: scale)
        hostLabel.alpha = TopChromeGeometry.hostAlpha(progress: progress)
        let collapsed = progress >= 0.5
        guard collapsed != isCollapsed else { return }
        isCollapsed = collapsed
        // Collapsed, VoiceOver reads the band as the address and a double tap brings the bar back.
        isAccessibilityElement = collapsed
        accessibilityHint = collapsed ? "Shows the toolbar." : nil
    }

    /// Only the glass's current area takes touches: below it (a collapsing band) the page does.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        point.y < glass.frame.maxY && super.point(inside: point, with: event)
    }

    override func accessibilityActivate() -> Bool {
        guard isCollapsed else { return false }
        onTap()
        return true
    }

    @objc private func tapped() {
        guard isCollapsed else { return }
        onTap()
    }
}
#endif
