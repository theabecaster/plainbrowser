import Foundation

/// The files the reader bundles: Readability's scripts, the page template and its stylesheet.
///
/// Each file is read from the bundle once, on first use. Every accessor is `@concurrent`, so the
/// read never happens on the main thread.
enum ReaderResources {
    enum Failure: Error {
        case missing(String)
    }

    /// `Readability-readerable.js` followed by `Readability.js`. Evaluating it defines
    /// `isProbablyReaderable` and `Readability` in the reader's content world.
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

    // Static lets are initialized lazily and exactly once, on the first caller's thread, which is
    // always one of the `@concurrent` accessors above.

    private static let readability: Result<String, any Error> = Result {
        let readerable = try text("Readability-readerable", "js")
        let readability = try text("Readability", "js")
        return readerable + "\n;\n" + readability + "\n;true;"
    }

    private static let parsedTemplate: Result<ReaderTemplate, any Error> = Result {
        ReaderTemplate(try text("reader", "html"))
    }

    private static let css: Result<Data, any Error> = Result {
        guard let url = Bundle.module.url(forResource: "reader", withExtension: "css", subdirectory: "Reader")
        else { throw Failure.missing("reader.css") }
        return try Data(contentsOf: url)
    }

    private static func text(_ name: String, _ ext: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Reader")
        else { throw Failure.missing("\(name).\(ext)") }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
