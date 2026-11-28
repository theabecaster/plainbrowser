import BrowserCore
import PerfSignposts
import UIKit

/// The perf reference: a bare UIKit screen, one text field with the address field's input traits
/// and two buttons, measured by the same signposts as Plain's own launch and focus
/// (`-PlainPerfReference`, isolated test runs only; `PerfTests.testReference*`). What it takes on a
/// device is the floor UIKit and the system keyboard set for those metrics there, so a budget can
/// be judged against the device instead of argued (docs/research/perf-pass-3.md).
enum PerfReference {
    static let argument = "-PlainPerfReference"
    /// With the reference: the field stays unfocused at launch (no keyboard), the floor for a
    /// launch that opens on the last tab.
    static let unfocusedArgument = "-PlainPerfReferenceUnfocused"

    static func isRequested(_ arguments: [String]) -> Bool {
        TestIsolation.isActive && arguments.contains(argument)
    }

    static func focusesAtLaunch(_ arguments: [String]) -> Bool {
        !arguments.contains(unfocusedArgument)
    }

    /// Nothing, on another queue: the hop a keystroke's database read makes (GRDB reads on its own
    /// queue and resumes the caller). A real dispatch, so the optimizer can't elide the hop.
    nonisolated static func offMain() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { done.resume() }
        }
    }
}

/// The reference screen. The field takes focus as the view appears, before the first frame, as
/// Plain's search field does at a search-first launch; `onFocused` ends the `launch` interval.
final class PerfReferenceController: UIViewController {
    private let field = UITextField()
    private let focus = UIButton(type: .system)
    private let done = UIButton(type: .system)
    private let onFocused: () -> Void
    private var focusedOnce = false

    init(onFocused: @escaping () -> Void) {
        self.onFocused = onFocused
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        field.accessibilityIdentifier = "referenceField"
        field.borderStyle = .roundedRect
        field.placeholder = "Search or enter address"
        field.font = .preferredFont(forTextStyle: .body)
        // The address field's traits (AddressPill), so the keyboard sets up the same way.
        field.keyboardType = .webSearch
        field.returnKeyType = .go
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartInsertDeleteType = .no
        field.clearButtonMode = .whileEditing
        focus.setTitle("Focus", for: .normal)
        focus.accessibilityIdentifier = "referenceFocus"
        focus.addAction(UIAction { [weak self] _ in self?.focusTapped() }, for: .primaryActionTriggered)
        // A keystroke as the address bar handles one, minus its work: the interval begins at
        // `.editingChanged`, hops off the main thread and back (where Plain reads the database),
        // and ends when the main thread takes the result. `testKeystrokeToSuggestions`'s floor.
        field.addAction(UIAction { _ in
            let state = Signposts.signposter.beginInterval(Signposts.referenceKeystroke)
            // On the main actor, as the address bar's task is: the end waits for the main thread.
            Task.immediate { @MainActor in
                await PerfReference.offMain()
                Signposts.signposter.endInterval(Signposts.referenceKeystroke, state)
            }
        }, for: .editingChanged)
        done.setTitle("Done", for: .normal)
        done.accessibilityIdentifier = "referenceDone"
        done.addAction(UIAction { [weak self] _ in self?.field.resignFirstResponder() }, for: .primaryActionTriggered)
        let stack = UIStackView(arrangedSubviews: [field, focus, done])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        guard !focusedOnce else { return }
        focusedOnce = true
        guard PerfReference.focusesAtLaunch(ProcessInfo.processInfo.arguments) else { return onFocused() }
        if field.becomeFirstResponder() { onFocused() }
    }

    private func focusTapped() {
        OpenIntervals.begin(Signposts.referenceReady, until: UIResponder.keyboardDidShowNotification)
        OpenIntervals.begin(Signposts.referenceKeyboardStart, until: UIResponder.keyboardWillShowNotification)
        field.becomeFirstResponder()
    }
}
