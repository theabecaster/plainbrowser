#if os(iOS)
import DesignSystem
import os
import PerfSignposts
import SwiftUI

/// The blocking demo: a small mock page (native views, no web view) with a banner ad, a sponsored
/// box, a sticky video ad, a cookie wall and a tracker count. "Block Ads and Trackers" clears them
/// one after another while the article reflows up into the space; off brings them back.
///
/// It plays once by itself (cluttered, then clean), then the user can flip it. Plain's blocking
/// is always on (`FixedChoices.contentBlockingAlwaysOn`); the caption says so.
struct BlockingDemo: View {
    @Bindable var model: IntroModel
    /// Each piece of clutter has its own flag so they can leave one after another.
    @State private var cookieWall = true
    @State private var videoAd = true
    @State private var bannerAd = true
    @State private var inlineAd = true
    @State private var trackersBlocked = false
    @State private var autoPlay: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private static let trackerCount = 9

    var body: some View {
        VStack(spacing: 0) {
            page
                // Under Reduce Motion nothing moves: the whole page crossfades between states.
                .id(reduceMotion ? AnyHashable(model.blockingOn) : AnyHashable("page"))
                .transition(.opacity)
                .frame(maxWidth: 360, maxHeight: 440)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.blockingOn
                    ? "Sample page with blocking on: just the article."
                    : "Sample page with blocking off: a banner ad, a sponsored box, a video ad, a cookie wall and \(Self.trackerCount) trackers.")
            toggleRow
                .frame(maxWidth: 360)
                .padding(.top, -26)
                .padding(.horizontal, 10)
            Text(model.blockingOn ? "Plain blocks these for you, on every site." : "The same page without blocking.")
                .font(.subheadline)
                .opacity(0.72)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
                .contentTransition(.opacity)
                .animation(IntroMotion.crossfade, value: model.blockingOn)
        }
        .onAppear(perform: startAutoPlay)
        .onDisappear { autoPlay?.cancel() }
    }

    // MARK: The page

    /// The page takes the height the step gives it, never its content's: the mock is a window onto
    /// a longer page, clipped at the bottom, so a short screen (the Duo's outer screen) still fits
    /// the title, the toggle and the button.
    private var page: some View {
        Color.white
            .frame(minHeight: 220)
            .overlay(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    addressBar
                    if bannerAd { banner.transition(.clutter) }
                    article
                }
            }
            .overlay(alignment: .bottom) { overlays }
            // At night the white page is dimmed a little, so it does not glare on the night paper.
            .overlay { Color.black.opacity(colorScheme == .dark ? 0.1 : 0).allowsHitTesting(false) }
            .clipShape(.rect(cornerRadius: 20, style: .continuous))
            // A sheet on the paper: a hairline edge and a soft shadow, as the feature cards.
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color(uiColor: BrandArt.ink).opacity(0.08), lineWidth: 1)
            }
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.shadow(.drop(color: Color(uiColor: Palette.floatingShadow).opacity(0.16), radius: 18, y: 8)))
            }
            .environment(\.colorScheme, .light)
    }

    /// The cookie wall, floating over the bottom of the article.
    private var overlays: some View {
        ZStack(alignment: .bottom) {
            if cookieWall {
                cookie.transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var addressBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold))
            Text("fieldnotes.example").font(.system(size: 12, weight: .medium))
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                Image(systemName: trackersBlocked ? "checkmark.shield.fill" : "eye.fill")
                    .contentTransition(.symbolEffect(.replace))
                Text(trackersBlocked ? "\(Self.trackerCount) blocked" : "\(Self.trackerCount) trackers")
                    .contentTransition(.numericText())
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color(uiColor: BrandArt.ink))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(trackersBlocked ? IntroStyle.mint : IntroStyle.coral, in: .capsule)
        }
        .foregroundStyle(.black.opacity(0.55))
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var banner: some View {
        HStack(spacing: 10) {
            Text("AD").font(.system(size: 9, weight: .heavy)).padding(3).background(.black.opacity(0.25), in: .rect(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 1) {
                Text("MEGA SALE · 70% OFF").font(.system(size: 13, weight: .black))
                Text("Ends tonight. Tap now!").font(.system(size: 10, weight: .semibold))
            }
            Spacer()
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).opacity(0.7)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(LinearGradient(colors: [Color(red: 1, green: 0.55, blue: 0.1), Color(red: 0.95, green: 0.15, blue: 0.45)],
                                   startPoint: .leading, endPoint: .trailing))
    }

    private var article: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Field Notes")
                .font(.system(size: 22, weight: .black, design: .serif))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
                .padding(.bottom, 8)
            Text("Twelve Quiet Trails Near the Coast")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.black)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
            Text("NOV 26 · 6 MIN READ")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.black.opacity(0.45))
                .padding(.horizontal, 14)
                .padding(.top, 6)
            hero
                // The sticky video ad sits over the photo, so the headline stays readable.
                .overlay(alignment: .bottomTrailing) {
                    if videoAd {
                        video
                            .padding(6)
                            .transition(.scale(scale: 0.2, anchor: .bottomTrailing).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
            lines(3).padding(.top, 12)
            if inlineAd { sponsored.transition(.clutter) }
            lines(4).padding(.top, 10)
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(uiColor: BrandArt.dawnViolet), Color(uiColor: BrandArt.lagoon), Color(uiColor: BrandArt.peach)],
                           startPoint: .top, endPoint: .bottom)
            Ellipse().fill(Color(uiColor: BrandArt.nightLagoon)).frame(height: 60).offset(x: -40, y: 30)
            Ellipse().fill(Color(uiColor: BrandArt.planet[0])).frame(height: 50).offset(x: 70, y: 28)
        }
        .frame(height: 96)
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
    }

    private func lines(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(0..<count, id: \.self) { index in
                Capsule().fill(.black.opacity(0.1))
                    .frame(height: 7)
                    .padding(.trailing, index == count - 1 ? 80 : 0)
            }
        }
        .padding(.horizontal, 14)
    }

    private var sponsored: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.98, green: 0.85, blue: 0.2)).frame(width: 52, height: 52)
                .overlay(Image(systemName: "cart.fill").foregroundStyle(.black.opacity(0.6)))
            VStack(alignment: .leading, spacing: 3) {
                Text("SPONSORED").font(.system(size: 8, weight: .heavy)).foregroundStyle(.black.opacity(0.45))
                Text("You won’t believe these boots").font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                Capsule().fill(.black.opacity(0.1)).frame(width: 90, height: 6)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color(red: 1, green: 0.97, blue: 0.85), in: .rect(cornerRadius: 10))
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    private var video: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8).fill(Color.black)
            Image(systemName: "play.fill").font(.system(size: 18)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("AD · 0:15").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
                .padding(4).background(Color(red: 0.95, green: 0.75, blue: 0.1).opacity(0.9), in: .rect(cornerRadius: 3)).padding(5)
        }
        .frame(width: 100, height: 56)
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
    }

    private var cookie: some View {
        // One compact row, so a short page (the Duo's outer screen) still shows the photo above it.
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("We value your privacy").font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                Text("We and 214 partners use cookies to follow you.")
                    .font(.system(size: 10)).foregroundStyle(.black.opacity(0.6)).lineLimit(2)
            }
            Spacer(minLength: 0)
            Text("Accept All")
                .font(.system(size: 11, weight: .bold))
                .padding(.horizontal, 12)
                .frame(minHeight: 30)
                .background(Color(red: 0.1, green: 0.4, blue: 0.95), in: .rect(cornerRadius: 6)).foregroundStyle(.white)
        }
        .padding(12)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .overlay(alignment: .top) { Rectangle().fill(.black.opacity(0.08)).frame(height: 1) }
        .shadow(color: .black.opacity(0.18), radius: 16, y: -6)
    }

    // MARK: The toggle

    private var toggleRow: some View {
        Toggle(isOn: Binding(get: { model.blockingOn }, set: { flip(to: $0, byUser: true) })) {
            Text("Block Ads and Trackers").font(.subheadline.weight(.semibold)).foregroundStyle(IntroStyle.text)
        }
        .tint(IntroStyle.lagoon)
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        // The demo's one control floats over the page, so it is Liquid Glass.
        .glassEffect(.regular.tint(Color(uiColor: Palette.glassTint)), in: .rect(cornerRadius: 18, style: .continuous))
        .accessibilityIdentifier("introBlockingToggle")
    }

    private func startAutoPlay() {
        guard !model.blockingDemoPlayed else { return }
        apply(model.blockingOn, animated: false)
        autoPlay = Task {
            try? await Task.sleep(for: .seconds(1.3))
            guard !Task.isCancelled, !model.blockingDemoPlayed else { return }
            flip(to: true, byUser: false)
        }
    }

    private func flip(to on: Bool, byUser: Bool) {
        model.blockingDemoPlayed = true
        autoPlay?.cancel()
        guard on != model.blockingOn else { return }
        if byUser { Haptic.selection.play() }
        let interval = Signposts.signposter.beginAnimationInterval(Signposts.introBlockingDemo, "\(on ? "clean" : "cluttered", privacy: .public)")
        if reduceMotion {
            // The page's identity follows `blockingOn`: change both in one crossfade.
            withAnimation(IntroMotion.crossfade) {
                model.blockingOn = on
                apply(on, animated: false)
            }
        } else {
            model.blockingOn = on
            apply(on, animated: true)
        }
        Task {
            try? await Task.sleep(for: .seconds(0.8))
            Signposts.signposter.endInterval(Signposts.introBlockingDemo, interval)
        }
    }

    /// Clean: the cookie wall drops away, the video ad shrinks into its corner, the banner and the
    /// sponsored box fold shut and the article rises into their space, the tracker count turns
    /// into "blocked". Cluttered is the same in reverse.
    private func apply(_ on: Bool, animated: Bool) {
        let steps: [(Double, () -> Void)] = [
            (0.0, { cookieWall = !on }),
            (0.05, { videoAd = !on }),
            (0.08, { inlineAd = !on }),
            (0.1, { trackersBlocked = on }),
            (0.12, { bannerAd = !on }),
        ]
        if !animated {
            steps.forEach { $0.1() }
        } else if reduceMotion {
            withAnimation(IntroMotion.crossfade) { steps.forEach { $0.1() } }
        } else {
            for (delay, change) in on ? steps : steps.reversed().enumerated().map({ (Double($0.offset) * 0.05, $0.element.1) }) {
                withAnimation(IntroMotion.reflow.delay(delay), change)
            }
        }
    }
}

private extension AnyTransition {
    /// A piece of clutter folding shut: it fades and squeezes to nothing while the page closes up.
    static var clutter: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.92, anchor: .top))
    }
}
#endif
