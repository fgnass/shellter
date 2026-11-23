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

    func testCodexMarkdownQuote() {
        // Codex: "•" in front of the message, Markdown quotes, hanging indent in lists.
        let raw = """
        • > Hey Ann, I'd like to move the uploading
          > service to the new server.
          >
          > 1. Before the move, could you pick two
          >    samples from the last import?
        """
        XCTAssertEqual(AgentText.clean(raw, columns: 44), """
        Hey Ann, I'd like to move the uploading service to the new server.

        1. Before the move, could you pick two samples from the last import?
        """)
    }

    func testSingleLineWithGreaterThanStays() {
        XCTAssertEqual(AgentText.clean("  > npm run build", columns: 80), "> npm run build")
    }

    func testAntigravityQuoteBarAndEarlyWrap() {
        // Antigravity quotes with "│" and breaks lines 2 cells before the right edge.
        let raw = """
          │ Please let me know if any test runs
          │ collide with our big planned cold-
          │ start window.
        """
        XCTAssertEqual(AgentText.clean(raw, columns: 41),
                       "Please let me know if any test runs collide with our big planned cold-start window.")
    }
}
