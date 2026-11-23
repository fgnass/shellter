import XCTest

final class RecentProjectsTests: XCTestCase {
    private func tab(_ cwd: String) -> SavedTab {
        SavedTab(id: UUID(), cwd: cwd, title: "", customTitle: nil, agent: nil, agentSession: nil)
    }

    func testProjectIsRecentOnlyAfterItsLastTabCloses() {
        var r = RecentProjects()
        let t0 = Date()
        r.tabClosed(tab("/p/a"), root: "/p/a", projectOpen: true, at: t0)
        XCTAssertTrue(r.projects.isEmpty)
        r.tabClosed(tab("/p/a/src"), root: "/p/a", projectOpen: false, at: t0.addingTimeInterval(60))
        XCTAssertEqual(r.projects.map(\.root), ["/p/a"])
        XCTAssertEqual(r.projects[0].tabs.map(\.cwd), ["/p/a", "/p/a/src"])
    }

    func testTabsClosedLongBeforeDoNotComeBack() {
        var r = RecentProjects()
        let t0 = Date()
        r.tabClosed(tab("/p/old"), root: "/p", projectOpen: true, at: t0)
        r.tabClosed(tab("/p/new"), root: "/p", projectOpen: false, at: t0.addingTimeInterval(RecentProjects.window + 1))
        XCTAssertEqual(r.projects[0].tabs.map(\.cwd), ["/p/new"])
    }

    func testLatestFirstWithoutDuplicatesAndLimited() {
        var r = RecentProjects()
        for i in 0..<(RecentProjects.limit + 3) {
            r.tabClosed(tab("/p/\(i)"), root: "/p/\(i)", projectOpen: false)
        }
        r.tabClosed(tab("/p/5"), root: "/p/5", projectOpen: false)
        XCTAssertEqual(r.projects.count, RecentProjects.limit)
        XCTAssertEqual(r.projects.first?.root, "/p/5")
        XCTAssertEqual(r.projects.filter { $0.root == "/p/5" }.count, 1)
        r.remove("/p/5")
        XCTAssertFalse(r.projects.contains { $0.root == "/p/5" })
    }
}
