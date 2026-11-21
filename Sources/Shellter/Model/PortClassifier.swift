import Foundation

/// Decides which listening ports the sidebar shows. Many tools open ports for internal
/// use (IDE bridges, debuggers, databases). Shellter shows a port only when the user
/// asked for it on the command line, or when it serves something a browser can open.
final class PortClassifier {
    static let shared = PortClassifier()

    private let queue = DispatchQueue(label: "shellter.ports", qos: .utility)
    private var cache: [String: (relevant: Bool, time: Date)] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 1.5
        c.timeoutIntervalForResource = 3
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    /// Returns the relevant ports of `owners` (port → listening pid), sorted.
    func relevantPorts(_ owners: [UInt16: pid_t], completion: @escaping ([UInt16]) -> Void) {
        queue.async {
            let group = DispatchGroup()
            var result: [UInt16] = []
            let lock = NSLock()
            for (port, pid) in owners {
                group.enter()
                self.classify(port: port, pid: pid) { relevant in
                    if relevant { lock.lock(); result.append(port); lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue: .main) { completion(result.sorted()) }
        }
    }

    /// Runs on `queue`.
    private func classify(port: UInt16, pid: pid_t, completion: @escaping (Bool) -> Void) {
        let key = "\(pid):\(port)"
        // A positive result holds as long as the process lives. Check a negative
        // result again later: the server may have been busy or still starting.
        if let c = cache[key], c.relevant || Date().timeIntervalSince(c.time) < 20 {
            return completion(c.relevant)
        }
        let done = { (relevant: Bool) in
            self.queue.async { self.cache[key] = (relevant, Date()) }
            completion(relevant)
        }
        if Self.argumentsMention(port, ProcessInspector.arguments(of: pid)) { return done(true) }
        probeHTTP(port: port, completion: done)
    }

    /// True if the command line names the port, e.g. `--port 3000`, `-p3000`, `:3000`.
    static func argumentsMention(_ port: UInt16, _ args: [String]) -> Bool {
        let p = String(port)
        for arg in args.dropFirst() {
            if arg == p { return true }
            for sep in ["=", ":", "-p"] where arg.hasSuffix(sep + p) { return true }
        }
        return false
    }

    /// True if `GET /` returns an HTML page or a success or redirect status.
    private func probeHTTP(port: UInt16, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "http://localhost:\(port)/") else { return completion(false) }
        session.dataTask(with: url) { _, response, _ in
            guard let http = response as? HTTPURLResponse else { return completion(false) }
            let html = (http.mimeType ?? "").contains("html")
            completion(html || (200..<400).contains(http.statusCode))
        }.resume()
    }
}
