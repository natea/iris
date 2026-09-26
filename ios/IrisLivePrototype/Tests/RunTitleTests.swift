import XCTest
@testable import IrisLivePrototype

final class RunTitleTests: XCTestCase {
    func testGoalOnItsOwnLineUsesTheNextLine() {
        XCTAssertEqual(
            RunTitle.summary(of: "Goal:\nSearch Nate's Calibre library for any books by Tiago Forte.\nContext: none"),
            "Search Nate's Calibre library for any books by Tiago Forte")
    }

    func testInlineGoalLabelIsDropped() {
        XCTAssertEqual(RunTitle.summary(of: "Goal: Check my Gmail for messages that need a reply today."),
                       "Check my Gmail for messages that need a reply today")
    }

    func testPlainTaskAndLongTaskAreHandled() {
        XCTAssertEqual(RunTitle.summary(of: "look up my calendar for today"), "look up my calendar for today")
        let long = RunTitle.summary(of: "Goal:\nFind the top-rated Brazilian restaurants in the Medford, Somerville, and Cambridge area and compare them")
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertLessThanOrEqual(long.count, 61)
        XCTAssertFalse(long.contains("Goal"))
    }

    func testEmptyAndAbbreviationsDoNotBreakIt() {
        XCTAssertEqual(RunTitle.summary(of: "   \n "), "Run")
        // A short leading fragment ending in a period is not treated as the sentence.
        XCTAssertEqual(RunTitle.summary(of: "Goal: Dr. Smith's report needs a summary"), "Dr. Smith's report needs a summary")
    }
}
