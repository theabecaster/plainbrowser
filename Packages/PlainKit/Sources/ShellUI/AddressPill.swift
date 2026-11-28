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
///
/// At its leading edge, while Dark Pages is applied to the page (or the user turned it off on
/// this site), a small indicator toggles it for the site (docs/state-rules.md, section 3).
final class AddressPill: UIView {
    let textField: UITextField = AddressField()
    /// Escape on a hardware keyboard, while the field has the keyboard.
    var onEscape: () -> Void {
        get { (textField as? AddressField)?.onEscape ?? {} }
        set { (textField as? AddressField)?.onEscape = newValue }
    }
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
    /// Copy inside the field, while it shows the page's own address untouched.
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
        // Inside its 44 pt target at the accessibility sizes too.
        button.maximumContentSizeCategory = .extraExtraExtraLarge
        button.addAction(UIAction { [weak self] _ in self?.copyTapped() }, for: .touchUpInside)
        return button
    }()
    private var copyToken = 0

    /// What sits at the field's trailing end (docs/research/arc-address-expand.md): Arc Search's
    /// field shows a microphone and a second option while empty, and a clear button once typed in.
    enum Accessory: Equatable {
        /// Nothing of Plain's: the system's clear button shows while there is text.
        case none
        /// Copy, while the field shows the page's own address untouched.
        case copy
        /// The empty field's options: dictation, and Browse for Me (armed: Return browses).
        case options(mic: Bool, browse: Bool, armed: Bool)
        /// Dictation is listening: the microphone, filled; a tap stops it.
        case dictating
    }

    private(set) var accessory = Accessory.none
    /// The microphone in the field: start dictation, or stop it.
    var onMic: () -> Void = {}
    /// Browse for Me in the empty field: arm it, or disarm it.
    var onBrowse: () -> Void = {}
    private lazy var micButton = makeOption(symbol: "mic", identifier: "field.mic", label: String(localized: "Dictate")) { [weak self] in
        self?.onMic()
    }
    private lazy var browseButton = makeOption(
        symbol: "binoculars", identifier: "field.browse", label: String(localized: "Browse for Me")
    ) { [weak self] in
        self?.onBrowse()
    }
    private lazy var optionsView = UIView()
    /// Behind the binoculars while Browse for Me is armed: the state stays plain while typing, when
    /// the placeholder that names it is gone.
    private lazy var armedBacking: UIView = {
        let side: CGFloat = 28
        let backing = UIView(frame: CGRect(x: 0, y: 0, width: side, height: side))
        backing.backgroundColor = Palette.accentOnGlass.withAlphaComponent(0.2)
        backing.layer.cornerRadius = side / 2
        backing.isUserInteractionEnabled = false
        backing.isHidden = true
        backing.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        return backing
    }()

    /// A tap on the Dark Pages indicator.
    var onDarkPagesTap: () -> Void = {}
    /// The Dark Pages indicator: `circle.lefthalf.filled`, Apple's Dark Mode symbol, in the
    /// accent while on and in the ink while off (a working switch, not a disabled one).
    private lazy var darkPagesButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "circle.lefthalf.filled")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium)
        configuration.contentInsets = .zero
        let button = UIButton(configuration: configuration)
        button.maximumContentSizeCategory = .extraExtraExtraLarge
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityIdentifier = "pill.darkPages"
        button.accessibilityLabel = String(localized: "Dark Pages")
        button.addAction(UIAction { [weak self] _ in self?.onDarkPagesTap() }, for: .primaryActionTriggered)
        button.alpha = 0
        button.isHidden = true
        return button
    }()
    /// What the indicator shows (`setDarkPages`).
    private(set) var darkPagesIndicator = DarkPagesIndicator.hidden
    /// The host gives way to the right of the indicator while it shows.
    private var hostClearsIndicator: NSLayoutConstraint?
    /// The resting pill for VoiceOver while the indicator is its own element beside it.
    private lazy var addressElement = PillAccessibilityElement(pill: self)

    private(set) var isEditing = false
    /// The bar is collapsed, or on its way there: only the tap works (and the indicator hides).
    var isCompact = false {
        didSet { if isCompact != oldValue { updateDarkPagesVisibility(animated: true) } }
    }
    /// A bar swipe between tabs is moving the hosts: the indicator belongs to the page leaving.
    private var isSlidingHost = false
    /// The resting pill's identifier, and the group's while the indicator and the stand-in show.
    static let identifier = "addressPill"
    static let groupIdentifier = "addressPillGroup"
    private var url: URL?
    private var notSecure = false
    /// The reader is open over the page, or the page is translated (`setMode`).
    private var isReader = false
    private var isTranslated = false
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
        rim.alpha = 0
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
            // Centered unless the indicator is in the way: a host shifts before it truncates.
            {
                let center = hostLabel.centerXAnchor.constraint(equalTo: glass.contentView.centerXAnchor)
                center.priority = UILayoutPriority(740)
                return center
            }(),
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

        glass.contentView.addSubview(darkPagesButton)
        NSLayoutConstraint.activate([
            darkPagesButton.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: Spacing.xxs),
            darkPagesButton.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
            darkPagesButton.widthAnchor.constraint(equalToConstant: Metrics.tapTarget),
            darkPagesButton.heightAnchor.constraint(equalToConstant: Metrics.tapTarget),
        ])
        hostClearsIndicator = hostLabel.leadingAnchor.constraint(greaterThanOrEqualTo: darkPagesButton.trailingAnchor)

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:))))

        accessibilityIdentifier = Self.identifier
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
        addressElement.accessibilityFrameInContainerSpace = bounds
    }

    // MARK: Dark Pages indicator

    /// Shows the Dark Pages indicator on (accent) or off (ink), or takes it away (the state rules'
    /// answer, `ControlRules.darkPagesIndicator`). It fades; nothing else moves unless the host
    /// was long enough to run under it.
    func setDarkPages(_ indicator: DarkPagesIndicator, animated: Bool) {
        guard indicator != darkPagesIndicator else { return }
        darkPagesIndicator = indicator
        if indicator != .hidden {
            darkPagesButton.configuration?.baseForegroundColor = indicator == .on ? Palette.accentOnGlass : Palette.textPrimary
            darkPagesButton.accessibilityValue = indicator == .on ? String(localized: "On") : String(localized: "Off")
            darkPagesButton.accessibilityHint = indicator == .on
                ? String(localized: "Turns Dark Pages off for this site.")
                : String(localized: "Turns Dark Pages on for this site.")
        }
        updateDarkPagesVisibility(animated: animated)
    }

    /// The indicator is visible: it applies, the pill rests whole, and no bar swipe is moving.
    private var showsDarkPages: Bool {
        darkPagesIndicator != .hidden && !isEditing && !isCompact && !isSlidingHost
    }

    private func updateDarkPagesVisibility(animated: Bool) {
        let shows = showsDarkPages
        hostClearsIndicator?.isActive = shows
        updateAccessibilityElements()
        let changes = {
            self.darkPagesButton.alpha = shows ? 1 : 0
            self.glass.contentView.layoutIfNeeded()
        }
        if shows { darkPagesButton.isHidden = false }
        let finish: () -> Void = { [weak self] in
            guard let self, !self.showsDarkPages else { return }
            self.darkPagesButton.isHidden = true
        }
        guard animated, window != nil else {
            UIView.performWithoutAnimation(changes)
            finish()
            return
        }
        Motion.animate(Motion.quick, changes: changes, completion: finish)
    }

    /// Resting, the pill is one "Address" button for VoiceOver; with the indicator showing, the
    /// indicator and a stand-in for that button (same name, value, hint and identifier) side by
    /// side; editing, the field inside is reachable.
    private func updateAccessibilityElements() {
        // The stand-in carries the "addressPill" identifier while it stands in, so there is one
        // address button, never two.
        if isEditing {
            isAccessibilityElement = false
            accessibilityElements = nil
            accessibilityIdentifier = Self.identifier
        } else if showsDarkPages {
            isAccessibilityElement = false
            accessibilityElements = [darkPagesButton, addressElement]
            accessibilityIdentifier = Self.groupIdentifier
        } else {
            accessibilityElements = nil
            isAccessibilityElement = true
            accessibilityIdentifier = Self.identifier
        }
    }

    /// A tap from VoiceOver on the stand-in.
    fileprivate func activateFromAccessibility() {
        guard !isEditing else { return }
        onTap()
    }

    private func resolveColors() {
        rim.gradient.colors = Palette.focusRim.map { $0.resolvedColor(with: traitCollection).cgColor }
    }

    /// Shows `url`'s host while resting, or the placeholder when there is no page. A page that is
    /// not secure (http, mixed content, a certificate the user chose to pass) says so before the
    /// host, as Safari does; so does a page in a mode (`setMode`), in the same quiet word.
    func display(url: URL?, notSecure: Bool = false) {
        self.url = url
        self.notSecure = notSecure
        hostLabel.attributedText = Self.hostText(
            for: url, query: url.flatMap(searchQuery), lead: lead, placeholder: "Search or enter address",
            isPrivate: isPrivateTint
        )
        // VoiceOver hears a mode as the pill shows it ("Reader, https://…"), without the private
        // mark's attachment character: the label already says Private.
        let mode = lead == .reader || lead == .translated ? lead?.word : nil
        let shown = hostLabel.text?.replacingOccurrences(of: "\u{FFFC} ", with: "")
        accessibilityValue = [mode, url?.absoluteString ?? shown].compactMap { $0 }.joined(separator: ", ")
    }

    /// The reader is open, or the page is translated: the pill names the mode in place of the
    /// security word ("Reader — host"), so the page's mode shows where its address does. Called
    /// with each chrome update; only a change draws again.
    func setMode(reader: Bool, translated: Bool) {
        guard reader != isReader || translated != isTranslated else { return }
        isReader = reader
        isTranslated = translated
        display(url: url, notSecure: notSecure)
    }

    /// The one lead word for the page on screen (`PillLead`: Private, then Reader or Translated,
    /// then Not Secure). Private draws as its own mark and word ahead of it (`hostText`'s
    /// `isPrivate`), so a private page still says Reader or Not Secure after "Private".
    private var lead: PillLead? {
        PillLead.resolve(isPrivate: false, isReader: isReader, isTranslated: isTranslated, notSecure: notSecure)
    }

    /// The query a page searches for when it is the search engine's results page (the shell
    /// answers from Settings' engine), so the pill reads what was searched, as Safari's does.
    var searchQuery: (URL) -> String? = { _ in nil }

    /// What the resting pill says for `url`: the search on the engine's results page, otherwise
    /// its host without `www.`, after the lead word ("Not Secure —", "Reader —") when there is
    /// one; the placeholder without a page. Private, the private mark and word lead, whatever follows.
    private static func hostText(
        for url: URL?, query: String? = nil, lead: PillLead?, placeholder: String, isPrivate: Bool
    ) -> NSAttributedString {
        let text = hostText(for: url, query: query, lead: lead, placeholder: placeholder)
        guard isPrivate else { return text }
        let marked = NSMutableAttributedString(attachment: privateMark())
        marked.append(NSAttributedString(string: " "))
        // On a page the word says it too (design review: the mark alone asked people to guess).
        // Not over the placeholder: the empty private tab's screen says Private already.
        if url != nil {
            // Headline: the body size, semibold.
            marked.append(NSAttributedString(
                string: String(localized: "Private"),
                attributes: [.foregroundColor: Palette.privateAccent, .font: UIFont.preferredFont(forTextStyle: .headline, compatibleWith: cappedTraits)]
            ))
            marked.append(NSAttributedString(string: "  ", attributes: [.foregroundColor: Palette.privateAccent]))
        }
        // The night's text colors, fixed: the private glass is always dark, whatever the glass
        // decides from the page behind it.
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        let light = NSMutableAttributedString(attributedString: text)
        light.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: light.length)) { value, range, _ in
            if let color = value as? UIColor { light.addAttribute(.foregroundColor, value: color.resolvedColor(with: dark), range: range) }
        }
        marked.append(light)
        return marked
    }

    /// The text size the host label draws at: the user's, capped where the label is.
    private static var cappedTraits: UITraitCollection {
        let size = UITraitCollection.current.preferredContentSizeCategory
        return UITraitCollection(preferredContentSizeCategory: min(size, .extraExtraExtraLarge))
    }

    /// The private mark at the pill's text size, in the private accent, centered on the capitals.
    private static func privateMark() -> NSTextAttachment {
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: cappedTraits)
        let configuration = UIImage.SymbolConfiguration(font: font, scale: .small)
        guard let symbol = UIImage(systemName: "hand.raised.fill", withConfiguration: configuration)?
            .withTintColor(Palette.privateAccent, renderingMode: .alwaysOriginal) else { return NSTextAttachment() }
        let attachment = NSTextAttachment(image: symbol)
        attachment.bounds = CGRect(
            x: 0, y: ((font.capHeight - symbol.size.height) / 2).rounded(), width: symbol.size.width, height: symbol.size.height
        )
        return attachment
    }

    private static func hostText(for url: URL?, query: String? = nil, lead: PillLead?, placeholder: String) -> NSAttributedString {
        if let query, lead == nil {
            return NSAttributedString(string: query, attributes: [.foregroundColor: Palette.textPrimary])
        }
        if let url, let host = url.host(), !host.isEmpty {
            let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            guard let lead else {
                return NSAttributedString(string: name, attributes: [.foregroundColor: Palette.textPrimary])
            }
            let text = NSMutableAttributedString(
                string: String(localized: "\(lead.word) — "), attributes: [.foregroundColor: Palette.textSecondary]
            )
            text.append(NSAttributedString(string: name, attributes: [.foregroundColor: Palette.textPrimary]))
            return text
        } else if let url {
            return NSAttributedString(string: url.absoluteString, attributes: [.foregroundColor: Palette.textPrimary])
        }
        return NSAttributedString(string: placeholder, attributes: [.foregroundColor: Palette.textSecondary])
    }

    /// Paper glass, or the private look while a private tab is on screen: deep violet glass drawn
    /// dark (light text), the private mark before the host and in the field, and a dark keyboard
    /// that predicts and rewrites nothing (docs/decisions.md, "Private mode you can't miss").
    func setPrivate(_ isPrivate: Bool) {
        let effect = UIGlassEffect(style: .regular)
        effect.tintColor = isPrivate ? Palette.privateGlassTint : Palette.glassTint
        effect.isInteractive = true
        glass.effect = effect
        scrim.isPrivate = isPrivate
        overrideUserInterfaceStyle = isPrivate ? .dark : .unspecified
        // On the effect view too: glass picks light or dark content from what is behind it, and
        // over a white page it drew dark text on the violet. Set there, it stays dark.
        glass.overrideUserInterfaceStyle = overrideUserInterfaceStyle
        accessibilityLabel = isPrivate ? "Private Address" : "Address"
        // The field says it too, for VoiceOver while editing (the pill is no element then).
        textField.accessibilityLabel = isPrivate ? String(localized: "Private, Search or enter address") : nil
        // Private, a long host loses its middle, never the mark at its start.
        hostLabel.lineBreakMode = isPrivate ? .byTruncatingMiddle : .byTruncatingHead
        display(url: url, notSecure: notSecure)
        // The field itself too: on the search sheet it sits over the paper card, so its own
        // controls (Dictate, Browse for Me) would take the card's light style on the violet.
        textField.overrideUserInterfaceStyle = isPrivate ? .dark : .unspecified
        // The field's text too, fixed light on the always-dark private glass.
        textField.textColor = isPrivate ? .white : Palette.textPrimary
        textField.attributedPlaceholder = NSAttributedString(
            string: textField.placeholder ?? "",
            attributes: [.foregroundColor: isPrivate ? UIColor(white: 1, alpha: 0.6) : Palette.textSecondary]
        )
        if isPrivate, textField.leftView == nil { textField.leftView = makeFieldMark() }
        textField.leftViewMode = isPrivate ? .always : .never
        // iOS has no "don't learn" flag for the keyboard (docs/research/private-mode.md). The field
        // already corrects and spell-checks nothing; private, it also predicts, rewrites and
        // grammar-checks nothing, and the keyboard is dark like the bar.
        textField.keyboardAppearance = isPrivate ? .dark : .default
        textField.inlinePredictionType = isPrivate ? .no : .default
        textField.writingToolsBehavior = isPrivate ? .none : .default
        textField.grammarCheckingType = isPrivate ? .no : .default
        if textField.isFirstResponder { textField.reloadInputViews() }
    }

    /// The private mark at the field's leading edge while it edits in a private tab.
    private func makeFieldMark() -> UIView {
        let mark = UIImageView(image: UIImage(systemName: "hand.raised.fill"))
        mark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body, scale: .small)
        mark.tintColor = Palette.privateAccent
        mark.contentMode = .center
        mark.isAccessibilityElement = false
        // In a wrapper: the field sizes an image view to its image, which ran the mark into the
        // caret (design review). The wrapper keeps the gap.
        let size = mark.intrinsicContentSize
        let wrapper = UIView(frame: CGRect(x: 0, y: 0, width: size.width + Spacing.m, height: Metrics.tapTarget))
        mark.frame = CGRect(x: 0, y: ((Metrics.tapTarget - size.height) / 2).rounded(), width: size.width, height: size.height)
        wrapper.addSubview(mark)
        wrapper.isUserInteractionEnabled = false
        return wrapper
    }

    // MARK: Bar swipe

    /// How fast the hosts fade per unit of swipe: each is fully gone or in by 80% of the way, and
    /// both show at half opacity or more around the middle, so the pill never reads empty.
    private static let hostFadeRate: CGFloat = 1.25

    /// Starts a bar swipe toward the tab showing `url`: its host waits beside the current one,
    /// inside the glass, which itself never moves.
    func beginHostSlide(to url: URL?) {
        incomingHost?.removeFromSuperview()
        if !isSlidingHost {
            isSlidingHost = true
            updateDarkPagesVisibility(animated: true)
        }
        let label = UILabel()
        label.font = hostLabel.font
        label.adjustsFontForContentSizeCategory = true
        label.maximumContentSizeCategory = hostLabel.maximumContentSizeCategory
        label.textAlignment = .center
        label.lineBreakMode = hostLabel.lineBreakMode
        label.attributedText = Self.hostText(
            for: url, query: url.flatMap(searchQuery), lead: nil, placeholder: "New Tab", isPrivate: isPrivateTint
        )
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
        if isSlidingHost {
            isSlidingHost = false
            updateDarkPagesVisibility(animated: true)
        }
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
        progressBar.isHidden = editing
        // At once, with the host: the field takes the pill's whole width.
        updateDarkPagesVisibility(animated: false)
    }

    /// The focus rim follows the sheet's progress (0 resting, 1 open): alpha only.
    func setFocusProgress(_ progress: CGFloat) {
        rim.alpha = min(max(progress, 0), 1)
    }

    /// Shows `accessory` at the field's trailing end. No layout outside the field: its text area
    /// is the field's own business within the pill.
    func setAccessory(_ next: Accessory) {
        guard next != accessory else { return }
        accessory = next
        switch next {
        case .none:
            textField.rightView = nil
            textField.rightViewMode = .never
            textField.clearButtonMode = .whileEditing
        case .copy:
            copyToken += 1
            setCopyGlyph(copied: false)
            show(rightView: copyButton)
        case .options(let mic, let browse, let armed):
            setGlyph(micButton, "mic", tint: Palette.textSecondary)
            micButton.accessibilityLabel = String(localized: "Dictate")
            setGlyph(browseButton, "binoculars", tint: armed ? Palette.accentOnGlass : Palette.textSecondary)
            browseButton.accessibilityValue = armed ? String(localized: "On") : nil
            layOutOptions([mic ? micButton : nil, browse ? browseButton : nil].compactMap { $0 })
            if armedBacking.superview == nil { browseButton.insertSubview(armedBacking, at: 0) }
            armedBacking.center = CGPoint(x: Metrics.tapTarget / 2, y: Metrics.tapTarget / 2)
            armedBacking.isHidden = !armed
            show(rightView: optionsView)
        case .dictating:
            setGlyph(micButton, "mic.fill", tint: Palette.accentOnGlass)
            micButton.accessibilityLabel = String(localized: "Stop Dictation")
            layOutOptions([micButton])
            show(rightView: optionsView)
        }
        // The placeholder says what Return will do.
        let armed = if case .options(_, _, true) = next { true } else { false }
        let placeholder = armed ? String(localized: "Ask Browse for Me") : "Search or enter address"
        if textField.placeholder != placeholder {
            textField.attributedPlaceholder = NSAttributedString(
                string: placeholder, attributes: [.foregroundColor: Palette.textSecondary]
            )
        }
    }

    private func show(rightView view: UIView) {
        if textField.rightView !== view { textField.rightView = view }
        textField.rightViewMode = .always
        textField.clearButtonMode = .never
    }

    private func layOutOptions(_ buttons: [UIButton]) {
        let size = Metrics.tapTarget
        for view in optionsView.subviews where !buttons.contains(where: { $0 === view }) { view.removeFromSuperview() }
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(x: CGFloat(index) * size, y: 0, width: size, height: size)
            if button.superview !== optionsView { optionsView.addSubview(button) }
        }
        let frame = CGRect(x: 0, y: 0, width: CGFloat(buttons.count) * size, height: size)
        if optionsView.frame != frame {
            optionsView.frame = frame
            // A right view that changed size is measured again.
            if textField.rightView === optionsView { textField.rightView = nil }
        }
    }

    private func makeOption(symbol: String, identifier: String, label: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body)
        configuration.baseForegroundColor = Palette.textSecondary
        configuration.contentInsets = .zero
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
        button.maximumContentSizeCategory = .extraExtraExtraLarge
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func setGlyph(_ button: UIButton, _ symbol: String, tint: UIColor) {
        button.configuration?.image = UIImage(systemName: symbol)
        button.configuration?.baseForegroundColor = tint
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

    /// Hides the field's caret while the sheet grows (`true`), and shows it once it is at rest
    /// (`false`), so nothing but the text rides with the field.
    func holdSelectionHighlight(_ hold: Bool) {
        textField.tintColor = hold ? .clear : nil
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

/// The pill's field. Escape on a hardware keyboard is the field's own key (the text system takes
/// it before any key command up the responder chain), so it is caught here.
private final class AddressField: UITextField {
    var onEscape: () -> Void = {}

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Marked text (an input method composing): Escape is the input method's.
        if markedTextRange == nil, presses.contains(where: { $0.key?.keyCode == .keyboardEscape }) {
            onEscape()
            return
        }
        super.pressesBegan(presses, with: event)
    }
}

/// The resting pill's "Address" button for VoiceOver while the Dark Pages indicator is an element
/// of its own: it reads everything from the pill, so it never goes stale.
private final class PillAccessibilityElement: UIAccessibilityElement {
    private weak var pill: AddressPill?

    init(pill: AddressPill) {
        self.pill = pill
        super.init(accessibilityContainer: pill)
    }

    override var accessibilityLabel: String? {
        get { pill?.accessibilityLabel }
        set {}
    }

    override var accessibilityValue: String? {
        get { pill?.accessibilityValue }
        set {}
    }

    override var accessibilityHint: String? {
        get { pill?.accessibilityHint }
        set {}
    }

    override var accessibilityTraits: UIAccessibilityTraits {
        get { pill?.accessibilityTraits ?? .button }
        set {}
    }

    override var accessibilityIdentifier: String? {
        get { AddressPill.identifier }
        set {}
    }

    override func accessibilityActivate() -> Bool {
        pill?.activateFromAccessibility()
        return pill != nil
    }
}
#endif
