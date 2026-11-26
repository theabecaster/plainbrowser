#if canImport(UIKit)
import DesignSystem
import UIKit

/// The gallery's floating bar: the gallery menu, New Tab and Done, on one glass capsule.
final class GalleryBottomBar: UIView {
    let menuButton = UIButton(type: .system)
    let newTabButton = UIButton(type: .system)
    let doneButton = UIButton(type: .system)
    private let glass = Glass.makeView(shape: .capsule, tint: Palette.glassTintOnPaper)

    private static let height: CGFloat = 52
    private static let padding: CGFloat = 4

    override init(frame: CGRect) {
        super.init(frame: frame)
        Glass.addShadow(to: self)
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

        for button in [menuButton, newTabButton, doneButton] {
            button.tintColor = Palette.accentOnGlass
            glass.contentView.addSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let done = max(Metrics.tapTarget, doneButton.sizeThatFits(size).width)
        let width = Self.padding * 2 + Metrics.tapTarget * 2 + done + Spacing.xl * 2
        return CGSize(width: width, height: Self.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        Glass.updateShadowPath(of: self)
        let side = Metrics.tapTarget
        let y = ((bounds.height - side) / 2).rounded()
        menuButton.frame = CGRect(x: Self.padding, y: y, width: side, height: side)
        newTabButton.frame = CGRect(x: menuButton.frame.maxX + Spacing.xl, y: y, width: side, height: side)
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
        Glass.addShadow(to: self)
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
        Glass.updateShadowPath(of: self)
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

    override init(frame: CGRect) {
        super.init(frame: frame)
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

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let text = label.sizeThatFits(CGSize(width: size.width, height: .greatestFiniteMagnitude))
        let buttonSize = button.sizeThatFits(size)
        return CGSize(width: size.width, height: ceil(text.height) + Spacing.l + max(Metrics.tapTarget, buttonSize.height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let text = label.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        label.frame = CGRect(x: 0, y: 0, width: bounds.width, height: ceil(text.height))
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
