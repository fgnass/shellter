import XCTest

final class AgentSessionTests: XCTestCase {
    func testCodexSessionIDFromRolloutPath() {
        let path = "/Users/me/.codex/sessions/2026/11/21/rollout-2026-11-21T15-02-13-0199a1b2-c3d4-4e5f-8a9b-0c1d2e3f4a5b.jsonl"
        XCTAssertEqual(AgentSession.codexSessionID(fromPath: path), "0199a1b2-c3d4-4e5f-8a9b-0c1d2e3f4a5b")
        XCTAssertNil(AgentSession.codexSessionID(fromPath: "/Users/me/.codex/config.toml"))
        XCTAssertNil(AgentSession.codexSessionID(fromPath: "/tmp/rollout-not-a-uuid.jsonl"))
    }

    func testPiSessionDirectory() {
        XCTAssertTrue(AgentSession.piSessionDirectory(for: "/Users/me/Projects/app").path
            .hasSuffix("/.pi/agent/sessions/--Users-me-Projects-app--"))
    }

    func testResumeCommands() {
        XCTAssertEqual(AgentSession.resumeCommand(.claude, session: "abc-123"), "claude --resume abc-123")
        XCTAssertEqual(AgentSession.resumeCommand(.claude, session: nil), "claude --continue")
        XCTAssertEqual(AgentSession.resumeCommand(.codex, session: nil), "codex resume --last")
        XCTAssertEqual(AgentSession.resumeCommand(.pi, session: "/Users/me/my sessions/a.jsonl"),
                       "pi --session '/Users/me/my sessions/a.jsonl'")
    }

    func testForkCommands() {
        XCTAssertEqual(AgentSession.forkCommand(.claude, session: "abc"), "claude --resume abc --fork-session")
        XCTAssertNil(AgentSession.forkCommand(.claude, session: nil), "forking needs the session")
        XCTAssertEqual(AgentSession.forkCommand(.codex, session: nil), "codex fork --last")
        XCTAssertEqual(AgentSession.forkCommand(.pi, session: "/s/a.jsonl"), "pi --fork /s/a.jsonl")
        XCTAssertNil(AgentSession.forkCommand(.opencode, session: "x"))
    }

    func testNamedFork() {
        XCTAssertEqual(AgentSession.forkCommand(.claude, session: "abc", name: "Branch: Mail client"),
                       "claude --resume abc --fork-session --name 'Branch: Mail client'")
        XCTAssertEqual(AgentSession.branchName(title: "  Eigener Mail-Client  "), "Branch: Eigener Mail-Client")
        XCTAssertEqual(AgentSession.branchName(title: String(repeating: "x", count: 50)).count, 48)
        XCTAssertEqual(AgentSession.branchName(title: ""), "Branch")
    }
}
