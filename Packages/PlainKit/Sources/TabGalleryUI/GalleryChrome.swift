#if canImport(UIKit)
import DesignSystem
import UIKit

/// The gallery's floating bar: the gallery menu, the private toggle, New Tab and Done, on one
/// glass capsule.
final class GalleryBottomBar: UIView {
    let menuButton = UIButton(type: .system)
    let privateButton = UIButton(type: .system)
    let newTabButton = UIButton(type: .system)
    let doneButton = UIButton(type: .system)
    /// Whether the private toggle shows (the data source supports private tabs).
    var showsPrivateButton = false {
        didSet {
            privateButton.isHidden = !showsPrivateButton
            setNeedsLayout()
        }
    }
    private let glass = Glass.makeView(shape: .capsule, tint: Palette.glassTintOnPaper)

    private static let height: CGFloat = 52
    private static let padding: CGFloat = 4

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(glass)

        let symbols = UIImage.SymbolConfiguration(textStyle: .body, scale: .large)
        menuButton.setImage(UIImage(systemName: "ellipsis", withConfiguration: symbols), for: .normal)
        menuButton.accessibilityLabel = "More"
        menuButton.accessibilityIdentifier = "galleryMenu"

        newTabButton.setImage(UIImage(systemName: "plus", withConfiguration: symbols.applying(UIImage.SymbolConfiguration(weight: .semibold))), for: .normal)
        newTabButton.accessibilityLabel = "New Tab"
        newTabButton.accessibilityIdentifier = "galleryNewTab"

        var done = UIButton.Configuration.plain()
        done.title = "Done"
        // Glass content draws text in the label color unless the button names its own.
        done.baseForegroundColor = Palette.accentOnGlass
        done.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .headline)
            return attributes
        }
        done.contentInsets = .init(top: 0, leading: Spacing.m, bottom: 0, trailing: Spacing.m)
        doneButton.configuration = done
        doneButton.accessibilityIdentifier = "galleryDone"

        privateButton.accessibilityLabel = "Private"
        privateButton.accessibilityIdentifier = "galleryPrivate"
        privateButton.isHidden = true
        setPrivate(false)

        // The glyphs are the label color (white on the always-dark gallery), so they read as
        // active on the dark glass; Done keeps the accent as the bar's one main action.
        for button in [menuButton, privateButton, newTabButton] {
            button.tintColor = Palette.textPrimary
        }
        doneButton.tintColor = Palette.accentOnGlass
        for button in [menuButton, privateButton, newTabButton, doneButton] {
            glass.contentView.addSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The private toggle's look: a filled hand while the gallery shows private tabs.
    func setPrivate(_ isPrivate: Bool) {
        let symbols = UIImage.SymbolConfiguration(textStyle: .body, scale: .large)
        privateButton.setImage(
            UIImage(systemName: isPrivate ? "hand.raised.fill" : "hand.raised", withConfiguration: symbols), for: .normal
        )
        privateButton.accessibilityValue = isPrivate ? "On" : "Off"
        privateButton.accessibilityTraits = isPrivate ? [.button, .selected] : .button
    }

    private var buttonCount: CGFloat { showsPrivateButton ? 3 : 2 }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let done = max(Metrics.tapTarget, doneButton.sizeThatFits(size).width)
        let width = Self.padding * 2 + Metrics.tapTarget * buttonCount + done + Spacing.xl * buttonCount
        return CGSize(width: width, height: Self.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        let side = Metrics.tapTarget
        let y = ((bounds.height - side) / 2).rounded()
        menuButton.frame = CGRect(x: Self.padding, y: y, width: side, height: side)
        var next = menuButton.frame.maxX + Spacing.xl
        if showsPrivateButton {
            privateButton.frame = CGRect(x: next, y: y, width: side, height: side)
            next = privateButton.frame.maxX + Spacing.xl
        }
        newTabButton.frame = CGRect(x: next, y: y, width: side, height: side)
        let doneX = newTabButton.frame.maxX + Spacing.xl
        doneButton.frame = CGRect(x: doneX, y: y, width: bounds.width - Self.padding - doneX, height: side)
    }
}

/// "Reopen Tab", shown only after a close and gone a few seconds later (docs/ui-reference.md).
final class ReopenToast: UIView {
    let button = UIButton(type: .system)
    private let glass = Glass.makeView(shape: .capsule, interactive: true, tint: Palette.glassTintOnPaper)
    private var hideTask: Task<Void, Never>?
    private(set) var isShowing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(glass)
        var configuration = UIButton.Configuration.plain()
        configuration.title = "Reopen Tab"
        configuration.image = UIImage(systemName: "arrow.uturn.backward")
        configuration.imagePadding = Spacing.s
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
            return attributes
        }
        configuration.contentInsets = .init(top: 0, leading: Spacing.l, bottom: 0, trailing: Spacing.l)
        configuration.baseForegroundColor = Palette.accentOnGlass
        button.configuration = configuration
        button.tintColor = Palette.accentOnGlass
        button.accessibilityIdentifier = "reopenTab"
        glass.contentView.addSubview(button)
        alpha = 0
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let fit = button.sizeThatFits(size)
        return CGSize(width: ceil(fit.width), height: Metrics.tapTarget)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        button.frame = bounds
    }

    /// Shows the toast, or keeps it up a little longer after another close.
    func show(animated: Bool) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(TabGalleryChoices.reopenToastDuration))
            guard !Task.isCancelled else { return }
            self?.hide(animated: true)
        }
        guard !isShowing else { return }
        isShowing = true
        isHidden = false
        UIAccessibility.post(notification: .announcement, argument: "Tab closed")
        if animated, !Motion.prefersCrossfade { transform = CGAffineTransform(translationX: 0, y: 12) }
        let changes = {
            self.alpha = 1
            self.transform = .identity
        }
        if animated {
            Motion.animate(Motion.reflow, changes: changes)
        } else {
            changes()
        }
    }

    func hide(animated: Bool) {
        hideTask?.cancel()
        hideTask = nil
        guard isShowing else { return }
        isShowing = false
        let finish = { [weak self] in
            guard let self, !isShowing else { return }
            isHidden = true
        }
        guard animated else {
            alpha = 0
            finish()
            return
        }
        Motion.animate(Motion.quick, changes: {
            self.alpha = 0
            if !Motion.prefersCrossfade { self.transform = CGAffineTransform(translationX: 0, y: 8) }
        }, completion: finish)
    }
}

/// Shown only when the gallery opens with no tabs. After the last tab closes, the shell goes
/// straight to the search field instead (docs/ui-reference.md).
final class GalleryEmptyView: UIView {
    let label = UILabel()
    let button = UIButton(type: .system)
    /// The mark, as on the start screen: a finger can spin it, so the screen is never dead.
    let mark = MarkView()
    private static let markSide: CGFloat = 88

    override init(frame: CGRect) {
        super.init(frame: frame)
        mark.isSpinnable = true
        addSubview(mark)
        label.text = "Your open tabs show up here."
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Palette.textSecondary
        label.textAlignment = .center
        label.numberOfLines = 0
        addSubview(label)

        var configuration = UIButton.Configuration.filled()
        configuration.title = "New Tab"
        configuration.baseBackgroundColor = Palette.accent
        configuration.cornerStyle = .capsule
        configuration.contentInsets = .init(top: Spacing.m, leading: Spacing.xl, bottom: Spacing.m, trailing: Spacing.xl)
        button.configuration = configuration
        button.accessibilityIdentifier = "emptyNewTab"
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The sentence and button for regular or private tabs.
    func setPrivate(_ isPrivate: Bool) {
        label.text = isPrivate
            ? "Private tabs show up here, and Plain keeps no history of them."
            : "Your open tabs show up here."
        button.configuration?.title = isPrivate ? "New Private Tab" : "New Tab"
        setNeedsLayout()
    }

    /// The regular list's sentence: the data source's (a profile with no tabs yet), else the
    /// default.
    @discardableResult
    func setText(_ text: String?) -> Bool {
        let text = text ?? "Your open tabs show up here."
        guard label.text != text else { return false }
        label.text = text
        setNeedsLayout()
        return true
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let text = label.sizeThatFits(CGSize(width: size.width, height: .greatestFiniteMagnitude))
        let buttonSize = button.sizeThatFits(size)
        return CGSize(
            width: size.width,
            height: Self.markSide + Spacing.xl + ceil(text.height) + Spacing.l + max(Metrics.tapTarget, buttonSize.height)
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let text = label.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        mark.frame = CGRect(x: ((bounds.width - Self.markSide) / 2).rounded(), y: 0, width: Self.markSide, height: Self.markSide)
        label.frame = CGRect(x: 0, y: mark.frame.maxY + Spacing.xl, width: bounds.width, height: ceil(text.height))
        let size = button.sizeThatFits(bounds.size)
        let height = max(Metrics.tapTarget, size.height)
        button.frame = CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: label.frame.maxY + Spacing.l, width: size.width, height: height)
    }
}

extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
#endif
