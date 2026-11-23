import AppKit
import Combine

/// Font and theme choices from the Settings window. Written to a Ghostty config file
/// that is loaded after the user's Ghostty config.
final class AppearanceSettings: ObservableObject {
    static let shared = AppearanceSettings()

    struct State: Codable, Equatable {
        var fontFamily: String?
        var fontSize: Double?
        var ligatures = true
        /// nil: Shellter's own choice. Otherwise the name of the editor to follow.
        var followEditor: String?
        var darkThemeID: String?
        var lightThemeID: String?
        var separateLightTheme = false
        /// `background-opacity`, nil: Ghostty config or 1.
        var backgroundOpacity: Double?
        /// `background-blur` radius, nil: Ghostty config or none.
        var backgroundBlur: Int?
        /// nil: the sidebar uses the terminal colors.
        var sidebarStyle: SidebarStyle?
    }

    enum SidebarStyle: String, Codable, CaseIterable, Identifiable {
        /// The sidebar has the background color of the theme.
        case terminal
        /// The translucent macOS sidebar material, flat at the window edge.
        case system
        /// The floating glass sidebar of macOS 26 over the terminal background.
        case floating
        var id: String { rawValue }
        var label: String {
            switch self {
            case .terminal: "Terminal colors"
            case .system: "macOS sidebar"
            case .floating: "Floating glass"
            }
        }

        /// The styles that this macOS version supports.
        static var available: [SidebarStyle] {
            if #available(macOS 26, *) { return allCases }
            return [.terminal, .system]
        }

        /// The style to use: before macOS 26, floating glass falls back to the macOS sidebar.
        var effective: SidebarStyle {
            if #available(macOS 26, *) { return self }
            return self == .floating ? .system : self
        }
    }

    @Published var state = State() {
        didSet {
            guard state != oldValue else { return }
            if Self.themeKey(state) != Self.themeKey(oldValue) {
                cachedThemeValue = nil
                lastEditorStamp = nil
            }
            scheduleApply()
        }
    }

    /// The fields that select the theme.
    private static func themeKey(_ s: State) -> [String?] {
        [s.followEditor, s.darkThemeID, s.lightThemeID, String(s.separateLightTheme)]
    }

    /// The `theme =` value, computed once per theme choice (it reads editor files).
    private var cachedThemeValue: String??
    private var applyPending = false

    /// The theme ids that apply when following an editor (for display).
    @Published private(set) var followedThemes: (dark: String?, light: String?) = (nil, nil)

    static var supportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shellter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var configURL: URL { supportDir.appendingPathComponent("appearance.config") }
    private static var stateURL: URL { supportDir.appendingPathComponent("appearance.json") }

    private var watchTimer: Timer?
    private var lastEditorStamp: Date?

    private init() {
        if let data = try? Data(contentsOf: Self.stateURL),
           let s = try? JSONDecoder().decode(State.self, from: data) {
            _state = Published(initialValue: s)   // no didSet, no reload
        }
        // Write the file again: an older version of Shellter may have written it.
        writeConfig()
    }

    /// Starts watching the followed editor's settings.
    func start() {
        #if DEBUG
        // Test hook: `notifyutil`-free reload via a distributed notification.
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.fgnass.shellter.reloadAppearance"), object: nil, queue: .main
        ) { [weak self] _ in
            guard let data = try? Data(contentsOf: Self.stateURL),
                  let s = try? JSONDecoder().decode(State.self, from: data) else { return }
            if self?.state == s { self?.apply() } else { self?.state = s }
        }
        #endif
        watchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.checkEditor()
        }
        checkEditor()
    }

    // MARK: Apply

    /// Applies changes at most ~30 times per second, so a dragged slider stays smooth.
    private func scheduleApply() {
        guard !applyPending else { return }
        applyPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30) { [weak self] in
            self?.applyPending = false
            self?.apply()
        }
    }

    private func apply() {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: Self.stateURL, options: .atomic)
        }
        writeConfig()
        GhosttyApp.shared.reloadConfig()
    }

    private func writeConfig() {
        var lines = ["# Generated by Shellter from the Settings window. Do not edit."]
        if let family = state.fontFamily {
            lines.append("font-family = \"\"")
            lines.append("font-family = \"\(family)\"")
        }
        if let size = state.fontSize {
            lines.append("font-size = \(size)")
        }
        if !state.ligatures {
            lines += ["font-feature = -calt", "font-feature = -liga", "font-feature = -dlig"]
        }
        if let opacity = state.backgroundOpacity {
            lines.append("background-opacity = \(opacity)")
        }
        if let blur = state.backgroundBlur {
            lines.append("background-blur = \(blur)")
        }
        if cachedThemeValue == nil { cachedThemeValue = .some(themeConfigValue()) }
        if let value = cachedThemeValue! {
            lines.append("theme = \(value)")
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: Self.configURL, atomically: true, encoding: .utf8)
    }

    private func themeConfigValue() -> String? {
        let lib = ThemeLibrary.shared
        let dark: TerminalTheme?
        let light: TerminalTheme?
        if let editor = state.followEditor {
            let ids = editorThemeIDs(editor)
            followedThemes = ids
            dark = lib.theme(id: ids.dark)
            light = lib.theme(id: ids.light) ?? dark
        } else {
            dark = lib.theme(id: state.darkThemeID)
            light = state.separateLightTheme ? (lib.theme(id: state.lightThemeID) ?? dark) : dark
        }
        guard let dark else { return light.map { lib.configValue(for: $0) } }
        let d = lib.configValue(for: dark)
        guard let light, light.id != dark.id else { return d }
        return "light:\(lib.configValue(for: light)),dark:\(d)"
    }

    // MARK: Following an editor

    var followedEditor: Editor? {
        guard let name = state.followEditor else { return nil }
        return ThemeLibrary.shared.editors.first { $0.name == name }
    }

    /// The editor's current dark and light theme ids, from its settings.json.
    private func editorThemeIDs(_ editorName: String) -> (dark: String?, light: String?) {
        guard let editor = ThemeLibrary.shared.editors.first(where: { $0.name == editorName }) else { return (nil, nil) }
        let settings = ThemeLibrary.readJSON(editor.settingsURL) as? [String: Any] ?? [:]
        let lib = ThemeLibrary.shared
        func id(_ name: String?) -> String? {
            guard let name else { return nil }
            return lib.editorTheme(editor.name, named: name)?.id
        }
        if settings["window.autoDetectColorScheme"] as? Bool == true {
            let dark = id(settings["workbench.preferredDarkColorTheme"] as? String ?? "Default Dark Modern")
            let light = id(settings["workbench.preferredLightColorTheme"] as? String ?? "Default Light Modern")
            return (dark, light)
        }
        let current = id(settings["workbench.colorTheme"] as? String ?? "Default Dark Modern")
        return (current, nil)
    }

    private func checkEditor() {
        guard let editor = followedEditor else { return }
        let fm = FileManager.default
        var stamps = [editor.settingsURL] + editor.extensionDirs
        stamps = stamps.filter { fm.fileExists(atPath: $0.path) }
        let latest = stamps.compactMap {
            (try? fm.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }.max()
        guard latest != lastEditorStamp else { return }
        let first = lastEditorStamp == nil
        lastEditorStamp = latest
        if !first { ThemeLibrary.shared.reload() }
        let before = followedThemes
        let ids = editorThemeIDs(editor.name)
        if ids.dark != before.dark || ids.light != before.light {
            cachedThemeValue = nil
            writeConfig()
            GhosttyApp.shared.reloadConfig()
        }
    }

    // MARK: Light / dark

    /// Reports the macOS appearance to libghostty, so `light:…,dark:…` themes switch.
    func observeSystemAppearance() {
        let update = {
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            GhosttyApp.shared.setColorScheme(dark: dark)
        }
        update()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            DispatchQueue.main.async(execute: update)
        }
    }
    private var appearanceObservation: NSKeyValueObservation?
}
