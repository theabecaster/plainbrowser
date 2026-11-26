#if canImport(UIKit)
import DesignSystem
import UIKit

/// One tab's card: the page preview on top, the site icon, title and close button under it.
///
/// Every frame is set by hand in `layoutSubviews` from the cell's fixed size, so a reused cell
/// with the same size never lays out again during a scroll. Images arrive already decoded.
final class TabCardCell: UICollectionViewCell, UIGestureRecognizerDelegate {
    static let reuseID = "TabCardCell"

    /// The tab this cell shows; image loads check it before assigning.
    private(set) var tabID: UUID?
    /// Called when the card was flicked far or fast enough, or its close button was tapped.
    /// `thrown` is true for a flick: the card is already flying off.
    var onClose: ((_ thrown: Bool) -> Void)?

    /// The part that moves when flicked. The collection view owns the cell's own frame and
    /// transform, so the gesture moves this instead.
    let cardView = UIView()
    /// The page preview, also the open/close transition's target.
    let thumbnailContainer = UIView()
    private let shadowView = UIView()
    private let imageView = UIImageView()
    private let placeholderIcon = UIImageView()
    private let faviconView = UIImageView()
    private let privateIcon = UIImageView(image: UIImage(systemName: "eye.slash.fill"))
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let flick = UIPanGestureRecognizer()

    private var thumbnailHeight: CGFloat = 0
    private var isSelectedTab = false
    private var isPrivateTab = false
    /// The card's offset when the finger went down (non-zero when it grabs a card mid-spring).
    private var flickStart: CGFloat = 0

    private static let faviconSize: CGFloat = 18
    private static let iconGap: CGFloat = 8
    private static let selectionWidth: CGFloat = 3

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(cardView)

        shadowView.layer.shadowOpacity = 0.12
        shadowView.layer.shadowRadius = 8
        shadowView.layer.shadowOffset = CGSize(width: 0, height: 2)
        cardView.addSubview(shadowView)

        thumbnailContainer.backgroundColor = Palette.surface
        thumbnailContainer.layer.cornerRadius = Radius.large
        thumbnailContainer.layer.cornerCurve = .continuous
        thumbnailContainer.clipsToBounds = true
        cardView.addSubview(thumbnailContainer)

        imageView.contentMode = .scaleToFill
        imageView.clipsToBounds = false
        thumbnailContainer.addSubview(imageView)

        placeholderIcon.contentMode = .scaleAspectFit
        placeholderIcon.tintColor = Palette.textSecondary
        thumbnailContainer.addSubview(placeholderIcon)

        faviconView.contentMode = .scaleAspectFit
        faviconView.layer.cornerRadius = 4
        faviconView.layer.cornerCurve = .continuous
        faviconView.clipsToBounds = true
        faviconView.tintColor = Palette.textSecondary
        cardView.addSubview(faviconView)

        privateIcon.contentMode = .scaleAspectFit
        privateIcon.tintColor = Palette.textSecondary
        privateIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote)
        cardView.addSubview(privateIcon)

        titleLabel.font = Self.titleFont(for: traitCollection)
        // The gallery reconfigures every card when the text size changes (its row height changes too).
        titleLabel.textColor = Palette.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        cardView.addSubview(titleLabel)

        let symbol = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)
            .applying(UIImage.SymbolConfiguration(weight: .semibold))
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: symbol), for: .normal)
        closeButton.tintColor = Palette.textSecondary
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?(false) }, for: .primaryActionTriggered)
        closeButton.isAccessibilityElement = false
        cardView.addSubview(closeButton)

        flick.delegate = self
        flick.addTarget(self, action: #selector(handleFlick(_:)))
        contentView.addGestureRecognizer(flick)

        isAccessibilityElement = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: TabCardCell, _) in
            cell.applyColors()
        }
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The title's text style. Cards are small in the grid, so the title is a step down there.
    static func titleFont(for traits: UITraitCollection) -> UIFont {
        let style: UIFont.TextStyle = traits.horizontalSizeClass == .regular ? .footnote : .subheadline
        let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: style, compatibleWith: traits)
            .addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.medium]])
        return UIFont(descriptor: descriptor, size: 0)
    }

    // MARK: Content

    func configure(item: TabGalleryItem, isSelected: Bool, thumbnailHeight: CGFloat, hidesThumbnail: Bool) {
        if tabID != item.id {
            imageView.image = nil
            faviconView.image = nil
        }
        tabID = item.id
        self.thumbnailHeight = thumbnailHeight
        isSelectedTab = isSelected
        isPrivateTab = item.isPrivate
        titleLabel.text = item.displayTitle
        titleLabel.font = Self.titleFont(for: traitCollection)
        privateIcon.isHidden = !item.isPrivate
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
                self?.onClose?(false)
                return true
            },
        ]
        setNeedsLayout()
    }

    func setThumbnail(_ image: UIImage?) {
        imageView.image = image
        updatePlaceholder()
        setNeedsLayout()
    }

    func setFavicon(_ image: UIImage?) {
        faviconView.image = image ?? UIImage(systemName: "globe")
        updatePlaceholder()
    }

    /// Hides the preview while the open/close transition stands in for it.
    func setThumbnailHidden(_ hidden: Bool) {
        thumbnailContainer.alpha = hidden ? 0 : 1
        shadowView.alpha = hidden ? 0 : 1
    }

    private func updatePlaceholder() {
        placeholderIcon.isHidden = imageView.image != nil
        if imageView.image == nil {
            placeholderIcon.image = faviconView.image ?? UIImage(systemName: "globe")
        }
    }

    private func applyColors() {
        let dark = traitCollection.userInterfaceStyle == .dark
        // Light mode lifts the card off the paper with a shadow; dark mode draws an edge instead.
        shadowView.layer.shadowColor = Palette.floatingShadow.resolvedColor(with: traitCollection).cgColor
        shadowView.isHidden = dark
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

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        // Never move the card while it is being flicked.
        if cardView.transform == .identity { cardView.frame = bounds } else { cardView.bounds.size = bounds.size }
        let width = bounds.width
        let thumbFrame = CGRect(x: 0, y: 0, width: width, height: thumbnailHeight)
        thumbnailContainer.frame = thumbFrame
        shadowView.frame = thumbFrame
        shadowView.layer.shadowPath = UIBezierPath(roundedRect: CGRect(origin: .zero, size: thumbFrame.size), cornerRadius: Radius.large).cgPath

        // The preview is the top of the page at the card's width: pages are anchored at the top.
        if let image = imageView.image, image.size.width > 0 {
            imageView.frame = CGRect(x: 0, y: 0, width: width, height: (width * image.size.height / image.size.width).rounded())
        } else {
            imageView.frame = .zero
        }
        let iconSide = min(48, thumbnailHeight * 0.3)
        placeholderIcon.frame = CGRect(x: (width - iconSide) / 2, y: (thumbnailHeight - iconSide) / 2, width: iconSide, height: iconSide)

        let rowTop = thumbnailHeight
        let rowHeight = bounds.height - rowTop
        let midY = rowTop + rowHeight / 2
        let side = Self.faviconSize
        faviconView.frame = CGRect(x: 2, y: (midY - side / 2).rounded(), width: side, height: side)
        var titleX = faviconView.frame.maxX + Self.iconGap
        if !privateIcon.isHidden {
            let size = privateIcon.intrinsicContentSize
            privateIcon.frame = CGRect(x: titleX, y: (midY - size.height / 2).rounded(), width: size.width, height: size.height)
            titleX = privateIcon.frame.maxX + Spacing.xs
        }
        let button = Metrics.tapTarget
        // The glyph lines up with the card's trailing edge; the 44 pt target overhangs it.
        closeButton.frame = CGRect(x: width - button + 12, y: (midY - button / 2).rounded(), width: button, height: button)
        let titleHeight = ceil(titleLabel.font.lineHeight)
        titleLabel.frame = CGRect(
            x: titleX, y: (midY - titleHeight / 2).rounded(),
            width: max(0, closeButton.frame.minX - titleX), height: titleHeight
        )
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cardView.layer.removeAllAnimations()
        cardView.transform = .identity
        cardView.alpha = 1
        onClose = nil
        flickStart = 0
    }

    // MARK: Flick to close

    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === flick else { return super.gestureRecognizerShouldBegin(gesture) }
        // Only a mostly sideways move: a vertical one scrolls the gallery.
        let velocity = flick.velocity(in: contentView)
        return abs(velocity.x) > abs(velocity.y) * 1.2
    }

    @objc private func handleFlick(_ gesture: UIPanGestureRecognizer) {
        let width = contentView.bounds.width
        switch gesture.state {
        case .began:
            // Grab the card where it is on screen, even mid-spring.
            flickStart = cardView.layer.presentation()?.affineTransform().tx ?? cardView.transform.tx
            Haptic.close.prepare()
        case .changed:
            let x = flickStart + gesture.translation(in: contentView).x
            UIView.animate(Motion.tracking) {
                self.cardView.transform = CGAffineTransform(translationX: x, y: 0)
                self.cardView.alpha = CardFlick.alpha(translation: x, cardWidth: width)
            }
        case .ended, .cancelled, .failed:
            let x = flickStart + gesture.translation(in: contentView).x
            let velocity = gesture.state == .ended ? gesture.velocity(in: contentView).x : 0
            if gesture.state == .ended, CardFlick.shouldClose(translation: x, velocity: velocity, cardWidth: width) {
                throwAway(translation: x, velocity: velocity)
            } else {
                Motion.animate(Motion.throwClose) {
                    self.cardView.transform = .identity
                    self.cardView.alpha = 1
                }
            }
        default:
            break
        }
    }

    /// Sends the card off the side it was thrown toward, with the flick's velocity. A snapshot
    /// flies, so the collection view can delete the cell and reflow the others at the same time.
    private func throwAway(translation: CGFloat, velocity: CGFloat) {
        Haptic.close.play()
        isUserInteractionEnabled = false
        let direction: CGFloat = (velocity != 0 ? velocity : translation) < 0 ? -1 : 1
        if let host = superview, let ghost = cardView.snapshotView(afterScreenUpdates: false) {
            let presented = cardView.layer.presentation()
            ghost.frame = contentView.convert(presented?.frame ?? cardView.frame, to: host)
            ghost.alpha = CGFloat(presented?.opacity ?? Float(cardView.alpha))
            ghost.isUserInteractionEnabled = false
            host.addSubview(ghost)
            cardView.layer.removeAllAnimations()
            cardView.alpha = 0
            let distance = max(host.bounds.width, ghost.frame.width) + ghost.frame.width
            let remaining = direction * distance - (ghost.frame.minX - contentView.convert(contentView.bounds, to: host).minX)
            if Motion.prefersCrossfade {
                UIView.animate(withDuration: Motion.crossfadeDuration, animations: { ghost.alpha = 0 }, completion: { _ in ghost.removeFromSuperview() })
            } else {
                let timing = Motion.throwCloseTiming(distance: remaining, velocity: velocity)
                let animator = UIViewPropertyAnimator(duration: 0, timingParameters: timing)
                animator.addAnimations {
                    ghost.center.x += remaining
                    ghost.alpha = 0.2
                }
                animator.addCompletion { _ in ghost.removeFromSuperview() }
                animator.startAnimation()
            }
        }
        onClose?(true)
    }

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        isUserInteractionEnabled = true
    }

    func gestureRecognizer(
        _ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        false
    }
}
#endif
