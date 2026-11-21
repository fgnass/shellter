import AppKit
import Combine
import SwiftUI

/// Hosts the terminal of the selected tab.
final class TerminalContainerController: NSViewController {
    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        view = v
    }

    func show(_ terminal: TerminalView) {
        if terminal.superview !== view {
            terminal.frame = view.bounds
            terminal.autoresizingMask = [.width, .height]
            view.addSubview(terminal)
        }
        for case let t as TerminalView in view.subviews {
            t.setVisible(t === terminal)
        }
        focus(terminal)
    }

    /// SwiftUI may take the focus after a layout pass, so focus again on the next run loop.
    func focus(_ terminal: TerminalView) {
        view.window?.makeFirstResponder(terminal)
        DispatchQueue.main.async { [weak self, weak terminal] in
            guard let terminal, terminal.window != nil else { return }
            self?.view.window?.makeFirstResponder(terminal)
        }
    }
}

final class MainWindowController: NSWindowController, NSWindowDelegate {
    let store: SessionStore
    private let split = NSSplitViewController()
    private let container = TerminalContainerController()
    private var bag = Set<AnyCancellable>()

    init(store: SessionStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.setFrameAutosaveName("ShellterMain")
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        let sidebar = NSHostingController(rootView: SidebarView(store: store))
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController: container)
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)
        split.splitView.autosaveName = "ShellterSplit"
        window.contentViewController = split
        window.minSize = NSSize(width: 600, height: 400)
        if !window.setFrameUsingName("ShellterMain") || window.frame.width < 600 {
            window.setContentSize(NSSize(width: 1200, height: 760))
            window.center()
        }

        store.onShow = { [weak self] s in self?.show(s) }
        store.$selectedID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &bag)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func show(_ s: Session) {
        let v = s.ensureView()
        v.eventHandler = store
        container.show(v)
        updateTitle()
    }

    func showSelected() {
        if let s = store.selected { show(s) }
    }

    private func updateTitle() {
        window?.title = store.selected?.title ?? "Shellter"
    }

    @objc func toggleSidebar(_ sender: Any?) {
        split.toggleSidebar(sender)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        GhosttyApp.shared.setFocus(true)
        store.selected?.clearAttention()
    }

    func windowDidResignKey(_ notification: Notification) {
        GhosttyApp.shared.setFocus(false)
    }
}
