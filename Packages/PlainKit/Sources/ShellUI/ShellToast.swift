#if canImport(UIKit)
import BrowserCore
import DesignSystem
import PerfSignposts
import UIKit

/// A short message over the chrome, with at most one button: "Reopen Tab" after a close, a
/// finished or failed download, a link opened in the background (docs/ui-reference.md: controls
/// show only while they apply). It goes away by itself after `FixedChoices.toastDuration`.
final class ShellToast: UIView {
    private let glass = Glass.makeView(shape: .capsule, interactive: true)
    private let label = UILabel()
    private let button = UIButton(type: .system)
    private var action: (() -> Void)?
    private var hideTask: Task<Void, Never>?
    private(set) var isShowing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(glass)
        label.font = UIFont.preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Palette.textPrimary
        label.lineBreakMode = .byTruncatingMiddle
        glass.contentView.addSubview(label)

        var configuration = UIButton.Configuration.plain()
        configuration.baseForegroundColor = Palette.accentOnGlass
        configuration.contentInsets = .init(top: 0, leading: Spacing.s, bottom: 0, trailing: Spacing.s)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
            return attributes
        }
        button.configuration = configuration
        button.accessibilityIdentifier = "toastButton"
        button.addAction(UIAction { [weak self] _ in
            let action = self?.action
            self?.hide(animated: true)
            action?()
        }, for: .primaryActionTriggered)
        glass.contentView.addSubview(button)
        accessibilityIdentifier = "toast"
        alpha = 0
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Its width under Auto Layout: the message and the button, capped by the pill's width.
    override var intrinsicContentSize: CGSize {
        sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: Metrics.tapTarget))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let labelSize = label.sizeThatFits(size)
        let buttonWidth = button.isHidden ? 0 : button.sizeThatFits(size).width
        let width = Spacing.l + ceil(labelSize.width) + (button.isHidden ? Spacing.l : Spacing.xs + ceil(buttonWidth) + Spacing.xs)
        return CGSize(width: min(width, size.width), height: Metrics.tapTarget)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        let buttonWidth = button.isHidden ? 0 : ceil(button.sizeThatFits(bounds.size).width)
        button.frame = CGRect(x: bounds.width - Spacing.xs - buttonWidth, y: 0, width: buttonWidth, height: bounds.height)
        let labelRight = button.isHidden ? bounds.width - Spacing.l : button.frame.minX - Spacing.xs
        label.frame = CGRect(x: Spacing.l, y: 0, width: max(0, labelRight - Spacing.l), height: bounds.height)
    }

    /// The glass tint: Paper, or the private tint while a private tab is on screen.
    func setPrivate(_ isPrivate: Bool) {
        let effect = UIGlassEffect(style: .regular)
        effect.tintColor = isPrivate ? Palette.privateGlassTint : Palette.glassTint
        effect.isInteractive = true
        glass.effect = effect
        overrideUserInterfaceStyle = isPrivate ? .dark : .unspecified
        glass.overrideUserInterfaceStyle = overrideUserInterfaceStyle
    }

    /// Shows `message` with an optional button, replacing a toast already up.
    func show(_ message: String, button title: String? = nil, action: (() -> Void)? = nil) {
        Signposts.signposter.emitEvent(Signposts.toast)
        label.text = message
        button.configuration?.title = title
        button.isHidden = title == nil
        self.action = action
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        superview?.layoutIfNeeded()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: FixedChoices.toastDuration)
            guard !Task.isCancelled else { return }
            self?.hide(animated: true)
        }
        UIAccessibility.post(notification: .announcement, argument: message)
        guard !isShowing else { return }
        isShowing = true
        isHidden = false
        if !Motion.prefersCrossfade { transform = CGAffineTransform(translationX: 0, y: 12) }
        Motion.animate(Motion.reflow) {
            self.alpha = 1
            self.transform = .identity
        }
    }

    func hide(animated: Bool) {
        hideTask?.cancel()
        hideTask = nil
        action = nil
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

extension UIFont {
    fileprivate func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
#endif
