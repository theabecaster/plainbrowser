#if canImport(UIKit)
import DesignSystem
import os
import PerfSignposts
import UIKit

/// One tab's card: the site icon and title on top, the page preview under them. Swipe it up to
/// close the tab, tap it to open it.
///
/// The gallery places the card with `center` and `transform` only, every frame of a scroll. Its
/// subviews are laid out once per size (`setSize`), so moving a card never runs a layout pass, and
/// images arrive already decoded.
final class TabCardView: UIView, UIGestureRecognizerDelegate {
    /// The tab this card shows; image loads check it before assigning.
    private(set) var tabID: UUID?
    /// The image requests this card shows; a load that finishes for an older key is dropped.
    var thumbnailKey: ThumbnailPipeline.Key?
    var faviconKey: ThumbnailPipeline.Key?

    /// The user tapped the card.
    var onOpen: (() -> Void)?
    /// The card was swiped up far or fast enough.
    var onSwipeAway: (() -> Void)?
    /// Close from VoiceOver.
    var onClose: (() -> Void)?

    /// The part that moves when swiped. The gallery owns the card's own center and transform.
    let body = UIView()
    /// The page preview, also the open/close transition's target.
    let thumbnailContainer = UIView()
    private let header = UIView()
    private let headerMask = CALayer()
    private let shadowView = UIView()
    private let imageView = UIImageView()
    private let placeholderIcon = UIImageView()
    private let faviconView = UIImageView()
    private let privateIcon = UIImageView(image: UIImage(systemName: "eye.slash.fill"))
    private let titleLabel = UILabel()
    private let swipe = UIPanGestureRecognizer()
    private let tap = UITapGestureRecognizer()

    private(set) var size: CGSize = .zero
    private var headerHeight: CGFloat = 0
    private var isSelectedTab = false
    private var titleAlpha: CGFloat = 1
    private var visibleWidth: CGFloat = 0
    /// The card's offset when the finger went down (non-zero when it grabs a card mid-spring).
    private var swipeStart: CGFloat = 0
    /// Whether a finger is moving this card now.
    var isSwiping: Bool { swipe.state == .began || swipe.state == .changed }
    /// Set while the card flies off; it no longer belongs to a tab.
    private(set) var isLeaving = false

    static let selectionWidth: CGFloat = 3
    private static let iconGap: CGFloat = 8

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(body)

        headerMask.backgroundColor = UIColor.black.cgColor
        header.layer.mask = headerMask
        body.addSubview(header)

        shadowView.layer.shadowOpacity = 0.16
        shadowView.layer.shadowRadius = 14
        shadowView.layer.shadowOffset = CGSize(width: 0, height: 4)
        body.addSubview(shadowView)

        thumbnailContainer.backgroundColor = Palette.surface
        thumbnailContainer.layer.cornerRadius = Radius.large
        thumbnailContainer.layer.cornerCurve = .continuous
        thumbnailContainer.clipsToBounds = true
        body.addSubview(thumbnailContainer)

        imageView.contentMode = .scaleToFill
        thumbnailContainer.addSubview(imageView)

        placeholderIcon.contentMode = .scaleAspectFit
        placeholderIcon.tintColor = Palette.textSecondary
        thumbnailContainer.addSubview(placeholderIcon)

        faviconView.contentMode = .scaleAspectFit
        faviconView.layer.cornerRadius = Radius.small
        faviconView.layer.cornerCurve = .continuous
        faviconView.clipsToBounds = true
        faviconView.tintColor = Palette.textSecondary
        header.addSubview(faviconView)

        privateIcon.contentMode = .scaleAspectFit
        privateIcon.tintColor = Palette.textSecondary
        privateIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote)
        header.addSubview(privateIcon)

        titleLabel.textColor = Palette.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        header.addSubview(titleLabel)

        swipe.delegate = self
        swipe.addTarget(self, action: #selector(handleSwipe(_:)))
        body.addGestureRecognizer(swipe)
        tap.addTarget(self, action: #selector(handleTap))
        body.addGestureRecognizer(tap)

        isAccessibilityElement = true
        accessibilityIdentifier = "tabCard"
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (card: TabCardView, _) in
            card.applyColors()
        }
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The title's text style: a step down in the grid, where cards are small.
    static func titleFont(for traits: UITraitCollection) -> UIFont {
        let style: UIFont.TextStyle = traits.horizontalSizeClass == .regular ? .footnote : .subheadline
        let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: style, compatibleWith: traits)
            .addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold]])
        return UIFont(descriptor: descriptor, size: 0)
    }

    // MARK: Content

    /// - Parameter showsPrivateBadge: false where the whole list is private (its tint says so);
    ///   VoiceOver still hears "Private".
    func configure(item: TabGalleryItem, isSelected: Bool, hidesThumbnail: Bool, showsPrivateBadge: Bool = true) {
        if tabID != item.id {
            imageView.image = nil
            faviconView.image = nil
            thumbnailKey = nil
            faviconKey = nil
        }
        tabID = item.id
        isSelectedTab = isSelected
        titleLabel.text = item.displayTitle
        let font = Self.titleFont(for: traitCollection)
        let fontChanged = titleLabel.font != font
        if fontChanged { titleLabel.font = font }
        let badge = item.isPrivate && showsPrivateBadge
        let privateChanged = privateIcon.isHidden == badge
        privateIcon.isHidden = !badge
        if privateChanged || fontChanged { layoutHeader() }
        setThumbnailHidden(hidesThumbnail)
        updatePlaceholder()
        applyColors()

        var label = item.displayTitle
        if let host = item.host, host != label { label += ", " + host }
        if item.isPrivate { label += ", " + String(localized: "Private") }
        accessibilityLabel = label
        accessibilityTraits = isSelected ? [.button, .selected] : [.button]
        accessibilityHint = String(localized: "Opens the tab.")
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "Close Tab")) { [weak self] _ in
                self?.onClose?()
                return true
            },
        ]
    }

    func setThumbnail(_ image: UIImage?) {
        imageView.image = image
        updatePlaceholder()
        layoutImage()
    }

    func setFavicon(_ image: UIImage?) {
        faviconView.image = image ?? UIImage(systemName: "globe")
        updatePlaceholder()
    }

    /// Hides the preview while the open/close transition stands in for it.
    func setThumbnailHidden(_ hidden: Bool) {
        let alpha: CGFloat = hidden ? 0 : 1
        if thumbnailContainer.alpha != alpha {
            thumbnailContainer.alpha = alpha
            shadowView.alpha = alpha
        }
    }

    /// How much of the title shows (0 under a covering card) and how wide the uncovered part is.
    /// Called every frame of a scroll: it only touches alpha and a mask's width when they change.
    func setHeader(titleAlpha alpha: CGFloat, visibleWidth width: CGFloat) {
        if abs(alpha - titleAlpha) > 0.01 || (alpha != titleAlpha && (alpha == 0 || alpha == 1)) {
            titleAlpha = alpha
            titleLabel.alpha = alpha
            privateIcon.alpha = alpha
        }
        // Deep in the stack the uncovered strip is narrower than the icon: icons there would pile
        // on top of each other, so they fade out.
        let iconAlpha = ((width - MetricsValues.favicon - Self.iconGap) / Self.iconGap).clamped(to: 0...1)
        if abs(iconAlpha - faviconView.alpha) > 0.01 || (iconAlpha != faviconView.alpha && (iconAlpha == 0 || iconAlpha == 1)) {
            faviconView.alpha = iconAlpha
        }
        let maskWidth = max(Self.iconGap + MetricsValues.favicon, width - Self.iconGap)
        if abs(maskWidth - visibleWidth) > 0.5 {
            visibleWidth = maskWidth
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            headerMask.frame = CGRect(x: -Self.iconGap, y: -Self.iconGap, width: maskWidth + Self.iconGap, height: headerHeight + Self.iconGap * 2)
            CATransaction.commit()
        }
    }

    private func updatePlaceholder() {
        placeholderIcon.isHidden = imageView.image != nil
        if imageView.image == nil {
            placeholderIcon.image = faviconView.image ?? UIImage(systemName: "globe")
        }
    }

    private func applyColors() {
        let dark = traitCollection.userInterfaceStyle == .dark
        // Light mode lifts the card off the paper with a shadow; dark mode deepens it and adds an
        // edge, so stacked dark pages stay apart.
        shadowView.layer.shadowColor = Palette.floatingShadow.resolvedColor(with: traitCollection).cgColor
        shadowView.layer.shadowOpacity = dark ? 0.5 : 0.16
        let layer = thumbnailContainer.layer
        if isSelectedTab {
            layer.borderWidth = Self.selectionWidth
            layer.borderColor = Palette.accent.cgColor
        } else {
            layer.borderWidth = dark ? 1 : 0
            layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        }
    }

    // MARK: Layout

    /// Sets the card's size and lays out its parts once. The gallery anchors the card at its
    /// preview's center, so scaling a card in the stack keeps the preview centered.
    func setSize(_ size: CGSize, headerHeight: CGFloat) {
        guard size != self.size || headerHeight != self.headerHeight else { return }
        self.size = size
        self.headerHeight = headerHeight
        let thumbHeight = size.height - headerHeight
        layer.anchorPoint = CGPoint(x: 0.5, y: size.height > 0 ? (headerHeight + thumbHeight / 2) / size.height : 0.5)
        bounds = CGRect(origin: .zero, size: size)
        body.bounds = bounds
        body.center = CGPoint(x: size.width / 2, y: size.height / 2)

        let thumbFrame = CGRect(x: 0, y: headerHeight, width: size.width, height: thumbHeight)
        thumbnailContainer.frame = thumbFrame
        shadowView.frame = thumbFrame
        shadowView.layer.shadowPath = UIBezierPath(roundedRect: CGRect(origin: .zero, size: thumbFrame.size), cornerRadius: Radius.large).cgPath
        layoutImage()
        let iconSide = min(48, thumbHeight * 0.3)
        placeholderIcon.frame = CGRect(x: (size.width - iconSide) / 2, y: (thumbHeight - iconSide) / 2, width: iconSide, height: iconSide)
        layoutHeader()
        visibleWidth = -1
        setHeader(titleAlpha: titleAlpha, visibleWidth: size.width)
    }

    private func layoutHeader() {
        let width = size.width
        let rowHeight = headerHeight - TabGalleryMetrics.headerGap
        header.frame = CGRect(x: 0, y: 0, width: width, height: rowHeight)
        let midY = rowHeight / 2
        let side = MetricsValues.favicon
        faviconView.frame = CGRect(x: 2, y: (midY - side / 2).rounded(), width: side, height: side)
        var titleX = faviconView.frame.maxX + Self.iconGap
        if !privateIcon.isHidden {
            let iconSize = privateIcon.intrinsicContentSize
            privateIcon.frame = CGRect(x: titleX, y: (midY - iconSize.height / 2).rounded(), width: iconSize.width, height: iconSize.height)
            titleX = privateIcon.frame.maxX + Spacing.xs
        }
        let titleHeight = ceil(titleLabel.font?.lineHeight ?? 18)
        titleLabel.frame = CGRect(x: titleX, y: (midY - titleHeight / 2).rounded(), width: max(0, width - titleX - 2), height: titleHeight)
    }

    /// The preview is the top of the page at the card's width: pages are anchored at the top.
    private func layoutImage() {
        let width = size.width
        if let image = imageView.image, image.size.width > 0 {
            imageView.frame = CGRect(x: 0, y: 0, width: width, height: (width * image.size.height / image.size.width).rounded())
        } else {
            imageView.frame = .zero
        }
    }

    /// Ready for another tab: no motion, no handlers.
    func prepareForReuse() {
        body.layer.removeAllAnimations()
        body.transform = .identity
        body.alpha = 1
        alpha = 1
        isLeaving = false
        isUserInteractionEnabled = true
        onOpen = nil
        onSwipeAway = nil
        onClose = nil
        swipeStart = 0
    }

    // MARK: Swipe up to close

    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === swipe else { return super.gestureRecognizerShouldBegin(gesture) }
        // Only a mostly vertical move: a sideways one scrolls the gallery.
        let velocity = swipe.velocity(in: body)
        return abs(velocity.y) > abs(velocity.x)
    }

    @objc private func handleTap() {
        onOpen?()
    }

    @objc private func handleSwipe(_ gesture: UIPanGestureRecognizer) {
        let height = size.height - headerHeight
        switch gesture.state {
        case .began:
            // Grab the card where it is on screen, even mid-spring.
            swipeStart = body.layer.presentation()?.affineTransform().ty ?? body.transform.ty
            Haptic.close.prepare()
        case .changed:
            let y = CardSwipe.offset(translation: swipeStart + gesture.translation(in: self).y, cardHeight: height)
            UIView.animate(Motion.tracking) {
                self.body.transform = CGAffineTransform(translationX: 0, y: y)
            }
        case .ended, .cancelled, .failed:
            let y = CardSwipe.offset(translation: swipeStart + gesture.translation(in: self).y, cardHeight: height)
            let velocity = gesture.state == .ended ? gesture.velocity(in: self).y : 0
            if gesture.state == .ended, CardSwipe.shouldClose(translation: y, velocity: velocity, cardHeight: height) {
                onSwipeAway?()
            } else {
                Motion.animate(Motion.cardReturn) {
                    self.body.transform = .identity
                }
            }
        default:
            break
        }
    }

    /// Sends the card up and off the screen, then calls `completion`. After a swipe the spring
    /// carries on from the finger's tracking animation, so the card keeps the release velocity
    /// with no hand-off (WWDC24, "Enhance your UI animations and transitions"). From a button or
    /// menu the card is at rest and simply rises away.
    func throwAway(completion: @escaping () -> Void) {
        isLeaving = true
        isUserInteractionEnabled = false
        if Motion.prefersCrossfade {
            UIView.animate(withDuration: Motion.crossfadeDuration, animations: { self.alpha = 0 }, completion: { _ in completion() })
            return
        }
        // Far enough that the card's bottom edge clears the top of the screen.
        let bottomOnScreen = superview.map { convert(CGPoint(x: 0, y: bounds.maxY), to: $0).y - $0.bounds.minY } ?? frame.maxY
        UIView.animate(Motion.cardThrow, changes: {
            self.body.transform = CGAffineTransform(translationX: 0, y: -(bottomOnScreen + Spacing.xl))
        }, completion: completion)
    }

    func gestureRecognizer(
        _ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        false
    }

    // MARK: Accessibility

    override func accessibilityActivate() -> Bool {
        onOpen?()
        return true
    }
}

/// Sizes the card uses that come from the gallery's metrics.
private enum MetricsValues {
    static let favicon = TabGalleryMetrics.faviconSize
}
#endif
