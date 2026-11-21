import AppKit
import Combine
import SwiftUI

/// Window and sidebar colors, derived from the terminal config.
final class WindowChrome: ObservableObject {
    static let shared = WindowChrome()

    @Published private(set) var background: NSColor = .windowBackgroundColor
    @Published private(set) var opacity: Double = 1
    @Published private(set) var blur = 0
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
            .sink { [weak self] style in self?.sidebarStyle = style ?? .terminal }
            .store(in: &bag)
        update()
    }

    func update() {
        let app = GhosttyApp.shared
        let bg = app.backgroundColor ?? .black
        background = bg
        opacity = app.backgroundOpacity
        blur = app.backgroundBlur
        isDark = Self.luminance(bg) < 0.5
    }

    var appearance: NSAppearance? {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    static func luminance(_ c: NSColor) -> Double {
        guard let rgb = c.usingColorSpace(.sRGB) else { return 0 }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }

    /// Makes the window see-through when the terminal background is not opaque.
    func apply(to window: NSWindow) {
        window.appearance = appearance
        let fullScreen = window.styleMask.contains(.fullScreen)
        let transparent = opacity < 1 && !fullScreen
        if transparent {
            window.isOpaque = false
            // Not .clear: this matches the look of Terminal.app (same as Ghostty).
            window.backgroundColor = .white.withAlphaComponent(0.001)
        } else {
            window.isOpaque = true
            window.backgroundColor = background
        }
        _ = CGSSetWindowBackgroundBlurRadius(
            CGSDefaultConnectionForThread(), window.windowNumber, Int32(transparent ? blur : 0))
        window.invalidateShadow()
    }
}

@_silgen_name("CGSDefaultConnectionForThread")
private func CGSDefaultConnectionForThread() -> UnsafeMutableRawPointer?

@_silgen_name("CGSSetWindowBackgroundBlurRadius")
private func CGSSetWindowBackgroundBlurRadius(_ cid: UnsafeMutableRawPointer?, _ wid: Int, _ radius: Int32) -> Int32

/// The sidebar background: the terminal color, or the translucent macOS sidebar material.
struct SidebarBackground: View {
    @ObservedObject var chrome = WindowChrome.shared

    var body: some View {
        Group {
            switch chrome.sidebarStyle {
            case .terminal:
                Color(nsColor: chrome.background).opacity(chrome.opacity)
            case .system:
                VisualEffect(material: .sidebar)
            }
        }
        .ignoresSafeArea()
    }
}

struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
    }
}
