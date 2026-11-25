import Darwin
import DarwinHeaders
import Foundation
import PulseCore

public struct ThreadDetail: Identifiable, Sendable {
    public let id: UInt64
    public let name: String
    /// Recent CPU use of this thread as a percentage of one core.
    public let cpu: Double
    public let cpuSeconds: Double
    public let state: String
}

public struct SocketDetail: Identifiable, Sendable {
    /// File descriptor number inside the inspected process.
    public let id: Int32
    public let transport: String
    public let family: String
    public let local: String
    public let remote: String
    public let state: String
}

/// A best-effort snapshot of one process instance. Endpoints can appear or vanish between reads.
public struct ProcessDetails: Sendable {
    public let id: ProcessID
    /// Nil when the task could not be inspected.
    public let threads: [ThreadDetail]?
    /// Open descriptors by kind. Nil when the list could not be read.
    public let descriptors: [(kind: String, count: Int)]?
    public let sockets: [SocketDetail]
    /// True when some descriptors disappeared or refused inspection during the read.
    public let partial: Bool
}

extension MacSampler {
    /// Returns nil when the PID no longer belongs to the instance that was asked for.
    public func details(for id: ProcessID) -> ProcessDetails? {
        guard isCurrent(id) else { return nil }
        let threads = threadDetails(id.pid)
        var partial = false
        var sockets: [SocketDetail] = []
        var kinds: [(kind: String, count: Int)]?
        if let open = descriptorList(id.pid) {
            var counts: [UInt32: Int] = [:]
            for item in open {
                counts[item.proc_fdtype, default: 0] += 1
                guard item.proc_fdtype == 2 else { continue }  // PROX_FDTYPE_SOCKET
                switch socket(id.pid, item.proc_fd) {
                case .some(.some(let detail)): sockets.append(detail)
                case .some(.none): break
                case .none: partial = true
                }
            }
            var list: [(kind: String, count: Int)] = []
            for (type, count) in counts.sorted(by: { $0.key < $1.key }) {
                list.append((kind: Self.descriptorKind(type), count: count))
            }
            list.sort { (a: (kind: String, count: Int), b: (kind: String, count: Int)) -> Bool in a.count > b.count }
            kinds = list
        }
        guard isCurrent(id) else { return nil }
        return ProcessDetails(id: id, threads: threads, descriptors: kinds, sockets: sockets, partial: partial)
    }

    /// True while the PID still belongs to the same process instance.
    public func isCurrent(_ id: ProcessID) -> Bool {
        bsdInfo(id.pid).map { identity($0) == id } ?? false
    }

    private func threadDetails(_ pid: Int32) -> [ThreadDetail]? {
        var handles = [UInt64](repeating: 0, count: 4096)
        let bytes = handles.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0 else { return nil }
        let size = Int32(MemoryLayout<proc_threadinfo>.size)
        let states = [1: "Running", 2: "Stopped", 3: "Waiting", 4: "Uninterruptible", 5: "Halted"]
        return handles.prefix(Int(bytes) / MemoryLayout<UInt64>.stride).compactMap { handle in
            var info = proc_threadinfo()
            guard proc_pidinfo(pid, PROC_PIDTHREADINFO, handle, &info, size) == size else { return nil }
            return ThreadDetail(id: handle, name: name(info.pth_name),
                                cpu: Double(info.pth_cpu_usage) / 10,  // TH_USAGE_SCALE is 1000
                                cpuSeconds: Double(info.pth_user_time + info.pth_system_time) / 1_000_000_000,
                                state: states[Int(info.pth_run_state)] ?? "Unknown")
        }
    }

    private func descriptorList(_ pid: Int32) -> [proc_fdinfo]? {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 32)
        let bytes = buffer.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0 else { return nil }
        return Array(buffer.prefix(Int(bytes) / stride))
    }

    /// Outer nil: the descriptor could not be read. Inner nil: readable, but not an internet socket.
    private func socket(_ pid: Int32, _ descriptor: Int32) -> SocketDetail?? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, descriptor, PROC_PIDFDSOCKETINFO, &info, size) == size else { return nil }
        let base = info.psi
        guard base.soi_family == AF_INET || base.soi_family == AF_INET6 else { return .some(nil) }
        let endpoint: in_sockinfo
        var state = ""
        switch base.soi_kind {
        case 2:  // SOCKINFO_TCP
            endpoint = base.soi_proto.pri_tcp.tcpsi_ini
            state = Self.tcpState(base.soi_proto.pri_tcp.tcpsi_state)
        case 1:  // SOCKINFO_IN
            endpoint = base.soi_proto.pri_in
        default:
            return .some(nil)
        }
        let v4 = endpoint.insi_vflag & 0x1 != 0
        let transport: String
        switch base.soi_protocol {
        case IPPROTO_TCP: transport = "TCP"
        case IPPROTO_UDP: transport = "UDP"
        default: transport = "IP \(base.soi_protocol)"
        }
        return SocketDetail(
            id: descriptor, transport: transport, family: v4 ? "IPv4" : "IPv6",
            local: Self.endpoint(v4: endpoint.insi_laddr.ina_46.i46a_addr4, v6: endpoint.insi_laddr.ina_6,
                                 isV4: v4, port: endpoint.insi_lport),
            remote: Self.endpoint(v4: endpoint.insi_faddr.ina_46.i46a_addr4, v6: endpoint.insi_faddr.ina_6,
                                  isV4: v4, port: endpoint.insi_fport),
            state: state)
    }

    private static func endpoint(v4: in_addr, v6: in6_addr, isV4: Bool, port: Int32) -> String {
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN) + 1)
        var first = v4, second = v6
        let done = isV4 ? inet_ntop(AF_INET, &first, &text, socklen_t(text.count))
            : inet_ntop(AF_INET6, &second, &text, socklen_t(text.count))
        guard done != nil else { return "—" }
        let number = UInt16(bigEndian: UInt16(truncatingIfNeeded: port))
        let host = String(cString: text)
        if number == 0 { return host == "0.0.0.0" || host == "::" ? "*" : host }
        return isV4 ? "\(host):\(number)" : "[\(host)]:\(number)"
    }

    private static func tcpState(_ value: Int32) -> String {
        let names = ["Closed", "Listen", "SYN sent", "SYN received", "Established", "Close wait",
                     "FIN wait 1", "Closing", "Last ACK", "FIN wait 2", "Time wait"]
        return names.indices.contains(Int(value)) ? names[Int(value)] : "State \(value)"
    }

    private static func descriptorKind(_ type: UInt32) -> String {
        let names: [UInt32: String] = [0: "AppleTalk", 1: "Files", 2: "Sockets", 3: "Shared memory", 4: "Semaphores",
                                       5: "Kernel queues", 6: "Pipes", 7: "FS events", 9: "Network policy",
                                       10: "Channels", 11: "Nexus"]
        return names[type] ?? "Type \(type)"
    }
}

public struct LaunchItem: Identifiable, Sendable {
    public let id: String
    public let label: String
    /// Where launchd loads the job from, such as "User agent".
    public let domain: String
    public let program: String
    public let runAtLoad: Bool
    public let disabled: Bool
    public let file: URL
}

/// Reads launchd job definitions. It never loads, edits or removes a job.
public enum LaunchItems {
    public static func read() -> [LaunchItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sources = [(home + "/Library/LaunchAgents", "User agent"),
                       ("/Library/LaunchAgents", "Global agent"),
                       ("/Library/LaunchDaemons", "Global daemon"),
                       ("/System/Library/LaunchAgents", "System agent"),
                       ("/System/Library/LaunchDaemons", "System daemon")]
        var items: [LaunchItem] = []
        for (folder, domain) in sources {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for name in names.sorted() where name.hasSuffix(".plist") {
                let file = URL(fileURLWithPath: folder).appendingPathComponent(name)
                guard let data = try? Data(contentsOf: file),
                      let job = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
                else { continue }
                let arguments = job["ProgramArguments"] as? [String]
                items.append(LaunchItem(id: file.path,
                                        label: job["Label"] as? String ?? String(name.dropLast(6)),
                                        domain: domain,
                                        program: job["Program"] as? String ?? arguments?.first ?? "—",
                                        runAtLoad: job["RunAtLoad"] as? Bool ?? false,
                                        disabled: job["Disabled"] as? Bool ?? false,
                                        file: file))
            }
        }
        return items
    }
}
