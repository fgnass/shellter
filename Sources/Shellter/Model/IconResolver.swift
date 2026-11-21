import AppKit

/// Finds icons for projects (files in the directory) and for local web servers (favicons).
final class IconResolver {
    static let shared = IconResolver()

    private let queue = DispatchQueue(label: "shellter.icons", qos: .utility)
    private var dirCache: [String: NSImage?] = [:]
    private var serverCache: [UInt16: (image: NSImage?, time: Date)] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 2
        c.timeoutIntervalForResource = 4
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    // MARK: Project root

    /// The Git root of `path`, or `path` itself.
    static func projectRoot(for path: String) -> String {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var url = URL(fileURLWithPath: path).standardizedFileURL
        while url.path != "/" && url.path != home {
            if fm.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
            url.deleteLastPathComponent()
        }
        return path
    }

    // MARK: Directory icons

    private static let candidates = [
        "favicon.svg", "favicon.png", "favicon.ico",
        "public/favicon.svg", "public/favicon.png", "public/favicon.ico", "public/apple-touch-icon.png",
        "static/favicon.svg", "static/favicon.png", "static/favicon.ico",
        "app/icon.svg", "app/icon.png", "app/favicon.ico", "app/apple-icon.png",
        "src/app/icon.svg", "src/app/icon.png", "src/app/favicon.ico",
        "src/favicon.svg", "src/favicon.ico", "web/favicon.png", "site/favicon.svg", "site/favicon.ico",
        "assets/icon.svg", "assets/icon.png", "assets/logo.svg", "assets/logo.png",
        "resources/icon.png", "build/icon.png", "build/icon.icns",
        "icon.svg", "icon.png", "icon.icns", "logo.svg", "logo.png",
        ".github/logo.svg", ".github/logo.png", "docs/logo.svg", "docs/logo.png",
    ]

    private static let skipDirs: Set<String> = [
        "node_modules", ".git", "dist", "build", "vendor", "Pods", "DerivedData", ".next",
        ".nuxt", ".svelte-kit", "target", ".venv", "venv", "__pycache__", "coverage", ".turbo",
    ]

    func directoryIcon(for root: String, completion: @escaping (NSImage?) -> Void) {
        queue.async {
            if let cached = self.dirCache[root] {
                DispatchQueue.main.async { completion(cached) }
                return
            }
            let image = Self.findDirectoryIcon(root)
            self.dirCache[root] = image
            DispatchQueue.main.async { completion(image) }
        }
    }

    func invalidateDirectoryIcon(_ root: String) {
        queue.async { self.dirCache[root] = nil }
    }

    private static func findDirectoryIcon(_ root: String) -> NSImage? {
        let base = URL(fileURLWithPath: root)
        let fm = FileManager.default
        for rel in candidates {
            let url = base.appendingPathComponent(rel)
            if fm.fileExists(atPath: url.path), let img = loadImage(url) { return img }
        }
        // Shallow search for favicons, app icons and Xcode asset catalogs.
        var best: (url: URL, score: Int)?
        var visited = 0
        func walk(_ dir: URL, depth: Int) {
            guard depth <= 4, visited < 4000,
                  let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { return }
            for item in items {
                visited += 1
                let name = item.lastPathComponent
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    if name.hasSuffix(".appiconset") {
                        if let png = largestPNG(in: item) { consider(png, score: 90) }
                        continue
                    }
                    if name.hasSuffix(".icon") {
                        consider(item, score: 92)   // Icon Composer document
                        continue
                    }
                    if !skipDirs.contains(name) && !name.hasSuffix(".app") { walk(item, depth: depth + 1) }
                    continue
                }
                let lower = name.lowercased()
                if lower.hasPrefix("favicon.") { consider(item, score: 100 - depth) }
                else if lower.hasPrefix("apple-touch-icon") && lower.hasSuffix(".png") { consider(item, score: 95 - depth) }
                else if lower.hasSuffix(".icns") { consider(item, score: 80 - depth) }
                else if lower == "icon.png" || lower == "icon.svg" || lower == "logo.svg" { consider(item, score: 70 - depth) }
            }
        }
        func consider(_ url: URL, score: Int) {
            if best == nil || score > best!.score { best = (url, score) }
        }
        walk(base, depth: 0)
        if let best, let img = loadImage(best.url) { return img }
        return nil
    }

    private static func largestPNG(in dir: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { $0.pathExtension.lowercased() == "png" }
            .max { a, b in
                let sa = (try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let sb = (try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return sa < sb
            }
    }

    private static func loadImage(_ url: URL) -> NSImage? {
        if url.pathExtension == "icon" { return IconComposerRenderer.render(url) }
        guard let img = NSImage(contentsOf: url), img.isValid, img.size.width > 0 else { return nil }
        return img
    }

    // MARK: Server favicons

    /// Tries the given ports in order and returns the first favicon found.
    func serverIcon(ports: [UInt16], completion: @escaping (NSImage?, UInt16?) -> Void) {
        queue.async {
            var pending = ports.filter { $0 >= 1024 }
            func next() {
                guard let port = pending.first else {
                    DispatchQueue.main.async { completion(nil, nil) }
                    return
                }
                pending.removeFirst()
                if let c = self.serverCache[port], Date().timeIntervalSince(c.time) < (c.image == nil ? 20 : 120) {
                    if let img = c.image { DispatchQueue.main.async { completion(img, port) } } else { next() }
                    return
                }
                self.fetchFavicon(port: port) { img in
                    self.queue.async {
                        self.serverCache[port] = (img, Date())
                        if let img { DispatchQueue.main.async { completion(img, port) } } else { next() }
                    }
                }
            }
            next()
        }
    }

    private func fetchFavicon(port: UInt16, completion: @escaping (NSImage?) -> Void) {
        let base = URL(string: "http://localhost:\(port)/")!
        session.dataTask(with: base) { data, response, _ in
            guard let http = response as? HTTPURLResponse else { return completion(nil) }
            var urls: [URL] = []
            if let data, let html = String(data: data.prefix(256_000), encoding: .utf8),
               (http.mimeType ?? "").contains("html") {
                urls = Self.iconLinks(in: html, base: http.url ?? base)
            }
            urls.append(base.appendingPathComponent("favicon.ico"))
            self.fetchFirstImage(urls, completion: completion)
        }.resume()
    }

    private func fetchFirstImage(_ urls: [URL], completion: @escaping (NSImage?) -> Void) {
        guard let url = urls.first else { return completion(nil) }
        session.dataTask(with: url) { data, response, _ in
            if let data, (response as? HTTPURLResponse)?.statusCode == 200,
               let img = NSImage(data: data), img.isValid, img.size.width > 0 {
                return completion(img)
            }
            self.fetchFirstImage(Array(urls.dropFirst()), completion: completion)
        }.resume()
    }

    /// Extracts `<link rel="...icon..." href="...">` URLs, best first.
    static func iconLinks(in html: String, base: URL) -> [URL] {
        guard let tagRe = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        var found: [(url: URL, score: Int)] = []
        for m in tagRe.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            guard let rel = attr("rel", in: tag)?.lowercased(), rel.contains("icon"),
                  !rel.contains("mask-icon"),
                  let href = attr("href", in: tag),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL else { continue }
            var score = 0
            let type = attr("type", in: tag)?.lowercased() ?? ""
            if type.contains("svg") || href.lowercased().hasSuffix(".svg") { score += 1000 }
            if rel.contains("apple-touch-icon") { score += 500 }
            if let sizes = attr("sizes", in: tag), let n = Int(sizes.split(separator: "x").first ?? "") { score += n }
            found.append((url, score))
        }
        return found.sorted { $0.score > $1.score }.map(\.url)
    }

    private static func attr(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length))
        else { return nil }
        for i in 1...3 where m.range(at: i).location != NSNotFound {
            return (tag as NSString).substring(with: m.range(at: i))
        }
        return nil
    }

    // MARK: Fallback

    static func color(for key: String) -> NSColor {
        var hash: UInt64 = 5381
        for b in key.utf8 { hash = (hash &* 33) &+ UInt64(b) }
        return NSColor(hue: CGFloat(hash % 360) / 360, saturation: 0.55, brightness: 0.75, alpha: 1)
    }
}

/// Draws an Icon Composer document (`.icon` folder): the fill from `icon.json`, then the
/// layer images of each group, bottom to top, in the rounded macOS icon shape. Glass
/// effects are left out; at sidebar size they do not show.
enum IconComposerRenderer {
    static func render(_ url: URL, size: CGFloat = 128) -> NSImage? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("icon.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let assets = url.appendingPathComponent("Assets")
        let groups = json["groups"] as? [[String: Any]] ?? []
        // In icon.json the first group and the first layer are on top.
        let layers: [NSImage] = groups.reversed().flatMap { group -> [NSImage] in
            let list = (group["layers"] as? [[String: Any]] ?? []).reversed()
            return list.compactMap { layer in
                if layer["hidden"] as? Bool == true { return nil }
                guard let name = layer["image-name"] as? String else { return nil }
                return NSImage(contentsOf: assets.appendingPathComponent(name))
            }
        }
        guard !layers.isEmpty else { return nil }

        let fill = json["fill"] as? [String: Any]
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: size * 0.225, yRadius: size * 0.225).addClip()
            if let stops = fill?["linear-gradient"] as? [String],
               let gradient = NSGradient(colors: stops.compactMap(color)) {
                gradient.draw(in: rect, angle: -90)
            } else if let solid = (fill?["solid"] as? String).flatMap(color) {
                solid.setFill()
                rect.fill()
            } else {
                NSColor.white.setFill()
                rect.fill()
            }
            for layer in layers { layer.draw(in: rect) }
            return true
        }
    }

    /// Parses "srgb:0.1,0.2,0.3,1.0" (also display-p3, extended-srgb, extended-gray).
    private static func color(_ s: String) -> NSColor? {
        let parts = s.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let v = parts[1].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        switch (parts[0], v.count) {
        case ("display-p3", 4): return NSColor(displayP3Red: v[0], green: v[1], blue: v[2], alpha: v[3])
        case (_, 4): return NSColor(srgbRed: v[0], green: v[1], blue: v[2], alpha: v[3])
        case (_, 2): return NSColor(white: v[0], alpha: v[1])
        default: return nil
        }
    }
}
