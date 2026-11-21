import Darwin
import Foundation

/// Reads process information via libproc. All functions are thread-safe.
enum ProcessInspector {
    struct Snapshot: Equatable {
        var pids: [pid_t] = []
        var names: [pid_t: String] = [:]
        var ports: [UInt16] = []          // TCP ports in LISTEN state, sorted
        var portOwners: [UInt16: pid_t] = [:]
        var agent: Agent?
        /// All processes of the agent (e.g. a node wrapper and its native child).
        var agentPIDs: [pid_t] = []
        /// The agent's session (ID or file), see AgentSession. Filled by the caller.
        var agentSession: String?
        /// App bundles that run below the terminal's processes but left the terminal
        /// (e.g. a browser that an MCP server started).
        var apps: [AppProcess] = []
    }

    struct AppProcess: Equatable {
        let pid: pid_t
        /// The parent process (the process that started the app).
        let parent: pid_t
        /// Path of the outermost .app bundle.
        let bundle: String
    }

    /// All processes whose controlling terminal is `tty` (e.g. "/dev/ttys003").
    static func snapshot(tty: String) -> Snapshot {
        let path = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        var st = stat()
        guard stat(path, &st) == 0 else { return Snapshot() }
        return snapshot(dev: UInt32(bitPattern: st.st_rdev))
    }

    /// The controlling terminal of a process and its foreground process group.
    static func terminal(of pid: pid_t) -> (dev: UInt32, foreground: pid_t)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.e_tdev != UInt32.max, info.e_tdev != 0 else { return nil }
        return (info.e_tdev, pid_t(info.e_tpgid))
    }

    /// All processes whose controlling terminal is the device `dev`.
    static func snapshot(dev: UInt32) -> Snapshot {
        var snap = Snapshot()
        var ports = Set<UInt16>()
        var children: [pid_t: [pid_t]] = [:]   // of the processes outside the terminal
        for pid in allPIDs() {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            guard info.e_tdev == dev else {
                children[pid_t(info.pbi_ppid), default: []].append(pid)
                continue
            }
            snap.pids.append(pid)
            snap.names[pid] = name(of: pid)
            if let agent = Agent.detect(path: Self.path(of: pid), args: arguments(of: pid)),
               snap.agent == nil || snap.agent == agent {
                snap.agent = agent
                snap.agentPIDs.append(pid)
            }
            for port in listeningPorts(of: pid) {
                ports.insert(port)
                snap.portOwners[port] = pid
            }
        }
        snap.ports = ports.sorted()
        snap.apps = apps(below: snap.pids, children: children)
        return snap
    }

    /// The processes below `roots` (outside the terminal) whose executable is in an app bundle.
    private static func apps(below roots: [pid_t], children: [pid_t: [pid_t]]) -> [AppProcess] {
        var result: [AppProcess] = []
        var queue = roots.flatMap { root in (children[root] ?? []).map { ($0, root) } }
        var seen = Set(roots)
        while !queue.isEmpty {
            let (pid, parent) = queue.removeFirst()
            guard seen.insert(pid).inserted else { continue }
            if let bundle = appBundle(of: path(of: pid)) {
                // Helpers of the app run below it; the app itself is enough.
                result.append(AppProcess(pid: pid, parent: parent, bundle: bundle))
                continue
            }
            queue += (children[pid] ?? []).map { ($0, pid) }
        }
        return result
    }

    /// "/Applications/X.app/Contents/MacOS/X" → "/Applications/X.app".
    static func appBundle(of path: String) -> String? {
        guard let r = path.range(of: ".app/Contents/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [] }
        return Array(pids.prefix(Int(n))).filter { $0 > 0 }
    }

    static func name(of pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : ""
    }

    /// Paths of the files a process has open.
    static func openFiles(of pid: pid_t) -> [String] {
        let bufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufSize > 0 else { return [] }
        let fdSize = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bufSize) / fdSize + 8)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * fdSize))
        guard used > 0 else { return [] }
        var paths: [String] = []
        for fd in fds.prefix(Int(used) / fdSize) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafePointer(to: &info.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }

    /// The path of the executable.
    static func path(of pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : ""
    }

    static func cwd(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    static func listeningPorts(of pid: pid_t) -> [UInt16] {
        let bufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufSize > 0 else { return [] }
        let fdSize = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bufSize) / fdSize + 8)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * fdSize))
        guard used > 0 else { return [] }

        var ports: [UInt16] = []
        for fd in fds.prefix(Int(used) / fdSize) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var si = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, size) == size,
                  si.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = si.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
            if port > 0 { ports.append(port) }
        }
        return ports
    }

    /// The full argument vector of a process (KERN_PROCARGS2).
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }   // exec path
        while i < size && buf[i] == 0 { i += 1 }   // padding
        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}
