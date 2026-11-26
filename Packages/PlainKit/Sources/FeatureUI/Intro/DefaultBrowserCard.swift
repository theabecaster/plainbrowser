#if os(iOS)
import DesignSystem
import os
import PerfSignposts
import SwiftUI
import UIKit

extension DefaultBrowserPrompts {
    /// Opens the system's Default Apps settings, where Plain would be picked as the browser.
    @MainActor
    public static func openSettings() {
        Signposts.signposter.emitEvent(Signposts.defaultBrowserPrompt)
        guard let url = URL(string: UIApplication.openDefaultApplicationsSettingsURLString)
            ?? URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// The empty start screen's default-browser prompt: Plain's mark, one sentence and one button, with
/// a close button. For the start screen to host when no pages are open (TabGalleryUI), behind
/// `DefaultBrowserPrompts.showsEmptyTabCard()`; closing it is remembered.
///
/// UIKit hosts take `makeDefaultBrowserCard(onDismiss:)`.
public struct DefaultBrowserCard: View {
    private let onDismiss: () -> Void

    /// - Parameter onDismiss: the host removes the card. The dismissal is already saved.
    public init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 14) {
            StemMark()
                .frame(width: 76, height: 80)
                // Keeps the cream ring's edge on the cream start screen.
                .shadow(color: Color(uiColor: Palette.floatingShadow).opacity(0.25), radius: 10, y: 4)
            Text("Open links from every app in Plain, with blocking on.")
                .font(.body.weight(.medium))
                .foregroundStyle(Color(uiColor: Palette.textPrimary))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Set as Default Browser") { DefaultBrowserPrompts.openSettings() }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(Style.accent)
                .accessibilityIdentifier("defaultBrowserCardButton")
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: 360)
        // No card surface: it sits on the start screen's own paper, like an empty state.
        .overlay(alignment: .topTrailing) {
            Button {
                DefaultBrowserPrompts.dismissEmptyTabCard()
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(uiColor: Palette.textSecondary))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close")
            .accessibilityIdentifier("defaultBrowserCardClose")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("defaultBrowserCard")
    }
}

/// The card in a hosting controller sized to fit, for UIKit screens.
@MainActor
public func makeDefaultBrowserCard(onDismiss: @escaping () -> Void) -> UIViewController {
    let host = UIHostingController(rootView: DefaultBrowserCard(onDismiss: onDismiss))
    host.sizingOptions = .intrinsicContentSize
    host.view.backgroundColor = .clear
    return host
}

#if DEBUG
/// A stand-in empty start screen with the card above a search field, so the card can be seen and
/// screenshotted before the real start screen hosts it (`-PlainPreviewEmptyTabCard`).
public final class DefaultBrowserCardPreviewController: UIViewController {
    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.background
        let card = makeDefaultBrowserCard(onDismiss: { [weak self] in self?.children.first?.view.isHidden = true })
        addChild(card)
        card.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card.view)
        card.didMove(toParent: self)
        let field = UIView()
        field.backgroundColor = Palette.surface
        field.layer.cornerRadius = 25
        field.layer.cornerCurve = .continuous
        let label = UILabel()
        label.text = "Search or enter address"
        label.textColor = Palette.textSecondary
        label.font = .preferredFont(forTextStyle: .body)
        for item in [field, label] as [UIView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            card.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.view.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            card.view.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            field.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            field.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            field.heightAnchor.constraint(equalToConstant: 50),
            label.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 20),
            label.centerYAnchor.constraint(equalTo: field.centerYAnchor),
        ])
    }
}
#endif
#endif
