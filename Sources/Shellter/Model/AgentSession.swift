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
        case .antigravity:
            // agy keeps presence/<id>.lock and conversations/<id>.db open while a conversation runs.
            for pid in pids {
                for path in ProcessInspector.openFiles(of: pid) {
                    if let id = antigravityConversationID(fromPath: path) { return id }
                }
            }
            return nil
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
        case .antigravity: return session.map { "agy --conversation \(Shell.quote($0))" } ?? "agy --continue"
        }
    }

    /// Command that starts a copy of the session that goes its own way, or nil.
    /// The fork starts with the whole conversation, so it looks like the original until
    /// the first new message; `name` (where the agent supports it) tells the two apart.
    static func forkCommand(_ agent: Agent, session: String?, name: String? = nil) -> String? {
        let named = name.map { " --name \(Shell.quote($0))" } ?? ""
        switch agent {
        case .claude: return session.map { "claude --resume \(Shell.quote($0)) --fork-session" + named }
        case .codex: return session.map { "codex fork \(Shell.quote($0))" } ?? "codex fork --last"
        case .pi: return session.map { "pi --fork \(Shell.quote($0))" + named }
        case .opencode, .antigravity: return nil
        }
    }

    /// The name of a branch: "Branch: <title>", short enough for the prompt box.
    static func branchName(title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespaces)
        let short = t.count > 40 ? String(t.prefix(39)) + "…" : t
        return short.isEmpty ? "Branch" : "Branch: \(short)"
    }

    // MARK: Helpers

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func codexSessionID(fromPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"), name.count > 42 else { return nil }
        let id = String(name.dropLast(6).suffix(36))
        return UUID(uuidString: id) != nil ? id : nil
    }

    /// The conversation ID in an Antigravity CLI path:
    /// ~/.gemini/antigravity-cli/presence/<id>.lock or …/conversations/<id>.db.
    static func antigravityConversationID(fromPath path: String) -> String? {
        guard path.contains("/antigravity-cli/presence/") || path.contains("/antigravity-cli/conversations/") else { return nil }
        let name = (path as NSString).lastPathComponent
        guard name.hasSuffix(".lock") || name.hasSuffix(".db") else { return nil }
        let id = (name as NSString).deletingPathExtension
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
