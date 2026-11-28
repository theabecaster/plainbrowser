import Foundation
import Testing
@testable import FeatureUI

/// The real Home Screen icons stay the pictures the app shows of them (docs/decisions.md, "App
/// icons: the Home Screen shows the picker's art"). Reads the repository's files: each choice's
/// Icon Composer document, project.yml's alternate icon names and the picker's previews.
///
/// The owner's report that led here: only one icon on the Home Screen looked like its tile. With
/// no dark fill of their own, iOS drew a near-black field under Coral's and Paper's art on a dark
/// Home Screen, and Dawn's designed dark art was a different picture from its tile.
@Suite struct AppIconDocumentTests {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private static func document(_ choice: AppIconChoice) -> URL {
        repo.appending(path: "Brand/\(choice.alternateIconName ?? "AppIcon").icon")
    }

    private static func json(_ choice: AppIconChoice) throws -> [String: Any] {
        let data = try Data(contentsOf: document(choice).appending(path: "icon.json"))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Every choice is a document that project.yml compiles, under the name the picker sets.
    @Test func everyChoiceIsACompiledIcon() throws {
        let project = try String(contentsOf: Self.repo.appending(path: "project.yml"), encoding: .utf8)
        let line = try #require(project.split(separator: "\n").first { $0.contains("ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES:") })
        let names = line.split(separator: ":", maxSplits: 1)[1].split(separator: " ").map(String.init)
        #expect(names == AppIconChoice.allCases.compactMap(\.alternateIconName))
        #expect(project.contains("ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon\n"))
        for choice in AppIconChoice.allCases {
            let name = choice.alternateIconName ?? "AppIcon"
            #expect(project.contains("- path: Brand/\(name).icon"), "\(name) is in the app's sources")
            #expect(FileManager.default.fileExists(atPath: Self.document(choice).appending(path: "icon.json").path), "\(name)")
            #expect(choice.previewURL != nil, "\(choice) has a preview")
        }
    }

    /// A dark Home Screen shows the default art: the dark fill is the default fill, and no layer
    /// has a dark image. (Without a dark fill iOS draws its own near-black field.)
    @Test func darkIsTheDefaultArt() throws {
        for choice in AppIconChoice.allCases {
            let doc = try Self.json(choice)
            let fills = try #require(doc["fill-specializations"] as? [[String: Any]])
            let plain = try #require(fills.first { $0["appearance"] == nil }?["value"] as? NSDictionary)
            let dark = try #require(fills.first { $0["appearance"] as? String == "dark" }?["value"] as? NSDictionary,
                                    "\(choice) has a dark fill")
            #expect(dark == plain, "\(choice): the dark fill is the default one")
            let groups = try #require(doc["groups"] as? [[String: Any]])
            for group in groups {
                for layer in group["layers"] as? [[String: Any]] ?? [] {
                    let specs = layer["image-name-specializations"] as? [[String: Any]] ?? []
                    #expect(!specs.contains { $0["appearance"] as? String == "dark" }, "\(choice) \(layer["name"] ?? "")")
                }
            }
        }
    }

    /// The icon's colors are the splash's and the intro mark's (`SplashTheme`): its field, its
    /// paper, its fold and the dawn in its window.
    @Test func theIconIsTheSplashsWorld() throws {
        func hex(_ c: SplashColor) -> String {
            String(format: "#%02X%02X%02X", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
        }
        func srgb(_ c: SplashColor) -> String {
            func n(_ v: Double) -> String { v == v.rounded() ? String(format: "%.1f", v) : String(format: "%.2f", v) }
            return "srgb:\(n(c.r)),\(n(c.g)),\(n(c.b)),1.0"
        }
        for choice in AppIconChoice.allCases {
            let theme = SplashTheme.theme(for: choice)
            let doc = try Self.json(choice)
            let fills = try #require(doc["fill-specializations"] as? [[String: Any]])
            let gradient = (fills.first?["value"] as? [String: Any])?["linear-gradient"] as? [String]
            #expect(gradient == theme.field.map(srgb), "\(choice) field")
            func asset(_ name: String) throws -> String {
                try String(contentsOf: Self.document(choice).appending(path: "Assets/\(name)"), encoding: .utf8).uppercased()
            }
            let ring = try asset("ring.svg"), curl = try asset("curl.svg"), view = try asset("view.svg")
            for c in theme.paper + [theme.paperWarm, theme.flapShade] { #expect(ring.contains(hex(c)), "\(choice) ring \(hex(c))") }
            for c in theme.curl { #expect(curl.contains(hex(c)), "\(choice) curl \(hex(c))") }
            for c in theme.sky + theme.planet + theme.sun + [theme.rim] { #expect(view.contains(hex(c)), "\(choice) view \(hex(c))") }
        }
    }
}
