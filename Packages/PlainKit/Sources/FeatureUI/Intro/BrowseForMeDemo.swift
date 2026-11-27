#if os(iOS)
import DesignSystem
import os
import PerfSignposts
import SwiftUI
import UIKit

/// The Browse for Me demo: a small mock of Plain's own search on a sheet of paper (native views,
/// no model, no web view). A question types itself into the field, Browse for Me is pressed, three
/// sources are read, and three short points arrive, each ending with its numbered citation, as
/// the real summary writes them.
///
/// It plays once by itself; a tap on its Browse for Me row plays it again (the step's one
/// control, as the blocking demo's toggle is). Every part keeps its place from the first frame,
/// so nothing on the step moves while it plays.
struct BrowseForMeDemo: View {
    @Bindable var model: IntroModel
    /// Characters of the question in the field.
    @State private var typed = 0
    @State private var pressed = false
    @State private var sourcesShown = 0
    @State private var sourcesRead = 0
    @State private var pointsShown = 0
    @State private var run: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let query = "quiet trails near the coast"
    private static let sources = ["fieldnotes", "coastwalks", "parkguide"]
    private static let points: [(text: String, sources: [Int])] = [
        ("Go on a weekday; lots fill by nine.", [1]),
        ("Bluff Loop is flat, shaded and short.", [2, 3]),
        ("Fog lifts by noon, so bring a layer.", [1]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
                .accessibilityHidden(true)
            row
                .padding(.top, 6)
            sourceChips
                .padding(.top, 12)
                .accessibilityHidden(true)
            pointList
                .padding(.top, 12)
                .accessibilityHidden(true)
        }
        .padding(14)
        .frame(maxWidth: 360, alignment: .leading)
        .background(IntroStyle.sheet)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Example: Browse for Me reads three pages about quiet trails near the coast and writes three short points, each citing its source.")
        .onAppear(perform: startAutoPlay)
        .onDisappear { run?.cancel() }
    }

    // MARK: The parts

    /// The search field, drawn like the resting pill: the placeholder, then the question typing in.
    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .opacity(0.5)
            Group {
                if typed == 0 {
                    Text("Search or enter address").opacity(0.45)
                } else {
                    Text(Self.query.prefix(typed))
                }
            }
            .font(.system(size: 15))
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(IntroStyle.text.opacity(0.055), in: .capsule)
    }

    /// The row above the field in the real search sheet. Tapping it plays the demo again.
    private var row: some View {
        Button(action: replay) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 22)
                Text("Browse for Me")
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color(uiColor: Palette.accentOnPaper))
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(IntroStyle.text.opacity(pressed ? 0.09 : 0), in: .rect(cornerRadius: 12, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Browse for Me")
        .accessibilityHint("Plays the example again")
        .accessibilityIdentifier("introBrowseDemo")
    }

    /// The pages it reads: an open ring while reading, then the number the points cite.
    private var sourceChips: some View {
        HStack(spacing: 6) {
            ForEach(Array(Self.sources.enumerated()), id: \.offset) { index, site in
                HStack(spacing: 5) {
                    ZStack {
                        if index < sourcesRead {
                            Text("\(index + 1)")
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                // The sheet's own color: white by day, night blue on the lighter
                                // night Lagoon.
                                .foregroundStyle(Color(uiColor: IntroPaper.sheet))
                                .frame(width: 15, height: 15)
                                .background(Color(uiColor: Palette.accentOnPaper), in: .circle)
                                .transition(.scale(scale: 0.5).combined(with: .opacity))
                        } else {
                            // Reading: an open ring that fills with the number once read.
                            Circle()
                                .strokeBorder(Color(uiColor: Palette.accentOnPaper), lineWidth: 1.5)
                                .transition(.opacity)
                        }
                    }
                    .frame(width: 15, height: 15)
                    Text(site)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
                .padding(.leading, 4)
                .padding(.trailing, 8)
                .padding(.vertical, 4)
                .background(IntroStyle.text.opacity(0.055), in: .capsule)
                .opacity(index < sourcesShown ? 1 : 0)
                .offset(y: index < sourcesShown || reduceMotion ? 0 : 6)
            }
        }
    }

    /// The answer: short points, each ending with small numbered citations in Lagoon.
    private var pointList: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(Self.points.enumerated()), id: \.offset) { index, point in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(IntroStyle.text.opacity(0.45))
                        .frame(width: 4, height: 4)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    Text("\(point.text)\(citations(point.sources))")
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(2)
                }
                .opacity(index < pointsShown ? 1 : 0)
                .offset(y: index < pointsShown || reduceMotion ? 0 : 6)
            }
        }
    }

    private func citations(_ numbers: [Int]) -> Text {
        Text(" " + numbers.map(String.init).joined(separator: " "))
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Color(uiColor: Palette.accentOnPaper))
            .baselineOffset(5)
    }

    // MARK: Playing

    private func startAutoPlay() {
        guard !model.browseDemoPlayed else {
            showFinished()
            return
        }
        play(typing: true)
    }

    private func replay() {
        // The same tick as the blocking demo's toggle.
        Haptic.selection.play()
        play(typing: false)
    }

    private func showFinished() {
        typed = Self.query.count
        sourcesShown = Self.sources.count
        sourcesRead = Self.sources.count
        pointsShown = Self.points.count
    }

    /// Types the question (the first time), presses the row, reads the sources, writes the points.
    /// Under Reduce Motion the finished answer crossfades in instead.
    private func play(typing: Bool) {
        run?.cancel()
        let interval = Signposts.signposter.beginAnimationInterval(Signposts.introBrowseDemo, "\(typing ? "auto" : "replay", privacy: .public)")
        run = Task {
            defer { Signposts.signposter.endInterval(Signposts.introBrowseDemo, interval) }
            withAnimation(IntroMotion.crossfade) {
                if typing { typed = 0 }
                sourcesShown = 0
                sourcesRead = 0
                pointsShown = 0
            }
            if reduceMotion {
                guard await pause(typing ? 0.6 : 0.3) else { return }
                withAnimation(IntroMotion.crossfade) { showFinished() }
                model.browseDemoPlayed = true
                return
            }
            if typing {
                guard await pause(0.5) else { return }
                for count in 1...Self.query.count {
                    typed = count
                    guard await pause(0.03) else { return }
                }
                guard await pause(0.25) else { return }
            } else {
                guard await pause(0.2) else { return }
            }
            withAnimation(.snappy(duration: 0.15)) { pressed = true }
            guard await pause(0.18) else { return }
            withAnimation(.snappy(duration: 0.3)) { pressed = false }
            for count in 1...Self.sources.count {
                withAnimation(IntroMotion.enter) { sourcesShown = count }
                guard await pause(0.1) else { return }
            }
            guard await pause(0.35) else { return }
            for count in 1...Self.sources.count {
                withAnimation(.snappy(duration: 0.25)) { sourcesRead = count }
                guard await pause(0.12) else { return }
            }
            guard await pause(0.1) else { return }
            for count in 1...Self.points.count {
                withAnimation(IntroMotion.enter) { pointsShown = count }
                guard await pause(0.26) else { return }
            }
            model.browseDemoPlayed = true
        }
    }

    /// Waits; false once the demo is gone or playing again.
    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    }
}

/// Settings for Apple Intelligence. No public URL opens its page, so Plain's own page in Settings
/// is the closest the API allows (`UIApplication.openSettingsURLString`); the step's line names
/// where to go from there.
@MainActor
enum AppleIntelligenceSettings {
    static func open() {
        Signposts.signposter.emitEvent(Signposts.introAISettings)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
#endif
