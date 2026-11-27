#if os(iOS)
import DesignSystem
import SwiftUI

/// The default-browser step's demo: a link in a message is tapped and opens in Plain's pill, with
/// the page's trackers already blocked. It plays once by itself; a tap on the message plays it
/// again. Behind `FixedChoices.defaultBrowserPromptsEnabled` with the rest of the step.
struct LinkHandoffDemo: View {
    @State private var pressed = false
    @State private var opened = false
    @State private var blocked = false
    @State private var run: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: { play() }) { bubble }
                .buttonStyle(.plain)
                .accessibilityLabel("Example: a link in a message opens in Plain, with its trackers blocked.")
                .accessibilityHint("Plays the example again")
                .accessibilityIdentifier("introLinkDemo")
            pill
                .frame(maxWidth: .infinity, alignment: .trailing)
                .opacity(opened ? 1 : 0)
                .offset(y: opened || reduceMotion ? 0 : 8)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: 320)
        .onAppear { play(delay: 0.9) }
        .onDisappear { run?.cancel() }
    }

    /// A message from a friend with a link in it, in the system's bubble gray.
    private var bubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Have you seen these trails?")
                .font(.system(size: 15))
            HStack(spacing: 5) {
                Image(systemName: "link").font(.system(size: 11, weight: .semibold))
                Text("fieldnotes.example/trails").font(.system(size: 13, weight: .medium)).underline()
            }
            .foregroundStyle(Color(uiColor: Palette.accentOnPaper))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemFill), in: .rect(cornerRadius: 18, style: .continuous))
        .scaleEffect(pressed ? 0.97 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Plain's resting pill with the page's host and its blocked trackers.
    private var pill: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").font(.system(size: 10, weight: .bold)).opacity(0.55)
            Text("fieldnotes.example").font(.system(size: 14, weight: .semibold))
            HStack(spacing: 3) {
                Image(systemName: "checkmark.shield.fill")
                Text("9 blocked")
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color(uiColor: BrandArt.ink))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(IntroStyle.mint, in: .capsule)
            .scaleEffect(blocked ? 1 : 0.6)
            .opacity(blocked ? 1 : 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .glassEffect(.regular.tint(Color(uiColor: Palette.glassTint)), in: .capsule)
    }

    private func play(delay: Double = 0.2) {
        run?.cancel()
        run = Task {
            withAnimation(IntroMotion.crossfade) {
                opened = false
                blocked = false
            }
            guard await pause(delay) else { return }
            if reduceMotion {
                withAnimation(IntroMotion.crossfade) {
                    opened = true
                    blocked = true
                }
                return
            }
            withAnimation(.snappy(duration: 0.15)) { pressed = true }
            guard await pause(0.16) else { return }
            withAnimation(.snappy(duration: 0.3)) { pressed = false }
            withAnimation(IntroMotion.enter) { opened = true }
            guard await pause(0.4) else { return }
            withAnimation(.spring(duration: 0.4, bounce: 0.12)) { blocked = true }
        }
    }

    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    }
}
#endif
