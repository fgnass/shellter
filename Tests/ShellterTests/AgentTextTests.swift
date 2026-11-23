import XCTest

final class AgentTextTests: XCTestCase {
    func testQuoteWithWrappedLines() {
        // Wrapped at 40 columns: "  ▎ " + text.
        let raw = """
          ▎ Hi Anna, the files that we need are
          ▎ not in the shared archive.
          ▎
          ▎ Please send me:
          ▎ 1. an API token from the token manager
          ▎ of the CMS.
          ▎ 2. an access key.
        """
        XCTAssertEqual(AgentText.clean(raw, columns: 40), """
        Hi Anna, the files that we need are not in the shared archive.

        Please send me:
        1. an API token from the token manager of the CMS.
        2. an access key.
        """)
    }

    func testMessageMarkerAndIndent() {
        let raw = """
        ⏺ The first line of the answer is long and
          continues here.

          A second paragraph.
        """
        XCTAssertEqual(AgentText.clean(raw, columns: 44), """
        The first line of the answer is long and continues here.

        A second paragraph.
        """)
    }

    func testToolResultMarkerWithNoBreakSpace() {
        XCTAssertEqual(AgentText.clean("  ⎿ \u{00A0}Allowed by auto mode", columns: 80), "Allowed by auto mode")
    }

    func testShortLinesStay() {
        let raw = """
          First line.
          Second line.
        """
        XCTAssertEqual(AgentText.clean(raw, columns: 80), "First line.\nSecond line.")
    }

    func testListItemsAndNestedListsStay() {
        let raw = """
          - Menu: it shows a tab, the other ones
            are higher.
            - A line is added below it.
          - Logo: half of its height is low.
        """
        XCTAssertEqual(AgentText.clean(raw, columns: 40), """
        - Menu: it shows a tab, the other ones are higher.
          - A line is added below it.
        - Logo: half of its height is low.
        """)
    }

    func testTableStays() {
        let raw = """
          ┌──────┬──────┐
          │ Name │ Size │
          └──────┴──────┘
        """
        XCTAssertEqual(AgentText.clean(raw, columns: 16), """
        ┌──────┬──────┐
        │ Name │ Size │
        └──────┴──────┘
        """)
    }

    func testSelectionStartsInTheMiddleOfALine() {
        // The selection starts at column 20; the first line ends at column 38.
        let raw = """
        that we need are not
          in the shared archive.
        """
        XCTAssertEqual(AgentText.clean(raw, columns: 40, firstColumn: 18),
                       "that we need are not in the shared archive.")
        XCTAssertEqual(AgentText.clean(raw, columns: 80, firstColumn: 18),
                       "that we need are not\nin the shared archive.")
    }
}
