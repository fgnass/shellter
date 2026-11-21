import AppKit
import CoreText

struct FontFamily: Identifiable, Hashable {
    var id: String { name }
    let name: String          // CoreText family name, as used by `font-family`
    let bundled: Bool
    let ligatures: Bool       // known to have programming ligatures

    /// A friendlier name for the list.
    var displayName: String {
        switch name {
        case "SourceCodeVF": return "Source Code Pro"
        case "CommitMono": return "Commit Mono"
        default:
            return name.hasPrefix("Monaspace ") && name.hasSuffix(" Var") ? String(name.dropLast(4)) : name
        }
    }
}

/// Bundled fonts (registered for this process only) and installed monospaced fonts.
enum FontLibrary {
    /// Ghostty's embedded default (also bundled, so previews can use it).
    static let defaultFamily = "JetBrains Mono"

    private static let ligatureFamilies: Set<String> = [
        "JetBrains Mono", "Fira Code", "Cascadia Code", "Iosevka", "Maple Mono", "Victor Mono",
        "Monaspace Argon Var", "Monaspace Krypton Var", "Monaspace Neon Var", "Monaspace Radon Var",
        "Monaspace Xenon Var", "Geist Mono", "Commit Mono", "CommitMono",
    ]

    private static var fontsURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true)
    }

    private(set) static var bundledFamilies: [FontFamily] = []

    /// Registers all fonts in Resources/Fonts for this process. Nothing is installed system-wide.
    static func registerBundledFonts() {
        guard let root = fontsURL,
              let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        var urls: [URL] = []
        var names = Set<String>()
        for case let url as URL in e where ["ttf", "otf", "ttc"].contains(url.pathExtension.lowercased()) {
            urls.append(url)
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
            for d in descriptors {
                if let fam = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String {
                    names.insert(fam)
                }
            }
        }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, false, nil)
        bundledFamilies = names.sorted()
            .map { FontFamily(name: $0, bundled: true, ligatures: ligatureFamilies.contains($0)) }
    }

    /// Installed fixed-pitch families that are not bundled.
    static func installedMonospaceFamilies() -> [FontFamily] {
        let bundled = Set(bundledFamilies.map(\.name))
        let fm = NSFontManager.shared
        let mono = fm.availableFontNames(with: .fixedPitchFontMask) ?? []
        var families = Set<String>()
        for name in mono {
            if let f = NSFont(name: name, size: 12), let fam = f.familyName, !fam.hasPrefix(".") {
                families.insert(fam)
            }
        }
        return families.subtracting(bundled).sorted()
            .map { FontFamily(name: $0, bundled: false, ligatures: ligatureFamilies.contains($0)) }
    }

    /// A font for previews in the Settings window.
    static func previewFont(_ family: String, size: CGFloat) -> NSFont {
        let d = NSFontDescriptor(fontAttributes: [.family: family])
        return NSFont(descriptor: d, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
