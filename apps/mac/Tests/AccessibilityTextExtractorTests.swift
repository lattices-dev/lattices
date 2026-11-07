import AppKit
import XCTest
@testable import Lattices

final class AccessibilityTextExtractorTests: XCTestCase {
    private typealias AttributeResponse = (AXError, CFTypeRef?)

    // Creating a handle does not query an app. Every AX attribute read in these
    // tests is supplied by the fixture, including child traversal.
    private let window = AXUIElementCreateApplication(123456)

    func testSuccessfulBlankAndShortWindowsAreAvailableToIndex() {
        let empty = fixture([:]).extract(window: window, wid: 42, minChars: 0)
        XCTAssertNotNil(empty)
        XCTAssertEqual(empty?.fullText, "")

        let short = fixture([kAXValueAttribute: (.success, "OK" as NSString)])
            .extract(window: window, wid: 42, minChars: 0)
        XCTAssertEqual(short?.fullText, "OK")
    }

    func testSecureOrHiddenTreeProducesSuccessfulEmptyResultWithoutReadingItsText() {
        let cases: [[String: AttributeResponse]] = [
            [kAXSubroleAttribute: (.success, "AXSecureTextField" as NSString)],
            [kAXHiddenAttribute: (.success, NSNumber(value: true))],
        ]
        for attributes in cases {
            var readContent = false
            let extractor = AccessibilityTextExtractor { _, name in
                let key = name as String
                if key == kAXValueAttribute || key == kAXChildrenAttribute || key == kAXVisibleChildrenAttribute {
                    readContent = true
                }
                return attributes[key] ?? (.attributeUnsupported, nil)
            }
            let result = extractor.extract(window: window, wid: 42, minChars: 0)
            XCTAssertNotNil(result)
            XCTAssertEqual(result?.fullText, "")
            XCTAssertFalse(readContent)
        }
    }

    func testCommunicationFailureIsUnavailableInsteadOfAnEmptyReplacement() {
        for attribute in [kAXSubroleAttribute, kAXValueAttribute, kAXVisibleChildrenAttribute, kAXChildrenAttribute] {
            let extractor = fixture([attribute: (.cannotComplete, nil)])
            XCTAssertNil(extractor.extract(window: window, wid: 42, minChars: 0), attribute)
        }
    }

    func testEmptyOrMalformedVisibleChildrenNeverFallsBackToAllChildren() {
        let cases: [CFTypeRef] = [NSArray(), "malformed" as NSString]
        for children in cases {
            var requestedAllChildren = false
            let extractor = AccessibilityTextExtractor { _, name in
                if name as String == kAXVisibleChildrenAttribute { return (.success, children) }
                if name as String == kAXChildrenAttribute { requestedAllChildren = true }
                return (.attributeUnsupported, nil)
            }
            XCTAssertEqual(extractor.extract(window: window, wid: 42, minChars: 0)?.fullText, "")
            XCTAssertFalse(requestedAllChildren)
        }
    }

    func testMalformedSuppliedVisibleRangeDoesNotExposeFullValue() {
        let extractor = fixture([
            kAXValueAttribute: (.success, "hidden document content" as NSString),
            kAXVisibleCharacterRangeAttribute: (.success, "malformed" as NSString),
        ])
        XCTAssertEqual(extractor.extract(window: window, wid: 42, minChars: 0)?.fullText, "")
    }

    private func fixture(_ attributes: [String: AttributeResponse]) -> AccessibilityTextExtractor {
        AccessibilityTextExtractor { _, name in
            attributes[name as String] ?? (.attributeUnsupported, nil)
        }
    }
}
