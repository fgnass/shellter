import AppKit
import Combine

struct SessionGroup: Identifiable {
    let id: String          // project root
    let name: String
    let sessions: [Session]
}

/// A window of another app in a project, with the tab it belongs to.
struct ProjectWindow: Identifiable {
    let link: LinkedWindow
    let session: Session
    var id: String { link.id }
}

/// Owns all tabs, their order, the selection and persistence.
final class SessionStore: ObservableObject, TerminalEventHandler {
    @Published private(set) var sessions: [Session] = []
    /// Per tab: apps that its processes started, and windows that show a file of its project.
    @Published private(set) var appWindows: [UUID: [LinkedWindow]] = [:]
    @Published private(set) var documentWindows: [UUID: [LinkedWindow]] = [:]
    /// Projects whose last tab closed, the latest first.
    @Published private(set) var recent = RecentProjects()
    /// Project icons of the recent projects, for the menu.
    @Published private(set) var recentIcons: [String: NSImage] = [:]
    @Published var selectedID: UUID? {
        didSet { if oldValue != selectedID { selectionDidChange() } }
    }

    /// Called when the selected terminal must be shown.
    var onShow: ((Session) -> Void)?
    /// Called for each new tab, so the window can create its terminal right away.
    var onAdd: ((Session) -> Void)?
    /// Called when the last tab closed.
    var onEmpty: (() -> Void)?

    private var bag = Set<AnyCancellable>()
    private var pollTimer: Timer?
    private var saveWork: DispatchWorkItem?
    private let pollQueue = DispatchQueue(label: "shellter.poll", qos: .utility)

    var selected: Session? { sessions.first { $0.id == selectedID } }

    /// Tabs grouped by project root. Group order follows the first tab of each group.
    var groups: [SessionGroup] {
        var order: [String] = []
        var map: [String: [Session]] = [:]
        for s in sessions {
            if map[s.projectRoot] == nil { order.append(s.projectRoot) }
            map[s.projectRoot, default: []].append(s)
        }
        return order.map { SessionGroup(id: $0, name: map[$0]![0].projectName, sessions: map[$0]!) }
    }

    /// Tabs in the order the sidebar shows them.
    var orderedSessions: [Session] { groups.flatMap(\.sessions) }

    // MARK: Lifecycle

    func start() {
        restore()
        // Launch arguments: -ShellterCwd <dir> -ShellterRun <command> open an extra tab.
        let defaults = UserDefaults.standard
        if let run = defaults.string(forKey: "ShellterRun") {
            newTab(cwd: defaults.string(forKey: "ShellterCwd"), input: run + "\n")
        } else if let cwd = defaults.string(forKey: "ShellterCwd") {
            newTab(cwd: cwd)
        }
        if sessions.isEmpty { newTab(cwd: FileManager.default.homeDirectoryForCurrentUser.path) }
        if Zmx.isAvailable { Zmx.killOrphans(keeping: Set(sessions.compactMap(\.zmxSession))) }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    // MARK: Tabs

    @discardableResult
    func newTab(cwd: String? = nil, input: String? = nil, select: Bool = true) -> Session {
        let dir = cwd ?? selected?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        let s = Session(cwd: dir)
        s.initialInput = input
        add(s)
        // Insert the new tab after the selected one if they share a project, else after
        // the last tab of its project. A new project goes to the end of the sidebar.
        sessions.removeLast()
        let sameProject = { (other: Session) in other.projectRoot == s.projectRoot }
        if let sel = selected, sameProject(sel), let i = sessions.firstIndex(where: { $0.id == sel.id }) {
            sessions.insert(s, at: i + 1)
        } else if let i = sessions.lastIndex(where: sameProject) {
            sessions.insert(s, at: i + 1)
        } else {
            sessions.append(s)
        }
        if select { selectedID = s.id }
        scheduleSave()
        return s
    }

    /// Opens one tab for each directory, for example for folders dropped on the sidebar.
    /// A file opens its parent directory. The last new tab becomes the selected tab.
    func openDirectories(_ urls: [URL]) {
        var seen = Set<String>()
        var last: Session?
        for url in urls where url.isFileURL {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            let dir = (isDir.boolValue ? url : url.deletingLastPathComponent()).standardizedFileURL.path
            guard seen.insert(dir).inserted else { continue }
            last = newTab(cwd: dir, select: false)
        }
        if let last { selectedID = last.id }
    }

    private func add(_ s: Session) {
        sessions.append(s)
        // The window creates the terminal now (hidden, in its final size), so hidden tabs
        // report bells, titles and progress too.
        onAdd?(s)
        s.loadDirectoryIcon()
        // A tab that starts to want attention bounces the Dock icon while Shellter is in
        // the background (once, like Terminal.app; it stops when Shellter becomes active).
        s.$activity
            .removeDuplicates()
            .filter { $0 == .needsInput }
            .receive(on: DispatchQueue.main)
            .sink { _ in
                if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
            }
            .store(in: &bag)
        // The Dock icon shows how many tabs want attention.
        s.$activity
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateDockBadge() }
            .store(in: &bag)
        // The agent starts or stops to work: the tab was active just now.
        s.$activity
            .removeDuplicates()
            .dropFirst()
            .sink { [weak s] _ in s?.lastActivity = Date() }
            .store(in: &bag)
        // Forward the session changes that the sidebar itself uses (groups, project icon,
        // menus, window owner). The rows observe their sessions. Titles and spinner ticks of
        // a working agent must not refresh the sidebar: that rebuilds an open context menu.
        Publishers.MergeMany(
            s.$projectRoot.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            s.$dirIcon.removeDuplicates(by: ===).map { _ in () }.eraseToAnyPublisher(),
            s.$agent.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            s.$activity.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            s.$ports.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            s.$serverPort.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
        )
        .dropFirst(6)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.objectWillChange.send() }
        .store(in: &bag)
    }

    /// Recent projects that have no open tab now.
    var recentProjects: [RecentProject] {
        let open = Set(sessions.map(\.projectRoot))
        return recent.projects.filter { !open.contains($0.root) }
    }

    /// Opens the tabs of a recent project again. Agents resume their sessions.
    func reopen(_ project: RecentProject) {
        recent.remove(project.root)
        var first: Session?
        for saved in project.tabs {
            let s = newTab(cwd: saved.cwd, select: false)
            s.rawTitle = saved.title
            s.customTitle = saved.customTitle
            if let agent = saved.agent.flatMap(Agent.init(rawValue:)) {
                s.agent = agent
                s.agentSession = saved.agentSession
                s.initialInput = AgentSession.resumeCommand(agent, session: saved.agentSession) + "\n"
            }
            first = first ?? s
        }
        if project.tabs.isEmpty { first = newTab(cwd: project.root, select: false) }
        if let first { selectedID = first.id }
        scheduleSave()
    }

    /// Opens the project that closed last. Returns false if there is none.
    @discardableResult
    func reopenLastProject() -> Bool {
        guard let p = recentProjects.first else { return false }
        reopen(p)
        return true
    }

    func clearRecentProjects() {
        recent.removeAll()
        scheduleSave()
    }

    /// Closes all tabs of a project. One question if processes still run in them.
    func close(project root: String) {
        let tabs = orderedSessions.filter { $0.projectRoot == root }
        let running = tabs.filter { runningProcess(in: $0) != nil }
        if !running.isEmpty {
            let alert = NSAlert()
            let name = tabs.first?.projectName ?? root
            alert.messageText = "Close “\(name)”?"
            alert.informativeText = running.count == 1
                ? "\(runningProcess(in: running[0])!) is still running in “\(running[0].title)”. Closing the project ends it."
                : "Processes are still running in \(running.count) tabs. Closing the project ends them."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        // Select a tab of another project first, so the tabs to close are not shown one by one.
        let ordered = orderedSessions
        if let sel = selected, sel.projectRoot == root, let i = ordered.firstIndex(where: { $0.id == sel.id }) {
            let other = ordered[i...].first { $0.projectRoot != root }
                ?? ordered[..<i].last { $0.projectRoot != root }
            if let other { selectedID = other.id }
        }
        for s in tabs { close(s, force: true) }
    }

    func close(_ s: Session, force: Bool = false) {
        if !force, let running = runningProcess(in: s) {
            let alert = NSAlert()
            alert.messageText = "Close “\(s.title)”?"
            alert.informativeText = "\(running) is still running in this tab. Closing the tab ends it."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        guard let idx = orderedSessions.firstIndex(where: { $0.id == s.id }) else { return }
        let ordered = orderedSessions
        s.destroyView()
        // Closing a tab ends its shell. (Quitting Shellter only detaches.)
        if let name = s.zmxSession { Zmx.kill(name) }
        sessions.removeAll { $0.id == s.id }
        recent.tabClosed(s.saved, root: s.projectRoot,
                         projectOpen: sessions.contains { $0.projectRoot == s.projectRoot })
        if let icon = s.dirIcon { recentIcons[s.projectRoot] = icon }
        appWindows[s.id] = nil
        updateDockBadge()
        if selectedID == s.id {
            let remaining = ordered.filter { $0.id != s.id }
            selectedID = remaining.isEmpty ? nil : remaining[min(idx, remaining.count - 1)].id
        }
        scheduleSave()
        if sessions.isEmpty { onEmpty?() }
    }

    /// The name of the program that runs in the tab besides its shell, or nil.
    /// With zmx the shell outlives the terminal view (and a restored tab has no view
    /// until it is shown), so ask the process table, not the view.
    func runningProcess(in s: Session) -> String? {
        if let name = s.zmxSession {
            guard let shell = Zmx.list()[name],
                  let term = ProcessInspector.terminal(of: shell),
                  term.foreground > 0, term.foreground != shell else { return nil }
            return s.agent?.name ?? ProcessInspector.name(of: term.foreground)
        }
        guard let v = s.view, v.needsConfirmQuit else { return nil }
        return s.agent?.name ?? "A process"
    }

    func select(_ s: Session) { selectedID = s.id }

    /// Opens a new tab next to `s` (in `cwd`, default: the directory of `s`) with a fresh
    /// session of `agent` (default: the agent of `s`).
    @discardableResult
    func newAgentSession(next s: Session, agent: Agent? = nil, cwd: String? = nil) -> Bool {
        guard let agent = agent ?? s.agent else { return false }
        selectedID = s.id
        newTab(cwd: cwd ?? s.cwd, input: agent.command + "\n")
        return true
    }

    /// Opens a new tab next to `s` with a fork of its agent session, to try something
    /// else from the same point. Returns false if the tab has no agent that can fork.
    @discardableResult
    func branch(_ s: Session) -> Bool {
        guard let agent = s.agent,
              let command = AgentSession.forkCommand(agent, session: s.agentSession,
                                                      name: AgentSession.branchName(title: s.title))
        else { return false }
        selectedID = s.id
        newTab(cwd: s.cwd, input: command + "\n")
        return true
    }

    // MARK: Organize

    /// Moves a tab within its project, to the place of `target`.
    /// Dragged down it lands after the target, dragged up before it.
    func move(tab id: UUID, to target: UUID) {
        guard let a = sessions.first(where: { $0.id == id }),
              let b = sessions.first(where: { $0.id == target }), a.projectRoot == b.projectRoot,
              let moved = Reorder.move(sessions, id: \.id, item: id, to: target) else { return }
        sessions = moved
        scheduleSave()
    }

    /// Moves all tabs of a project to the place of the project `target`.
    func move(group root: String, to target: String) {
        guard let newOrder = Reorder.move(groups.map(\.id), id: { $0 }, item: root, to: target) else { return }
        let byRoot = Dictionary(grouping: sessions, by: \.projectRoot)
        sessions = newOrder.flatMap { byRoot[$0] ?? [] }
        scheduleSave()
    }

    func rename(_ s: Session, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        s.customTitle = t.isEmpty ? nil : t
        scheduleSave()
    }

    func selectRelative(_ delta: Int) {
        let list = orderedSessions
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == selectedID } ?? 0
        selectedID = list[(i + delta + list.count) % list.count].id
    }

    func selectIndex(_ i: Int) {
        let list = orderedSessions
        guard !list.isEmpty else { return }
        selectedID = list[min(max(i, 0), list.count - 1)].id
    }

    /// Jumps to the next tab that wants attention.
    func selectNextNeedingInput() {
        let list = orderedSessions
        let start = list.firstIndex { $0.id == selectedID } ?? -1
        for k in 1...max(list.count, 1) {
            let s = list[(start + k + list.count) % list.count]
            if s.activity == .needsInput { selectedID = s.id; return }
        }
    }

    private func selectionDidChange() {
        guard let s = selected else { return }
        s.lastActivity = Date()
        s.clearAttention()
        onShow?(s)
        scheduleSave()
    }

    /// True when the user can see this tab right now.
    func isVisible(_ s: Session) -> Bool {
        s.id == selectedID && NSApp.isActive && (s.view?.window?.isKeyWindow ?? false)
    }

    // MARK: TerminalEventHandler

    private func session(for view: TerminalView) -> Session? {
        sessions.first { $0.view === view }
    }

    func terminal(_ view: TerminalView, didEmit event: TerminalEvent) {
        guard let s = session(for: view) else { return }
        switch event {
        case .title(let t):
            s.setTitle(t)
            scheduleSave()
        case .pwd(let p):
            let path = p.hasPrefix("file://") ? (URL(string: p)?.path ?? p) : p
            s.setCwd(path)
            scheduleSave()
        case .bell, .notification:
            if !isVisible(s) { s.requestAttention() }
        case .progress(let active):
            s.setProgress(active)
            if !active && !isVisible(s) { s.requestAttention() }
        case .childExited:
            // The zmx session ended (e.g. `exit` in the shell): close the tab, as without zmx.
            if s.zmxSession != nil { close(s, force: true) }
        case .commandFinished:
            break
        case .newTab:
            newTab(cwd: s.cwd)
        case .closeTab:
            close(s)
        case .gotoTab(let n):
            switch n {
            case -1: selectRelative(-1)
            case -2: selectRelative(1)
            case -3: selectIndex(orderedSessions.count - 1)
            default: if n >= 1 { selectIndex(n - 1) }
            }
        case .quit:
            NSApp.terminate(nil)
        }
    }

    func terminalDidRequestClose(_ view: TerminalView, processAlive: Bool) {
        guard let s = session(for: view) else { return }
        close(s, force: !processAlive)
    }

    func terminalDidReceiveInput(_ view: TerminalView) {
        session(for: view)?.clearAttention()
    }

    // MARK: Polling (processes, ports, favicons, spinner decay)

    private func poll() {
        // Pick up changed project icons. The resolver only looks at the disk every few seconds.
        for s in sessions { s.loadDirectoryIcon() }
        // With zmx the shell runs on the daemon's PTY, not on the terminal's. Find it via
        // the shell's PID. Without zmx use the terminal's TTY and foreground process.
        if Zmx.isAvailable {
            let list = sessions.map { ($0, $0.zmxSession) }
            pollQueue.async { [weak self] in
                let pids = Zmx.list()
                DispatchQueue.main.async {
                    for (s, name) in list {
                        guard let name, let pid = pids[name] else { continue }
                        self?.inspect(s, shellPID: pid)
                    }
                }
            }
        }
        pollDocumentWindows()
        for s in sessions {
            // Spinner ticks stop without an event; re-evaluate the state.
            if s.recompute() && !isVisible(s) { s.requestAttention() }
            if isVisible(s) { s.clearAttention() }

            guard s.zmxSession == nil, let tty = s.view?.ttyName else { continue }
            let fgPID = s.view?.foregroundPID
            pollQueue.async { [weak self, weak s] in
                var snap = ProcessInspector.snapshot(tty: tty)
                snap.agentSession = Self.agentSession(in: snap)
                let fgCwd = fgPID.flatMap { ProcessInspector.cwd(of: $0) }
                let fgName = fgPID.map { ProcessInspector.name(of: $0) } ?? ""
                DispatchQueue.main.async {
                    guard let self, let s else { return }
                    if s.foregroundName != fgName { s.foregroundName = fgName }
                    self.apply(snap, fallbackCwd: fgCwd, to: s)
                }
            }
        }
    }

    /// Windows of other apps that show a file in a tab's folder (needs Accessibility).
    private func pollDocumentWindows() {
        guard LinkedWindows.hasAccess else { return }
        let apps = LinkedWindows.regularApps()
        // A file anywhere in the project belongs to it, but the home folder is no project.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tabs = sessions.filter { $0.projectRoot != home }
            .map { (id: $0.id, cwd: $0.projectRoot, hasAgent: $0.agent != nil) }
        pollQueue.async { [weak self] in
            let found = LinkedWindows.assign(LinkedWindows.documentWindows(apps: apps), to: tabs)
            DispatchQueue.main.async {
                guard let self, found != self.documentWindows else { return }
                self.documentWindows = found
            }
        }
    }

    /// The number of tabs with the bell on the Dock icon, or no badge.
    private func updateDockBadge() {
        let n = sessions.filter { $0.activity == .needsInput }.count
        let label = n > 0 ? String(n) : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }

    /// The windows of other apps in a project: apps first, then files, each once.
    /// When more tabs share a window (e.g. two agents use the same browser), the window
    /// belongs to the tab with the latest activity, so a click shows that tab's session.
    func windows(of group: SessionGroup) -> [ProjectWindow] {
        var index: [String: Int] = [:]
        var result: [ProjectWindow] = []
        for kind in [appWindows, documentWindows] {
            for s in group.sessions {
                for link in kind[s.id] ?? [] {
                    let w = ProjectWindow(link: link, session: s)
                    if let i = index[link.id] {
                        if s.lastActivity > result[i].session.lastActivity { result[i] = w }
                    } else {
                        index[link.id] = result.count
                        result.append(w)
                    }
                }
            }
        }
        return result
    }

    private func inspect(_ s: Session, shellPID: pid_t) {
        pollQueue.async { [weak self, weak s] in
            guard let term = ProcessInspector.terminal(of: shellPID) else { return }
            var snap = ProcessInspector.snapshot(dev: term.dev)
            snap.agentSession = Self.agentSession(in: snap)
            let fg = term.foreground > 0 ? term.foreground : shellPID
            let fgCwd = ProcessInspector.cwd(of: fg)
            let fgName = ProcessInspector.name(of: fg)
            DispatchQueue.main.async {
                guard let self, let s else { return }
                if s.foregroundName != fgName { s.foregroundName = fgName }
                self.apply(snap, fallbackCwd: fgCwd, to: s)
            }
        }
    }

    /// Runs on the poll queue: reads session files of the agent.
    private static func agentSession(in snap: ProcessInspector.Snapshot) -> String? {
        guard let agent = snap.agent, let pid = snap.agentPIDs.first else { return nil }
        let cwd = ProcessInspector.cwd(of: pid) ?? FileManager.default.homeDirectoryForCurrentUser.path
        return AgentSession.current(agent, pids: snap.agentPIDs, cwd: cwd)
    }

    private func apply(_ snap: ProcessInspector.Snapshot, fallbackCwd: String?, to s: Session) {
        let names = snap.pids.compactMap { snap.names[$0] }.filter { !$0.isEmpty }
        if names != s.processNames { s.processNames = names }
        let apps = LinkedWindows.apps(from: snap.apps)
        if apps != (appWindows[s.id] ?? []) { appWindows[s.id] = apps.isEmpty ? nil : apps }
        if snap.agent != s.agent {
            s.agent = snap.agent
            s.agentSession = snap.agentSession
            scheduleSave()
        } else if let id = snap.agentSession, id != s.agentSession {
            s.agentSession = id   // e.g. /clear or /resume inside the agent
            scheduleSave()
        }
        // Without shell integration there is no OSC 7; use the process cwd instead.
        if let fallbackCwd, s.rawTitle.isEmpty || s.cwd == FileManager.default.homeDirectoryForCurrentUser.path {
            s.setCwd(fallbackCwd)
        }
        guard snap.portOwners != s.listeningPorts else { return }
        s.listeningPorts = snap.portOwners
        PortClassifier.shared.relevantPorts(snap.portOwners) { [weak s] ports in
            guard let s, s.listeningPorts == snap.portOwners else { return }
            self.show(ports, on: s)
        }
    }

    private func show(_ ports: [UInt16], on s: Session) {
        guard ports != s.ports else { return }
        s.ports = ports
        if ports.isEmpty {
            s.serverIcon = nil
            s.serverPort = nil
            return
        }
        IconResolver.shared.serverIcon(ports: ports) { [weak s] img, port in
            guard let s, s.ports == ports else { return }
            s.serverIcon = img
            s.serverPort = port ?? ports.first
        }
    }

    // MARK: Persistence

    private struct State: Codable {
        var sessions: [Session.Saved]
        var selected: UUID?
        var recent: [RecentProject]?
    }

    private static var stateURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shellter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }

    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func save() {
        let state = State(sessions: sessions.map(\.saved), selected: selectedID,
                          recent: recentProjects)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: Self.stateURL, options: .atomic)
        }
    }

    private func restore() {
        guard let data = try? Data(contentsOf: Self.stateURL),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return }
        recent = RecentProjects(projects: state.recent ?? [])
        for p in recent.projects {
            IconResolver.shared.directoryIcon(for: p.root) { [weak self] img in
                if let img { self?.recentIcons[p.root] = img }
            }
        }
        // Shells that still run in zmx come back as they were. Where the shell is gone
        // (after a reboot, or without zmx), start the agent of the tab again where it was.
        let alive = Zmx.isAvailable ? Set(Zmx.list().keys) : []
        for saved in state.sessions {
            let s = Session(id: saved.id, cwd: saved.cwd, title: saved.title)
            s.customTitle = saved.customTitle
            if let agent = saved.agent.flatMap(Agent.init(rawValue:)) {
                s.agent = agent
                s.agentSession = saved.agentSession
                if s.zmxSession.map({ !alive.contains($0) }) ?? true {
                    s.initialInput = AgentSession.resumeCommand(agent, session: saved.agentSession) + "\n"
                }
            }
            add(s)
        }
        selectedID = sessions.contains { $0.id == state.selected } ? state.selected : sessions.first?.id
    }
}
