import Foundation

/// Finds the session of a running coding agent, and builds the commands that resume it
/// (after a reboot) or fork it into a new tab ("Branch Session").
enum AgentSession {
    /// The session of the agent that runs as `pids` in `cwd`: an ID or a session file path.
    static func current(_ agent: Agent, pids: [pid_t], cwd: String) -> String? {
        switch agent {
        case .claude:
            // Claude Code writes ~/.claude/sessions/<pid>.json with the session ID.
            for pid in pids {
                let url = home.appendingPathComponent(".claude/sessions/\(pid).json")
                if let data = try? Data(contentsOf: url),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let id = json["sessionId"] as? String { return id }
            }
            return nil
        case .codex:
            // Codex keeps its rollout file open: rollout-<time>-<uuid>.jsonl.
            for pid in pids {
                for path in ProcessInspector.openFiles(of: pid) {
                    if let id = codexSessionID(fromPath: path) { return id }
                }
            }
            return nil
        case .pi:
            return newestFile(in: piSessionDirectory(for: cwd))?.path
        case .opencode:
            return nil
        }
    }

    /// Command that continues the session in the same place.
    static func resumeCommand(_ agent: Agent, session: String?) -> String {
        switch agent {
        case .claude: return session.map { "claude --resume \(Shell.quote($0))" } ?? "claude --continue"
        case .codex: return session.map { "codex resume \(Shell.quote($0))" } ?? "codex resume --last"
        case .pi: return session.map { "pi --session \(Shell.quote($0))" } ?? "pi --continue"
        case .opencode: return "opencode --continue"
        }
    }

    /// Command that starts a copy of the session that goes its own way, or nil.
    static func forkCommand(_ agent: Agent, session: String?) -> String? {
        switch agent {
        case .claude: return session.map { "claude --resume \(Shell.quote($0)) --fork-session" }
        case .codex: return session.map { "codex fork \(Shell.quote($0))" } ?? "codex fork --last"
        case .pi: return session.map { "pi --fork \(Shell.quote($0))" }
        case .opencode: return nil
        }
    }

    // MARK: Helpers

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func codexSessionID(fromPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"), name.count > 42 else { return nil }
        let id = String(name.dropLast(6).suffix(36))
        return UUID(uuidString: id) != nil ? id : nil
    }

    /// Pi stores sessions in ~/.pi/agent/sessions/--Users-me-project--/.
    static func piSessionDirectory(for cwd: String) -> URL {
        let name = "--" + cwd.split(separator: "/").joined(separator: "-") + "--"
        return home.appendingPathComponent(".pi/agent/sessions/\(name)", isDirectory: true)
    }

    private static func newestFile(in dir: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "jsonl" }.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
    }

}
