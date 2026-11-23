import AppKit

/// A terminal color theme from any source.
struct TerminalTheme: Identifiable, Hashable {
    enum Source: Hashable {
        case builtin
        case editor(String)     // editor name, e.g. "VS Code"
        case imported
    }

    let id: String
    let name: String
    let source: Source
    let isDark: Bool
    let background: RGB
    let foreground: RGB
    let palette: [RGB]          // 16 ANSI colors
    let cursor: RGB?
    let selection: RGB?
    /// Built-in: the theme name. Others: the file is written on demand.
    let builtinName: String?

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    /// Ghostty config file contents for this theme.
    var ghosttyConfig: String {
        var lines = [
            "background = \(background.hex)",
            "foreground = \(foreground.hex)",
        ]
        if let cursor { lines.append("cursor-color = \(cursor.hex)") }
        if let selection {
            lines.append("selection-background = \(selection.hex)")
            // Without a foreground, Ghostty draws selected text in the background color.
            // Editors draw the selection behind the text, so keep the text colors.
            lines.append("selection-foreground = cell-foreground")
        }
        for (i, c) in palette.enumerated() { lines.append("palette = \(i)=\(c.hex)") }
        return lines.joined(separator: "\n") + "\n"
    }
}

struct RGB: Hashable {
    var r: Double, g: Double, b: Double     // 0...1

    var hex: String {
        String(format: "#%02x%02x%02x", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    var color: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }

    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    /// Parses #rgb, #rgba, #rrggbb, #rrggbbaa (or without "#"). Alpha is blended over `over`.
    static func parse(_ s: String, over: RGB? = nil) -> RGB? {
        var h = s.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 3 || h.count == 4 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
        let hasAlpha = h.count == 8
        let shift: UInt64 = hasAlpha ? 8 : 0
        var c = RGB(r: Double((v >> (16 + shift)) & 0xff) / 255,
                    g: Double((v >> (8 + shift)) & 0xff) / 255,
                    b: Double((v >> shift) & 0xff) / 255)
        if hasAlpha, let over {
            let a = Double(v & 0xff) / 255
            c = RGB(r: c.r * a + over.r * (1 - a), g: c.g * a + over.g * (1 - a), b: c.b * a + over.b * (1 - a))
        }
        return c
    }
}

/// An installed VS Code–like editor.
struct Editor: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let extensionDirs: [URL]
    let settingsURL: URL
}

final class ThemeLibrary {
    static let shared = ThemeLibrary()

    private(set) var builtin: [TerminalTheme] = []
    private(set) var editorThemes: [String: [TerminalTheme]] = [:]
    private(set) var imported: [TerminalTheme] = []
    private var loaded = false

    static var themesDir: URL {
        AppearanceSettings.supportDir.appendingPathComponent("themes", isDirectory: true)
    }
    static var importedDir: URL { themesDir.appendingPathComponent("imported", isDirectory: true) }

    var all: [TerminalTheme] {
        editors.flatMap { editorThemes[$0.name] ?? [] } + imported + builtin
    }

    private var byID: [String: TerminalTheme] = [:]

    func theme(id: String?) -> TerminalTheme? {
        guard let id else { return nil }
        loadIfNeeded()
        return byID[id]
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        reload()
    }

    func reload() {
        loaded = true
        builtin = loadBuiltin()
        editorThemes = [:]
        for e in editors { editorThemes[e.name] = loadEditorThemes(e) }
        imported = loadImported()
        byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Built-in (Ghostty theme files)

    private func loadBuiltin() -> [TerminalTheme] {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("ghostty/themes"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return files.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let name = url.lastPathComponent
            return Self.parseGhosttyTheme(text, id: "builtin:\(name)", name: name, source: .builtin, builtinName: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func parseGhosttyTheme(_ text: String, id: String, name: String,
                                  source: TerminalTheme.Source, builtinName: String?) -> TerminalTheme? {
        var bg: RGB?, fg: RGB?, cursor: RGB?, sel: RGB?
        var palette = defaultPalette(dark: true)
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "background": bg = RGB.parse(value)
            case "foreground": fg = RGB.parse(value)
            case "cursor-color": cursor = RGB.parse(value)
            case "selection-background": sel = RGB.parse(value)
            case "palette":
                let parts = value.split(separator: "=", maxSplits: 1)
                if parts.count == 2, let i = Int(parts[0].trimmingCharacters(in: .whitespaces)), (0..<16).contains(i),
                   let c = RGB.parse(String(parts[1])) {
                    palette[i] = c
                }
            default: break
            }
        }
        guard let bg, let fg else { return nil }
        return TerminalTheme(id: id, name: name, source: source, isDark: bg.luminance < 0.5,
                             background: bg, foreground: fg, palette: palette, cursor: cursor,
                             selection: sel, builtinName: builtinName)
    }

    // MARK: Editors (VS Code, Cursor, VSCodium, Windsurf)

    lazy var editors: [Editor] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support")
        let candidates: [(String, String, String, String)] = [
            ("VS Code", ".vscode/extensions", "Visual Studio Code.app", "Code"),
            ("Cursor", ".cursor/extensions", "Cursor.app", "Cursor"),
            ("VSCodium", ".vscode-oss/extensions", "VSCodium.app", "VSCodium"),
            ("Windsurf", ".windsurf/extensions", "Windsurf.app", "Windsurf"),
        ]
        return candidates.compactMap { name, extDir, app, supportName in
            let fm = FileManager.default
            let user = home.appendingPathComponent(extDir)
            let builtin = URL(fileURLWithPath: "/Applications/\(app)/Contents/Resources/app/extensions")
            let dirs = [builtin, user].filter { fm.fileExists(atPath: $0.path) }
            guard !dirs.isEmpty else { return nil }
            return Editor(name: name, extensionDirs: dirs,
                          settingsURL: support.appendingPathComponent("\(supportName)/User/settings.json"))
        }
    }()

    private func loadEditorThemes(_ editor: Editor) -> [TerminalTheme] {
        var byLabel: [String: TerminalTheme] = [:]
        let fm = FileManager.default
        for dir in editor.extensionDirs {
            let exts = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }   // newer versions last
            for ext in exts {
                let pkgURL = ext.appendingPathComponent("package.json")
                guard let pkg = Self.readJSON(pkgURL) as? [String: Any],
                      let contributes = pkg["contributes"] as? [String: Any],
                      let themes = contributes["themes"] as? [[String: Any]] else { continue }
                let nls = Self.readJSON(ext.appendingPathComponent("package.nls.json")) as? [String: Any] ?? [:]
                for t in themes {
                    guard var label = (t["label"] as? String) ?? (t["id"] as? String),
                          let path = t["path"] as? String else { continue }
                    if label.hasPrefix("%"), label.hasSuffix("%") {
                        let key = String(label.dropFirst().dropLast())
                        label = (nls[key] as? String) ?? ((nls[key] as? [String: Any])?["message"] as? String) ?? label
                    }
                    let ui = t["uiTheme"] as? String ?? "vs-dark"
                    let dark = ui == "vs-dark" || ui == "hc-black"
                    let colors = Self.vscodeColors(ext.appendingPathComponent(path))
                    let theme = Self.convertVSCode(colors: colors, dark: dark,
                                                   id: "editor:\(editor.name):\(label)", name: label,
                                                   source: .editor(editor.name))
                    byLabel[label] = theme
                    if let id = t["id"] as? String, id != label { aliases[editor.name, default: [:]][id] = label }
                }
            }
        }
        return byLabel.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Theme ids that differ from labels, per editor (`workbench.colorTheme` may use either).
    private var aliases: [String: [String: String]] = [:]

    func editorTheme(_ editor: String, named name: String) -> TerminalTheme? {
        loadIfNeeded()
        let list = editorThemes[editor] ?? []
        let label = aliases[editor]?[name] ?? name
        return list.first { $0.name == label }
    }

    /// Reads `colors` of a VS Code theme file, following `include`.
    static func vscodeColors(_ url: URL, depth: Int = 0) -> [String: String] {
        guard depth < 5, let json = readJSON(url) as? [String: Any] else { return [:] }
        var colors: [String: String] = [:]
        if let include = json["include"] as? String {
            colors = vscodeColors(url.deletingLastPathComponent().appendingPathComponent(include), depth: depth + 1)
        }
        for (k, v) in (json["colors"] as? [String: Any]) ?? [:] {
            if let s = v as? String { colors[k] = s }
        }
        return colors
    }

    static func convertVSCode(colors: [String: String], dark: Bool, id: String, name: String,
                              source: TerminalTheme.Source) -> TerminalTheme {
        let defBG = RGB.parse(dark ? "#1f1f1f" : "#ffffff")!
        let bg = colors["terminal.background"].flatMap { RGB.parse($0) }
            ?? colors["editor.background"].flatMap { RGB.parse($0) } ?? defBG
        let fg = colors["terminal.foreground"].flatMap { RGB.parse($0, over: bg) }
            ?? colors["editor.foreground"].flatMap { RGB.parse($0, over: bg) }
            ?? RGB.parse(dark ? "#cccccc" : "#3b3b3b")!
        let keys = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
        var palette = defaultPalette(dark: dark)
        for (i, k) in keys.enumerated() {
            if let c = colors["terminal.ansi\(k)"].flatMap({ RGB.parse($0, over: bg) }) { palette[i] = c }
            if let c = colors["terminal.ansiBright\(k)"].flatMap({ RGB.parse($0, over: bg) }) { palette[i + 8] = c }
        }
        let cursor = (colors["terminalCursor.foreground"] ?? colors["editorCursor.foreground"]).flatMap { RGB.parse($0, over: bg) }
        let sel = (colors["terminal.selectionBackground"] ?? colors["editor.selectionBackground"]).flatMap { RGB.parse($0, over: bg) }
        return TerminalTheme(id: id, name: name, source: source, isDark: bg.luminance < 0.5,
                             background: bg, foreground: fg, palette: palette, cursor: cursor,
                             selection: sel, builtinName: nil)
    }

    /// VS Code's default terminal ANSI colors.
    static func defaultPalette(dark: Bool) -> [RGB] {
        let hex = dark
            ? ["#000000", "#cd3131", "#0dbc79", "#e5e510", "#2472c8", "#bc3fbc", "#11a8cd", "#e5e5e5",
               "#666666", "#f14c4c", "#23d18b", "#f5f543", "#3b8eea", "#d670d6", "#29b8db", "#e5e5e5"]
            : ["#000000", "#cd3131", "#107c10", "#949800", "#0451a5", "#bc05bc", "#0598bc", "#555555",
               "#666666", "#cd3131", "#14ce14", "#b5ba00", "#0451a5", "#bc05bc", "#0598bc", "#a5a5a5"]
        return hex.map { RGB.parse($0)! }
    }

    // MARK: Imported

    private func loadImported() -> [TerminalTheme] {
        let dir = Self.importedDir
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let name = url.lastPathComponent
            return Self.parseGhosttyTheme(text, id: "imported:\(name)", name: name, source: .imported, builtinName: nil)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Imports a .itermcolors, VS Code theme JSON or Ghostty theme file. Returns the new theme.
    func importTheme(from url: URL) throws -> TerminalTheme {
        let name = Self.safeName(url.deletingPathExtension().lastPathComponent)
        let theme: TerminalTheme
        switch url.pathExtension.lowercased() {
        case "itermcolors":
            guard let t = Self.parseITerm(url, name: name) else { throw CocoaError(.fileReadCorruptFile) }
            theme = t
        case "json":
            let colors = Self.vscodeColors(url)
            guard !colors.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            let json = Self.readJSON(url) as? [String: Any]
            let type = json?["type"] as? String ?? "dark"
            theme = Self.convertVSCode(colors: colors, dark: type != "light" && type != "hcLight",
                                       id: "imported:\(name)", name: name, source: .imported)
        default:
            let text = try String(contentsOf: url, encoding: .utf8)
            guard let t = Self.parseGhosttyTheme(text, id: "imported:\(name)", name: name,
                                                 source: .imported, builtinName: nil)
            else { throw CocoaError(.fileReadCorruptFile) }
            theme = t
        }
        try FileManager.default.createDirectory(at: Self.importedDir, withIntermediateDirectories: true)
        try theme.ghosttyConfig.write(to: Self.importedDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        imported = loadImported()
        byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return imported.first { $0.id == theme.id } ?? theme
    }

    private static func parseITerm(_ url: URL, name: String) -> TerminalTheme? {
        guard let plist = NSDictionary(contentsOf: url) as? [String: Any] else { return nil }
        func color(_ key: String) -> RGB? {
            guard let d = plist[key] as? [String: Any],
                  let r = d["Red Component"] as? Double, let g = d["Green Component"] as? Double,
                  let b = d["Blue Component"] as? Double else { return nil }
            return RGB(r: r, g: g, b: b)
        }
        guard let bg = color("Background Color"), let fg = color("Foreground Color") else { return nil }
        var palette = defaultPalette(dark: bg.luminance < 0.5)
        for i in 0..<16 { if let c = color("Ansi \(i) Color") { palette[i] = c } }
        return TerminalTheme(id: "imported:\(name)", name: name, source: .imported, isDark: bg.luminance < 0.5,
                             background: bg, foreground: fg, palette: palette, cursor: color("Cursor Color"),
                             selection: color("Selection Color"), builtinName: nil)
    }

    // MARK: Config value

    /// The value for `theme = …`. Writes a theme file for non-built-in themes.
    func configValue(for theme: TerminalTheme) -> String {
        if let name = theme.builtinName { return name }
        if case .imported = theme.source {
            return Self.importedDir.appendingPathComponent(theme.name).path
        }
        let dir = Self.themesDir.appendingPathComponent("editors", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(Self.safeName(theme.id))
        try? theme.ghosttyConfig.write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    static func safeName(_ s: String) -> String {
        String(s.map { "/:,\\".contains($0) ? "-" : $0 })
    }

    // MARK: JSONC

    static func readJSON(_ url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // JSON5 allows comments and trailing commas, like VS Code's JSONC.
        if let obj = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed, .fragmentsAllowed]) {
            return obj
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(stripJSONC(text).utf8), options: [.fragmentsAllowed])
    }

    /// Removes comments and trailing commas (VS Code files are JSON with comments).
    static func stripJSONC(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var chars = Array(text.unicodeScalars)
        var i = 0
        var inString = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.unicodeScalars.append(c)
                if c == "\\", i + 1 < chars.count { out.unicodeScalars.append(chars[i + 1]); i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; out.unicodeScalars.append(c); i += 1; continue }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            out.unicodeScalars.append(c)
            i += 1
        }
        chars.removeAll()
        // Trailing commas (after comments are gone).
        return out.replacingOccurrences(of: ",\\s*([}\\]])", with: "$1", options: .regularExpression)
    }
}
