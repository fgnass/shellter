import AppKit
import UniformTypeIdentifiers

/// Drag and drop into the terminal, like Terminal.app: files insert their escaped paths.
/// Also handles what Terminal.app does not: images without a file (e.g. from a browser)
/// and file promises (Photos, Mail) are saved to a folder first, then inserted as a path.
/// Coding agents read images from such paths. Text inserts as a paste.
extension TerminalView {
    static let dropTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .png, .tiff, .string] + NSFilePromiseReceiver.readableDraggedTypes.map { .init($0) }

    func registerForDrops() {
        registerForDraggedTypes(Self.dropTypes)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard

        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            insertPaths(urls)
            return true
        }

        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !promises.isEmpty, let dir = Self.dropFolder() {
            var urls: [URL] = []
            let group = DispatchGroup()
            for promise in promises {
                group.enter()
                promise.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: .main) { url, error in
                    if error == nil { urls.append(url) }
                    group.leave()
                }
            }
            group.notify(queue: .main) { [weak self] in self?.insertPaths(urls) }
            return true
        }

        if let image = NSImage(pasteboard: pb), pb.string(forType: .string) == nil,
           let url = Self.save(image) {
            insertPaths([url])
            return true
        }

        if let text = pb.string(forType: .string), !text.isEmpty {
            pasteText(text)
            return true
        }
        return false
    }

    private func insertPaths(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pasteText(urls.map { Self.shellEscape($0.path) }.joined(separator: " ") + " ")
        window?.makeFirstResponder(self)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Characters that the shell would interpret, escaped with a backslash (as Terminal.app does).
    static func shellEscape(_ s: String) -> String {
        var out = ""
        for c in s {
            if "\\ ()[]{}<>\"'`!#$&;|*?\t~".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// Dropped images and promised files land here. macOS cleans the caches folder when space is low.
    private static func dropFolder() -> URL? {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shellter/Drops", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    private static func save(_ image: NSImage) -> URL? {
        guard let dir = dropFolder(), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("image-\(stamp).png")
        do {
            try png.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
