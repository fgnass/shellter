import Foundation

/// Cleans text that the user copies from the terminal UI of a coding agent such as Claude Code.
///
/// The agent draws its messages with markers (`⏺`, `⎿`), indents them, shows quotes with a
/// bar (`▎`) and breaks long lines itself at the terminal width. Copied as is, the text has
/// these markers and a line break wherever the line was full.
enum AgentText {
    /// - Parameters:
    ///   - columns: the terminal width when the agent drew the text.
    ///   - firstColumn: the column where the selection starts in its first line.
    static func clean(_ text: String, columns: Int, firstColumn: Int = 0) -> String {
        // Claude Code puts a no-break space after some markers.
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .components(separatedBy: "\n")
            .map { Line(text: trimTrailing($0)) }
        guard !lines.isEmpty else { return text }

        // The column where each line ends on screen, before markers are removed.
        for i in lines.indices {
            lines[i].endColumn = (i == 0 ? firstColumn : 0) + width(lines[i].text)
        }

        // Markers in front of a message or a tool result: replace them with spaces of the
        // same width, so the indent of the following lines still matches.
        for i in lines.indices where i > 0 || firstColumn == 0 {
            for marker in markers where lines[i].text.hasPrefix(marker) {
                lines[i].text = String(repeating: " ", count: width(marker))
                    + lines[i].text.dropFirst(marker.count)
                break
            }
        }

        removeCommonIndent(&lines)
        // Quotes: remove the bar in front of each line (drafts of messages are often quotes).
        // Codex shows Markdown quotes ("> "): only a block of such lines is a quote.
        let markdown = lines.map { $0.text == ">" || $0.text.hasPrefix("> ") }
        for i in lines.indices {
            let inBlock = markdown[i] && ((i > 0 && markdown[i - 1]) || (i + 1 < lines.count && markdown[i + 1]))
            guard inBlock || isQuoted(lines[i].text) else { continue }
            lines[i].text = String(lines[i].text.dropFirst())
            if lines[i].text.hasPrefix(" ") { lines[i].text.removeFirst() }
        }

        // Join the lines that the agent broke because they were full.
        var out: [String] = []
        var previous: Line?
        for line in lines {
            if let p = previous, var last = out.last,
               isWrapped(p, before: line.text, columns: columns) {
                // A word with a hyphen can be broken after the hyphen.
                let hyphen = last.hasSuffix("-") && last.dropLast().last?.isLetter == true
                last += (hyphen ? "" : " ") + line.text.drop(while: { $0 == " " })
                out[out.count - 1] = last
            } else {
                out.append(line.text)
            }
            previous = line
        }
        while out.last?.isEmpty == true { out.removeLast() }
        // The indent of the first line is left over from a marker or the selection start.
        if let first = out.first { out[0] = String(first.drop(while: { $0 == " " })) }
        return out.joined(separator: "\n")
    }

    private struct Line {
        var text: String
        var endColumn = 0
    }

    /// Claude Code: "⏺" in front of a message, "⎿" in front of a tool result. Codex: "•".
    private static let markers = ["⏺ ", "● ", "  ⎿  ", "• "]
    /// Claude Code shows quotes with "▎", Antigravity with "│".
    private static let quoteBars: Set<Character> = ["▎", "│"]

    /// "│" also draws tables: then the line has more box drawing characters.
    private static func isQuoted(_ s: String) -> Bool {
        guard let first = s.first, quoteBars.contains(first) else { return false }
        return first == "▎" || !s.dropFirst().unicodeScalars.contains { (0x2500...0x257F).contains($0.value) }
    }

    /// Some agents break lines a few cells before the right edge (Antigravity: 2).
    private static let wrapTolerance = 3

    /// True if the line was full: the first word of the next line did not fit after it.
    /// A line that ends far from the right edge has a real line break.
    private static func isWrapped(_ line: Line, before next: String, columns: Int) -> Bool {
        let body = next.drop(while: { $0 == " " })
        guard !line.text.isEmpty, !body.isEmpty, !startsBlock(String(body)),
              !isTableLine(line.text) else { return false }
        let word = body.prefix(while: { $0 != " " })
        return line.endColumn + 1 + width(String(word)) > columns - wrapTolerance
    }

    /// A list item, a heading or a table row starts on a new line.
    private static func startsBlock(_ s: String) -> Bool {
        if isTableLine(s) || s.hasPrefix("#") { return true }
        for bullet in ["- ", "* ", "• ", "+ "] where s.hasPrefix(bullet) { return true }
        // "1. " or "1) "
        let digits = s.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3 {
            let rest = s.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { return true }
        }
        return false
    }

    private static func isTableLine(_ s: String) -> Bool {
        guard let c = s.drop(while: { $0 == " " }).unicodeScalars.first else { return false }
        return (0x2500...0x257F).contains(c.value)   // box drawing
    }

    /// Removes the indent that all lines share. The first line does not count: the
    /// selection often starts at its first word.
    private static func removeCommonIndent(_ lines: inout [Line]) {
        let rest = lines.count > 1 ? Array(lines.dropFirst()) : lines
        let indents = rest.filter { !$0.text.isEmpty }.map { $0.text.prefix(while: { $0 == " " }).count }
        guard let common = indents.min(), common > 0 else { return }
        for i in lines.indices {
            let n = min(common, lines[i].text.prefix(while: { $0 == " " }).count)
            lines[i].text = String(lines[i].text.dropFirst(n))
        }
    }

    private static func trimTrailing(_ s: String) -> String {
        var s = Substring(s)
        while let c = s.last, c == " " || c == "\t" { s.removeLast() }
        return String(s)
    }

    /// The number of terminal cells: East Asian wide characters and emoji take two.
    static func width(_ s: String) -> Int {
        s.reduce(0) { sum, ch in
            guard let v = ch.unicodeScalars.first?.value else { return sum }
            let wide = (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v)
                || (0xAC00...0xD7A3).contains(v) || (0xF900...0xFAFF).contains(v)
                || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
                || (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1FAFF).contains(v)
                || (0x20000...0x3FFFD).contains(v)
            return sum + (wide ? 2 : 1)
        }
    }
}
