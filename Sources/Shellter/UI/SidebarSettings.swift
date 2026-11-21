import AppKit
import Combine

/// Layout choices for the sidebar (Settings → Window). Stored in UserDefaults.
final class SidebarSettings: ObservableObject {
    static let shared = SidebarSettings()

    enum GroupStyle: String, CaseIterable, Identifiable {
        case cards, lines
        var id: String { rawValue }
        var label: String { self == .cards ? "Cards" : "Lines in the project color" }
    }

    @Published var groupStyle: GroupStyle {
        didSet { UserDefaults.standard.set(groupStyle.rawValue, forKey: "SidebarGroupStyle") }
    }

    /// Tab titles in a condensed font, so more text fits in a row.
    @Published var condensedTitles: Bool {
        didSet { UserDefaults.standard.set(condensedTitles, forKey: "SidebarCondensedTitles") }
    }

    private init() {
        let d = UserDefaults.standard
        groupStyle = GroupStyle(rawValue: d.string(forKey: "SidebarGroupStyle") ?? "") ?? .cards
        condensedTitles = d.bool(forKey: "SidebarCondensedTitles")
    }
}

/// The main color of a project icon, for the group lines in the sidebar.
enum ProjectColor {
    private static let cache = NSCache<NSImage, NSColor>()

    static func of(image: NSImage?, key: String) -> NSColor {
        guard let image else { return IconResolver.color(for: key) }
        if let c = cache.object(forKey: image) { return c }
        let c = dominantColor(image) ?? IconResolver.color(for: key)
        cache.setObject(c, forKey: image)
        return c
    }

    /// Average of the visible pixels, weighted by saturation, so that white and
    /// gray areas count less than the colored parts of a logo.
    private static func dominantColor(_ image: NSImage) -> NSColor? {
        let n = 24
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: n, height: n))
        NSGraphicsContext.restoreGraphicsState()

        var r = 0.0, g = 0.0, b = 0.0, total = 0.0
        for x in 0..<n {
            for y in 0..<n {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5 else { continue }
                let w = 0.05 + c.saturationComponent * c.brightnessComponent
                r += c.redComponent * w; g += c.greenComponent * w; b += c.blueComponent * w
                total += w
            }
        }
        guard total > 0 else { return nil }
        return NSColor(srgbRed: r / total, green: g / total, blue: b / total, alpha: 1)
    }
}
