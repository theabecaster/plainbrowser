#if os(iOS)
import PlainShared
import SwiftUI
import Testing
import WidgetKit
@testable import WidgetUI

@Suite struct WidgetTimelineTests {
    @Test func oneEntryWithTheFavoritesAndNoRefresh() {
        let favorites = SearchWidgetContent.sample.favorites
        let provider = SearchProvider { SearchWidgetContent(favorites: favorites + favorites) }
        let timeline = provider.timeline()
        #expect(timeline.entries.count == 1)
        #expect(timeline.entries.first?.content.favorites == favorites)
        #expect(timeline.policy == .never)
    }

    @Test func theGalleryShowsTheSampleUntilThereAreFavorites() {
        let empty = SearchProvider { SearchWidgetContent(favorites: []) }
        #expect(empty.snapshot(isPreview: true).content == .sample)
        #expect(empty.snapshot(isPreview: false).content.favorites.isEmpty)
    }
}

/// Renders the widget faces to PNGs for review (docs/workflow.md, design review). The folder is
/// `PLAIN_WIDGET_SHOTS` (pass `TEST_RUNNER_PLAIN_WIDGET_SHOTS` to xcodebuild), else a temporary one;
/// the path is printed.
@MainActor @Suite struct WidgetFaceRenders {
    private static let folder: URL = {
        let path = ProcessInfo.processInfo.environment["PLAIN_WIDGET_SHOTS"]
        let url = path.map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.temporaryDirectory.appending(path: "PlainWidgetShots", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// A Home Screen widget's frame: paper behind, 16 pt margins, the system's corner radius.
    private func homeScreen(_ content: some View, size: CGSize) -> some View {
        ZStack {
            WidgetPaper()
            content.padding(16)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(20)
        .background(Color(white: 0.55))
    }

    private func render(_ view: some View, name: String, dark: Bool) throws {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 3
        let image = try #require(renderer.uiImage)
        let url = Self.folder.appending(path: "\(name)-\(dark ? "dark" : "light").png")
        try #require(image.pngData()).write(to: url)
        print("[plain-widget-shot] \(url.path)")
    }

    @Test(arguments: [false, true]) func faces(dark: Bool) throws {
        let small = CGSize(width: 170, height: 170)
        let medium = CGSize(width: 364, height: 170)
        try render(homeScreen(SmallSearch(), size: small), name: "small", dark: dark)
        try render(homeScreen(MediumSearch(favorites: SearchWidgetContent.sample.favorites), size: medium),
                   name: "medium", dark: dark)
        try render(homeScreen(MediumSearch(favorites: Array(SearchWidgetContent.sample.favorites.prefix(2))), size: medium),
                   name: "medium-two", dark: dark)
        try render(homeScreen(MediumSearch(favorites: []), size: medium), name: "medium-empty", dark: dark)
        let lock = ZStack { Color.black; HStack(spacing: 24) {
            AccessoryCircular().frame(width: 72, height: 72)
            AccessoryRectangular().frame(width: 172, height: 76)
        } }
        .frame(width: 320, height: 120)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        try render(lock, name: "lockscreen", dark: dark)
    }
}
#endif
