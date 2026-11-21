import XCTest

final class ShellTests: XCTestCase {
    func testEscapeLikeTerminalApp() {
        XCTAssertEqual(Shell.escape("/Users/me/My Files/a (1).png"), "/Users/me/My\\ Files/a\\ \\(1\\).png")
        XCTAssertEqual(Shell.escape("plain/path.txt"), "plain/path.txt")
        XCTAssertEqual(Shell.escape("it's$x&y"), "it\\'s\\$x\\&y")
    }

    func testQuote() {
        XCTAssertEqual(Shell.quote("simple-1.0/path"), "simple-1.0/path")
        XCTAssertEqual(Shell.quote("with space"), "'with space'")
        XCTAssertEqual(Shell.quote("it's"), "'it'\\''s'")
        XCTAssertEqual(Shell.quote(""), "''")
    }
}
