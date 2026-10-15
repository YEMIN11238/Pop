import XCTest
@testable import Pop

final class TextUtilitiesTests: XCTestCase {
    func testSelectedIdentifiersAreSplitWithoutBreakingAcronyms() {
        let cases = [
            "getUserName": "get User Name", "parseHTTPResponse": "parse HTTP Response",
            "user_name": "user name", "__HTTP_RESPONSE__": "HTTP RESPONSE",
            "version2Value": "version2 Value", "HTTP": "HTTP", "Hello": "Hello"
        ]
        for (input, expected) in cases {
            XCTAssertEqual(TextUtilities.normalizedInput(input, splitIdentifiers: true), expected)
        }
    }

    func testProseParagraphsAndLinksStayIntact() {
        let prose = "Use camelCase in this sentence.\n\nOpenAI and HTTP are proper names."
        XCTAssertEqual(TextUtilities.normalizedInput(prose, splitIdentifiers: true), prose)
        for value in ["https://example.com/mySnake_case?q=getUserID", "www.example.com/my_value", "user_name@example.com"] {
            XCTAssertEqual(TextUtilities.normalizedInput(value, splitIdentifiers: true), value)
        }
    }

    func testSplittingCanBeDisabledAndSelectionEdgesAreTrimmed() {
        XCTAssertEqual(TextUtilities.normalizedInput("  getUserID\n", splitIdentifiers: false), "getUserID")
        XCTAssertEqual(TextUtilities.normalizedInput("\n\t", splitIdentifiers: true), "")
        XCTAssertEqual(TextUtilities.normalizedInput("___", splitIdentifiers: true), "___")
    }

    func testLocalLanguageDetectionHasExplicitUnknownResult() {
        XCTAssertEqual(TextUtilities.detectLanguage("1234 !?"), "auto")
        XCTAssertEqual(TextUtilities.detectLanguage(""), "auto")
        XCTAssertEqual(TextUtilities.detectLanguage("The application translates a selected paragraph into another language and preserves its meaning."), "en")
    }

    func testReadingLanguagePreservesUsefulRegionalVariants() {
        XCTAssertEqual(TextUtilities.readingLanguageCode("zh-Hans"), "zh-CN")
        XCTAssertEqual(TextUtilities.readingLanguageCode("zh-Hant"), "zh-TW")
        XCTAssertEqual(TextUtilities.readingLanguageCode("en-GB"), "en-GB")
        XCTAssertEqual(TextUtilities.readingLanguageCode("ja"), "ja-JP")
    }

    func testEntitiesAreDecodedOnceWithoutParsingMarkup() {
        XCTAssertEqual(TextUtilities.decodeHTMLEntities("A &amp; B &lt;tag&gt; &quot;x&quot; &#39;y&#39; &#x4E2D;&#25991;"), "A & B <tag> \"x\" 'y' 中文")
        XCTAssertEqual(TextUtilities.decodeHTMLEntities("&amp;lt; &unknown; &#xD800; &#9999999999999999;"), "&lt; &unknown; &#xD800; &#9999999999999999;")
        XCTAssertEqual(TextUtilities.decodeHTMLEntities("&eacute;&hellip;"), "é…")
    }
}
