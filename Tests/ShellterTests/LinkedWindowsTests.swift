import XCTest

final class LinkedWindowsTests: XCTestCase {
    func testAppBundle() {
        XCTAssertEqual(ProcessInspector.appBundle(of: "/Applications/Habitab.app/Contents/MacOS/Habitab"),
                       "/Applications/Habitab.app")
        XCTAssertEqual(ProcessInspector.appBundle(
            of: "/Applications/X.app/Contents/Frameworks/X Helper.app/Contents/MacOS/X Helper"), "/Applications/X.app")
        XCTAssertNil(ProcessInspector.appBundle(of: "/opt/homebrew/bin/node"))
    }

    func testDeepestFolderWins() {
        let root = UUID(), sub = UUID()
        let w = LinkedWindows.DocumentWindow(pid: 1, appName: "Deck", path: "/p/slides/a.pptx")
        let found = LinkedWindows.assign([w], to: [(root, "/p", true), (sub, "/p/slides", false)])
        XCTAssertNil(found[root])
        XCTAssertEqual(found[sub]?.first?.document, "/p/slides/a.pptx")
    }

    func testAgentTabWinsATie() {
        let shell = UUID(), agent = UUID()
        let w = LinkedWindows.DocumentWindow(pid: 1, appName: "Deck", path: "/p/a.pptx")
        let found = LinkedWindows.assign([w], to: [(shell, "/p", false), (agent, "/p", true)])
        XCTAssertNil(found[shell])
        XCTAssertEqual(found[agent]?.count, 1)
    }

    func testOtherFoldersDoNotMatch() {
        let a = UUID()
        let w = LinkedWindows.DocumentWindow(pid: 1, appName: "Deck", path: "/pages/a.pptx")
        XCTAssertTrue(LinkedWindows.assign([w], to: [(a, "/p", true)]).isEmpty)
    }
}
