#if canImport(UIKit)
import DesignSystem
import UIKit

/// The URL pill: a paper-tinted glass capsule at the bottom (Brand/identity.md, URL bar).
///
/// Resting, it shows the page's host and the load progress; a tap asks to edit it and a long
/// press opens the page menu. Editing, it is the search field, with the mint-to-blue focus rim.
/// The same view does both, so focusing is the bar growing, not a second view appearing.
///
/// Collapsed (`isCompact`), it takes taps only: it sits in the home-indicator zone, where swipes
/// and holds belong to the system. Every other gesture attaches to the expanded pill.
final class AddressPill: UIView, UIContextMenuInteractionDelegate {
    let textField = UITextField()
    let progressBar = ProgressBar()
    private let glass = Glass.makeView(shape: .capsule, interactive: true)
    private let hostLabel = UILabel()
    private let rim = GradientView()
    private let rimMask = CAShapeLayer()

    /// A tap on the resting pill.
    var onTap: () -> Void = {}
    /// The page menu for a long press, or nil when there is no page.
    var menuProvider: () -> UIMenu? = { nil }

    private(set) var isEditing = false
    /// The bar is collapsed, or on its way there: only the tap works.
    var isCompact = false
    private var url: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        hostLabel.font = .preferredFont(forTextStyle: .body)
        hostLabel.adjustsFontForContentSizeCategory = true
        hostLabel.textAlignment = .center
        hostLabel.lineBreakMode = .byTruncatingHead
        hostLabel.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(hostLabel)

        textField.accessibilityIdentifier = "searchField"
        textField.placeholder = "Search or enter address"
        // Darker than the system placeholder, which washes out on paper glass.
        textField.attributedPlaceholder = NSAttributedString(
            string: "Search or enter address", attributes: [.foregroundColor: Palette.textSecondary]
        )
        textField.font = .preferredFont(forTextStyle: .body)
        textField.adjustsFontForContentSizeCategory = true
        textField.textColor = Palette.textPrimary
        textField.keyboardType = .webSearch
        textField.returnKeyType = .go
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.smartInsertDeleteType = .no
        textField.clearButtonMode = .whileEditing
        textField.enablesReturnKeyAutomatically = false
        textField.translatesAutoresizingMaskIntoConstraints = false
        // A long address must scroll inside the field, never widen the pill: the pill's width
        // (750 in the shell) has to beat the text's natural width.
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        glass.contentView.addSubview(textField)

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(progressBar)

        rim.isUserInteractionEnabled = false
        rim.gradient.startPoint = CGPoint(x: 0, y: 0.5)
        rim.gradient.endPoint = CGPoint(x: 1, y: 0.5)
        rimMask.fillColor = nil
        rimMask.strokeColor = UIColor.black.cgColor
        rimMask.lineWidth = 2
        rim.layer.mask = rimMask
        rim.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rim)
        resolveColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (pill: AddressPill, _) in pill.resolveColors() }

        let radius = ChromeGeometry.pillHeight / 2
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            rim.topAnchor.constraint(equalTo: topAnchor),
            rim.bottomAnchor.constraint(equalTo: bottomAnchor),
            rim.leadingAnchor.constraint(equalTo: leadingAnchor),
            rim.trailingAnchor.constraint(equalTo: trailingAnchor),

            hostLabel.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
            hostLabel.centerXAnchor.constraint(equalTo: glass.contentView.centerXAnchor),
            hostLabel.leadingAnchor.constraint(greaterThanOrEqualTo: glass.contentView.leadingAnchor, constant: Spacing.l),
            hostLabel.trailingAnchor.constraint(lessThanOrEqualTo: glass.contentView.trailingAnchor, constant: -Spacing.l),

            textField.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            textField.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            textField.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: Spacing.l + Spacing.xs),
            textField.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -Spacing.s),

            // Along the bottom edge, inside the capsule's straight run.
            progressBar.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: radius - Spacing.xs),
            progressBar.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -(radius - Spacing.xs)),
            progressBar.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -Spacing.xxs),
            progressBar.heightAnchor.constraint(equalToConstant: 2.5),
        ])
        progressBar.layer.cornerRadius = 1.25

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addInteraction(UIContextMenuInteraction(delegate: self))

        accessibilityIdentifier = "addressPill"
        accessibilityLabel = "Address"
        accessibilityTraits = .button
        accessibilityHint = "Search or enter an address. Long press for page actions."
        setEditing(false)
        display(url: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = rimMask.lineWidth / 2
        let shape = bounds.insetBy(dx: inset, dy: inset)
        rimMask.frame = bounds
        rimMask.path = UIBezierPath(roundedRect: shape, cornerRadius: shape.height / 2).cgPath
    }

    private func resolveColors() {
        rim.gradient.colors = Palette.focusRim.map { $0.resolvedColor(with: traitCollection).cgColor }
    }

    /// Shows `url`'s host while resting, or the placeholder when there is no page. A page that is
    /// not secure (http, mixed content, a certificate the user chose to pass) says so before the
    /// host, as Safari does.
    func display(url: URL?, notSecure: Bool = false) {
        self.url = url
        if let url, let host = url.host(), !host.isEmpty {
            let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if notSecure {
                let text = NSMutableAttributedString(
                    string: "Not Secure — ", attributes: [.foregroundColor: Palette.textSecondary]
                )
                text.append(NSAttributedString(string: name, attributes: [.foregroundColor: Palette.textPrimary]))
                hostLabel.attributedText = text
            } else {
                hostLabel.text = name
                hostLabel.textColor = Palette.textPrimary
            }
        } else if let url {
            hostLabel.text = url.absoluteString
            hostLabel.textColor = Palette.textPrimary
        } else {
            hostLabel.text = textField.placeholder
            hostLabel.textColor = Palette.textSecondary
        }
        accessibilityValue = url?.absoluteString ?? hostLabel.text
    }

    /// Switches between the resting pill and the search field. Animatable: call it inside an
    /// animation block to cross over with the move.
    func setEditing(_ editing: Bool) {
        isEditing = editing
        // The host and the full address swap at once: crossfading them reads as doubled text.
        UIView.performWithoutAnimation {
            hostLabel.alpha = editing ? 0 : 1
            textField.alpha = editing ? 1 : 0
        }
        textField.isUserInteractionEnabled = editing
        rim.alpha = editing ? 1 : 0
        progressBar.isHidden = editing
        // Resting, the pill is one button for VoiceOver; editing, the field inside is reachable.
        isAccessibilityElement = !editing
    }

    /// Makes the field first responder. Resting, the field takes no touches (taps belong to the
    /// pill), and a field without interaction cannot become first responder, so allow it first.
    @discardableResult
    func beginEditing() -> Bool {
        textField.isUserInteractionEnabled = true
        return textField.becomeFirstResponder()
    }

    /// Collapsed, only the tap begins: no hold, no swipe (the context menu's and any later
    /// gesture's recognizers are turned away here, in one place).
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard isCompact, !isEditing else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        return gestureRecognizer is UITapGestureRecognizer && gestureRecognizer.view === self
    }

    @objc private func tapped() {
        guard !isEditing else { return }
        onTap()
    }

    // MARK: UIContextMenuInteractionDelegate

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard !isEditing, !isCompact, let menu = menuProvider() else { return nil }
        let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
        // The same top-to-bottom order wherever the menu opens, app items last.
        configuration.preferredMenuElementOrder = .fixed
        return configuration
    }
}
#endif
