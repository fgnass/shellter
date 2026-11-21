import Foundation

/// Keeps the shells of the tabs alive when Shellter quits, with zmx
/// (https://github.com/neurosnap/zmx, bundled in Contents/MacOS).
///
/// Each tab attaches to its own zmx session. The zmx daemon owns the PTY and the shell,
/// so the shell, a coding agent or a dev server keep running while Shellter restarts.
/// On the next start the tab attaches again and zmx restores screen and scrollback.
enum Zmx {
    /// The bundled binary, or nil if the build has none (then tabs run their shell directly).
    static let binary: String? = {
        guard let url = Bundle.main.url(forAuxiliaryExecutable: "zmx"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url.path
    }()

    static var isAvailable: Bool { binary != nil }

    /// Shellter's own socket directory, apart from a zmx that the user runs. It must be short:
    /// a Unix socket path has at most 104 bytes.
    static let directory: String = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shellter/zmx", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }()

    /// The session name of a tab: short, because it becomes part of the socket path.
    static func sessionName(for id: UUID) -> String {
        "s" + id.uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
    }

    /// The command that the terminal runs for a tab. Ghostty runs it through a shell.
    static func attachCommand(session: String) -> String? {
        guard let binary else { return nil }
        return "\(Shell.quote(binary)) attach \(session)"
    }

    /// Environment for the zmx client. The daemon and the shell in it inherit it.
    static var environment: [String: String] {
        var env = ["ZMX_DIR": directory, "ZMX_NO_DETACH_KEY": "1"]
        // Ghostty injects its shell integration only when it starts a shell itself.
        // Here it starts zmx, so set up the integration for zsh and fish ourselves.
        guard let integration = Bundle.main.resourceURL?
            .appendingPathComponent("ghostty/shell-integration").path else { return env }
        let current = ProcessInfo.processInfo.environment
        switch ((current["SHELL"] ?? "") as NSString).lastPathComponent {
        case "zsh":
            if let old = current["ZDOTDIR"] { env["GHOSTTY_ZSH_ZDOTDIR"] = old }
            env["ZDOTDIR"] = integration + "/zsh"
        case "fish":
            let dirs = current["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share"
            env["GHOSTTY_SHELL_INTEGRATION_XDG_DIR"] = integration
            env["XDG_DATA_DIRS"] = integration + ":" + dirs
        default:
            break
        }
        return env
    }

    /// Session name → PID of the shell in it.
    static func list() -> [String: pid_t] {
        guard let out = run(["list"]) else { return [:] }
        var result: [String: pid_t] = [:]
        for line in out.split(separator: "\n") {
            var name: String?, pid: pid_t?
            for field in line.split(separator: "\t") {
                let f = field.trimmingCharacters(in: .whitespaces)
                if f.hasPrefix("name=") { name = String(f.dropFirst(5)) }
                if f.hasPrefix("pid=") { pid = pid_t(f.dropFirst(4)) }
            }
            if let name, let pid { result[name] = pid }
        }
        return result
    }

    static func kill(_ session: String) {
        DispatchQueue.global(qos: .utility).async { _ = run(["kill", session]) }
    }

    /// Kills the sessions that no tab uses (e.g. tabs closed while zmx was not available).
    static func killOrphans(keeping names: Set<String>) {
        DispatchQueue.global(qos: .utility).async {
            for name in list().keys where !names.contains(name) { _ = run(["kill", name]) }
        }
    }

    @discardableResult
    private static func run(_ args: [String]) -> String? {
        guard let binary else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(["ZMX_DIR": directory]) { $1 }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

}
