import Foundation

/// The saved state of a tab.
struct SavedTab: Codable {
    var id: UUID
    var cwd: String
    var title: String
    var customTitle: String?
    /// The coding agent that ran in the tab and its session, to resume it after a reboot.
    var agent: String?
    var agentSession: String?
}

/// A project whose last tab closed, with the tabs to open again.
struct RecentProject: Codable, Identifiable {
    var root: String
    var closed: Date
    var tabs: [SavedTab]
    var id: String { root }

    var name: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return root == home ? "~" : (root as NSString).lastPathComponent
    }
}

/// Remembers closed tabs per project. When the last tab of a project closes, the project
/// becomes a recent project with the tabs that closed shortly before it, so a project that
/// the user closes tab by tab comes back complete.
struct RecentProjects {
    static let limit = 15
    /// Tabs that closed longer ago than this before the project closed do not come back.
    static let window: TimeInterval = 10 * 60

    private(set) var projects: [RecentProject] = []
    private var closedTabs: [String: [(date: Date, tab: SavedTab)]] = [:]

    init(projects: [RecentProject] = []) { self.projects = projects }

    /// Records a closed tab. `projectOpen`: other tabs of the project are still open.
    mutating func tabClosed(_ tab: SavedTab, root: String, projectOpen: Bool, at date: Date = Date()) {
        var recent = (closedTabs[root] ?? []).filter { date.timeIntervalSince($0.date) <= Self.window }
        recent.append((date, tab))
        guard !projectOpen else { closedTabs[root] = recent; return }
        closedTabs[root] = nil
        let tabs = recent.map(\.tab)
        projects.removeAll { $0.root == root }
        projects.insert(RecentProject(root: root, closed: date, tabs: tabs), at: 0)
        if projects.count > Self.limit { projects.removeLast(projects.count - Self.limit) }
    }

    /// Removes a project, for example when it opens again.
    mutating func remove(_ root: String) {
        projects.removeAll { $0.root == root }
        closedTabs[root] = nil
    }

    mutating func removeAll() {
        projects = []
        closedTabs = [:]
    }
}
