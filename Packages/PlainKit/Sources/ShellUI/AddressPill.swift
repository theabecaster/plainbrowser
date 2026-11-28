#if canImport(UIKit)
import BrowserCore
import DesignSystem
import UIKit

/// The URL pill: a paper-tinted glass capsule at the bottom (Brand/identity.md, URL bar).
///
/// Resting, it shows the page's host and the load progress; a tap opens the search and a long
/// press the page sheet. Editing, it is the search field, with the mint-to-blue focus rim.
/// The same view does both, so focusing is the bar growing, not a second view appearing.
///
/// Collapsed (`isCompact`), it takes taps only: it sits in the home-indicator zone, where swipes
/// and holds belong to the system. Every other gesture attaches to the expanded pill.
final class AddressPill: UIView {
    let textField = UITextField()
    let progressBar = ProgressBar()
    private let glass = Glass.makeView(shape: .capsule, interactive: true)
    /// The soft paper glow under the glass, so the host reads over any page.
    private let scrim = ChromeScrim()
    private let hostLabel = UILabel()
    private let rim = GradientView()
    private let rimMask = CAShapeLayer()

    /// A tap on the resting pill.
    var onTap: () -> Void = {}
    /// A long press on the resting pill: the page sheet.
    var onLongPress: () -> Void = {}
    /// Copy inside the field, while it edits the page's own address.
    var onCopy: () -> Void = {}
    private lazy var copyButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "link")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body)
        configuration.baseForegroundColor = Palette.accentOnGlass
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Spacing.s, bottom: 0, trailing: Spacing.s)
        let button = UIButton(configuration: configuration)
        button.frame = CGRect(x: 0, y: 0, width: Metrics.tapTarget, height: Metrics.tapTarget)
        button.accessibilityLabel = String(localized: "Copy Link")
        button.accessibilityIdentifier = "field.copy"
        button.addAction(UIAction { [weak self] _ in self?.copyTapped() }, for: .touchUpInside)
        return button
    }()
    private var copyToken = 0

    private(set) var isEditing = false
    /// The bar is collapsed, or on its way there: only the tap works.
    var isCompact = false
    private var url: URL?
    private var notSecure = false
    /// What the resting pill says, and its short form for a pill too narrow for it.
    private var restingText: NSAttributedString?
    private var compactText: NSAttributedString?
    /// The glass has the private tint (`setPrivate`).
    var isPrivateTint = false
    /// The neighbour tab's host, sliding in during a bar swipe.
    private var incomingHost: UILabel?

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrim.frame = bounds
        scrim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(scrim)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        // The resting capsule keeps its height, so its host stops growing at the largest
        // non-accessibility size, as Safari's address field does: past it the text overflowed the
        // capsule and the head truncation left "…Secure — host". The field being typed in is not
        // capped: what the user types keeps their text size, and the field scrolls sideways.
        hostLabel.maximumContentSizeCategory = .extraExtraExtraLarge

        hostLabel.font = .preferredFont(forTextStyle: .body)
        hostLabel.adjustsFontForContentSizeCategory = true
        hostLabel.textAlignment = .center
        hostLabel.lineBreakMode = .byTruncatingHead
        hostLabel.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(hostLabel)
        // The hosts slide inside the capsule during a bar swipe, never past it.
        glass.contentView.clipsToBounds = true

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
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:))))

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
        scrim.shapes = [bounds]
        fitHostText()
    }

    /// A narrow pill (the inner screen's portrait with the side pane open) has no room for
    /// "Not Secure — host": cut at the head it read "…ure — localhost". There the warning
    /// becomes its symbol and the host stays whole.
    private func fitHostText() {
        guard notSecure, let full = restingText, let compact = compactText, hostLabel.bounds.width > 0 else { return }
        let fits = ceil(full.size().width) <= hostLabel.bounds.width
        let wanted = fits ? full : compact
        if hostLabel.attributedText != wanted { hostLabel.attributedText = wanted }
    }

    private func resolveColors() {
        rim.gradient.colors = Palette.focusRim.map { $0.resolvedColor(with: traitCollection).cgColor }
    }

    /// Shows `url`'s host while resting, or the placeholder when there is no page. A page that is
    /// not secure (http, mixed content, a certificate the user chose to pass) says so before the
    /// host, as Safari does.
    func display(url: URL?, notSecure: Bool = false) {
        self.url = url
        self.notSecure = notSecure
        let text = Self.hostText(
            for: url, query: url.flatMap(searchQuery), notSecure: notSecure, placeholder: textField.placeholder ?? ""
        )
        restingText = text
        compactText = notSecure ? Self.compactNotSecureText(for: url, font: hostLabel.font) : nil
        hostLabel.attributedText = text
        fitHostText()
        accessibilityValue = url?.absoluteString ?? text.string
    }

    /// The query a page searches for when it is the search engine's results page (the shell
    /// answers from Settings' engine), so the pill reads what was searched, as Safari's does.
    var searchQuery: (URL) -> String? = { _ in nil }

    /// What the resting pill says for `url`: the search on the engine's results page, otherwise
    /// its host without `www.`, after "Not Secure —" when the page is not secure; the placeholder
    /// without a page.
    private static func hostText(for url: URL?, query: String? = nil, notSecure: Bool, placeholder: String) -> NSAttributedString {
        if let query, !notSecure {
            return NSAttributedString(string: query, attributes: [.foregroundColor: Palette.textPrimary])
        }
        if let url, let host = url.host(), !host.isEmpty {
            let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            guard notSecure else {
                return NSAttributedString(string: name, attributes: [.foregroundColor: Palette.textPrimary])
            }
            let text = NSMutableAttributedString(string: "Not Secure — ", attributes: [.foregroundColor: Palette.textSecondary])
            text.append(NSAttributedString(string: name, attributes: [.foregroundColor: Palette.textPrimary]))
            return text
        } else if let url {
            return NSAttributedString(string: url.absoluteString, attributes: [.foregroundColor: Palette.textPrimary])
        }
        return NSAttributedString(string: placeholder, attributes: [.foregroundColor: Palette.textSecondary])
    }

    /// "Not Secure — host" for a pill too narrow for the words: the warning's symbol, then the host.
    private static func compactNotSecureText(for url: URL?, font: UIFont) -> NSAttributedString? {
        guard let host = url?.host(), !host.isEmpty else { return nil }
        let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let symbol = UIImage(
            systemName: "exclamationmark.triangle", withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small)
        )?.withTintColor(Palette.textSecondary, renderingMode: .alwaysOriginal)
        let text = NSMutableAttributedString()
        if let symbol { text.append(NSAttributedString(attachment: NSTextAttachment(image: symbol))) }
        text.append(NSAttributedString(string: " " + name, attributes: [.foregroundColor: Palette.textPrimary]))
        return text
    }

    /// The glass tint: Paper, or the quiet private tint while a private tab is on screen.
    func setPrivate(_ isPrivate: Bool) {
        let effect = UIGlassEffect(style: .regular)
        effect.tintColor = isPrivate ? Palette.privateGlassTint : Palette.glassTint
        effect.isInteractive = true
        glass.effect = effect
        scrim.isPrivate = isPrivate
        accessibilityLabel = isPrivate ? "Private Address" : "Address"
    }

    // MARK: Bar swipe

    /// How fast the hosts fade per unit of swipe: each is fully gone or in by 80% of the way, and
    /// both show at half opacity or more around the middle, so the pill never reads empty.
    private static let hostFadeRate: CGFloat = 1.25

    /// Starts a bar swipe toward the tab showing `url`: its host waits beside the current one,
    /// inside the glass, which itself never moves.
    func beginHostSlide(to url: URL?) {
        incomingHost?.removeFromSuperview()
        let label = UILabel()
        label.font = hostLabel.font
        label.adjustsFontForContentSizeCategory = true
        label.maximumContentSizeCategory = hostLabel.maximumContentSizeCategory
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingHead
        label.attributedText = Self.hostText(for: url, query: url.flatMap(searchQuery), notSecure: false, placeholder: "New Tab")
        label.alpha = 0
        label.isAccessibilityElement = false
        let height = max(hostLabel.bounds.height, label.font.lineHeight)
        label.frame = CGRect(
            x: Spacing.l, y: (hostLabel.center.y - height / 2).rounded(),
            width: max(0, bounds.width - Spacing.l * 2), height: height
        )
        glass.contentView.addSubview(label)
        incomingHost = label
    }

    /// Moves the hosts with the page: `progress` is the page's offset over its width (negative
    /// toward the next tab). The current host slides and fades out, the neighbour's in.
    func slideHost(progress: CGFloat) {
        let travel = bounds.width * 0.5
        let p = min(max(progress, -1), 1)
        hostLabel.transform = CGAffineTransform(translationX: p * travel, y: 0)
        // A crossfade that overlaps, so some host always reads mid-swipe.
        hostLabel.alpha = max(0, 1 - abs(p) * Self.hostFadeRate)
        guard let incoming = incomingHost else { return }
        let side: CGFloat = p < 0 ? 1 : -1
        incoming.transform = CGAffineTransform(translationX: (p + side) * travel, y: 0)
        incoming.alpha = min(1, abs(p) * Self.hostFadeRate)
    }

    /// Ends a bar swipe: the current host comes back (the new tab's host arrives through
    /// `display(url:)` when it switched).
    func endHostSlide() {
        incomingHost?.removeFromSuperview()
        incomingHost = nil
        hostLabel.transform = .identity
        hostLabel.alpha = isEditing ? 0 : 1
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

    /// Shows Copy inside the field (editing the page's own address) in place of the clear
    /// button, or takes it away. No layout: the field's text area keeps its frame either way
    /// within the pill.
    func setCopyShown(_ shown: Bool) {
        let showing = textField.rightView != nil && textField.rightViewMode == .always
        guard shown != showing else { return }
        if shown {
            copyToken += 1
            setCopyGlyph(copied: false)
            textField.rightView = copyButton
            textField.rightViewMode = .always
            textField.clearButtonMode = .never
        } else {
            textField.rightView = nil
            textField.rightViewMode = .never
            textField.clearButtonMode = .whileEditing
        }
    }

    private func copyTapped() {
        onCopy()
        copyToken += 1
        let token = copyToken
        setCopyGlyph(copied: true)
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Copied"))
        DispatchQueue.main.asyncAfter(deadline: .now() + FixedChoices.copiedConfirmation) { [weak self] in
            guard let self, self.copyToken == token else { return }
            self.setCopyGlyph(copied: false)
        }
    }

    /// The copy glyph, or a check mark for a moment after a copy: same size, so nothing moves.
    private func setCopyGlyph(copied: Bool) {
        copyButton.configuration?.image = UIImage(systemName: copied ? "checkmark" : "link")
        copyButton.accessibilityLabel = copied ? String(localized: "Copied") : String(localized: "Copy Link")
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

    @objc private func pressed(_ press: UILongPressGestureRecognizer) {
        guard press.state == .began, !isEditing, !isCompact else { return }
        Haptic.threshold.play()
        onLongPress()
    }
}
#endif
