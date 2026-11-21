import XCTest

final class AgentTests: XCTestCase {
    func testClaudeNativeBinary() {
        XCTAssertEqual(Agent.detect(path: "/Users/me/.local/share/claude/versions/2.1.330", args: ["claude"]), .claude)
    }

    func testClaudeFromNpm() {
        XCTAssertEqual(Agent.detect(path: "/usr/local/bin/node",
                                    args: ["node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"]), .claude)
    }

    func testCodexNodeWrapperAndNativeChild() {
        XCTAssertEqual(Agent.detect(path: "/opt/node/bin/node",
                                    args: ["node", "/opt/node/lib/node_modules/@openai/codex/bin/codex.js"]), .codex)
        XCTAssertEqual(Agent.detect(path: "/opt/codex/vendor/codex", args: ["codex"]), .codex)
    }

    func testPiFromManagedInstall() {
        XCTAssertEqual(Agent.detect(path: "/Users/me/.local/share/pi-node/current/bin/node",
                                    args: ["node", "/Users/me/.pi/agent/install/releases/1.6.0/node_modules/.bin/pi"]), .pi)
    }

    func testOpenCode() {
        XCTAssertEqual(Agent.detect(path: "/opt/homebrew/bin/opencode", args: ["opencode"]), .opencode)
    }

    func testOtherProgramsAreNoAgents() {
        XCTAssertNil(Agent.detect(path: "/bin/zsh", args: ["-zsh"]))
        XCTAssertNil(Agent.detect(path: "/opt/node/bin/node", args: ["node", "/app/node_modules/.bin/vite", "--host"]))
        XCTAssertNil(Agent.detect(path: "/usr/bin/pip3", args: ["pip3", "install", "pi"]), "only argv 0 and 1 count")
    }
}
