import Darwin
import Foundation

/// Reads process information via libproc. All functions are thread-safe.
enum ProcessInspector {
    struct Snapshot: Equatable {
        var pids: [pid_t] = []
        var names: [pid_t: String] = [:]
        var ports: [UInt16] = []          // TCP ports in LISTEN state, sorted
    }

    /// All processes whose controlling terminal is `tty` (e.g. "/dev/ttys003").
    static func snapshot(tty: String) -> Snapshot {
        let path = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        var st = stat()
        guard stat(path, &st) == 0 else { return Snapshot() }
        let dev = UInt32(bitPattern: st.st_rdev)

        var snap = Snapshot()
        var ports = Set<UInt16>()
        for pid in allPIDs() {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.e_tdev == dev else { continue }
            snap.pids.append(pid)
            snap.names[pid] = name(of: pid)
            ports.formUnion(listeningPorts(of: pid))
        }
        snap.ports = ports.sorted()
        return snap
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
