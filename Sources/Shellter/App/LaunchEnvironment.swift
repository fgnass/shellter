import Foundation

/// Cleans the environment when Shellter was started from a shell (`open` passes the
/// caller's environment on). Otherwise every tab would inherit the variables of that
/// shell: the session markers of a coding agent, a stale PATH, TERM_PROGRAM and so on.
/// Login shells in the tabs then set everything up again, as after a start from the Dock.
enum LaunchEnvironment {
    /// The variables that macOS sets for an app started from the Finder or the Dock.
    private static let keep: Set<String> = [
        "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "SSH_AUTH_SOCK", "LANG",
        "COMMAND_MODE", "XPC_FLAGS", "XPC_SERVICE_NAME", "__CF_USER_TEXT_ENCODING",
        "__CFBundleIdentifier",
    ]

    static func clean() {
        let env = ProcessInfo.processInfo.environment
        // Apps from the Dock have no SHLVL and no TERM.
        guard env["SHLVL"] != nil || env["TERM"] != nil else { return }
        for key in env.keys where !keep.contains(key) && !key.hasPrefix("LC_") {
            unsetenv(key)
        }
        // The launchd default. The login shell adds the rest (path_helper, profile).
        setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1)
    }
}
