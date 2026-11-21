// Parts of this file are adapted from the Ghostty macOS app
// (https://github.com/ghostty-org/ghostty), MIT License,
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors.

import AppKit
import GhosttyKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let ghosttyConfigDidChange = Notification.Name("ShellterGhosttyConfigDidChange")
}

/// Events from libghostty that the rest of the app cares about.
enum TerminalEvent {
    case title(String)
    case pwd(String)
    case bell
    case notification(title: String, body: String)
    case progress(active: Bool)
    case commandFinished(exitCode: Int?)
    case childExited
    case newTab
    case closeTab
    case gotoTab(Int)       // >= 1: one-based index; -1 previous; -2 next; -3 last
    case quit
}

protocol TerminalEventHandler: AnyObject {
    func terminal(_ view: TerminalView, didEmit event: TerminalEvent)
    func terminalDidRequestClose(_ view: TerminalView, processAlive: Bool)
    func terminalDidReceiveInput(_ view: TerminalView)
}

/// Owns the single `ghostty_app_t` and routes runtime callbacks.
final class GhosttyApp {
    static let shared = GhosttyApp()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?

    private init() {
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            NSLog("Shellter: ghostty_init failed")
            return
        }

        FontLibrary.registerBundledFonts()
        guard let cfg = Self.makeConfig() else {
            NSLog("Shellter: ghostty_config_new failed")
            return
        }
        config = cfg

        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: true,
            wakeup_cb: { _ in
                DispatchQueue.main.async { GhosttyApp.shared.tick() }
            },
            action_cb: { app, target, action in
                GhosttyApp.shared.handleAction(target: target, action: action)
            },
            read_clipboard_cb: { ud, location, state, mimes, mimesLen, list in
                GhosttyApp.readClipboard(ud, location: location, state: state,
                                         mimes: mimes, mimesLen: mimesLen, list: list)
            },
            confirm_read_clipboard_cb: { ud, confirm, state, _ in
                GhosttyApp.confirmReadClipboard(ud, confirm: confirm, state: state)
            },
            write_clipboard_cb: { _, location, content, len, _ in
                GhosttyApp.writeClipboard(location: location, content: content, len: len)
            },
            close_surface_cb: { ud, processAlive in
                guard let view = TerminalView.from(userdata: ud) else { return }
                DispatchQueue.main.async {
                    view.eventHandler?.terminalDidRequestClose(view, processAlive: processAlive)
                }
            }
        )
        app = ghostty_app_new(&runtime, cfg)
        if app == nil { NSLog("Shellter: ghostty_app_new failed") }
    }

    /// Paths of the config files, in load order. Later files win.
    static var appearanceConfigPath: String {
        AppearanceSettings.configURL.path
    }

    private static func makeConfig() -> ghostty_config_t? {
        guard let cfg = ghostty_config_new() else { return nil }
        let fm = FileManager.default
        // 1. Shellter defaults  2. the user's Ghostty config
        // 3. choices from the Settings window  4. ~/.config/shellter/config
        if let defaults = Bundle.main.path(forResource: "defaults", ofType: "config") {
            ghostty_config_load_file(cfg, defaults)
        }
        ghostty_config_load_default_files(cfg)
        if fm.fileExists(atPath: appearanceConfigPath) {
            ghostty_config_load_file(cfg, appearanceConfigPath)
        }
        let override = fm.homeDirectoryForCurrentUser.appendingPathComponent(".config/shellter/config").path
        if fm.fileExists(atPath: override) {
            ghostty_config_load_file(cfg, override)
        }
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)

        let count = ghostty_config_diagnostics_count(cfg)
        for i in 0..<count {
            let d = ghostty_config_get_diagnostic(cfg, i)
            NSLog("Shellter config: %@", String(cString: d.message))
        }
        return cfg
    }

    /// Loads all config files again and applies them to every terminal.
    func reloadConfig() {
        guard let app, let cfg = Self.makeConfig() else { return }
        ghostty_app_update_config(app, cfg)
        if let old = config { ghostty_config_free(old) }
        config = cfg
        NotificationCenter.default.post(name: .ghosttyConfigDidChange, object: nil)
    }

    /// Tells libghostty whether macOS is in light or dark mode (for `theme = light:…,dark:…`).
    func setColorScheme(dark: Bool) {
        guard let app else { return }
        ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    /// The terminal background color of the current config.
    var backgroundColor: NSColor? {
        guard let config else { return nil }
        var c = ghostty_config_color_s()
        let key = "background"
        guard ghostty_config_get(config, &c, key, UInt(key.utf8.count)) else { return nil }
        return NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func setFocus(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }

    // MARK: Actions

    private func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        // App-level actions.
        switch action.tag {
        case GHOSTTY_ACTION_QUIT:
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return true
        default:
            break
        }

        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let view = TerminalView.from(userdata: ghostty_surface_userdata(surface))
        else { return false }

        // Copy any C strings now: they are only valid during this call.
        let event: TerminalEvent?
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            event = .title(String(cString: action.action.set_title.title))
        case GHOSTTY_ACTION_PWD:
            event = .pwd(String(cString: action.action.pwd.pwd))
        case GHOSTTY_ACTION_RING_BELL:
            event = .bell
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let n = action.action.desktop_notification
            event = .notification(
                title: String(cString: n.title),
                body: String(cString: n.body))
        case GHOSTTY_ACTION_PROGRESS_REPORT:
            let state = action.action.progress_report.state
            event = .progress(active: state != GHOSTTY_PROGRESS_STATE_REMOVE)
        case GHOSTTY_ACTION_COMMAND_FINISHED:
            let code = action.action.command_finished.exit_code
            event = .commandFinished(exitCode: code < 0 ? nil : Int(code))
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            event = .childExited
        case GHOSTTY_ACTION_NEW_TAB, GHOSTTY_ACTION_NEW_WINDOW:
            event = .newTab
        case GHOSTTY_ACTION_CLOSE_TAB, GHOSTTY_ACTION_CLOSE_WINDOW:
            event = .closeTab
        case GHOSTTY_ACTION_GOTO_TAB:
            event = .gotoTab(Int(action.action.goto_tab.rawValue))
        case GHOSTTY_ACTION_CELL_SIZE:
            let s = action.action.cell_size
            let scale = view.window?.backingScaleFactor ?? 2
            view.cellSize = NSSize(width: Double(s.width) / scale, height: Double(s.height) / scale)
            return true
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            view.setMouseShape(action.action.mouse_shape)
            return true
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            let u = action.action.open_url
            let data = Data(bytes: u.url, count: Int(u.len))
            if let str = String(data: data, encoding: .utf8) {
                let url = URL(string: str) ?? URL(fileURLWithPath: str)
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            }
            return true
        case GHOSTTY_ACTION_RENDER, GHOSTTY_ACTION_COLOR_CHANGE, GHOSTTY_ACTION_CONFIG_CHANGE,
             GHOSTTY_ACTION_SCROLLBAR, GHOSTTY_ACTION_RENDERER_HEALTH, GHOSTTY_ACTION_MOUSE_OVER_LINK,
             GHOSTTY_ACTION_SELECTION_CHANGED, GHOSTTY_ACTION_INITIAL_SIZE, GHOSTTY_ACTION_SIZE_LIMIT:
            return true
        default:
            return false
        }

        guard let event else { return false }
        let send: () -> Void = { view.eventHandler?.terminal(view, didEmit: event) }
        if Thread.isMainThread { send() } else { DispatchQueue.main.async(execute: send) }
        return true
    }

    // MARK: Clipboard

    private static func pasteboard(_ location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD: return .general
        case GHOSTTY_CLIPBOARD_SELECTION: return NSPasteboard(name: .init("com.fgnass.shellter.selection"))
        default: return nil
        }
    }

    private static func data(from pb: NSPasteboard, mime: String) -> Data? {
        switch mime {
        case "text/plain":
            if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty,
               urls.allSatisfy(\.isFileURL) {
                return Data(urls.map { $0.path.replacingOccurrences(of: " ", with: "\\ ") }
                    .joined(separator: " ").utf8)
            }
            return pb.string(forType: .string).map { Data($0.utf8) }
        default:
            guard let type = NSPasteboard.PasteboardType(mimeType: mime) else { return nil }
            return pb.data(forType: type)
        }
    }

    private static func complete(
        _ surface: ghostty_surface_t,
        contents: [(mime: String, data: Data)],
        available: [String],
        state: UnsafeMutableRawPointer,
        confirmed: Bool
    ) {
        var cStrings: [UnsafeMutablePointer<CChar>] = []
        var buffers: [UnsafeMutableRawPointer] = []
        defer {
            cStrings.forEach { free($0) }
            buffers.forEach { $0.deallocate() }
        }

        var cContents: [ghostty_clipboard_content_s] = []
        for entry in contents {
            guard let mime = strdup(entry.mime) else { continue }
            cStrings.append(mime)
            let buf = UnsafeMutableRawPointer.allocate(byteCount: max(entry.data.count, 1), alignment: 1)
            buffers.append(buf)
            entry.data.withUnsafeBytes { src in
                if let base = src.baseAddress { buf.copyMemory(from: base, byteCount: src.count) }
            }
            cContents.append(ghostty_clipboard_content_s(
                mime: mime, data: buf.assumingMemoryBound(to: CChar.self), len: entry.data.count))
        }
        var cAvailable: [UnsafePointer<CChar>] = []
        for mime in available {
            guard let s = strdup(mime) else { continue }
            cStrings.append(s)
            cAvailable.append(UnsafePointer(s))
        }

        cContents.withUnsafeBufferPointer { cb in
            cAvailable.withUnsafeBufferPointer { ab in
                var c = ghostty_clipboard_complete_s(
                    contents: cb.baseAddress, contents_len: cb.count,
                    available: ab.baseAddress, available_len: ab.count,
                    confirmed: confirmed, remember: false)
                ghostty_surface_complete_clipboard_request(surface, &c, state)
            }
        }
    }

    static func readClipboard(
        _ ud: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer,
        mimes: UnsafePointer<UnsafePointer<CChar>>,
        mimesLen: Int,
        list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard let view = TerminalView.from(userdata: ud), let surface = view.surface,
              let pb = pasteboard(location)
        else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }

        var contents: [(mime: String, data: Data)] = []
        var seen = Set<String>()
        for i in 0..<mimesLen {
            let mime = String(cString: mimes[i])
            guard seen.insert(mime).inserted, let d = data(from: pb, mime: mime) else { continue }
            contents.append((mime, d))
        }
        let available: [String] = list
            ? (pb.types ?? []).compactMap { $0 == .string ? "text/plain" : $0.mimeType }
            : []
        if contents.isEmpty && !list { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        complete(surface, contents: contents, available: available, state: state, confirmed: false)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    static func confirmReadClipboard(
        _ ud: UnsafeMutableRawPointer?,
        confirm: UnsafePointer<ghostty_clipboard_confirm_s>,
        state: UnsafeMutableRawPointer
    ) {
        guard let view = TerminalView.from(userdata: ud), let surface = view.surface else { return }
        let c = confirm.pointee
        var contents: [(mime: String, data: Data)] = []
        if let ptr = c.contents {
            for i in 0..<c.contents_len {
                let e = ptr[i]
                contents.append((String(cString: e.mime), Data(bytes: e.data, count: e.len)))
            }
        }
        var available: [String] = []
        if let ptr = c.available {
            for i in 0..<c.available_len { available.append(String(cString: ptr[i])) }
        }
        let preview = contents.first(where: { $0.mime == "text/plain" })
            .flatMap { String(data: $0.data, encoding: .utf8) } ?? ""

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Allow clipboard access?"
            alert.informativeText = String(preview.prefix(500))
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Deny")
            let finish: (NSApplication.ModalResponse) -> Void = { resp in
                if resp == .alertFirstButtonReturn {
                    complete(surface, contents: contents, available: available, state: state, confirmed: true)
                } else {
                    ghostty_surface_deny_clipboard_request(surface, state)
                }
            }
            if let window = view.window {
                alert.beginSheetModal(for: window, completionHandler: finish)
            } else {
                finish(alert.runModal())
            }
        }
    }

    static func writeClipboard(
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>,
        len: Int
    ) {
        guard len > 0, let pb = pasteboard(location) else { return }
        var items: [(NSPasteboard.PasteboardType, Data)] = []
        for i in 0..<len {
            let e = content[i]
            let mime = String(cString: e.mime)
            let type: NSPasteboard.PasteboardType? = mime == "text/plain" ? .string : .init(mimeType: mime)
            guard let type else { continue }
            items.append((type, Data(bytes: e.data, count: e.len)))
        }
        let write = {
            pb.declareTypes(items.map(\.0), owner: nil)
            for (type, data) in items { pb.setData(data, forType: type) }
        }
        if Thread.isMainThread { write() } else { DispatchQueue.main.async(execute: write) }
    }
}

extension NSPasteboard.PasteboardType {
    init?(mimeType: String) {
        switch mimeType {
        case "text/plain": self = .string
        case "text/html": self = .html
        case "image/png": self = .png
        default:
            guard let ut = UTType(mimeType: mimeType) else { return nil }
            self.init(ut.identifier)
        }
    }

    var mimeType: String? {
        UTType(rawValue)?.preferredMIMEType
    }
}

