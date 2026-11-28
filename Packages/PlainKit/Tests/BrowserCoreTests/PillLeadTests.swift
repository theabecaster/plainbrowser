import BrowserCore
import Testing

/// The pill's one lead word (docs/decisions.md, "The pill's lead word").
@Suite struct PillLeadTests {
    @Test func oneWordByPrecedence() {
        #expect(PillLead.resolve(isPrivate: false, isReader: false, isTranslated: false, notSecure: false) == nil)
        #expect(PillLead.resolve(isPrivate: false, isReader: false, isTranslated: false, notSecure: true) == .notSecure)
        #expect(PillLead.resolve(isPrivate: false, isReader: true, isTranslated: false, notSecure: true) == .reader)
        #expect(PillLead.resolve(isPrivate: false, isReader: false, isTranslated: true, notSecure: true) == .translated)
        // The reader shows the article's text, not the translated page under it.
        #expect(PillLead.resolve(isPrivate: false, isReader: true, isTranslated: true, notSecure: false) == .reader)
        #expect(PillLead.resolve(isPrivate: true, isReader: true, isTranslated: true, notSecure: true) == .private)
    }

    @Test func words() {
        #expect(PillLead.reader.word == "Reader")
        #expect(PillLead.translated.word == "Translated")
        #expect(PillLead.notSecure.word == "Not Secure")
        #expect(PillLead.private.word == "Private")
    }
}
