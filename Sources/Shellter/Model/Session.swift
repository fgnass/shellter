import AppKit
import Combine

enum ActivityState: Equatable {
    case idle
    case working
    case needsInput
}

/// One terminal tab.
final class Session: ObservableObject, Identifiable {
    let id: UUID
    @Published var rawTitle: String = ""
    @Published var cwd: String
    @Published private(set) var projectRoot: String
    @Published var activity: ActivityState = .idle
    /// Listening ports that the sidebar shows (see PortClassifier).
    @Published var ports: [UInt16] = []
    /// All listening ports of the tab's processes, with their owners.
    var listeningPorts: [UInt16: pid_t] = [:]
    @Published var serverIcon: NSImage?
    @Published var serverPort: UInt16?
    @Published var dirIcon: NSImage?
    @Published var processNames: [String] = []
    /// The coding agent that runs in this tab, if any.
    @Published var agent: Agent?
    /// The agent's session (ID or file path), to resume or fork it.
    var agentSession: String?

    /// Created on first display, so restored tabs start their shell only when needed.
    private(set) var view: TerminalView?

    // Activity detection
    private var progressActive = false
    private var lastSpinnerTick: Date?
    private var attention = false

    init(id: UUID = UUID(), cwd: String, title: String = "") {
        self.id = id
        self.cwd = cwd
        self.rawTitle = title
        self.projectRoot = IconResolver.projectRoot(for: cwd)
    }

    /// Text typed into the shell once it starts (used by `-ShellterRun`).
    var initialInput: String?

    /// The zmx session that keeps this tab's shell alive (see Zmx).
    var zmxSession: String? { Zmx.isAvailable ? Zmx.sessionName(for: id) : nil }

    func ensureView() -> TerminalView {
        if let view { return view }
        let v: TerminalView
        if let name = zmxSession, let command = Zmx.attachCommand(session: name) {
            v = TerminalView(workingDirectory: cwd, initialInput: initialInput,
                             command: command, env: Zmx.environment)
        } else {
            v = TerminalView(workingDirectory: cwd, initialInput: initialInput)
        }
        view = v
        return v
    }

    func destroyView() {
        view?.removeFromSuperview()
        view?.destroy()
        view = nil
    }

    /// Name of the foreground process (e.g. "zsh", "claude", "vim").
    @Published var foregroundName: String = ""

    /// A title the user gave the tab. It wins over the title from the shell.
    @Published var customTitle: String?

    var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        let t = Self.stripSpinner(rawTitle).trimmingCharacters(in: .whitespaces)
        if !t.isEmpty && !Self.looksLikePath(t) { return t }
        // Shells often set the title to the cwd: the sidebar already shows that.
        if let agent { return agent.name }
        return foregroundName.isEmpty ? "shell" : foregroundName
    }

    static func looksLikePath(_ s: String) -> Bool {
        if s == "~" { return true }
        guard !s.contains(" ") else { return false }
        return s.hasPrefix("/") || s.hasPrefix("~/") || s.hasPrefix("…") || s.hasPrefix("...")
    }

    var projectName: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if projectRoot == home { return "~" }
        return (projectRoot as NSString).lastPathComponent
    }

    var icon: NSImage? { serverIcon ?? dirIcon }

    // MARK: Updates from the terminal

    func setCwd(_ path: String) {
        guard path != cwd, !path.isEmpty else { return }
        cwd = path
        let root = IconResolver.projectRoot(for: path)
        if root != projectRoot {
            projectRoot = root
            dirIcon = nil
            loadDirectoryIcon()
        }
    }

    func setTitle(_ new: String) {
        let old = rawTitle
        rawTitle = new
        // A title that changes only in its first glyph is an animated spinner.
        if !old.isEmpty, !new.isEmpty, old.first != new.first,
           old.dropFirst() == new.dropFirst(), Self.isSpinnerGlyph(new.first!) {
            lastSpinnerTick = Date()
        }
        recompute()
    }

    func setProgress(_ active: Bool) {
        progressActive = active
        recompute()
    }

    /// The tab wants the user (bell, notification, or work finished while unseen).
    func requestAttention() {
        attention = true
        recompute()
    }

    func clearAttention() {
        guard attention else { return }
        attention = false
        recompute()
    }

    var isWorking: Bool {
        if progressActive { return true }
        if let t = lastSpinnerTick, Date().timeIntervalSince(t) < 2.5 { return true }
        return false
    }

    /// Returns true when the tab went from working to idle.
    @discardableResult
    func recompute() -> Bool {
        let wasWorking = activity == .working
        let next: ActivityState = isWorking ? .working : (attention ? .needsInput : .idle)
        if next != activity { activity = next }
        return wasWorking && next != .working
    }

    func loadDirectoryIcon() {
        let root = projectRoot
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard root != home, root != "/" else { dirIcon = nil; return }
        IconResolver.shared.directoryIcon(for: root) { [weak self] img in
            guard let self, self.projectRoot == root else { return }
            self.dirIcon = img
        }
    }

    // MARK: Helpers

    static func isSpinnerGlyph(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first else { return false }
        if (0x2800...0x28FF).contains(s.value) { return true }     // braille spinners
        return "✢✳✶✻✽·*◐◓◑◒⠁|/-\\".contains(c)
    }

    static func stripSpinner(_ title: String) -> String {
        guard let first = title.first, isSpinnerGlyph(first) else { return title }
        return String(title.dropFirst())
    }

    // MARK: Persistence

    struct Saved: Codable {
        var id: UUID
        var cwd: String
        var title: String
        var customTitle: String?
        /// The coding agent that ran in the tab and its session, to resume it after a reboot.
        var agent: String?
        var agentSession: String?
    }

    var saved: Saved {
        Saved(id: id, cwd: cwd, title: rawTitle, customTitle: customTitle,
              agent: agent?.rawValue, agentSession: agentSession)
    }
}
