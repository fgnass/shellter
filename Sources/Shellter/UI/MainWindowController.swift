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
    private let split: NSSplitViewController = {
        let c = NSSplitViewController()
        c.splitView = ChromeSplitView()
        c.splitView.isVertical = true
        return c
    }()
    private let container = TerminalContainerController()
    private var sidebarItem: NSSplitViewItem!
    private var bag = Set<AnyCancellable>()

    init(store: SessionStore) {
        self.store = store
        let window = ShellterWindow(
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
        // A plain item, not a sidebar item: the sidebar item adds the system material,
        // and Shellter draws its own background (see SidebarBackground).
        let sidebarItem = NSSplitViewItem(viewController: sidebar)
        self.sidebarItem = sidebarItem
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController: container)
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)
        split.splitView.autosaveName = "ShellterSplit"
        split.splitView.dividerStyle = .thin
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
        WindowChrome.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyChrome() }
            .store(in: &bag)
        applyChrome()
    }

    private func applyChrome() {
        guard let window else { return }
        WindowChrome.shared.apply(to: window)
        split.splitView.needsDisplay = true
    }

    func windowDidEnterFullScreen(_ notification: Notification) { applyChrome() }
    func windowDidExitFullScreen(_ notification: Notification) { applyChrome() }

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
        sidebarItem.animator().isCollapsed.toggle()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        GhosttyApp.shared.setFocus(true)
        if !(window?.firstResponder is TerminalView), let v = store.selected?.view {
            container.focus(v)
        }
        store.selected?.clearAttention()
    }

    func windowDidResignKey(_ notification: Notification) {
        GhosttyApp.shared.setFocus(false)
    }
}

/// A divider that fits the terminal colors.
final class ChromeSplitView: NSSplitView {
    override var dividerColor: NSColor {
        WindowChrome.shared.isDark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.12)
    }
}

/// Keeps the keyboard focus in the terminal: the sidebar never takes it.
final class ShellterWindow: NSWindow {
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if let view = responder as? NSView, !(view is TerminalView), !(view is NSTextView),
           isInSidebar(view),
           let terminal = terminalView(in: contentView) {
            return super.makeFirstResponder(terminal)
        }
        return super.makeFirstResponder(responder)
    }

    private func isInSidebar(_ view: NSView) -> Bool {
        var v: NSView? = view
        while let cur = v {
            if cur is TerminalView { return false }
            if cur is NSSplitView { return true }   // reached the split without a terminal
            v = cur.superview
        }
        return true
    }

    private func terminalView(in root: NSView?) -> TerminalView? {
        guard let root else { return nil }
        for sub in root.subviews {
            if let t = sub as? TerminalView, !t.isHidden { return t }
            if let t = terminalView(in: sub) { return t }
        }
        return nil
    }
}
