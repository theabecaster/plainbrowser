#if canImport(UIKit)
import BrowserCore
import DesignSystem
import UIKit
import WebEngine

/// What covers the page when it can't show: it crashed again after the engine's reloads, it
/// failed to load, or a restored form result waits to be sent again. One sentence and one main
/// button (docs/ui-reference.md, "Empty and first-run states"), in Plain's words, never WebKit's.
final class PageStateView: UIView {
    struct State {
        var message: String
        var button: String
        var action: () -> Void
        /// A quieter second button under the main one, only where a page can't show for a reason
        /// the user can fix in two places (cellular data off for Plain: Open Settings, or join
        /// Wi-Fi and Try Again).
        var secondary: (title: String, action: () -> Void)?
    }

    private let label = UILabel()
    private let button = UIButton(configuration: .borderedProminent())
    private let secondaryButton = UIButton(configuration: .plain())
    private var action: (() -> Void)?
    private var secondaryAction: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        Paper.apply(to: self)
        accessibilityIdentifier = "pageState"
        isHidden = true

        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Palette.textPrimary
        label.textAlignment = .center
        label.numberOfLines = 0

        button.configuration?.cornerStyle = .capsule
        button.tintColor = Palette.accent
        button.addAction(UIAction { [weak self] _ in self?.action?() }, for: .primaryActionTriggered)
        button.accessibilityIdentifier = "pageState.button"
        secondaryButton.tintColor = Palette.accent
        secondaryButton.isHidden = true
        secondaryButton.accessibilityIdentifier = "pageState.secondary"
        secondaryButton.addAction(UIAction { [weak self] _ in self?.secondaryAction?() }, for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [label, button, secondaryButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Spacing.l
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: safeAreaLayoutGuide.centerYAnchor, constant: -Spacing.xl * 2),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: readableContentGuide.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: readableContentGuide.trailingAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.tapTarget),
            secondaryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.tapTarget),
        ])
        stack.setCustomSpacing(Spacing.xs, after: button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `state`, or hides the view for nil.
    func show(_ state: State?) {
        guard let state else {
            isHidden = true
            action = nil
            secondaryAction = nil
            return
        }
        label.text = state.message
        button.configuration?.title = state.button
        action = state.action
        secondaryButton.configuration?.title = state.secondary?.title
        secondaryAction = state.secondary?.action
        secondaryButton.isHidden = state.secondary == nil
        isHidden = false
    }

    /// A load that failed for want of the network (`LoadFailure.offline`), as opposed to the site
    /// or its certificate: where cellular data off for Plain is the reason to name.
    /// `simulated` (Debug's `-PlainSystemAccess cellular=denied`) counts a host that isn't
    /// answering or can't be found too, so captures can show the cellular page on a simulator
    /// that is online.
    static func isNetworkFailure(_ error: LoadError, simulated: Bool = false) -> Bool {
        switch error.failure {
        case .offline: true
        case .notAnswering, .refused, .notFound, .timedOut: simulated
        default: false
        }
    }

    /// Plain's sentence for a failed load, from the known error cases (`LoadFailure`;
    /// docs/ui-reference.md, "Wording": never the raw WebKit or server text).
    static func message(for error: LoadError) -> String {
        error.failure.message
    }
}
#endif
