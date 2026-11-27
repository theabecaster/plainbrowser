#if os(iOS)
import DesignSystem
import SwiftUI

/// The intro's steps after the splash, on paper. A step lifts away like a sheet; the next one's
/// parts arrive one after another (headline, then rows or the demo, then the button), each rising
/// into place. The dawn behind them is `DawnView`, owned by the view controller.
struct IntroStepsView: View {
    @Bindable var model: IntroModel

    var body: some View {
        ZStack {
            if let step = model.step {
                StepView(step: step, model: model)
                    .id(step)
                    .transition(.asymmetric(insertion: .identity, removal: .introLift))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StepView: View {
    let step: IntroModel.Step
    @Bindable var model: IntroModel

    var body: some View {
        VStack(spacing: 0) {
            topRow
                // On the promise step it waits for the window to open under it (white on paper otherwise).
                .entrance(step == .promise ? 4 : 0)
            Color.clear
                .frame(height: max(0, IntroLayout.reserve(step, safeHeight: model.safeHeight)))
            content
                .frame(maxWidth: IntroStyle.contentWidth, maxHeight: .infinity)
                .padding(.horizontal, 24)
            buttons
                .frame(maxWidth: IntroStyle.contentWidth)
                .padding(.horizontal, 24)
                .padding(.top, 14)
                .padding(.bottom, 12)
        }
        .foregroundStyle(IntroStyle.text)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("intro.\(step.rawValue)")
    }

    /// The step rings and Skip, in white on the dawn window's sky.
    private var topRow: some View {
        HStack {
            StepRings(count: model.steps.count, current: model.steps.firstIndex(of: step) ?? 0)
                .padding(.leading, 30)
            Spacer()
            // The frame is inside the label, so the whole 44 pt square takes the tap (outside the
            // button it only spaced a 35 x 20 pt target).
            Button { model.skip() } label: {
                Text("Skip")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .padding(.trailing, 20)
            .accessibilityIdentifier("introSkip")
            .accessibilityHint("Ends the introduction")
        }
        .frame(height: IntroLayout.topRow)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .promise: PromiseStep()
        case .inside: InsideStep()
        case .icon: IconStep(model: model)
        case .blocking: BlockingStep(model: model)
        case .defaultBrowser: DefaultBrowserStep()
        }
    }

    @ViewBuilder private var buttons: some View {
        switch step {
        case .defaultBrowser:
            VStack(spacing: 4) {
                Button {
                    DefaultBrowserPrompts.openSettings()
                    model.finish()
                } label: {
                    IntroButtonLabel(title: "Set as Default Browser")
                }
                .introPrimaryButton()
                .accessibilityIdentifier("introSetDefault")
                Button("Not Now") { model.finish() }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(IntroStyle.text.opacity(0.7))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("introNotNow")
            }
            .entrance(6)
        default:
            Button { model.next() } label: {
                IntroButtonLabel(title: model.isLastStep ? "Let’s Go" : "Next")
            }
            .introPrimaryButton()
            .accessibilityIdentifier(model.isLastStep ? "introLetsGo" : "introNext")
            .entrance(step == .promise ? 3 : 6)
        }
    }
}

/// Where the reader is in the intro: one small ring per step, like the mark's ring; the current
/// one is filled.
private struct StepRings: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .strokeBorder(.white.opacity(index == current ? 1 : 0.5), lineWidth: 1.5)
                    .background { if index == current { Circle().fill(.white) } }
                    .frame(width: 9, height: 9)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

// MARK: Steps

/// "The web, plainly." under the mark (the mark is the splash's, held by the view controller; the
/// step view has already left room for it).
private struct PromiseStep: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            DisplayText(lead: "The web, ", emphasis: "plainly", trail: ".")
                .entrance(1)
            Text("Nothing in the way of the page.")
                .font(.title3)
                .opacity(0.75)
                .multilineTextAlignment(.center)
                .padding(.top, 14)
                .entrance(2)
            Spacer(minLength: 20)
            Spacer(minLength: 0)
        }
    }
}

private struct InsideStep: View {
    private let rows: [(symbol: String, title: String, detail: String)] = [
        ("shield.lefthalf.filled", "Blocking Everywhere", "Ads, trackers and cookie banners stay off every site."),
        ("archivebox.fill", "Tabs Tidy Themselves", "Tabs you leave for a day move to a searchable archive."),
        ("eye.slash.fill", "Private Tabs", "No history, and their site data goes when you close them."),
        ("rectangle.split.2x1.fill", "Made for iPhone Duo", "Unfold for two pages side by side."),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                DisplayText(lead: "Built to stay\n", emphasis: "out of your way", trail: "")
                    .padding(.top, 14)
                    .padding(.bottom, 16)
                    .entrance(1)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    FeatureRow(symbol: row.symbol, title: row.title, detail: row.detail)
                        .entrance(2 + index)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
    }
}

/// A sheet of paper with one feature on it: a small ring with the symbol, a title and one line.
private struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(IntroStyle.text.opacity(0.85))
                .frame(width: 38, height: 38)
                .background(IntroStyle.text.opacity(0.05), in: .circle)
                .overlay { Circle().strokeBorder(IntroStyle.text.opacity(0.22), lineWidth: 1.5) }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).opacity(0.68)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(IntroStyle.sheet)
        .accessibilityElement(children: .combine)
    }
}

private struct IconStep: View {
    @Bindable var model: IntroModel
    @ScaledMetric(relativeTo: .body) private var tile: CGFloat = 92
    /// Two columns while two tiles fit; one at the largest text sizes.
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: tile + 40), spacing: 20)] }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                DisplayText(lead: "Pick your ", emphasis: "icon", trail: "")
                    .padding(.top, 14)
                    .entrance(1)
                Text("For your Home Screen. Change it any time in Settings.")
                    .font(.body)
                    .opacity(0.72)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                    .entrance(2)
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(Array(AppIconChoice.allCases.enumerated()), id: \.element) { index, choice in
                        IconTile(choice: choice, image: model.iconPreviews[choice], selected: model.icon == choice, size: tile) {
                            withAnimation(Motion.urlFocus) { model.pick(choice) }
                        }
                        .entrance(3 + index)
                    }
                }
                .frame(maxWidth: max(300, 2 * tile + 60))
                .padding(.top, 28)
            }
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .task { await model.loadPreviews() }
    }
}

private struct IconTile: View {
    let choice: AppIconChoice
    let image: UIImage?
    let selected: Bool
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    if let image {
                        Image(uiImage: image).resizable().interpolation(.high)
                    } else {
                        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).fill(IntroStyle.text.opacity(0.06))
                    }
                }
                .frame(width: size, height: size)
                .clipShape(.rect(cornerRadius: size * 0.225, style: .continuous))
                .padding(5)
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.225 + 5, style: .continuous)
                        .strokeBorder(IntroStyle.lagoon, lineWidth: selected ? 2.5 : 0)
                }
                .scaleEffect(selected ? 1.04 : 1)
                HStack(spacing: 6) {
                    ZStack {
                        Circle().strokeBorder(IntroStyle.text.opacity(0.35), lineWidth: 1.5)
                        if selected {
                            Circle().fill(IntroStyle.coral)
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                        }
                    }
                    .frame(width: 20, height: 20)
                    Text(choice.title).font(.subheadline.weight(.semibold))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(choice.accessibilityDescription)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("introIcon.\(choice.rawValue)")
    }
}

private struct BlockingStep: View {
    @Bindable var model: IntroModel

    var body: some View {
        VStack(spacing: 0) {
            DisplayText(lead: "The page, minus the ", emphasis: "junk", trail: "")
                .padding(.top, 10)
                .entrance(1)
            BlockingDemo(model: model)
                .padding(.top, 18)
                .entrance(2)
        }
    }
}

private struct DefaultBrowserStep: View {
    var body: some View {
        VStack(spacing: 0) {
            // The mark rests on the window's sill, like the promise step's.
            StemMark()
                .frame(width: IntroLayout.markSize, height: IntroLayout.markSize)
                .padding(.top, -(IntroLayout.markSize / 2 + IntroLayout.markLift))
                .entrance(1)
            Spacer(minLength: 16)
            DisplayText(lead: "Make Plain your ", emphasis: "default", trail: "")
                .entrance(2)
            Text("Links from Mail, Messages and every other app open in Plain, with blocking on.")
                .font(.body)
                .opacity(0.72)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
                .entrance(3)
            Spacer(minLength: 12)
            Spacer(minLength: 0)
        }
    }
}

// MARK: Shared pieces

/// The intro's display line, set in New York (the serif the Reader reads in), with the one word
/// that matters underlined by a coral stroke cut like the mark's fold. `lead` ends in its own space
/// or line break.
struct DisplayText: View {
    let lead: String
    let emphasis: String
    let trail: String
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 36

    var body: some View {
        Text("\(lead)\(Text(emphasis).customAttribute(FoldEmphasis()))\(trail)")
            .font(.system(size: size, weight: .semibold, design: .serif))
            .tracking(-0.3)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.7)
            .fixedSize(horizontal: false, vertical: true)
            .textRenderer(FoldUnderline(color: IntroStyle.coral))
            .accessibilityAddTraits(.isHeader)
    }
}

/// Marks the emphasized word of a display line.
struct FoldEmphasis: TextAttribute {}

/// Draws a coral stroke under each emphasized run, below the baseline and behind the letters, with
/// its trailing end cut at the fold's 45 degrees.
struct FoldUnderline: TextRenderer {
    let color: Color

    var displayPadding: EdgeInsets { EdgeInsets(top: 0, leading: 2, bottom: 10, trailing: 10) }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line where run[FoldEmphasis.self] != nil {
                let bounds = run.typographicBounds
                let thickness = max(3, bounds.ascent * 0.13)
                let top = bounds.origin.y + bounds.descent * 0.32
                let left = bounds.origin.x - 1
                let right = bounds.origin.x + bounds.width + 1
                var stroke = Path()
                stroke.move(to: CGPoint(x: left, y: top))
                stroke.addLine(to: CGPoint(x: right + thickness, y: top))
                stroke.addLine(to: CGPoint(x: right, y: top + thickness))
                stroke.addLine(to: CGPoint(x: left, y: top + thickness))
                stroke.closeSubpath()
                context.fill(stroke, with: .color(color))
            }
        }
        for line in layout { context.draw(line) }
    }
}

/// The main button's label: full width.
struct IntroButtonLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 36)
    }
}

extension View {
    /// The intro's one main button: Lagoon Blue Liquid Glass, the app's one action color.
    func introPrimaryButton() -> some View {
        buttonStyle(.glassProminent)
            .tint(IntroStyle.action)
            .controlSize(.large)
    }
}

/// The static Stem mark, for SwiftUI, with its paper shadow so the ring holds its edge on paper.
struct StemMark: UIViewRepresentable {
    var shadowed = true
    func makeUIView(context: Context) -> StemMarkView { StemMarkView(shadowed: shadowed) }
    func updateUIView(_ view: StemMarkView, context: Context) {}
}

enum IntroStyle {
    static let text = Color(uiColor: BrandArt.text)
    static let lagoon = Color(uiColor: BrandArt.lagoon)
    /// Lagoon a step deeper for the main button's fill, so its white label holds 4.5:1.
    static let action = Color(red: 0x23 / 255, green: 0x66 / 255, blue: 0xF0 / 255)
    static let mint = Color(uiColor: BrandArt.mint)
    static let coral = Color(uiColor: BrandArt.coral)
    /// A sheet of paper on the paper: white by day, a lifted night blue by night, with a hairline
    /// edge and a soft shadow.
    static var sheet: some View {
        let shape = RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
        return shape
            .fill(Color(uiColor: IntroPaper.sheet).shadow(.drop(color: Color(uiColor: Palette.floatingShadow).opacity(0.08), radius: 10, y: 4)))
            .overlay { shape.strokeBorder(text.opacity(0.07), lineWidth: 1) }
    }
    /// The column the steps keep to on wide screens (the Duo's inner screen).
    static let contentWidth: CGFloat = 440
    static let cardRadius: CGFloat = 16
}

// MARK: Motion

/// A part of a step arriving: it rises a little into place, after the parts before it.
private struct Entrance: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : IntroMotion.rise)
            .onAppear {
                let animation = reduceMotion
                    ? IntroMotion.crossfade
                    : IntroMotion.enter.delay(IntroMotion.enterDelay + Double(index) * IntroMotion.stagger)
                withAnimation(animation) { shown = true }
            }
    }
}

extension View {
    fileprivate func entrance(_ index: Int) -> some View { modifier(Entrance(index: index)) }
}

/// A step leaving: it lifts off like a sheet of paper, rising a little as it fades. Under Reduce
/// Motion, a plain fade.
private struct Lift: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .offset(y: active && !reduceMotion ? -IntroMotion.lift : 0)
            .scaleEffect(active && !reduceMotion ? 0.985 : 1)
    }
}

extension AnyTransition {
    static var introLift: AnyTransition {
        .modifier(active: Lift(active: true), identity: Lift(active: false))
    }
}
#endif
