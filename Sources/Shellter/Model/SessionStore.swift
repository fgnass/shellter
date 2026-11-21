import AppKit
import Combine

struct SessionGroup: Identifiable {
    let id: String          // project root
    let name: String
    let sessions: [Session]
}

/// Owns all tabs, their order, the selection and persistence.
final class SessionStore: ObservableObject, TerminalEventHandler {
    @Published private(set) var sessions: [Session] = []
    @Published var selectedID: UUID? {
        didSet { if oldValue != selectedID { selectionDidChange() } }
    }

    /// Called when the selected terminal must be shown.
    var onShow: ((Session) -> Void)?
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
        // Insert the new tab after the selected one, so it lands in the same group.
        if let sel = selected, let i = sessions.firstIndex(where: { $0.id == sel.id }) {
            sessions.removeLast()
            sessions.insert(s, at: i + 1)
        }
        if select { selectedID = s.id }
        scheduleSave()
        return s
    }

    private func add(_ s: Session) {
        sessions.append(s)
        let v = s.ensureView()
        v.eventHandler = self
        s.loadDirectoryIcon()
        // Forward session changes so the sidebar refreshes.
        s.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)
    }

    func close(_ s: Session, force: Bool = false) {
        if !force, let v = s.view, v.needsConfirmQuit {
            let alert = NSAlert()
            alert.messageText = "Close “\(s.title)”?"
            alert.informativeText = "A process is still running in this tab."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        guard let idx = orderedSessions.firstIndex(where: { $0.id == s.id }) else { return }
        let ordered = orderedSessions
        s.destroyView()
        sessions.removeAll { $0.id == s.id }
        if selectedID == s.id {
            let remaining = ordered.filter { $0.id != s.id }
            selectedID = remaining.isEmpty ? nil : remaining[min(idx, remaining.count - 1)].id
        }
        scheduleSave()
        if sessions.isEmpty { onEmpty?() }
    }

    func select(_ s: Session) { selectedID = s.id }

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
        case .commandFinished, .childExited:
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
        for s in sessions {
            // Spinner ticks stop without an event; re-evaluate the state.
            if s.recompute() && !isVisible(s) { s.requestAttention() }
            if isVisible(s) { s.clearAttention() }

            guard let tty = s.view?.ttyName else { continue }
            let fgPID = s.view?.foregroundPID
            pollQueue.async { [weak self, weak s] in
                let snap = ProcessInspector.snapshot(tty: tty)
                let fgCwd = fgPID.flatMap { ProcessInspector.cwd(of: $0) }
                DispatchQueue.main.async {
                    guard let self, let s else { return }
                    self.apply(snap, fallbackCwd: fgCwd, to: s)
                }
            }
        }
    }

    private func apply(_ snap: ProcessInspector.Snapshot, fallbackCwd: String?, to s: Session) {
        let names = snap.pids.compactMap { snap.names[$0] }.filter { !$0.isEmpty }
        if names != s.processNames { s.processNames = names }
        // Without shell integration there is no OSC 7; use the process cwd instead.
        if let fallbackCwd, s.rawTitle.isEmpty || s.cwd == FileManager.default.homeDirectoryForCurrentUser.path {
            s.setCwd(fallbackCwd)
        }
        guard snap.ports != s.ports else { return }
        s.ports = snap.ports
        if snap.ports.isEmpty {
            s.serverIcon = nil
            s.serverPort = nil
            return
        }
        IconResolver.shared.serverIcon(ports: snap.ports) { [weak s] img, port in
            guard let s, s.ports == snap.ports else { return }
            s.serverIcon = img
            s.serverPort = port ?? snap.ports.first
        }
    }

    // MARK: Persistence

    private struct State: Codable {
        var sessions: [Session.Saved]
        var selected: UUID?
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
        let state = State(sessions: sessions.map(\.saved), selected: selectedID)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: Self.stateURL, options: .atomic)
        }
    }

    private func restore() {
        guard let data = try? Data(contentsOf: Self.stateURL),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return }
        for saved in state.sessions {
            add(Session(id: saved.id, cwd: saved.cwd, title: saved.title))
        }
        selectedID = sessions.contains { $0.id == state.selected } ? state.selected : sessions.first?.id
    }
}
