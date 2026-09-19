import XCTest
@testable import IrisLivePrototype

final class MarkdownBlockTests: XCTestCase {
    func testBlocks() {
        let blocks = MarkdownBlock.parse("""
        # Title
        Some **bold** text
        that wraps.

        - one
          - nested
        1. first
        > quoted
        ---
        ```
        let x = 1
        ```
        | a | b |
        |---|---|
        | 1 | 2 |
        """)
        XCTAssertEqual(blocks, [
            .heading(1, "Title"),
            .paragraph("Some **bold** text that wraps."),
            .listItem(marker: "•", indent: 0, text: "one"),
            .listItem(marker: "•", indent: 1, text: "nested"),
            .listItem(marker: "1.", indent: 0, text: "first"),
            .quote("quoted"),
            .rule,
            .code("let x = 1"),
            .code("| a | b |\n| 1 | 2 |"),
        ])
    }

    func testInlineMarkdownIsInterpreted() {
        XCTAssertEqual(String(MarkdownBlock.inline("a **b** `c`").characters), "a b c")
    }

    func testUnclosedFenceAndPlainTextSurvive() {
        XCTAssertEqual(MarkdownBlock.parse("```\nabc"), [.code("abc")])
        XCTAssertEqual(MarkdownBlock.parse("just text"), [.paragraph("just text")])
    }
}
