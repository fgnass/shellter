import AppKit
import ApplicationServices

/// A window of another app that belongs to a tab. Two kinds:
/// - an app that runs below the tab's processes (e.g. a browser that a coding agent
///   started through an MCP server),
/// - a window that shows a file in the tab's folder (e.g. a slide deck that the agent
///   opened with `open`), or an editor window of the tab's project folder (e.g. after
///   `code .`). This needs the Accessibility permission.
struct LinkedWindow: Identifiable, Equatable {
    /// The app's PID.
    let pid: pid_t
    let appName: String
    /// The file the window shows, or the project folder of an editor window. Nil for an
    /// app from the process tree.
    let document: String?
    /// The PID of the process that started the app, for apps that can show one of their
    /// sessions (Habitab: its session ID is "hb-p<pid>").
    let launcherParent: pid_t?

    var id: String { "\(pid):\(document ?? "")" }

    var label: String {
        guard let document else { return appName }
        return "\(appName): \((document as NSString).lastPathComponent)"
    }

    var icon: NSImage? { NSRunningApplication(processIdentifier: pid)?.icon }
}

enum LinkedWindows {
    // MARK: Apps in the process tree

    /// Maps the app bundles from a process snapshot to running apps with windows.
    /// Must run on the main thread (NSWorkspace).
    static func apps(from processes: [ProcessInspector.AppProcess]) -> [LinkedWindow] {
        let own = Bundle.main.bundleURL.standardizedFileURL.path
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var result: [LinkedWindow] = []
        for p in processes where p.bundle != own {
            let app = running.first { $0.processIdentifier == p.pid }
                ?? running.first { $0.bundleURL?.standardizedFileURL.path == p.bundle }
            guard let app, !result.contains(where: { $0.pid == app.processIdentifier }) else { continue }
            result.append(LinkedWindow(pid: app.processIdentifier,
                                       appName: app.localizedName ?? (p.bundle as NSString).lastPathComponent,
                                       document: nil, launcherParent: p.parent))
        }
        return result
    }

    // MARK: Windows with documents (Accessibility)

    struct DocumentWindow: Equatable {
        let pid: pid_t
        let appName: String
        /// The file of the window (AXDocument), if any.
        let path: String?
        /// The name of the folder that an editor window of the VS Code family shows.
        var folderName: String? = nil
    }

    static var hasAccess: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that adds Shellter to Accessibility in System Settings.
    static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// The windows of all regular apps that show a file. Safe on a background queue.
    /// An app that does not answer in time is skipped.
    static func documentWindows(apps: [RegularApp]) -> [DocumentWindow] {
        guard hasAccess else { return [] }
        var result: [DocumentWindow] = []
        for app in apps {
            let editor = vscodeFamily.contains(app.bundleID)
            for w in windows(of: app.pid) {
                let path = document(of: w)
                let folder = editor ? title(of: w).flatMap(folderName(fromTitle:)) : nil
                guard path != nil || folder != nil else { continue }
                result.append(DocumentWindow(pid: app.pid, appName: app.name, path: path, folderName: folder))
            }
        }
        return result
    }

    /// The folder name in a window title of the VS Code family: "<file> — <folder>",
    /// or only "<folder>" when no file is open.
    static func folderName(fromTitle title: String) -> String? {
        let parts = title.components(separatedBy: " — ")
        let name = (parts.count >= 2 ? parts[1] : parts[0]).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Editors of the VS Code family. Their window title is "<file> — <folder name>", so
    /// the window of a project is found also when its file is not saved.
    static let vscodeFamily: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.exafunction.windsurf", "com.vscodium",
    ]

    struct RegularApp {
        let pid: pid_t
        let name: String
        let bundleID: String
    }

    /// Regular apps except Shellter. Must run on the main thread.
    static func regularApps() -> [RegularApp] {
        let own = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != own }
            .map { RegularApp(pid: $0.processIdentifier, name: $0.localizedName ?? "",
                              bundleID: $0.bundleIdentifier ?? "") }
    }

    /// The document windows that belong to each tab: the file is in the tab's folder.
    /// When more tabs match, the tabs with the deepest folder win, and of these the tabs
    /// with a coding agent (the agent most likely opened the file).
    static func assign(_ windows: [DocumentWindow],
                       to tabs: [(id: UUID, cwd: String, hasAgent: Bool)]) -> [UUID: [LinkedWindow]] {
        var result: [UUID: [LinkedWindow]] = [:]
        func add(_ link: LinkedWindow, to id: UUID) {
            if !(result[id] ?? []).contains(link) { result[id, default: []].append(link) }
        }
        for w in windows {
            // An editor window belongs to all tabs of the project with the folder's name.
            // When more projects have this name, the file of the window decides.
            if let name = w.folderName {
                var roots = Set(tabs.map(\.cwd).filter { ($0 as NSString).lastPathComponent == name })
                if roots.count > 1, let path = w.path {
                    roots = roots.filter { path.hasPrefix($0 + "/") }
                }
                if !roots.isEmpty {
                    for root in roots {
                        let link = LinkedWindow(pid: w.pid, appName: w.appName, document: root, launcherParent: nil)
                        for t in tabs where t.cwd == root { add(link, to: t.id) }
                    }
                    continue
                }
            }
            guard let path = w.path else { continue }
            var matches = tabs.filter { $0.cwd != "/" && path.hasPrefix($0.cwd + "/") }
            guard let deepest = matches.map(\.cwd.count).max() else { continue }
            matches = matches.filter { $0.cwd.count == deepest }
            if matches.contains(where: \.hasAgent) { matches = matches.filter(\.hasAgent) }
            let link = LinkedWindow(pid: w.pid, appName: w.appName, document: path, launcherParent: nil)
            for m in matches { add(link, to: m.id) }
        }
        return result
    }

    // MARK: Bring to front

    static func show(_ link: LinkedWindow) {
        guard let app = NSRunningApplication(processIdentifier: link.pid) else { return }
        // The project folder of an editor: opening the folder again brings its window
        // to the front, also when the window shows another file now.
        var isDir: ObjCBool = false
        if let folder = link.document, let appURL = app.bundleURL,
           FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue {
            NSWorkspace.shared.open([URL(fileURLWithPath: folder, isDirectory: true)],
                                    withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        if let document = link.document, hasAccess,
           let w = windows(of: link.pid).first(where: { Self.document(of: $0) == document }) {
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        }
        if app.bundleIdentifier == "dev.habitab.Habitab", let parent = link.launcherParent,
           let url = URL(string: "habitab://session/hb-p\(parent)"),
           NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
            return
        }
        app.activate()
    }

    // MARK: AX helpers

    private static func windows(of pid: pid_t) -> [AXUIElement] {
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list
    }

    private static func title(of window: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    /// The file of a window (AXDocument is a file URL string).
    private static func document(of window: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &value) == .success,
              let s = value as? String, let url = URL(string: s), url.isFileURL else { return nil }
        return url.standardizedFileURL.path
    }
}
