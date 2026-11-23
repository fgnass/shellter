import AppKit
import SwiftUI

/// Compact Mode: a small panel that floats above all apps and shows only the bottom rows
/// of the selected tab, e.g. to dictate feedback on something else on the screen.
/// The terminal keeps its size (no reflow of the agent's UI). The panel is a viewport on
/// it: the scroll wheel moves the viewport, not the terminal's scrollback.
final class CompactPanelController: NSWindowController, NSWindowDelegate {
    static let headerHeight: CGFloat = 26
    static let defaultHeight: CGFloat = 170

    /// Called when the user wants the normal window back.
    var onExpand: (() -> Void)?

    private let scroll: NSScrollView = {
        let s = NSScrollView()
        s.hasVerticalScroller = false
        s.hasHorizontalScroller = false
        s.drawsBackground = false
        s.verticalScrollElasticity = .none
        s.horizontalScrollElasticity = .none
        return s
    }()
    private let header = NSHostingView(rootView: AnyView(EmptyView()))
    private(set) var terminal: TerminalView?

    /// The clip view's y (from the document's bottom) that shows the last row at the
    /// panel's bottom: Ghostty's padding below the last row takes no space.
    private var anchor: CGFloat = 0

    init() {
        let panel = CompactPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: Self.defaultHeight),
            styleMask: [.borderless, .resizable],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        super.init(window: panel)
        panel.delegate = self

        let content = NSView()
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor(white: 1, alpha: 0.1).cgColor
        panel.contentView = content

        content.addSubview(scroll)
        content.addSubview(header)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Shows `terminal` of `session` in the panel. The terminal keeps its current size.
    func show(_ terminal: TerminalView, of session: Session) {
        guard let panel = window, let content = panel.contentView else { return }
        let size = terminal.frame.size
        if self.terminal !== terminal {
            if let old = self.terminal, old.superview === scroll.documentView { old.removeFromSuperview() }
            terminal.removeFromSuperview()
            let doc = NSView(frame: NSRect(origin: .zero, size: size))
            terminal.frame = doc.bounds
            terminal.autoresizingMask = []
            doc.addSubview(terminal)
            scroll.documentView = doc
            self.terminal = terminal
        }
        terminal.setVisible(true)
        header.rootView = AnyView(CompactHeader(session: session) { [weak self] in self?.onExpand?() })
        content.layer?.backgroundColor = WindowChrome.shared.background
            .withAlphaComponent(max(WindowChrome.shared.opacity, 0.92)).cgColor

        // As wide as the terminal; the height is free up to the full terminal.
        let width = size.width
        var frame = panel.frame
        let saved = UserDefaults.standard.double(forKey: "CompactPanelHeight")
        frame.size = NSSize(width: width, height: min(saved > 0 ? saved : Self.defaultHeight,
                                                      size.height + Self.headerHeight))
        if !panel.isVisible {
            frame.origin = Self.savedOrigin(for: frame.size)
                ?? Self.defaultOrigin(for: frame.size, on: NSScreen.main)
        }
        panel.minSize = NSSize(width: width, height: Self.headerHeight + 40)
        panel.maxSize = NSSize(width: width, height: size.height + Self.headerHeight)
        panel.setFrame(frame, display: true)
        layout()
        anchor = max(0, terminal.bottomPadding - 2)
        scrollToBottom()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(terminal)
    }

    /// Takes the terminal out of the panel and hides it.
    func close() -> TerminalView? {
        let t = terminal
        t?.removeFromSuperview()
        scroll.documentView = nil
        terminal = nil
        window?.orderOut(nil)
        return t
    }

    var isShown: Bool { window?.isVisible ?? false }

    private func layout() {
        guard let content = window?.contentView else { return }
        let b = content.bounds
        header.frame = NSRect(x: 0, y: b.height - Self.headerHeight, width: b.width, height: Self.headerHeight)
        scroll.frame = NSRect(x: 0, y: 0, width: b.width, height: b.height - Self.headerHeight)
    }

    /// The terminal's last row at the panel's bottom.
    private func scrollToBottom() {
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: anchor))   // the document is not flipped: y 0 is the bottom
        scroll.reflectScrolledClipView(clip)
    }

    // MARK: NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        // Keep the bottom rows in view when the panel gets taller or smaller.
        let atBottom = abs(scroll.contentView.bounds.minY - anchor) < 1
        layout()
        if atBottom { scrollToBottom() }
        if let h = window?.frame.height { UserDefaults.standard.set(h, forKey: "CompactPanelHeight") }
    }

    func windowDidMove(_ notification: Notification) {
        guard let f = window?.frame else { return }
        UserDefaults.standard.set([f.minX, f.minY], forKey: "CompactPanelOrigin")
    }

    func windowDidBecomeKey(_ notification: Notification) {
        GhosttyApp.shared.setFocus(true)
        if let terminal { window?.makeFirstResponder(terminal) }
    }

    func windowDidResignKey(_ notification: Notification) {
        GhosttyApp.shared.setFocus(false)
    }

    // MARK: Position

    private static func savedOrigin(for size: NSSize) -> NSPoint? {
        guard let a = UserDefaults.standard.array(forKey: "CompactPanelOrigin") as? [Double], a.count == 2
        else { return nil }
        let origin = NSPoint(x: a[0], y: a[1])
        // Only when the panel is still on a screen (e.g. after a display was removed).
        let rect = NSRect(origin: origin, size: size)
        return NSScreen.screens.contains { $0.visibleFrame.intersects(rect) } ? origin : nil
    }

    /// Bottom center of the screen, a bit above the Dock.
    private static func defaultOrigin(for size: NSSize, on screen: NSScreen?) -> NSPoint {
        let v = (screen ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: v.midX - size.width / 2, y: v.minY + 24)
    }
}

/// A borderless panel that can take the keyboard focus.
private final class CompactPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The panel's title line: the project and the tab, and a button for the normal window.
private struct CompactHeader: View {
    @ObservedObject var session: Session
    let expand: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            ProjectIcon(image: session.dirIcon, name: session.projectName, key: session.projectRoot, size: 14)
            Text("\(session.projectName) · \(session.title)")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary.opacity(0.85))
            Spacer(minLength: 8)
            Button(action: expand) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Back to the Window (⌘⇧K)")
        }
        .font(.system(size: 11.5))
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.05))
        .environment(\.colorScheme, WindowChrome.shared.isDark ? .dark : .light)
    }
}
