import AppKit
import OSLog
import UniformTypeIdentifiers

private let log = Logger(subsystem: "com.fgnass.shellter", category: "drop")

/// File promises are written on this queue, not on the main queue (as Apple recommends).
private let promiseQueue: OperationQueue = {
    let q = OperationQueue()
    q.qualityOfService = .userInitiated
    return q
}()

/// The URL of a promised file that the source already knows (e.g. the screenshot thumbnail).
private let promisedFileURL = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url")

/// Drag and drop into the terminal, like Terminal.app: files insert their escaped paths.
/// Also handles what Terminal.app does not: images without a file (e.g. from a browser)
/// and file promises (Photos, Mail) are saved to a folder first, then inserted as a path.
/// Coding agents read images from such paths. Text inserts as a paste.
extension TerminalView {
    static let dropTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .URL, promisedFileURL, .init("NSFilenamesPboardType"),
         .png, .tiff, .init("public.jpeg"), .init("public.heic"), .string] + NSFilePromiseReceiver.readableDraggedTypes.map { .init($0) }

    func registerForDrops() {
        registerForDraggedTypes(Self.dropTypes)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        log.notice("drop, types: \((pb.types ?? []).map(\.rawValue), privacy: .public)")

        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            insertPaths(urls)
            return true
        }

        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !promises.isEmpty, let dir = Self.dropFolder() {
            // The source may also name the file it writes; use it if it already exists.
            if let s = pb.string(forType: promisedFileURL), let url = URL(string: s),
               FileManager.default.fileExists(atPath: url.path) {
                insertPaths([url])
                return true
            }
            var urls: [URL] = []
            let group = DispatchGroup()
            for promise in promises {
                let count = max(promise.fileNames.count, 1)
                for _ in 0..<count { group.enter() }
                promise.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: promiseQueue) { url, error in
                    if let error {
                        log.error("file promise failed: \(error.localizedDescription, privacy: .public)")
                    } else {
                        DispatchQueue.main.async { urls.append(url) }
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) { [weak self] in
                log.notice("received \(urls.count) promised files")
                self?.insertPaths(urls)
            }
            return true
        }

        if let s = pb.string(forType: promisedFileURL), let url = URL(string: s) {
            insertPaths([url])
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
        let paths = urls.map { Self.keep($0).path }
        log.notice("insert paths: \(paths, privacy: .public)")
        pasteText(paths.map(Shell.escape).joined(separator: " ") + " ")
        window?.makeFirstResponder(self)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Files in a temporary folder (e.g. the screenshot thumbnail stages its image in
    /// TemporaryItems and removes it soon after the drop) are copied to the drop folder,
    /// so the inserted path still works when a program reads it later.
    private static func keep(_ url: URL) -> URL {
        let path = url.path
        guard path.contains("/TemporaryItems/") || path.contains("/NSIRD_"),
              let dir = dropFolder() else { return url }
        var target = dir.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) {
            let stamp = Int(Date().timeIntervalSince1970)
            target = dir.appendingPathComponent("\(stamp)-\(url.lastPathComponent)")
        }
        do {
            try FileManager.default.copyItem(at: url, to: target)
            return target
        } catch {
            log.error("copy of \(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return url
        }
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
