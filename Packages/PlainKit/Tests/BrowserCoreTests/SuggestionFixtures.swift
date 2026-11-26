import Foundation

/// Response bodies recorded from each suggestion endpoint on 2026-11-26 (query "swift ui" unless
/// noted). Tests parse these instead of touching the network.
enum SuggestionFixtures {
    static let google = #"""
    ["swift ui",["swift ui","swift ui documentation","swift ui components","swift ui skill","swift ui tutorial","swift ui vs uikit","swift ui buttons","swift ui component library","swift ui examples","swift ui library"],[],{"google:suggestsubtypes":[[512,433],[512],[512],[512],[512],[512],[512],[512],[512],[512]]}]
    """#

    /// Query "café". Location-specific entries removed from the recording.
    static let googleUnicode = #"""
    ["café",["café","café au lait","café de flore"],[],{"google:suggestsubtypes":[[512,433,131,457],[512],[512]]}]
    """#

    static let duckDuckGo = #"""
    ["swift ui",["swift ui","swift ui tutorial","swift ui windows","swift uikit","swift ui interview questions","swift ui documentation","swift ui online","swift ui docs"]]
    """#

    static let brave = #"""
    ["swift ui",["swiftui","swiftui tutorial","swiftui documentation","swiftui picker","swiftui smoke effect","swiftui xcode cloud","swiftui view size","swiftui dividerstyle"]]
    """#

    static let kagi = #"""
    ["swift ui",["swift ui tutorial","swift ui windows","swift uikit","swift ui interview questions","swift ui documentation","swift ui online","swift ui docs","swift ui skill","swift ui compiler","swift ui interview questions and answers"]]
    """#

    /// Startpage repeats entries; the parser drops the duplicate.
    static let startpage = #"""
    ["swift ui",["swift ui","swift ui"]]
    """#
}
