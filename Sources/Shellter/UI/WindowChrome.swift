import AppKit
import Combine
import SwiftUI

/// Window and sidebar colors, derived from the terminal config.
final class WindowChrome: ObservableObject {
    static let shared = WindowChrome()

    @Published private(set) var background: NSColor = .windowBackgroundColor
    @Published private(set) var opacity: Double = 1
    @Published private(set) var isDark = true
    @Published private(set) var sidebarStyle: AppearanceSettings.SidebarStyle = .terminal

    private var bag = Set<AnyCancellable>()

    private init() {
        NotificationCenter.default.publisher(for: .ghosttyConfigDidChange)
            .sink { [weak self] _ in self?.update() }
            .store(in: &bag)
        AppearanceSettings.shared.$state
            .map(\.sidebarStyle)
            .removeDuplicates()
            .sink { [weak self] style in self?.sidebarStyle = (style ?? .terminal).effective }
            .store(in: &bag)
        update()
    }

    func update() {
        let app = GhosttyApp.shared
        let bg = app.backgroundColor ?? .black
        // Assign only changed values: every assignment re-renders the sidebar.
        if background != bg { background = bg }
        if opacity != app.backgroundOpacity { opacity = app.backgroundOpacity }
        let dark = Self.luminance(bg) < 0.5
        if isDark != dark { isDark = dark }
    }

    var appearance: NSAppearance? {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    static func luminance(_ c: NSColor) -> Double {
        guard let rgb = c.usingColorSpace(.sRGB) else { return 0 }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }

    /// The macOS sidebar material behind the whole window. A transparent terminal shows it
    /// tinted with the theme background, so it looks the same with every sidebar style.
    /// The macOS sidebar style needs it also for an opaque terminal.
    var showsMaterial: Bool { sidebarStyle == .system || opacity < 1 }

    /// The floating glass sidebar of macOS 26. It gets its own material, so the window
    /// needs none.
    var floatingSidebar: Bool { sidebarStyle == .floating }

    /// Makes the window see-through when the terminal background is not opaque.
    func apply(to window: NSWindow) {
        // Change only what differs: a new appearance re-draws the whole window.
        if window.appearance?.name != appearance?.name { window.appearance = appearance }
        let fullScreen = window.styleMask.contains(.fullScreen)
        let transparent = opacity < 1 && !fullScreen
        // Not .clear for a transparent window: this matches Terminal.app (same as Ghostty).
        let color = transparent ? NSColor.white.withAlphaComponent(0.001) : background
        if window.isOpaque == transparent { window.isOpaque = !transparent }
        if window.backgroundColor != color { window.backgroundColor = color }
    }
}

/// The sidebar background: the terminal color, or the translucent macOS sidebar material.
struct SidebarBackground: View {
    @ObservedObject var chrome = WindowChrome.shared

    var body: some View {
        Group {
            switch chrome.sidebarStyle {
            case .terminal:
                Color(nsColor: chrome.background).opacity(chrome.opacity)
            case .system, .floating:
                Color.clear   // the window's material or the glass panel shows through
            }
        }
        .ignoresSafeArea()
    }
}
