#if canImport(UIKit)
import DesignSystem
import UIKit

/// The card beside a lone tab in the gallery: a sheet of paper with "+" and "New Tab", where the
/// next tab would go (docs/state-rules.md §6). It looks like the card past the last tab in the bar
/// swipe and like a new tab's own card (paper in the window's appearance, not the gallery's dark),
/// so the three read as one idea. A tap opens a new tab with the search field.
///
/// It sits in the slot after the last card and is placed like a card: `center` and `transform`
/// only, sized once per gallery size, anchored at its page area's center. It has no title row (the
/// paper says what it is) and nothing to swipe away.
final class NewTabCardView: UIView {
    var onTap: (() -> Void)?

    private let shadowView = UIView()
    private let paper = UIView()
    private let symbol = UIImageView()
    private let label = UILabel()
    private let content = UIStackView()
    /// Where the content's center sits across the card, in the card's own points.
    private var contentX: CGFloat = -1
    private(set) var size: CGSize = .zero
    private var headerHeight: CGFloat = 0
    private var isPrivate = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        shadowView.layer.shadowOpacity = 0.16
        shadowView.layer.shadowRadius = 14
        shadowView.layer.shadowOffset = CGSize(width: 0, height: 4)
        addSubview(shadowView)

        paper.layer.cornerRadius = Radius.large
        paper.layer.cornerCurve = .continuous
        paper.clipsToBounds = true
        addSubview(paper)

        symbol.image = UIImage(systemName: "plus.circle", withConfiguration: UIImage.SymbolConfiguration(textStyle: .largeTitle))
        symbol.tintColor = Palette.accent
        label.text = String(localized: "New Tab")
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        content.addArrangedSubview(symbol)
        content.addArrangedSubview(label)
        content.axis = .vertical
        content.alignment = .center
        content.spacing = Spacing.s
        content.translatesAutoresizingMaskIntoConstraints = false
        paper.addSubview(content)
        // Centered on the card; `setVisibleSpan` slides it (a transform, no layout) to the middle
        // of the part on screen, so it reads while the card only peeks in from the side.
        NSLayoutConstraint.activate([
            content.centerYAnchor.constraint(equalTo: paper.centerYAnchor),
            content.centerXAnchor.constraint(equalTo: paper.centerXAnchor),
        ])

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "New Tab")
        accessibilityTraits = .button
        accessibilityIdentifier = "galleryNewTabCard"
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (card: NewTabCardView, _) in card.applyColors() }
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Same size and anchor as a tab card, so it sits in the cascade or the grid like one.
    func setSize(_ size: CGSize, headerHeight: CGFloat) {
        guard size != self.size || headerHeight != self.headerHeight else { return }
        self.size = size
        self.headerHeight = headerHeight
        let thumbHeight = size.height - headerHeight
        layer.anchorPoint = CGPoint(x: 0.5, y: size.height > 0 ? (headerHeight + thumbHeight / 2) / size.height : 0.5)
        bounds = CGRect(origin: .zero, size: size)
        let frame = CGRect(x: 0, y: headerHeight, width: size.width, height: thumbHeight)
        paper.frame = frame
        shadowView.frame = frame
        shadowView.layer.shadowPath = UIBezierPath(roundedRect: CGRect(origin: .zero, size: frame.size), cornerRadius: Radius.large).cgPath
    }

    /// Centers "+" and "New Tab" in the part of the card on screen, `minX...maxX` in the card's
    /// own points, never closer than a margin to its edges. Called every scroll frame: it only
    /// moves a transform, and only when the place changes.
    func setVisibleSpan(minX: CGFloat, maxX: CGFloat) {
        let half = content.bounds.width / 2 + Spacing.l
        let x = min(max((minX + maxX) / 2, half), max(half, size.width - half))
        guard abs(x - contentX) > 0.5 else { return }
        contentX = x
        content.transform = CGAffineTransform(translationX: (x - size.width / 2).rounded(toScale: 3), y: 0)
    }

    /// The private list's card takes the private paper.
    func setPrivate(_ isPrivate: Bool) {
        guard isPrivate != self.isPrivate else { return }
        self.isPrivate = isPrivate
        applyColors()
    }

    /// Touches only on the paper, not the empty title row above it.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        paper.frame.contains(point)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { applyColors() }
    }

    private func applyColors() {
        // The paper and its words in the window's appearance, as the start screen shows them: the
        // gallery around it is always dark.
        let pageTraits = window?.windowScene?.traitCollection ?? traitCollection
        let dark = pageTraits.userInterfaceStyle == .dark
        paper.backgroundColor = isPrivate ? Palette.privateBackground.resolvedColor(with: pageTraits) : Paper.resolved(for: pageTraits)
        label.textColor = Palette.textSecondary.resolvedColor(with: pageTraits)
        paper.layer.borderWidth = dark ? 1 : 0
        paper.layer.borderColor = UIColor.separator.resolvedColor(with: pageTraits).cgColor
        shadowView.layer.shadowColor = Palette.floatingShadow.resolvedColor(with: traitCollection).cgColor
        shadowView.layer.shadowOpacity = traitCollection.userInterfaceStyle == .dark ? 0.5 : 0.16
    }

    @objc private func tapped() {
        onTap?()
    }

    override func accessibilityActivate() -> Bool {
        onTap?()
        return true
    }
}
#endif
