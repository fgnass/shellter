import AppKit
import ApplicationServices

/// A window of another app that belongs to a tab. Two kinds:
/// - an app that runs below the tab's processes (e.g. a browser that a coding agent
///   started through an MCP server),
/// - a window that shows a file in the tab's folder (e.g. a slide deck that the agent
///   opened with `open`). This needs the Accessibility permission.
struct LinkedWindow: Identifiable, Equatable {
    /// The app's PID.
    let pid: pid_t
    let appName: String
    /// The file the window shows, nil for an app from the process tree.
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
        let path: String
    }

    static var hasAccess: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that adds Shellter to Accessibility in System Settings.
    static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// The windows of all regular apps that show a file. Safe on a background queue.
    /// An app that does not answer in time is skipped.
    static func documentWindows(apps: [(pid: pid_t, name: String)]) -> [DocumentWindow] {
        guard hasAccess else { return [] }
        var result: [DocumentWindow] = []
        for app in apps {
            for w in windows(of: app.pid) {
                guard let path = document(of: w) else { continue }
                result.append(DocumentWindow(pid: app.pid, appName: app.name, path: path))
            }
        }
        return result
    }

    /// Regular apps except Shellter. Must run on the main thread.
    static func regularApps() -> [(pid: pid_t, name: String)] {
        let own = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != own }
            .map { ($0.processIdentifier, $0.localizedName ?? "") }
    }

    /// The document windows that belong to each tab: the file is in the tab's folder.
    /// When more tabs match, the tabs with the deepest folder win, and of these the tabs
    /// with a coding agent (the agent most likely opened the file).
    static func assign(_ windows: [DocumentWindow],
                       to tabs: [(id: UUID, cwd: String, hasAgent: Bool)]) -> [UUID: [LinkedWindow]] {
        var result: [UUID: [LinkedWindow]] = [:]
        for w in windows {
            var matches = tabs.filter { $0.cwd != "/" && w.path.hasPrefix($0.cwd + "/") }
            guard let deepest = matches.map(\.cwd.count).max() else { continue }
            matches = matches.filter { $0.cwd.count == deepest }
            if matches.contains(where: \.hasAgent) { matches = matches.filter(\.hasAgent) }
            let link = LinkedWindow(pid: w.pid, appName: w.appName, document: w.path, launcherParent: nil)
            for m in matches where !(result[m.id] ?? []).contains(link) { result[m.id, default: []].append(link) }
        }
        return result
    }

    // MARK: Bring to front

    static func show(_ link: LinkedWindow) {
        guard let app = NSRunningApplication(processIdentifier: link.pid) else { return }
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

    /// The file of a window (AXDocument is a file URL string).
    private static func document(of window: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &value) == .success,
              let s = value as? String, let url = URL(string: s), url.isFileURL else { return nil }
        return url.standardizedFileURL.path
    }
}
