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
    /// Registration is slow (~0.5 s), so only the fonts of `family` are registered now, the
    /// others in the background. `completion` runs on the main thread when all are registered.
    static func registerBundledFonts(now family: String?, completion: @escaping () -> Void) {
        guard let root = fontsURL,
              let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        var now: [URL] = [], later: [URL] = []
        var names = Set<String>()
        for case let url as URL in e where ["ttf", "otf", "ttc"].contains(url.pathExtension.lowercased()) {
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
            let families = descriptors.compactMap {
                CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String
            }
            names.formUnion(families)
            if let family, families.contains(family) { now.append(url) } else { later.append(url) }
        }
        bundledFamilies = names.sorted()
            .map { FontFamily(name: $0, bundled: true, ligatures: ligatureFamilies.contains($0)) }
        if !now.isEmpty { CTFontManagerRegisterFontURLs(now as CFArray, .process, false, nil) }
        DispatchQueue.global(qos: .userInitiated).async {
            CTFontManagerRegisterFontURLs(later as CFArray, .process, false, nil)
            DispatchQueue.main.async(execute: completion)
        }
    }

    /// Installed fixed-pitch families that are not bundled.
    /// Uses CoreText, so it can run in the background.
    static func installedMonospaceFamilies() -> [FontFamily] {
        let bundled = Set(bundledFamilies.map(\.name))
        let collection = CTFontCollectionCreateFromAvailableFonts(nil)
        let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
        var families = Set<String>()
        for d in descriptors {
            guard let traits = CTFontDescriptorCopyAttribute(d, kCTFontTraitsAttribute) as? [CFString: Any],
                  let sym = traits[kCTFontSymbolicTrait] as? UInt32,
                  sym & CTFontSymbolicTraits.traitMonoSpace.rawValue != 0,
                  let fam = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String,
                  !fam.hasPrefix(".")
            else { continue }
            families.insert(fam)
        }
        return families.subtracting(bundled).sorted()
            .map { FontFamily(name: $0, bundled: false, ligatures: ligatureFamilies.contains($0)) }
    }

    /// A font for previews in the Settings window.
    static func previewFont(_ family: String, size: CGFloat) -> NSFont {
        let key = "\(family)|\(size)" as NSString
        if let f = previewCache.object(forKey: key) { return f }
        let d = NSFontDescriptor(fontAttributes: [.family: family])
        let f = NSFont(descriptor: d, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        previewCache.setObject(f, forKey: key)
        return f
    }
    private static let previewCache = NSCache<NSString, NSFont>()

    /// Installed families, loaded once in the background.
    static func loadInstalledMonospaceFamilies(_ completion: @escaping ([FontFamily]) -> Void) {
        if let cached = installedCache { return completion(cached) }
        DispatchQueue.global(qos: .userInitiated).async {
            let list = installedMonospaceFamilies()
            DispatchQueue.main.async {
                installedCache = list
                completion(list)
            }
        }
    }
    private static var installedCache: [FontFamily]?
}
