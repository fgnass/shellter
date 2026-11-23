import AppKit
import Combine

/// The editor that opens a project folder (context menu "Open in …"). Settings → Window.
final class EditorSettings: ObservableObject {
    static let shared = EditorSettings()

    struct App: Identifiable, Hashable {
        let bundleID: String
        let name: String
        let url: URL
        var id: String { bundleID }
        var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
    }

    /// Editors that Shellter knows. Only the installed ones show in the settings.
    static let known = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.exafunction.windsurf", "com.vscodium",
        "dev.zed.Zed", "com.sublimetext.4", "com.panic.Nova", "com.barebones.bbedit",
        "com.jetbrains.intellij", "com.jetbrains.WebStorm", "com.apple.dt.Xcode",
    ]

    @Published private(set) var editor: App?

    private init() {
        let saved = UserDefaults.standard.string(forKey: "EditorBundleID")
        editor = saved.flatMap(Self.app) ?? Self.installed().first
    }

    /// The installed known editors, and the chosen editor when it is not a known one.
    func choices() -> [App] {
        var list = Self.installed()
        if let editor, !list.contains(editor) { list.append(editor) }
        return list
    }

    func select(_ app: App) {
        editor = app
        UserDefaults.standard.set(app.bundleID, forKey: "EditorBundleID")
    }

    /// Lets the user pick any app in /Applications.
    func chooseOther() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.prompt = "Choose Editor"
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier else { return }
        select(App(bundleID: id, name: Self.displayName(url), url: url))
    }

    /// Opens `folder` in the editor. An editor of the VS Code family brings its window to
    /// the front when the folder is open in it already.
    func open(_ folder: String) {
        guard let editor else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: folder, isDirectory: true)],
                                withApplicationAt: editor.url,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    private static func installed() -> [App] { known.compactMap(app) }

    private static func app(_ bundleID: String) -> App? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return App(bundleID: bundleID, name: displayName(url), url: url)
    }

    private static func displayName(_ url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
