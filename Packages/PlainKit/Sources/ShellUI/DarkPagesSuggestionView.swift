#if canImport(UIKit)
import BrowserCore
import DesignSystem
import PerfSignposts
import UIKit

/// The one suggestion to turn Dark Pages on (docs/research/dark-pages-optin.md, "The
/// suggestion"): a small glass card by the address bar, above the pill at the bottom and under it
/// in the top bar. It asks a question with two answers, so it has a title, one sentence and two
/// worded buttons, like a TipKit tip, rather than the one-line toast. It never blocks the page.
///
/// The shell decides when it shows (`DarkPagesSuggestion`) and hides it the moment its page is no
/// longer the one on screen; the card only lays itself out, times itself out and reports.
final class DarkPagesSuggestionView: UIView {
    /// How the card went away.
    enum Outcome {
        case turnOn, noThanks, timedOut, hidden
    }

    /// Called once per showing, after it starts leaving.
    var onFinish: (Outcome) -> Void = { _ in }

    private let glass = Glass.makeView(shape: .rounded(22), interactive: true)
    private let icon = UIImageView()
    private let title = UILabel()
    private let message = UILabel()
    private let noThanks = UIButton(type: .system)
    private let turnOn = UIButton(type: .system)
    private var timeout: Task<Void, Never>?
    private(set) var isShowing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        icon.image = UIImage(systemName: "circle.lefthalf.filled")
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .large)
        icon.tintColor = Palette.accentOnGlass
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        icon.isAccessibilityElement = false

        title.text = String(localized: "Dark Pages")
        title.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: .init(preferredContentSizeCategory: .large)).pointSize, weight: .semibold)
        )
        title.adjustsFontForContentSizeCategory = true
        title.textColor = Palette.textPrimary
        title.numberOfLines = 0
        message.text = String(localized: "Show every website dark, even ones made only in light?")
        message.font = .preferredFont(forTextStyle: .subheadline)
        message.adjustsFontForContentSizeCategory = true
        // The ink, not the secondary grey: on glass the grey read as disabled. The title's weight
        // carries the hierarchy.
        message.textColor = Palette.textPrimary
        message.numberOfLines = 0

        configure(noThanks, title: String(localized: "No Thanks"), color: Palette.textPrimary, weight: .regular, id: "darkPagesSuggestion.noThanks")
        configure(turnOn, title: String(localized: "Turn On"), color: Palette.accentOnGlass, weight: .semibold, id: "darkPagesSuggestion.turnOn")
        noThanks.addAction(UIAction { [weak self] _ in self?.finish(.noThanks) }, for: .primaryActionTriggered)
        turnOn.addAction(UIAction { [weak self] _ in self?.finish(.turnOn) }, for: .primaryActionTriggered)

        let words = UIStackView(arrangedSubviews: [title, message])
        words.axis = .vertical
        words.spacing = Spacing.xxs
        let top = UIStackView(arrangedSubviews: [icon, words])
        top.alignment = .firstBaseline
        top.spacing = Spacing.s
        let buttons = UIStackView(arrangedSubviews: [UIView(), noThanks, turnOn])
        buttons.spacing = Spacing.xs
        let column = UIStackView(arrangedSubviews: [top, buttons])
        column.axis = .vertical
        column.spacing = Spacing.xs
        column.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(column)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: Spacing.m),
            column.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -Spacing.xs),
            column.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: Spacing.l),
            column.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -Spacing.s),
        ])

        // VoiceOver reads the card as one sentence, then its two buttons.
        let words11y = UIAccessibilityElement(accessibilityContainer: self)
        words11y.accessibilityLabel = String(localized: "Dark Pages. Show every website dark, even ones made only in light?")
        wordsElement = words11y
        accessibilityIdentifier = "darkPagesSuggestion"
        alpha = 0
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var wordsElement: UIAccessibilityElement?

    override func layoutSubviews() {
        super.layoutSubviews()
        var elements: [Any] = []
        if let wordsElement, let words = title.superview {
            wordsElement.accessibilityFrameInContainerSpace = words.convert(words.bounds, to: self)
            elements.append(wordsElement)
        }
        accessibilityElements = elements + [noThanks, turnOn]
    }

    private func configure(_ button: UIButton, title: String, color: UIColor, weight: UIFont.Weight, id: String) {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.baseForegroundColor = color
        configuration.contentInsets = .init(top: 0, leading: Spacing.s, bottom: 0, trailing: Spacing.s)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            let font = UIFont.preferredFont(forTextStyle: .subheadline)
            attributes.font = weight == .regular ? font : font.bold()
            return attributes
        }
        button.configuration = configuration
        button.accessibilityIdentifier = id
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.tapTarget).isActive = true
    }

    /// Shows the card and starts its clock (none while VoiceOver runs: it stays until answered or
    /// the page changes).
    func show() {
        guard !isShowing else { return }
        isShowing = true
        Signposts.signposter.emitEvent(Signposts.darkPagesSuggestion, "shown")
        isHidden = false
        superview?.layoutIfNeeded()
        if !Motion.prefersCrossfade { transform = CGAffineTransform(translationX: 0, y: slideOffset) }
        Motion.animate(Motion.reflow) {
            self.alpha = 1
            self.transform = .identity
        }
        UIAccessibility.post(notification: .screenChanged, argument: wordsElement)
        timeout?.cancel()
        guard !UIAccessibility.isVoiceOverRunning else { return }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: FixedChoices.darkPagesSuggestionDuration)
            guard !Task.isCancelled else { return }
            self?.finish(.timedOut)
        }
    }

    /// Which way it slides in: up from the pill below it, down from the bar above it.
    var slideOffset: CGFloat = 12

    /// Takes the card away without an answer (its page left the screen, something else needs the
    /// place). Counts as ignored.
    func hide() {
        finish(.hidden)
    }

    private func finish(_ outcome: Outcome) {
        guard isShowing else { return }
        isShowing = false
        timeout?.cancel()
        timeout = nil
        Signposts.signposter.emitEvent(Signposts.darkPagesSuggestion, "\(String(describing: outcome), privacy: .public)")
        Motion.animate(Motion.quick, changes: {
            self.alpha = 0
            if !Motion.prefersCrossfade { self.transform = CGAffineTransform(translationX: 0, y: self.slideOffset * 0.66) }
        }, completion: { [weak self] in
            guard let self, !self.isShowing else { return }
            self.isHidden = true
        })
        onFinish(outcome)
    }
}

extension UIFont {
    fileprivate func bold() -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold]])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
#endif
