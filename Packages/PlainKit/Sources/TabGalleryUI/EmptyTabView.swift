#if canImport(UIKit)
import DesignSystem
import PerfSignposts
import UIKit

/// What an empty tab shows (and the gallery when a list is empty): the mark in the space above the
/// keyboard and the search field, one sentence, and one main button while the keyboard is down
/// (docs/ui-reference.md: an empty state is one sentence and one main button). Spin the mark and
/// it turns; nothing else moves on its own.
public final class EmptyTabView: UIView {
    /// The sentence under the mark.
    public var message: String {
        get { label.text ?? "" }
        set { label.text = newValue }
    }

    /// The main button's title; nil hides it.
    public var buttonTitle: String? {
        didSet { applyButton() }
    }

    /// The main button was tapped.
    public var onAction: (() -> Void)?

    /// Room kept free above the keyboard (or the bottom edge) for the controls that sit there: the
    /// search field and the favorites strip.
    public var bottomReserve: CGFloat = 0 {
        didSet { reserve.constant = -bottomReserve }
    }

    public let mark = MarkView()
    private let label = UILabel()
    private let button = UIButton(type: .system)
    private let stack = UIStackView()
    private let region = UILayoutGuide()
    private var reserve: NSLayoutConstraint!
    private var keyboardUp = false
    private let glow = CAGradientLayer()
    private var accessory: UIView?

    /// The mark's width: large, the one thing on the screen (Arc's start screen shows its logo the
    /// same way).
    public static let markSize: CGFloat = 132

    override public init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "emptyTab"
        // Opaque: an empty tab's blank web view is under it. Paper warming toward Lagoon at the
        // bottom, a quiet dawn behind the mark.
        backgroundColor = Palette.background
        glow.locations = [0.35, 1]
        layer.addSublayer(glow)
        applyGlow()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: EmptyTabView, _) in view.applyGlow() }
        mark.isSpinnable = true
        mark.translatesAutoresizingMaskIntoConstraints = false

        label.text = String(localized: "Start with a search or an address.")
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Palette.textSecondary
        label.textAlignment = .center
        label.numberOfLines = 0

        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = Palette.accent
        configuration.cornerStyle = .capsule
        configuration.contentInsets = .init(top: Spacing.m, leading: Spacing.xl, bottom: Spacing.m, trailing: Spacing.xl)
        button.configuration = configuration
        button.accessibilityIdentifier = "emptyTabAction"
        button.addAction(UIAction { [weak self] _ in self?.onAction?() }, for: .primaryActionTriggered)

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Spacing.l
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [mark, label, button] { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(Spacing.xl, after: mark)
        addSubview(stack)
        addLayoutGuide(region)

        reserve = region.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor)
        let centered = stack.centerYAnchor.constraint(equalTo: region.centerYAnchor)
        centered.priority = .defaultHigh
        NSLayoutConstraint.activate([
            region.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            region.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            region.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            reserve,
            centered,
            stack.topAnchor.constraint(greaterThanOrEqualTo: region.topAnchor, constant: Spacing.l),
            stack.centerXAnchor.constraint(equalTo: region.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: region.widthAnchor, constant: -Spacing.xl * 2),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            mark.widthAnchor.constraint(equalToConstant: Self.markSize),
            mark.heightAnchor.constraint(equalToConstant: (Self.markSize / MarkView.aspect).rounded()),
        ])
        // The button only while the keyboard is down: with it up, the field is the action.
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide), name: UIResponder.keyboardWillHideNotification, object: nil)
        applyButton()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A card that sits under the sentence, above the search field (a "Set as Default Browser"
    /// offer, say). One at most; nil removes it.
    public func setAccessory(_ view: UIView?) {
        accessory?.removeFromSuperview()
        accessory = view
        guard let view else { return }
        stack.insertArrangedSubview(view, at: stack.arrangedSubviews.count - 1)
        stack.setCustomSpacing(Spacing.xl, after: label)
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        if glow.frame != bounds {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glow.frame = bounds
            CATransaction.commit()
        }
    }

    private func applyGlow() {
        glow.colors = [UIColor.clear.cgColor, Palette.startGlow.resolvedColor(with: traitCollection).cgColor]
    }

    @objc private func keyboardWillShow() {
        keyboardUp = true
        applyButton()
    }

    @objc private func keyboardWillHide() {
        keyboardUp = false
        applyButton()
    }

    private func applyButton() {
        button.configuration?.title = buttonTitle
        let hidden = buttonTitle == nil || keyboardUp
        guard button.alpha != (hidden ? 0 : 1) else { return }
        Motion.animate(Motion.quick) { self.button.alpha = hidden ? 0 : 1 }
        button.isUserInteractionEnabled = !hidden
    }
}
#endif
