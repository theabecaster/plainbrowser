#if canImport(UIKit)
import BrowserCore
import DesignSystem
import os
import PerfSignposts
import UIKit
import WebEngine
import WebKit

/// The browser's root screen: a search field that is focused on the first frame, and the page.
///
/// Launch order (docs/plan.md, "Engine rules"):
/// 1. The first frame shows the field already first responder, keyboard up.
/// 2. After that frame, the pool warms one offscreen web view with `about:blank`.
/// 3. The first submitted address gets that warm web view.
public final class BrowserViewController: UIViewController, UITextFieldDelegate {
    private let pool: WebViewPool
    private let searchEngine: SearchEngine
    private let onSearchFieldReady: () -> Void
    private let navigationSignposter = NavigationSignposter()

    private let searchField = UITextField()
    private var webView: WKWebView?
    private var didFocusAtLaunch = false
    private var didWarmUp = false

    /// - Parameter onSearchFieldReady: called once, when the field first becomes first responder.
    public init(pool: WebViewPool, searchEngine: SearchEngine = FixedChoices.defaultSearchEngine, onSearchFieldReady: @escaping () -> Void) {
        self.pool = pool
        self.searchEngine = searchEngine
        self.onSearchFieldReady = onSearchFieldReady
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.background
        view.tintColor = Palette.accent

        searchField.accessibilityIdentifier = "searchField"
        searchField.placeholder = "Search or enter address"
        searchField.backgroundColor = Palette.fieldBackground
        searchField.layer.cornerRadius = 24
        searchField.layer.cornerCurve = .continuous
        searchField.font = .preferredFont(forTextStyle: .body)
        searchField.adjustsFontForContentSizeCategory = true
        searchField.keyboardType = .webSearch
        searchField.returnKeyType = .go
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.spellCheckingType = .no
        searchField.clearButtonMode = .whileEditing
        searchField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 18, height: 1))
        searchField.leftViewMode = .always
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchField)

        // The field rides on the keyboard while it is up and sits at the bottom when it is down.
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 48),
            searchField.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
        ])
    }

    override public func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // The view is in the window now, so it can take first responder before the first frame
        // is committed.
        guard !didFocusAtLaunch, searchField.becomeFirstResponder() else { return }
        didFocusAtLaunch = true
        Signposts.signposter.emitEvent(Signposts.searchFieldReady)
        onSearchFieldReady()
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didWarmUp else { return }
        didWarmUp = true
        // A dispatch to the main queue can run before Core Animation commits the first frame.
        // A display link's first callback comes at the vsync after that commit, so the warm-up
        // starts only once the first frame has gone to the render server.
        let link = CADisplayLink(target: self, selector: #selector(firstFrameDidCommit(_:)))
        link.add(to: .main, forMode: .common)
    }

    @objc private func firstFrameDidCommit(_ link: CADisplayLink) {
        link.invalidate()
        pool.warmUp()
    }

    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let signposter = Signposts.signposter
        let state = signposter.beginInterval(Signposts.addressSubmit)
        guard let input = AddressBarInput(textField.text ?? ""),
              let url = input.destination(searchingWith: searchEngine)
        else {
            signposter.endInterval(Signposts.addressSubmit, state, "ignored")
            return false
        }
        load(url)
        textField.text = url.absoluteString
        textField.resignFirstResponder()
        signposter.endInterval(Signposts.addressSubmit, state, "loaded")
        return false
    }

    private func load(_ url: URL) {
        let webView = self.webView ?? installWebView()
        webView.load(URLRequest(url: url))
    }

    private func installWebView() -> WKWebView {
        let webView = pool.dequeueWebView()
        webView.navigationDelegate = navigationSignposter
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(webView, belowSubview: searchField)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: searchField.topAnchor, constant: -12),
        ])
        self.webView = webView
        return webView
    }
}
#endif
