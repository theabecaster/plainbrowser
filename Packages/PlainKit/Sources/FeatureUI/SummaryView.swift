#if os(iOS)
import BrowserCore
import DesignSystem
import Observation
import PerfSignposts
import SwiftUI

/// What the summary screen shows, fed by the shell from the summary pipeline. Structure changes
/// (a stage, a source's state, a new section or point) show at once; the words of a point that is
/// being written redraw at most every `FixedChoices.summaryRedrawInterval`, so streaming costs a
/// steady few layouts a second instead of one per token.
@MainActor @Observable public final class SummaryScreenModel {
    public private(set) var progress: SummaryProgress
    /// Sources opened in the background from this screen, marked on their rows.
    public private(set) var openedInBackground: Set<URL> = []

    /// Open a source: in a new tab, shown (`background` false), or behind the page.
    @ObservationIgnored public var onOpenSource: (URL, _ background: Bool) -> Void = { _, _ in }
    /// Try Again after a failure that a second try can help.
    @ObservationIgnored public var onRetry: () -> Void = {}
    /// Browse for Me's way out: the ordinary search for the same words.
    @ObservationIgnored public var onSearchInstead: ((String) -> Void)?
    @ObservationIgnored public var onDone: () -> Void = {}

    @ObservationIgnored private var pending: SummaryProgress?
    @ObservationIgnored private var flush: Task<Void, Never>?

    public init(progress: SummaryProgress) {
        self.progress = progress
    }

    public func apply(_ next: SummaryProgress) {
        if Self.onlyWordsChanged(from: progress, to: next) {
            pending = next
            guard flush == nil else { return }
            flush = Task { [weak self] in
                try? await Task.sleep(for: FixedChoices.summaryRedrawInterval)
                guard let self, !Task.isCancelled else { return }
                self.flush = nil
                if let pending = self.pending {
                    self.pending = nil
                    self.progress = pending
                }
            }
        } else {
            flush?.cancel()
            flush = nil
            pending = nil
            progress = next
        }
    }

    func markOpened(_ url: URL) {
        openedInBackground.insert(url)
    }

    /// The same stage, sources and outline: only words within the current title or points grew.
    static func onlyWordsChanged(from old: SummaryProgress, to new: SummaryProgress) -> Bool {
        guard old.stage == new.stage, old.sources == new.sources, old.subject == new.subject,
              old.draft.sections.count == new.draft.sections.count, !old.draft.isEmpty
        else { return false }
        for (a, b) in zip(old.draft.sections, new.draft.sections) where a.points.count != b.points.count || a.heading != b.heading {
            return false
        }
        return true
    }
}

/// The summary page: Browse for Me's answer or a page's summary, on Plain's paper, streamed as
/// the on-device model writes it. Headings and bullet points; each point ends with numbered
/// citations that open their source; the sources are listed at the end. Before the first words,
/// the screen says honestly what it is doing: which engine it searches, which sites it reads and
/// which it skipped.
public struct SummaryView: View {
    let model: SummaryScreenModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: SummaryScreenModel) {
        self.model = model
    }

    private var progress: SummaryProgress { model.progress }

    public var body: some View {
        // The title and Done are pinned above the scroll view, not in a navigation bar: on the
        // Duo's outer screen (compact height) a sheet's bar scrolled away with the summary and
        // took Done with it (design review, 2026-11-27).
        VStack(spacing: 0) {
            SummaryHeader(title: sheetTitle, onDone: model.onDone)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if showsReading { readingList.transition(.opacity) }
                    if !progress.draft.isEmpty { summary.transition(.opacity) }
                    if case .failed(let failure) = progress.stage { failureView(failure).transition(.opacity) }
                    if progress.stage == .done, !progress.citedSources.isEmpty { sourcesList.transition(.opacity) }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.3), value: structure)
            }
            .scrollContentBackground(.hidden)
            .environment(\.openURL, OpenURLAction { url in
                guard let number = SummaryLinks.citation(url), let source = progress.source(numbered: number) else {
                    return .discarded
                }
                open(source.url, background: false)
                return .handled
            })
        }
        .paperSheet()
        .accessibilityIdentifier("summaryScreen")
    }

    private var sheetTitle: String {
        switch progress.subject {
        case .search: String(localized: "Browse for Me")
        case .page: String(localized: "Summary")
        }
    }

    /// Changes that move things: animated. Words growing inside a point are not.
    private var structure: [Int] {
        [progress.sources.count, progress.draft.sections.count, progress.draft.sections.reduce(0) { $0 + $1.points.count },
         showsReading ? 1 : 0, progress.stage.isFinished ? 1 : 0]
    }

    private var showsReading: Bool {
        guard case .search = progress.subject else { return false }
        switch progress.stage {
        case .reading: return true
        case .writing: return progress.draft.isEmpty
        default: return false
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch progress.subject {
            case .search(let query):
                Text(query)
                    .font(.system(.title2, design: .serif).weight(.semibold))
                    .foregroundStyle(Style.ink)
                    .accessibilityAddTraits(.isHeader)
            case .page(let title, let url):
                Text(title)
                    .font(.system(.title2, design: .serif).weight(.semibold))
                    .foregroundStyle(Style.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(BrowseForMe.siteName(url)).font(.subheadline).foregroundStyle(Style.inkSecondary)
            }
            status
        }
    }

    @ViewBuilder private var status: some View {
        if let line = statusLine {
            HStack(spacing: 8) {
                if !progress.stage.isFinished { ProgressView().controlSize(.small) }
                Text(line).font(.footnote).foregroundStyle(Style.inkSecondary)
                    .contentTransition(.opacity)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("summaryStatus")
        }
    }

    private var statusLine: String? {
        switch progress.stage {
        case .searching(let engine): return String(localized: "Searching \(engine)…")
        case .reading:
            // What is left, as the rows show what is done or skipped.
            let left = progress.sources.filter { $0.state == .reading || $0.state == .waiting }.count
            return left == 1 ? String(localized: "Reading, 1 page left…") : String(localized: "Reading, \(left) pages left…")
        case .writing:
            switch progress.subject {
            case .search:
                let count = progress.citedSources.count
                return count == 1 ? String(localized: "Writing from 1 page…") : String(localized: "Writing from \(count) pages…")
            case .page: return String(localized: "Writing…")
            }
        case .done:
            guard case .search = progress.subject else { return String(localized: "Written on this iPhone") }
            let count = progress.citedSources.count
            return count == 1 ? String(localized: "From 1 page, written on this iPhone") : String(localized: "From \(count) pages, written on this iPhone")
        case .failed: return nil
        }
    }

    // MARK: Reading

    private var readingList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(progress.sources) { source in
                ReadingRow(source: source)
                if source.id != progress.sources.last?.id { Divider().overlay(Style.hairline) }
            }
        }
        .padding(.horizontal, 14)
        .background(Style.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("summaryReading")
    }

    // MARK: Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(progress.draft.sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 8) {
                    if !section.heading.isEmpty {
                        Text(section.heading)
                            .font(.system(.headline, design: .serif))
                            .foregroundStyle(Style.ink)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(Array(section.points.enumerated()), id: \.offset) { _, point in
                        PointRow(point: point, sources: progress.sources)
                    }
                }
            }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("summaryText")
    }

    // MARK: Sources

    private var sourcesList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sources").font(.system(.headline, design: .serif)).foregroundStyle(Style.ink)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(progress.citedSources) { source in
                    SourceRow(
                        source: source, opened: model.openedInBackground.contains(source.url),
                        open: { open(source.url, background: $0) }
                    )
                    if source.id != progress.citedSources.last?.id { Divider().overlay(Style.hairline) }
                }
            }
            .padding(.horizontal, 14)
            .background(Style.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("summarySources")
    }

    private func open(_ url: URL, background: Bool) {
        if background { model.markOpened(url) }
        model.onOpenSource(url, background)
    }

    // MARK: Failure

    private func failureView(_ failure: SummaryFailure) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(failure.message)
                .font(.body)
                .foregroundStyle(Style.ink)
                .accessibilityIdentifier("summaryFailure")
            if failure.canRetry {
                Button("Try Again") { model.onRetry() }
                    .buttonStyle(.borderedProminent)
                    .tint(Style.accent)
                    .accessibilityIdentifier("summaryTryAgain")
            } else if case .search(let query) = progress.subject, let searchInstead = model.onSearchInstead {
                Button("Search Instead") { searchInstead(query) }
                    .buttonStyle(.borderedProminent)
                    .tint(Style.accent)
                    .accessibilityIdentifier("summarySearchInstead")
            }
        }
        .padding(.top, 4)
    }
}

/// The sheet's header: its serif title centered, as every sheet's, and the one Done at the end.
/// Opaque paper, outside the scroll view, so it stays put and the text never shows through it.
private struct SummaryHeader: View {
    let title: String
    let onDone: () -> Void

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(.headline, design: .serif))
                .foregroundStyle(Style.ink)
                .lineLimit(1)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 96)
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(.glass)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Style.hairline).frame(height: 0.5)
        }
    }
}

/// Citation links inside the summary's text: `plain-citation:<n>`, handled by the screen, never
/// opened as a web address.
enum SummaryLinks {
    static let scheme = "plain-citation"

    static func url(_ number: Int) -> URL { URL(string: "\(scheme):\(number)")! }

    static func citation(_ url: URL) -> Int? {
        guard url.scheme == scheme else { return nil }
        return Int(url.absoluteString.dropFirst(scheme.count + 1))
    }
}

/// One source while the pages are read: its site, its title and what is happening to it.
private struct ReadingRow: View {
    let source: SummarySource

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.site).font(.subheadline.weight(.semibold)).foregroundStyle(Style.ink)
                Text(source.title).font(.footnote).foregroundStyle(Style.inkSecondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            stateView
        }
        .padding(.vertical, 10)
        .opacity(source.state == .skipped ? 0.72 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityValue(stateLabel)
    }

    @ViewBuilder private var stateView: some View {
        switch source.state {
        case .waiting: Image(systemName: "circle").foregroundStyle(Style.hairline).imageScale(.small)
        case .reading: ProgressView().controlSize(.small)
        case .read: Image(systemName: "checkmark").foregroundStyle(Style.accent).fontWeight(.semibold).imageScale(.small)
        case .skipped: Text("Skipped").font(.footnote).foregroundStyle(Style.inkSecondary)
        }
    }

    private var stateLabel: String {
        switch source.state {
        case .waiting: String(localized: "Waiting")
        case .reading: String(localized: "Reading")
        case .read: String(localized: "Read")
        case .skipped: String(localized: "Skipped")
        }
    }
}

/// A bullet point: its text, then its citations as small numbered links in the accent color.
private struct PointRow: View {
    let point: SummaryDraft.Point
    let sources: [SummarySource]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(Style.inkSecondary).accessibilityHidden(true)
            Text(attributed)
                .font(.body)
                .foregroundStyle(Style.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var attributed: AttributedString {
        var text = AttributedString(point.text)
        // "¹,²", never "¹²": two sources must not read as source twelve.
        for (index, number) in point.sources.enumerated() {
            var space = AttributedString(index == 0 ? "\u{2009}" : ",\u{2009}")
            space.font = .caption2.weight(.semibold)
            space.foregroundColor = Style.inkSecondary
            space.baselineOffset = 5
            var mark = AttributedString("\(number)")
            mark.font = .caption2.weight(.semibold)
            mark.foregroundColor = Style.accent
            mark.baselineOffset = 5
            mark.link = SummaryLinks.url(number)
            text += space + mark
        }
        return text
    }

    private var accessibilityText: String {
        let names = point.sources.compactMap { number in sources.first { $0.number == number }?.site }
        guard !names.isEmpty else { return point.text }
        let end = point.text.last.map { ".!?".contains($0) } == true ? " " : ". "
        return point.text + end + String(localized: "Sources: \(names.joined(separator: ", "))")
    }
}

/// A source at the end of the summary: its number, title and site. A tap opens it in a new tab;
/// its menu opens it behind the page, copies or shares the link.
private struct SourceRow: View {
    let source: SummarySource
    let opened: Bool
    let open: (_ background: Bool) -> Void

    var body: some View {
        Button { open(false) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(source.number ?? 0)")
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Style.accent)
                    .frame(minWidth: 18, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title).font(.subheadline).foregroundStyle(Style.ink).lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(opened ? String(localized: "\(source.site) · Opened in background") : source.site)
                        .font(.footnote).foregroundStyle(Style.inkSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { open(false) } label: { Label("Open in New Tab", systemImage: "plus.square.on.square") }
            Button { open(true) } label: { Label("Open in Background", systemImage: "square.on.square.dashed") }
            Button { copyLink(source.url) } label: { Label("Copy Link", systemImage: "link") }
            ShareLink(item: source.url) { Label("Share", systemImage: "square.and.arrow.up") }
        }
        .accessibilityIdentifier("summarySource.\(source.number ?? 0)")
    }
}

#if DEBUG
#Preview("Browse for Me, writing") {
    let model = SummaryScreenModel(progress: SummaryProgress(
        subject: .search("best trail running shoes"), stage: .writing,
        sources: [
            SummarySource(url: URL(string: "https://www.runnersworld.example/a")!, title: "The best trail shoes", state: .read, number: 1),
            SummarySource(url: URL(string: "https://slow.example/b")!, title: "Slow", state: .skipped),
            SummarySource(url: URL(string: "https://gear.example/c")!, title: "Gear guide", state: .read, number: 2),
        ],
        draft: SummaryDraft(title: "Grip, fit and cushioning matter most", sections: [
            .init(heading: "What to look for", points: [
                .init(text: "Deep lugs grip on mud and loose rock.", sources: [1, 2]),
                .init(text: "A snug heel and room for the toes prevent blisters on descents.", sources: [2]),
            ]),
        ])
    ))
    return SummaryView(model: model)
}
#endif
#endif
