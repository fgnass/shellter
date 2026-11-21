import AppKit
import Combine

/// Colors that the user chose for projects (project root → color). They win over the
/// color from the project icon. Stored in UserDefaults.
final class ProjectColors: ObservableObject {
    static let shared = ProjectColors()

    struct Swatch: Identifiable {
        let name: String
        let hex: String
        var id: String { hex }
        var color: NSColor { ProjectColors.color(hex: hex) ?? .gray }
    }

    static let palette: [Swatch] = [
        Swatch(name: "Red", hex: "#E5484D"),
        Swatch(name: "Orange", hex: "#F76B15"),
        Swatch(name: "Amber", hex: "#FFB224"),
        Swatch(name: "Lime", hex: "#99D52A"),
        Swatch(name: "Green", hex: "#46A758"),
        Swatch(name: "Teal", hex: "#12A594"),
        Swatch(name: "Cyan", hex: "#00A2C7"),
        Swatch(name: "Blue", hex: "#3E63DD"),
        Swatch(name: "Indigo", hex: "#6E56CF"),
        Swatch(name: "Purple", hex: "#8E4EC6"),
        Swatch(name: "Pink", hex: "#D6409F"),
        Swatch(name: "Brown", hex: "#AD7F58"),
    ]

    private static let key = "ProjectColors"
    @Published private(set) var custom: [String: String]

    private init() {
        custom = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    func color(for root: String) -> NSColor? {
        custom[root].flatMap(Self.color(hex:))
    }

    func hex(for root: String) -> String? { custom[root] }

    /// nil: back to the color from the icon.
    func set(_ color: NSColor?, for root: String) {
        custom[root] = color.flatMap(Self.hex(of:))
        UserDefaults.standard.set(custom, forKey: Self.key)
    }

    // MARK: Custom color from the color panel

    private var panelRoot: String?

    func showColorPanel(for root: String) {
        panelRoot = root
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = color(for: root) ?? .systemBlue
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func colorPanelChanged(_ panel: NSColorPanel) {
        guard let root = panelRoot else { return }
        set(panel.color, for: root)
    }

    // MARK: Hex

    static func hex(of color: NSColor) -> String? {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    static func color(hex: String) -> NSColor? {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(srgbRed: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                       blue: Double(v & 0xFF) / 255, alpha: 1)
    }

    /// A filled circle for menus (not a template image, so it keeps its color).
    static func swatchImage(_ color: NSColor, size: CGFloat = 12) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
