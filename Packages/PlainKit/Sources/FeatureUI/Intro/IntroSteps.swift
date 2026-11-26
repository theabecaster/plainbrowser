#if os(iOS)
import DesignSystem
import SwiftUI

/// The intro's steps after the splash. A step leaves with a blur dissolve; the next one's parts
/// arrive one after another (headline, then rows or the demo, then the button), each rising out of
/// a blur. The field behind them is `IntroBackdrop`, owned by the view controller.
struct IntroStepsView: View {
    @Bindable var model: IntroModel

    var body: some View {
        ZStack {
            if let step = model.step {
                StepView(step: step, model: model)
                    .id(step)
                    .transition(.asymmetric(insertion: .identity, removal: .introDissolve))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StepView: View {
    let step: IntroModel.Step
    @Bindable var model: IntroModel

    private var ink: Color { step == .defaultBrowser ? IntroStyle.ink : IntroStyle.onField }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip") { model.skip() }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ink.opacity(0.8))
                    .frame(minWidth: 44, minHeight: 44)
                    .padding(.trailing, 8)
                    .accessibilityIdentifier("introSkip")
                    .accessibilityHint("Ends the introduction")
            }
            .entrance(0)
            content
                .frame(maxWidth: IntroStyle.contentWidth, maxHeight: .infinity)
                .padding(.horizontal, 24)
            buttons
                .frame(maxWidth: IntroStyle.contentWidth)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
        }
        .foregroundStyle(ink)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("intro.\(step.rawValue)")
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
                Button("Set as Default Browser") {
                    DefaultBrowserPrompts.openSettings()
                    model.finish()
                }
                .buttonStyle(IntroPillStyle(kind: .lagoon))
                .accessibilityIdentifier("introSetDefault")
                Button("Not Now") { model.finish() }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(IntroStyle.ink.opacity(0.7))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("introNotNow")
            }
            .entrance(6)
        default:
            Button(model.isLastStep ? "Let’s Go" : "Next") { model.next() }
                .buttonStyle(IntroPillStyle(kind: .paper))
                .accessibilityIdentifier(model.isLastStep ? "introLetsGo" : "introNext")
                .entrance(step == .promise ? 3 : 6)
        }
    }
}

// MARK: Steps

/// "The web, plainly." under the mark (the mark is the splash's, held by the view controller).
private struct PromiseStep: View {
    var body: some View {
        VStack(spacing: 0) {
            // The splash's mark rests here (IntroLayout).
            Color.clear.frame(height: IntroLayout.promiseMarkTop + IntroLayout.promiseMarkSize - 44)
            Spacer(minLength: 24)
            DisplayText(lead: "The web,", emphasis: "plainly", trail: ".")
                .entrance(1)
            Text("Nothing in the way of the page.")
                .font(.title3.weight(.medium))
                .opacity(0.85)
                .multilineTextAlignment(.center)
                .padding(.top, 14)
                .entrance(2)
            Spacer(minLength: 24)
            Spacer(minLength: 0)
        }
    }
}

private struct InsideStep: View {
    private let rows: [(symbol: String, title: String, detail: String, tint: Color)] = [
        ("shield.lefthalf.filled", "Blocking, Everywhere", "Ads, trackers and cookie walls stay off every site.", IntroStyle.coral),
        ("archivebox.fill", "Tabs Tidy Themselves", "Tabs you leave for a day move to a searchable archive.", IntroStyle.mint),
        ("eye.slash.fill", "Private Tabs", "No history, and nothing kept once you close them.", IntroStyle.violet),
        ("rectangle.split.2x1.fill", "Made for iPhone Duo", "Unfold for two pages side by side.", IntroStyle.lagoon),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                DisplayText(lead: "Built to stay", emphasis: "out of your way", trail: "")
                    .padding(.top, 12)
                    .padding(.bottom, 14)
                    .entrance(1)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    FeatureRow(symbol: row.symbol, title: row.title, detail: row.detail, tint: row.tint)
                        .entrance(2 + index)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(tint.gradient, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).opacity(0.72)
            }
            .foregroundStyle(IntroStyle.ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(IntroStyle.card, in: .rect(cornerRadius: IntroStyle.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct IconStep: View {
    @Bindable var model: IntroModel
    private let columns = [GridItem(.flexible(), spacing: 20), GridItem(.flexible(), spacing: 20)]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                DisplayText(lead: "Pick your", emphasis: "icon", trail: "")
                    .padding(.top, 12)
                    .entrance(1)
                Text("For your Home Screen. Change it any time in Settings.")
                    .font(.body.weight(.medium))
                    .opacity(0.85)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                    .entrance(2)
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(Array(AppIconChoice.allCases.enumerated()), id: \.element) { index, choice in
                        IconTile(choice: choice, image: model.iconPreviews[choice], selected: model.icon == choice) {
                            withAnimation(Motion.urlFocus) { model.pick(choice) }
                        }
                        .entrance(3 + index)
                    }
                }
                .frame(maxWidth: 300)
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
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 84

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    if let image {
                        Image(uiImage: image).resizable().interpolation(.high)
                    } else {
                        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).fill(.white.opacity(0.2))
                    }
                }
                .frame(width: size, height: size)
                .clipShape(.rect(cornerRadius: size * 0.225, style: .continuous))
                .padding(5)
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.225 + 5, style: .continuous)
                        .strokeBorder(.white, lineWidth: selected ? 3 : 0)
                }
                .scaleEffect(selected ? 1.04 : 1)
                HStack(spacing: 6) {
                    ZStack {
                        Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1.5)
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
            DisplayText(lead: "The page,", emphasis: "minus the junk", trail: "")
                .padding(.top, 4)
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
            Spacer(minLength: 12)
            StemMark()
                .frame(width: 112, height: 116)
                .entrance(1)
            DisplayText(lead: "Make Plain your", emphasis: "default", trail: "")
                .padding(.top, 26)
                .entrance(2)
            Text("Links from Mail, Messages and every other app open in Plain, with blocking on.")
                .font(.body.weight(.medium))
                .opacity(0.75)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
                .entrance(3)
            Spacer(minLength: 12)
            Spacer(minLength: 0)
        }
    }
}

// MARK: Shared pieces

/// The intro's display line: big, heavy and rounded, with one word in italics.
struct DisplayText: View {
    let lead: String
    let emphasis: String
    let trail: String
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 38

    var body: some View {
        Text("\(lead) \(Text(emphasis).italic())\(trail)")
            .font(.system(size: size, weight: .heavy, design: .rounded))
            .tracking(-0.4)
            .multilineTextAlignment(.center)
            .lineSpacing(-2)
            .minimumScaleFactor(0.7)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The big capsule buttons.
struct IntroPillStyle: ButtonStyle {
    enum Kind { case paper, lagoon }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(kind == .paper ? IntroStyle.lagoon : .white)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(kind == .paper ? IntroStyle.paper : IntroStyle.lagoon, in: .capsule)
            .shadow(color: .black.opacity(kind == .paper ? 0.12 : 0.18), radius: 12, y: 6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

/// The static Stem mark, for SwiftUI.
struct StemMark: UIViewRepresentable {
    func makeUIView(context: Context) -> StemMarkView { StemMarkView() }
    func updateUIView(_ view: StemMarkView, context: Context) {}
}

enum IntroStyle {
    static let ink = Color(uiColor: BrandArt.ink)
    static let onField = Color(uiColor: BrandArt.onField)
    static let paper = Color(uiColor: BrandArt.paperField)
    static let card = Color(uiColor: BrandArt.paperField).opacity(0.94)
    static let lagoon = Color(uiColor: BrandArt.lagoon)
    static let mint = Color(uiColor: BrandArt.mint)
    static let coral = Color(uiColor: BrandArt.coral)
    static let violet = Color(uiColor: BrandArt.bloomViolet)
    /// The column the steps keep to on wide screens (the Duo's inner screen).
    static let contentWidth: CGFloat = 440
    static let cardRadius: CGFloat = 18
}

/// Where the splash's mark comes to rest on the promise step, shared by the view controller (which
/// moves the mark there) and `PromiseStep` (which leaves the room for it).
enum IntroLayout {
    /// From the safe area's top to the mark's top.
    static let promiseMarkTop: CGFloat = 76
    static let promiseMarkSize: CGFloat = 96
}

// MARK: Motion

/// A part of a step arriving: it rises a little out of a blur, after the parts before it.
private struct Entrance: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let still = shown || reduceMotion
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: still ? 0 : IntroMotion.blur)
            .offset(y: still ? 0 : IntroMotion.rise)
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

/// A step leaving: it blurs, fades and shrinks a little. Under Reduce Motion, a plain fade.
private struct Dissolve: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .blur(radius: active && !reduceMotion ? IntroMotion.blur : 0)
            .scaleEffect(active && !reduceMotion ? 0.96 : 1)
    }
}

extension AnyTransition {
    static var introDissolve: AnyTransition {
        .modifier(active: Dissolve(active: true), identity: Dissolve(active: false))
    }
}
#endif
