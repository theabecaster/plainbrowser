// plain-blocklists: fetches the filter lists in sources.json, converts them from Adblock syntax to
// WebKit content-rule JSON with SafariConverterLib, splits the result into lists small enough to
// compile reliably on iOS, and writes the JSON, a manifest with content hashes and a NOTICE file.
//
// Lists come out in three groups, in this order (the app compiles them in manifest order; see
// FixedChoices.priorityBlocklist and cosmeticBlocklist):
//   1. blocklist-01, the priority list: filled to the rule limit with the highest-value network
//      rules, in this order: third-party domain blocks from EasyList and EasyPrivacy
//      (`||host^$third-party`), EasyPrivacy's other domain blocks, then EasyPrivacy's other
//      network rules. Trackers and ad servers are where blocking matters most, so on first launch
//      they are blocked after the first compile, not the last.
//   2. blocklist-02: every cosmetic rule (element hiding, `css-display-none`), in one list. Each
//      frame then gets one hide stylesheet, and cosmetic churn recompiles one list. The tool fails
//      if they no longer fit in one list.
//   3. Every other network rule, including what did not fit in the priority list.
//
// Usage (from the repo root; tools/blocklists/generate.sh does this):
//   swift run -c release --package-path tools/blocklists plain-blocklists [options]
//
// Options:
//   --max-rules N   Most WebKit rules per output list (default 35000, see docs/decisions.md).
//   --output DIR    Where the JSON, manifest.json and NOTICE.txt go
//                   (default Packages/PlainKit/Sources/ContentBlocking/Resources/BlockLists).
//   --cache DIR     Where downloads are kept (default build/blocklists, gitignored).
//   --offline       Use the cached downloads instead of fetching.
//
// Output is deterministic: the same downloads give byte-identical files, so an unchanged list keeps
// its hash and the app keeps its compiled copy.

import ContentBlockerConverter
import CryptoKit
import Foundation

// MARK: - Options

struct Options {
    var maxRules = 35_000
    var output = "Packages/PlainKit/Sources/ContentBlocking/Resources/BlockLists"
    var cache = "build/blocklists"
    var sources = "tools/blocklists/sources.json"
    var offline = false

    init(arguments: [String]) throws {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            func value() throws -> String {
                guard let next = iterator.next() else { throw ToolError("\(argument) needs a value") }
                return next
            }
            switch argument {
            case "--max-rules":
                guard let number = Int(try value()), number > 0 else { throw ToolError("bad --max-rules") }
                maxRules = number
            case "--output": output = try value()
            case "--cache": cache = try value()
            case "--sources": sources = try value()
            case "--offline": offline = true
            default: throw ToolError("unknown option \(argument)")
            }
        }
    }
}

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Sources

struct Source: Codable {
    let name: String
    let url: String
    let homepage: String
    let license: String
    let licenseURL: String
    let attribution: String
}

struct FetchedSource {
    let source: Source
    let version: String
    let lines: [String]
}

func fileName(for source: Source) -> String {
    URL(string: source.url)!.lastPathComponent
}

func fetch(_ source: Source, cache: URL, offline: Bool) async throws -> String {
    let cached = cache.appendingPathComponent(fileName(for: source))
    if !offline {
        var request = URLRequest(url: URL(string: source.url)!)
        request.setValue("plain-blocklists", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ToolError("\(source.url): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        try data.write(to: cached)
    }
    guard let text = try? String(contentsOf: cached, encoding: .utf8) else {
        throw ToolError("\(cached.path) missing or not UTF-8 (run without --offline)")
    }
    return text
}

/// The list's own header value for `key` ("! Version: ..."), if it has one.
func header(_ key: String, in text: String) -> String? {
    for line in text.split(separator: "\n", maxSplits: 40).prefix(40) where line.hasPrefix("! \(key):") {
        return line.dropFirst(key.count + 3).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return nil
}

/// Filter lines with comments, headers and preprocessor blocks removed.
///
/// `!#if` blocks target other blockers (for example `!#if ext_abp`), so they are skipped whole, and
/// `!#include` is ignored: only the rules in the published file are used.
func ruleLines(of text: String) -> [String] {
    var lines: [String] = []
    var skipDepth = 0
    for raw in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("!#if") { skipDepth += 1; continue }
        if line.hasPrefix("!#endif") { skipDepth = max(0, skipDepth - 1); continue }
        if skipDepth > 0 || line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { continue }
        lines.append(line)
    }
    return lines
}

/// Element-hiding and other cosmetic rules (`##`, `#?#`, `#$#`, `#%#`), which convert to
/// `css-display-none` (or are dropped as advanced rules).
func isCosmetic(_ line: String) -> Bool {
    line.contains("##") || line.contains("#?#") || line.contains("#$#") || line.contains("#%#")
}

/// A plain domain block: `||host^`, optionally `$third-party`. EasyList's ad-server and
/// third-party sections are made of these.
func isDomainBlock(_ line: String) -> Bool {
    guard line.hasPrefix("||") else { return false }
    let parts = line.dropFirst(2).split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
    guard let pattern = parts.first, pattern.hasSuffix("^") else { return false }
    let host = pattern.dropLast()
    guard !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return false }
    guard parts.count == 2 else { return true }
    return parts[1].split(separator: ",").allSatisfy { $0 == "third-party" || $0 == "3p" }
}

/// How valuable a network line is for the priority list; lower is better, nil means "not
/// priority". See the top of the file.
func priorityRank(_ line: String, source: String) -> Int? {
    let thirdPartyDomain = isDomainBlock(line) && line.contains("$")
    switch source {
    case "EasyList": return thirdPartyDomain ? 0 : nil
    case "EasyPrivacy": return thirdPartyDomain ? 0 : isDomainBlock(line) ? 1 : 2
    default: return nil
    }
}

/// The longest start of `lines` that converts, with every exception line, to at most `maxRules`
/// rules. Binary search over the converter, which is monotonic in the lines it gets.
func fill(_ lines: [String], exceptions: [String], maxRules: Int) throws -> (chunk: Chunk, used: Int) {
    func fits(_ count: Int) -> Chunk? {
        let chunk = convert(Array(lines.prefix(count)) + exceptions)
        return chunk.discarded == 0 && chunk.ruleCount <= maxRules ? chunk : nil
    }
    if let all = fits(lines.count) { return (all, lines.count) }
    var low = 0, high = lines.count // fits(low) holds (or low is 0); fits(high) does not.
    var best: Chunk?
    while high - low > 1 {
        let middle = (low + high) / 2
        if let chunk = fits(middle) {
            low = middle
            best = chunk
        } else {
            high = middle
        }
    }
    guard let best, low > 0 else { throw ToolError("--max-rules \(maxRules) is too small for the exception lines") }
    return (best, low)
}

/// Rules that remove or weaken other rules. Every output list gets all of them, because WebKit's
/// `ignore-previous-rules` only reaches rules in the same compiled list.
func isException(_ line: String) -> Bool {
    if line.hasPrefix("@@") || line.contains("#@") { return true }
    if let dollar = line.lastIndex(of: "$"), line[dollar...].contains("badfilter") { return true }
    return false
}

// MARK: - Conversion

struct Chunk {
    let json: String
    let ruleCount: Int
    /// Rules the converter dropped because the part went over WebKit's 150k limit.
    let discarded: Int
}

func convert(_ lines: [String]) -> Chunk {
    let result = ContentBlockerConverter().convertArray(
        rules: lines,
        // Safari 26 is the newest engine the converter knows; Plain needs iOS 27.2, which has it.
        safariVersion: .safari26,
        advancedBlocking: false
    )
    return Chunk(
        json: result.safariRulesJSON, ruleCount: result.safariRulesCount,
        discarded: result.discardedSafariRules)
}

/// Splits `blocking` into the fewest parts whose converted lists each hold at most `maxRules`
/// rules. Each part is converted together with every exception line.
///
/// Lines are dealt round-robin rather than cut into runs: the lists group rules by kind (network,
/// element hiding), which convert to very different rule counts, so dealing keeps parts even.
func split(blocking: [String], exceptions: [String], maxRules: Int) throws -> [Chunk] {
    var parts = 1
    while true {
        var groups = Array(repeating: [String](), count: parts)
        for (index, line) in blocking.enumerated() { groups[index % parts].append(line) }
        let chunks = groups.map { convert($0 + exceptions) }
        // A part that lost rules to the converter's own limit counts as over the limit too.
        let largest = chunks.map { $0.ruleCount + $0.discarded }.max() ?? 0
        if largest <= maxRules && chunks.allSatisfy({ $0.discarded == 0 }) { return chunks }
        // Grow by the overshoot, at least one part, so this converges in a couple of passes.
        parts = max(parts + 1, Int((Double(parts) * Double(largest) / Double(maxRules)).rounded(.up)))
        if parts > blocking.count { throw ToolError("--max-rules \(maxRules) is too small") }
    }
}

// MARK: - Output

struct Manifest: Codable {
    struct SourceEntry: Codable {
        let name: String
        let url: String
        let version: String
        let license: String
        let ruleLines: Int
    }

    struct ListEntry: Codable {
        let name: String
        let file: String
        let sha256: String
        let ruleCount: Int
        let bytes: Int
    }

    let formatVersion: Int
    let converter: String
    let maxRulesPerList: Int
    let sources: [SourceEntry]
    let lists: [ListEntry]
}

func notice(sources: [FetchedSource], converter: String) -> String {
    var text = """
        Plain content-blocking lists: sources and licenses
        ==================================================

        The blocklist-*.json files in this folder are generated by tools/blocklists from the filter
        lists below. Each file combines rules from all of them, converted to WebKit content-rule
        JSON with \(converter) (https://github.com/AdguardTeam/SafariConverterLib, GPL-3.0),
        which runs at build time only and is not part of the app.

        The generated files are distributed under GPL-3.0-or-later, the GPL option of the EasyList
        dual license, which is compatible with Plain's AGPL-3.0-only license. The attributions
        below are kept as the source licenses require.


        """
    for fetched in sources {
        let source = fetched.source
        text += """
            \(source.name) (version \(fetched.version))
              Source:      \(source.url)
              Homepage:    \(source.homepage)
              License:     \(source.license) (\(source.licenseURL))
              Attribution: \(source.attribution)


            """
    }
    return text
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Main

func run() async throws {
    let options = try Options(arguments: CommandLine.arguments)
    // Without a fixed hash seed the converter orders some rules differently on every run, which
    // would change every list's hash and force a recompile on every device for nothing.
    guard ProcessInfo.processInfo.environment["SWIFT_DETERMINISTIC_HASHING"] == "1" else {
        throw ToolError("set SWIFT_DETERMINISTIC_HASHING=1 (tools/blocklists/generate.sh does)")
    }
    let fileManager = FileManager.default
    let cache = URL(fileURLWithPath: options.cache, isDirectory: true)
    let output = URL(fileURLWithPath: options.output, isDirectory: true)
    try fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: output, withIntermediateDirectories: true)

    let sources = try JSONDecoder().decode(
        [Source].self, from: Data(contentsOf: URL(fileURLWithPath: options.sources)))

    var fetched: [FetchedSource] = []
    for source in sources {
        let text = try await fetch(source, cache: cache, offline: options.offline)
        // A captive portal or an error page is not a filter list.
        guard let title = header("Title", in: text),
            title.caseInsensitiveCompare(source.name) == .orderedSame
        else {
            throw ToolError("\(source.url) does not look like \(source.name)")
        }
        let version = header("Version", in: text) ?? header("Last modified", in: text) ?? "unknown"
        let lines = ruleLines(of: text)
        guard lines.count > 1_000 else { throw ToolError("\(source.name) has only \(lines.count) rules") }
        fetched.append(FetchedSource(source: source, version: version, lines: lines))
        print("\(source.name) \(version): \(lines.count) rule lines")
    }

    // Lists overlap a little; keep the first copy of each line.
    var seen = Set<String>()
    var ranked: [(rank: Int, line: String)] = []
    var cosmetic: [String] = []
    var network: [String] = []
    var exceptions: [String] = []
    for fetchedSource in fetched {
        for line in fetchedSource.lines where seen.insert(line).inserted {
            if isException(line) {
                exceptions.append(line)
            } else if isCosmetic(line) {
                cosmetic.append(line)
            } else if let rank = priorityRank(line, source: fetchedSource.source.name) {
                ranked.append((rank, line))
            } else {
                network.append(line)
            }
        }
    }
    // Stable: within a rank, lines keep their list order.
    let priority = ranked.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
        .map(\.element.line)

    let (priorityChunk, used) = try fill(priority, exceptions: exceptions, maxRules: options.maxRules)
    network = Array(priority.dropFirst(used)) + network
    print("""
        priority list: \(used) of \(priority.count) priority lines; \(cosmetic.count) cosmetic lines; \
        \(network.count) other network lines; \(exceptions.count) exception lines in every list
        """)
    let cosmeticChunks = try split(blocking: cosmetic, exceptions: exceptions, maxRules: options.maxRules)
    guard cosmeticChunks.count == 1 else {
        throw ToolError("cosmetic rules need \(cosmeticChunks.count) lists; they must fit in one (raise --max-rules or trim)")
    }
    let networkChunks = try split(blocking: network, exceptions: exceptions, maxRules: options.maxRules)
    let chunks = [priorityChunk] + cosmeticChunks + networkChunks

    // Replace the previous output whole, so a list that is no longer produced does not linger.
    for file in try fileManager.contentsOfDirectory(atPath: output.path)
    where file.hasPrefix("blocklist-") && file.hasSuffix(".json") {
        try fileManager.removeItem(at: output.appendingPathComponent(file))
    }

    var lists: [Manifest.ListEntry] = []
    for (index, chunk) in chunks.enumerated() {
        let name = String(format: "blocklist-%02d", index + 1)
        let data = Data(chunk.json.utf8)
        try data.write(to: output.appendingPathComponent("\(name).json"))
        lists.append(.init(
            name: name, file: "\(name).json", sha256: sha256Hex(data), ruleCount: chunk.ruleCount,
            bytes: data.count))
        print("\(name): \(chunk.ruleCount) rules, \(data.count / 1024) KiB")
    }

    let converter = "SafariConverterLib \(ContentBlockerConverterVersion.library)"
    let manifest = Manifest(
        formatVersion: 1,
        converter: converter,
        maxRulesPerList: options.maxRules,
        sources: fetched.map {
            .init(
                name: $0.source.name, url: $0.source.url, version: $0.version,
                license: $0.source.license, ruleLines: $0.lines.count)
        },
        lists: lists
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(manifest).write(to: output.appendingPathComponent("manifest.json"))
    try Data(notice(sources: fetched, converter: converter).utf8)
        .write(to: output.appendingPathComponent("NOTICE.txt"))
    print("Wrote \(lists.count) lists, \(lists.map(\.ruleCount).reduce(0, +)) rules, to \(output.path)")
}

do {
    try await run()
} catch {
    FileHandle.standardError.write(Data("plain-blocklists: \(error)\n".utf8))
    exit(1)
}
