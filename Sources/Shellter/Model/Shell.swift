import Foundation

/// Quoting for text that Shellter types into a shell.
enum Shell {
    /// Escapes shell characters with a backslash, as Terminal.app does for dropped files.
    static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            if "\\ ()[]{}<>\"'`!#$&;|*?\t~".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// Quotes a string as one literal argument (like Python's `shlex.quote`).
    static func quote(_ s: String) -> String {
        if !s.isEmpty, s.range(of: "^[A-Za-z0-9_@%+=:,./-]+$", options: .regularExpression) != nil { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
