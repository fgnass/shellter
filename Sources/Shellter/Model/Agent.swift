import AppKit

/// A coding agent (harness) that runs in a tab.
enum Agent: String, Equatable, CaseIterable {
    case claude, codex, opencode, pi

    var name: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .pi: return "Pi"
        }
    }

    /// The agent's logo (lobe-icons, see Resources/AgentIcons), as a template image to tint.
    var icon: NSImage? { Self.icons[self] ?? nil }

    private static let icons: [Agent: NSImage?] = Dictionary(uniqueKeysWithValues: allCases.map { agent in
        let file = agent == .claude ? "claudecode" : agent.rawValue
        let url = Bundle.main.resourceURL?.appendingPathComponent("AgentIcons/\(file).svg")
        let image = url.flatMap { NSImage(contentsOf: $0) }
        image?.isTemplate = true
        return (agent, image)
    })

    /// Color of the agent icon.
    var color: NSColor {
        switch self {
        case .claude: return NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        case .codex: return NSColor(srgbRed: 0.06, green: 0.60, blue: 0.47, alpha: 1)
        case .opencode: return NSColor(srgbRed: 0.93, green: 0.64, blue: 0.10, alpha: 1)
        case .pi: return NSColor(srgbRed: 0.40, green: 0.42, blue: 0.95, alpha: 1)
        }
    }

    /// The agent a process belongs to, from its executable path and arguments.
    /// Agents often run as `node <script>`, so the first two arguments count too.
    static func detect(path: String, args: [String]) -> Agent? {
        let words = [path] + args.prefix(2)
        for w in words {
            let lower = w.lowercased()
            let base = (lower as NSString).lastPathComponent
            if base == "claude" || lower.contains("/claude/versions/") || lower.contains("@anthropic-ai/claude-code") {
                return .claude
            }
            if base == "codex" || base == "codex.js" || lower.contains("@openai/codex") { return .codex }
            if base == "opencode" || lower.contains("opencode-ai") || lower.contains("/opencode/") { return .opencode }
            if base == "pi" || lower.contains("pi-coding-agent") || lower.contains("/.pi/agent/") { return .pi }
        }
        return nil
    }
}
