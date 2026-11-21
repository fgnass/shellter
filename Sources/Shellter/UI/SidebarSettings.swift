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

    /// `dark`: the sidebar is dark, so the color must be light enough, and the other way round.
    static func of(image: NSImage?, key: String, dark: Bool) -> NSColor {
        legible(base(image: image, key: key), onDark: dark)
    }

    private static func base(image: NSImage?, key: String) -> NSColor {
        guard let image else { return IconResolver.color(for: key) }
        if let c = cache.object(forKey: image) { return c }
        let c = dominantColor(image) ?? IconResolver.color(for: key)
        cache.setObject(c, forKey: image)
        return c
    }

    /// The strongest hue of the icon: colored pixels are sorted into hue buckets and the
    /// bucket with the most color wins. White, gray and black do not count. The result is
    /// made bright enough to read on a dark sidebar. Icons with almost no color return nil.
    private static func dominantColor(_ image: NSImage) -> NSColor? {
        let n = 32
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: n, height: n))
        NSGraphicsContext.restoreGraphicsState()

        let buckets = 12
        var weight = [Double](repeating: 0, count: buckets)
        var sum = [(h: Double, s: Double, b: Double)](repeating: (0, 0, 0), count: buckets)
        var visible = 0.0
        for x in 0..<n {
            for y in 0..<n {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      c.alphaComponent > 0.5 else { continue }
                visible += 1
                let chroma = c.saturationComponent * c.brightnessComponent
                guard chroma > 0.12 else { continue }
                let i = min(Int(c.hueComponent * Double(buckets)), buckets - 1)
                weight[i] += chroma
                sum[i].h += c.hueComponent * chroma
                sum[i].s += c.saturationComponent * chroma
                sum[i].b += c.brightnessComponent * chroma
            }
        }
        guard visible > 0, let best = weight.indices.max(by: { weight[$0] < weight[$1] }),
              weight[best] / visible > 0.02 else { return nil }
        let w = weight[best]
        let hue = sum[best].h / w
        let sat = min(max(sum[best].s / w, 0.35), 0.75)
        let bright = max(sum[best].b / w, 0.75)
        return NSColor(hue: hue, saturation: sat, brightness: bright, alpha: 1)
    }

    /// Blue looks much darker than orange at the same brightness. On a dark sidebar, mix
    /// dark colors with white until their relative luminance is high enough; on a light
    /// sidebar, mix light colors with black until it is low enough.
    static func legible(_ color: NSColor, onDark dark: Bool) -> NSColor {
        var c = color.usingColorSpace(.sRGB) ?? color
        for _ in 0..<12 {
            let l = luminance(c)
            if dark ? l >= 0.24 : l <= 0.28 { break }
            c = c.blended(withFraction: 0.12, of: dark ? .white : .black) ?? c
        }
        return c
    }

    static func luminance(_ c: NSColor) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }
}
