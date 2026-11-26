// Checks on the generated lists themselves: plain JSON, no WebKit, so they run on macOS too.
import BrowserCore
@testable import ContentBlocking
import CryptoKit
import Foundation
import Testing

@Suite struct BundledListTests {
    let directory = RuleListManifest.bundledDirectory!

    func actions(in list: RuleListManifest.List) throws -> [String: Int] {
        let data = try Data(contentsOf: directory.appendingPathComponent(list.file))
        let rules = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        var counts: [String: Int] = [:]
        for rule in rules {
            let type = (rule["action"] as? [String: Any])?["type"] as? String ?? "?"
            counts[type, default: 0] += 1
        }
        return counts
    }

    @Test func manifestMatchesTheFiles() async throws {
        let manifest = try await RuleListManifest.load(from: directory)
        #expect(!manifest.lists.isEmpty)
        for list in manifest.lists {
            let data = try Data(contentsOf: directory.appendingPathComponent(list.file))
            #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == list.sha256, "\(list.name)")
            #expect(list.ruleCount <= 35_000, "\(list.name)")
        }
    }

    /// All `css-display-none` rules are in the cosmetic list, and it holds nothing else but
    /// exceptions; the priority list holds network blocks only.
    @Test func cosmeticRulesAreInOneListAndThePriorityListIsNetworkOnly() async throws {
        let manifest = try await RuleListManifest.load(from: directory)
        var cosmeticLists: [String] = []
        for list in manifest.lists {
            let counts = try actions(in: list)
            if counts["css-display-none", default: 0] > 0 { cosmeticLists.append(list.name) }
            switch list.name {
            case FixedChoices.priorityBlocklist:
                #expect(Set(counts.keys).isSubset(of: ["block", "block-cookies", "ignore-previous-rules", "make-https"]))
            case FixedChoices.cosmeticBlocklist:
                #expect(Set(counts.keys) == ["css-display-none", "ignore-previous-rules"])
            default:
                break
            }
        }
        #expect(cosmeticLists == [FixedChoices.cosmeticBlocklist])
    }

    @Test func priorityThenCosmeticCompileFirst() {
        func list(_ name: String) -> RuleListManifest.List {
            .init(name: name, file: name + ".json", sha256: String(repeating: "0", count: 64), ruleCount: 1)
        }
        let order = ContentBlocker.compileOrder(["blocklist-04", "blocklist-02", "blocklist-03", "blocklist-01"].map(list))
        #expect(order.map(\.name) == ["blocklist-01", "blocklist-02", "blocklist-04", "blocklist-03"])
    }
}
