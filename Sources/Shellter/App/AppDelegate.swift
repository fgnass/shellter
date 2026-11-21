import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private var windowController: MainWindowController?
    private var termSource: DispatchSourceSignal?

    static func main() {
        LaunchEnvironment.clean()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = AppearanceSettings.shared   // writes appearance.config before libghostty reads it
        _ = GhosttyApp.shared
        AppearanceSettings.shared.observeSystemAppearance()
        AppearanceSettings.shared.start()
        NSApp.mainMenu = buildMenu()

        let wc = MainWindowController(store: store)
        windowController = wc
        store.onEmpty = { NSApp.terminate(nil) }
        store.start()
        handleTerminationSignal()
        wc.showWindow(nil)
        wc.showSelected()
        NSApp.activate(ignoringOtherApps: true)
        if UserDefaults.standard.bool(forKey: "ShellterShowSettings") {
            // Test hook. Opened a bit later, so it can be profiled apart from the launch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { SettingsWindowController.open() }
        }
    }

    /// SIGTERM (e.g. from `scripts/restart.sh`) quits without a dialog, but saves the tabs first.
    private func handleTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            self?.store.save()
            exit(0)
        }
        source.resume()
        termSource = source
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController?.showWindow(nil)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        store.save()
        // With zmx the processes keep running after quitting: nothing to confirm.
        if Zmx.isAvailable { return .terminateNow }
        let busy = store.sessions.filter { $0.view?.needsConfirmQuit ?? false }
        guard !busy.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Shellter?"
        alert.informativeText = busy.count == 1
            ? "A process is still running in “\(busy[0].title)”."
            : "Processes are still running in \(busy.count) tabs."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.save()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        store.selected?.clearAttention()
    }

    // MARK: Actions

    @objc func newTab(_ sender: Any?) { store.newTab() }
    @objc func find(_ sender: Any?) { store.selected?.view?.startSearch() }
    @objc func findNext(_ sender: Any?) { store.selected?.view?.searchNext() }
    @objc func findPrevious(_ sender: Any?) { store.selected?.view?.searchPrevious() }
    @objc func closeTab(_ sender: Any?) { if let s = store.selected { store.close(s) } }
    @objc func nextTab(_ sender: Any?) { store.selectRelative(1) }
    @objc func previousTab(_ sender: Any?) { store.selectRelative(-1) }
    @objc func nextNeedingInput(_ sender: Any?) { store.selectNextNeedingInput() }
    @objc func selectTabByTag(_ sender: NSMenuItem) { store.selectIndex(sender.tag) }
    @objc func toggleSidebar(_ sender: Any?) { windowController?.toggleSidebar(sender) }
    @objc func showSettings(_ sender: Any?) { SettingsWindowController.open() }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector?, _ key: String,
                  _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }

        submenu("Shellter", [
            item("About Shellter", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Settings…", #selector(showSettings(_:)), ",", target: self),
            .separator(),
            item("Hide Shellter", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item("Quit Shellter", #selector(NSApplication.terminate(_:)), "q"),
        ])

        submenu("Shell", [
            item("New Tab", #selector(newTab(_:)), "t", target: self),
            item("Close Tab", #selector(closeTab(_:)), "w", target: self),
        ])

        submenu("Edit", [
            item("Copy", #selector(TerminalView.copy(_:)), "c"),
            item("Paste", #selector(TerminalView.paste(_:)), "v"),
            item("Select All", #selector(NSResponder.selectAll(_:)), "a"),
            .separator(),
            item("Find…", #selector(find(_:)), "f", target: self),
            item("Find Next", #selector(findNext(_:)), "g", target: self),
            item("Find Previous", #selector(findPrevious(_:)), "g", [.command, .shift], target: self),
        ])

        submenu("View", [
            item("Toggle Sidebar", #selector(toggleSidebar(_:)), "s", [.command, .control], target: self),
        ])

        var windowItems: [NSMenuItem] = [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            .separator(),
            item("Next Tab", #selector(nextTab(_:)), "\t", [.control], target: self),
            item("Previous Tab", #selector(previousTab(_:)), "\t", [.control, .shift], target: self),
            item("Next Tab", #selector(nextTab(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!),
                 [.command, .option], target: self),
            item("Previous Tab", #selector(previousTab(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!),
                 [.command, .option], target: self),
            item("Next Tab Needing Input", #selector(nextNeedingInput(_:)), "j", target: self),
            .separator(),
        ]
        for n in 1...9 {
            let i = item("Select Tab \(n)", #selector(selectTabByTag(_:)), "\(n)", target: self)
            i.tag = n == 9 ? Int.max / 2 : n - 1   // ⌘9 selects the last tab
            windowItems.append(i)
        }
        submenu("Window", windowItems)
        NSApp.windowsMenu = main.items.last?.submenu
        return main
    }
}
