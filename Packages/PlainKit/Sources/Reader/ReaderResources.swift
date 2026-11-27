import DesignSystem
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The files the reader bundles: Readability's scripts, the page template and its stylesheet, plus
/// the paper tiles under the page, made from the app's own `PaperTexture`.
///
/// Each file is read from the bundle once, on first use. Every accessor is `@concurrent`, so the
/// read never happens on the main thread.
enum ReaderResources {
    enum Failure: Error {
        case missing(String)
    }

    /// `Readability-readerable.js` alone (about 4 KB): defines `isProbablyReaderable`. This is the
    /// only part that runs on every page.
    @concurrent static func readerableScript() async throws -> String {
        try readerable.get()
    }

    /// `Readability-readerable.js` followed by `Readability.js`. Evaluating it defines
    /// `isProbablyReaderable` and `Readability` in the reader's content world. Injected only when
    /// the user opens reader mode.
    @concurrent static func readabilityScript() async throws -> String {
        try readability.get()
    }

    /// The reader page template, parsed into slots.
    @concurrent static func template() async throws -> ReaderTemplate {
        try parsedTemplate.get()
    }

    /// The reader stylesheet.
    @concurrent static func stylesheet() async throws -> Data {
        try css.get()
    }

    /// The paper tile for `sheet` as a PNG (320 px square), for the page's background.
    @concurrent static func paperTile(_ sheet: PaperTexture.Sheet) async throws -> Data {
        try (sheet == .day ? paperDay : paperNight).get()
    }

    // Static lets are initialized lazily and exactly once, on the first caller's thread, which is
    // always one of the `@concurrent` accessors above.

    private static let readerable: Result<String, any Error> = Result {
        try text("Readability-readerable", "js")
    }

    private static let readability: Result<String, any Error> = Result {
        try readerable.get() + "\n;\n" + text("Readability", "js") + "\n;true;"
    }

    private static let parsedTemplate: Result<ReaderTemplate, any Error> = Result {
        ReaderTemplate(try text("reader", "html"))
    }

    private static let css: Result<Data, any Error> = Result {
        guard let url = Bundle.module.url(forResource: "reader", withExtension: "css", subdirectory: "Reader")
        else { throw Failure.missing("reader.css") }
        return try Data(contentsOf: url)
    }

    private static let paperDay: Result<Data, any Error> = Result { try png(.day) }
    private static let paperNight: Result<Data, any Error> = Result { try png(.night) }

    private static func png(_ sheet: PaperTexture.Sheet) throws -> Data {
        let data = NSMutableData()
        guard let image = PaperTexture.makeImage(sheet),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure.missing("paper tile") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.missing("paper tile") }
        return data as Data
    }

    private static func text(_ name: String, _ ext: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Reader")
        else { throw Failure.missing("\(name).\(ext)") }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
