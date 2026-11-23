import AppKit
import Combine
import SwiftUI

/// Hosts the terminal of the selected tab.
final class TerminalContainerController: NSViewController {
    /// The find bar of the shown terminal, at the top right.
    private var searchHost: NSHostingView<AnyView>?
    private var searchVisible: AnyCancellable?

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        view = v
    }

    /// Adds a terminal hidden, unless it is the one on screen.
    func add(_ terminal: TerminalView) {
        guard terminal.superview !== view else { return }
        terminal.frame = view.bounds
        terminal.autoresizingMask = [.width, .height]
        view.addSubview(terminal, positioned: .below, relativeTo: searchHost)
        terminal.setVisible(false)
    }

    func show(_ terminal: TerminalView) {
        add(terminal)
        for case let t as TerminalView in view.subviews {
            t.setVisible(t === terminal)
        }
        showSearchBar(of: terminal)
        if !terminal.search.visible { focus(terminal) }
    }

    private func showSearchBar(of terminal: TerminalView) {
        searchHost?.removeFromSuperview()
        let host = NSHostingView(rootView: AnyView(SearchBar(search: terminal.search, terminal: terminal)))
        host.isHidden = !terminal.search.visible
        view.addSubview(host)
        searchHost = host
        layoutSearchBar()
        searchVisible = terminal.search.$visible
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible in
                host.isHidden = !visible
                self?.layoutSearchBar()
            }
    }

    private func layoutSearchBar() {
        guard let host = searchHost else { return }
        let size = host.fittingSize
        let b = view.bounds
        host.frame = NSRect(x: b.maxX - size.width - 16, y: b.maxY - size.height - 12,
                            width: size.width, height: size.height)
        host.autoresizingMask = [.minXMargin, .minYMargin]
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
    private var root: ChromeRootController!
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
        let sidebarItem = Self.makeSidebarItem(sidebar, floating: WindowChrome.shared.floatingSidebar)
        self.sidebarItem = sidebarItem
        // The floating sidebar reaches up next to the traffic lights only in a window
        // with a toolbar (unified style; not with unifiedCompact).
        if WindowChrome.shared.floatingSidebar { window.toolbar = NSToolbar() }
        let contentItem = NSSplitViewItem(viewController: container)
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)
        split.splitView.autosaveName = "ShellterSplit"
        split.splitView.dividerStyle = .thin
        let root = ChromeRootController(split: split)
        self.root = root
        window.contentViewController = root
        window.minSize = NSSize(width: 600, height: 400)
        if !window.setFrameUsingName("ShellterMain") || window.frame.width < 600 {
            window.setContentSize(NSSize(width: 1200, height: 760))
            window.center()
        }

        store.onShow = { [weak self] s in self?.show(s) }
        store.onAdd = { [weak self] s in self?.attach(s) }
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

    /// A sidebar item gives the floating glass sidebar of macOS 26. Otherwise a plain item:
    /// the sidebar item adds the system material, and Shellter draws its own background
    /// (see SidebarBackground).
    private static func makeSidebarItem(_ vc: NSViewController, floating: Bool) -> NSSplitViewItem {
        let item = floating ? NSSplitViewItem(sidebarWithViewController: vc)
                            : NSSplitViewItem(viewController: vc)
        item.minimumThickness = 180
        item.maximumThickness = 400
        item.canCollapse = true
        return item
    }

    /// Replaces the sidebar item when the sidebar style changes between floating and flat.
    private func updateSidebarItem() {
        let floating = WindowChrome.shared.floatingSidebar
        guard (sidebarItem.behavior == .sidebar) != floating else { return }
        let old = sidebarItem!
        // The width of the split pane: the floating sidebar's own view is inset in it.
        let width = split.splitView.arrangedSubviews.first?.frame.width ?? old.viewController.view.frame.width
        let collapsed = old.isCollapsed
        split.removeSplitViewItem(old)
        let item = Self.makeSidebarItem(old.viewController, floating: floating)
        item.isCollapsed = collapsed
        split.insertSplitViewItem(item, at: 0)
        sidebarItem = item
        window?.toolbar = floating ? NSToolbar() : nil
        if !collapsed { split.splitView.setPosition(width, ofDividerAt: 0) }
    }

    private func applyChrome() {
        guard let window else { return }
        WindowChrome.shared.apply(to: window)
        updateSidebarItem()
        let chrome = WindowChrome.shared
        root.setMaterial(chrome.sidebarStyle == .system)
        root.setBackdrop(chrome.floatingSidebar ? chrome.background.withAlphaComponent(chrome.opacity) : nil)
        split.splitView.needsDisplay = true
    }

    func windowDidEnterFullScreen(_ notification: Notification) { applyChrome() }
    func windowDidExitFullScreen(_ notification: Notification) { applyChrome() }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func show(_ s: Session) {
        container.show(terminal(for: s))
        updateTitle()
    }

    /// Creates the terminal of a new tab hidden in the container, so it starts in the size
    /// of the visible terminal and follows the window size from then on.
    private func attach(_ s: Session) {
        container.add(terminal(for: s))
    }

    private func terminal(for s: Session) -> TerminalView {
        window?.layoutIfNeeded()   // the container's real size, also before the window shows
        let v = s.ensureView(frame: container.view.bounds)
        v.eventHandler = store
        return v
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

/// Holds the split view over one material layer for the whole window, so the sidebar,
/// the divider and the terminal share the same backdrop (macOS sidebar style).
final class ChromeRootController: NSViewController {
    private let split: NSSplitViewController
    private let material: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        v.autoresizingMask = [.width, .height]
        v.isHidden = true
        return v
    }()

    init(split: NSSplitViewController) {
        self.split = split
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 760))
        material.frame = v.bounds
        v.addSubview(material)
        addChild(split)
        split.view.frame = v.bounds
        split.view.autoresizingMask = [.width, .height]
        v.addSubview(split.view)
        view = v
    }

    func setMaterial(_ on: Bool) {
        material.isHidden = !on
    }

    /// The terminal background behind the floating sidebar, so the terminal seems to
    /// continue under the glass panel. Only behind the sidebar pane: the terminal draws
    /// its own (maybe translucent) background.
    private let backdrop: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.isHidden = true
        return v
    }()
    private var resizeObserver: NSObjectProtocol?

    func setBackdrop(_ color: NSColor?) {
        if backdrop.superview == nil {
            view.addSubview(backdrop, positioned: .above, relativeTo: material)
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification, object: split.splitView, queue: .main
            ) { [weak self] _ in self?.layoutBackdrop() }
        }
        backdrop.isHidden = color == nil
        backdrop.layer?.backgroundColor = color?.cgColor
        layoutBackdrop()
    }

    private func layoutBackdrop() {
        guard !backdrop.isHidden, let pane = split.splitView.arrangedSubviews.first else { return }
        let width = split.splitViewItems.first?.isCollapsed == true ? 0
            : pane.frame.width + split.splitView.dividerThickness
        backdrop.frame = NSRect(x: 0, y: 0, width: width, height: view.bounds.height)
        backdrop.autoresizingMask = [.height]
    }
}

/// A divider that fits the terminal colors. It fills its gap first, so the desktop
/// does not show through a transparent window.
final class ChromeSplitView: NSSplitView {
    override var dividerColor: NSColor {
        WindowChrome.shared.isDark ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.1)
    }

    override func drawDivider(in rect: NSRect) {
        let chrome = WindowChrome.shared
        // The floating sidebar has no divider line: the backdrop fills the gap.
        if chrome.floatingSidebar { return }
        if chrome.sidebarStyle == .terminal {
            chrome.background.withAlphaComponent(chrome.opacity).setFill()
            rect.fill(using: .copy)
        }
        dividerColor.setFill()
        rect.fill(using: .sourceOver)
    }
}

/// Keeps the keyboard focus in the terminal: the sidebar never takes it.
final class ShellterWindow: NSWindow {
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if let view = responder as? NSView, !(view is TerminalView), !(view is NSTextView),
           !(view is NSTextField),
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
