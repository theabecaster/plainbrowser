#if canImport(UIKit)
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
    }

    private let label = UILabel()
    private let button = UIButton(configuration: .borderedProminent())
    private var action: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Palette.background
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

        let stack = UIStackView(arrangedSubviews: [label, button])
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
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `state`, or hides the view for nil.
    func show(_ state: State?) {
        guard let state else {
            isHidden = true
            action = nil
            return
        }
        label.text = state.message
        button.configuration?.title = state.button
        action = state.action
        isHidden = false
    }

    /// Plain's sentence for a failed load, from the known error cases (docs/ui-reference.md,
    /// "Wording": never the raw WebKit or server text).
    static func message(for error: LoadError) -> String {
        guard error.domain == NSURLErrorDomain else { return "Plain couldn't open this page." }
        switch error.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed:
            return "You're offline."
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "Plain can't find this site."
        case NSURLErrorTimedOut:
            return "The site took too long to answer."
        case NSURLErrorCannotConnectToHost:
            return "The site isn't answering."
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorSecureConnectionFailed:
            return "This site's connection isn't private."
        default:
            return "Plain couldn't open this page."
        }
    }
}
#endif
