import XCTest

final class AgentTextTests: XCTestCase {
    func testQuoteWithWrappedLines() {
        // Wrapped at 40 columns: "  ▎ " + text.
        let raw = """
          ▎ Hi Nils, the users that we need are
          ▎ not in the partner portal.
          ▎
          ▎ Please send me:
          ▎ 1. an API token from the token manager
          ▎ of the DCD.
          ▎ 2. an access key.
        """
        XCTAssertEqual(AgentText.clean(raw, columns: 40), """
        Hi Nils, the users that we need are not in the partner portal.

        Please send me:
        1. an API token from the token manager of the DCD.
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
          - Bass: it plays an F1, the references
            are higher.
            - A sine is added below it.
          - Kick: half of its energy is low.
        """
        XCTAssertEqual(AgentText.clean(raw, columns: 40), """
        - Bass: it plays an F1, the references are higher.
          - A sine is added below it.
        - Kick: half of its energy is low.
        """)
    }

    func testTableStays() {
        let raw = """
          ┌──────┬──────┐
          │ Band │ Filo │
          └──────┴──────┘
        """
        XCTAssertEqual(AgentText.clean(raw, columns: 16), """
        ┌──────┬──────┐
        │ Band │ Filo │
        └──────┴──────┘
        """)
    }

    func testSelectionStartsInTheMiddleOfALine() {
        // The selection starts at column 20; the first line ends at column 38.
        let raw = """
        that we need are not
          in the partner portal.
        """
        XCTAssertEqual(AgentText.clean(raw, columns: 40, firstColumn: 18),
                       "that we need are not in the partner portal.")
        XCTAssertEqual(AgentText.clean(raw, columns: 80, firstColumn: 18),
                       "that we need are not\nin the partner portal.")
    }

    func testCodexMarkdownQuote() {
        // Codex: "•" in front of the message, Markdown quotes, hanging indent in lists.
        let raw = """
        • > Hey Sam, I'd like to move the reporting
          > service to the new server.
          >
          > 1. Before the move, could you pick two
          >    reports from the last import?
        """
        XCTAssertEqual(AgentText.clean(raw, columns: 44), """
        Hey Sam, I'd like to move the reporting service to the new server.

        1. Before the move, could you pick two reports from the last import?
        """)
    }

    func testSingleLineWithGreaterThanStays() {
        XCTAssertEqual(AgentText.clean("  > npm run build", columns: 80), "> npm run build")
    }

    func testAntigravityQuoteBarAndEarlyWrap() {
        // Antigravity quotes with "│" and breaks lines 2 cells before the right edge.
        let raw = """
          │ Please let me know if any cron jobs
          │ collide with our big planned cold-
          │ start window.
        """
        XCTAssertEqual(AgentText.clean(raw, columns: 41),
                       "Please let me know if any cron jobs collide with our big planned cold-start window.")
    }
}
