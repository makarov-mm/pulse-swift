import Darwin
import DarwinHeaders
import Foundation
import PulseCore

/// All OS reads run on this actor, away from the window's main actor.
public actor MacSampler {
    public init() {}

    public func sample() -> RawSample {
        let system = ProcessInfo.processInfo
        var result = RawSample(date: Date(), machTime: mach_absolute_time(),
                               uptime: system.systemUptime, totalRAM: system.physicalMemory)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        result.host = hostCPU(host)
        result.wiredBytes = wiredBytes(host)
        if let pids = processIDs() {
            result.listedProcesses = pids.count
            result.processes = pids.compactMap(readProcess)
        }
        result.cores = coreTicks(host)
        result.interfaces = networkCounters()
        result.disks = diskCounters()

        let data = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)
        if let values = try? data.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]) {
            result.volumeFreeBytes = values.volumeAvailableCapacity.flatMap { UInt64(exactly: $0) }
            result.volumeTotalBytes = values.volumeTotalCapacity.flatMap { UInt64(exactly: $0) }
        }
        return result
    }

    public func executable(for id: ProcessID) -> URL? {
        guard currentIdentity(id.pid) == id else { return nil }
        // proc_pidpath accepts a buffer up to four MAXPATHLENs.
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes {
            proc_pidpath(id.pid, $0.baseAddress, UInt32($0.count))
        }
        guard length > 0, currentIdentity(id.pid) == id else { return nil }
        let bytes = buffer.prefix { $0 != 0 }
        guard let path = String(bytes: bytes, encoding: .utf8), path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func hostCPU(_ host: host_t) -> HostTicks? {
        var counters = [Int32](repeating: 0, count: Int(CPU_STATE_MAX))
        var count = mach_msg_type_number_t(counters.count)
        let result = counters.withUnsafeMutableBufferPointer {
            host_statistics(host, HOST_CPU_LOAD_INFO, $0.baseAddress!, &count)
        }
        guard result == KERN_SUCCESS, Int(count) == counters.count else { return nil }
        func ticks(_ index: Int32) -> UInt32 { UInt32(bitPattern: counters[Int(index)]) }
        return HostTicks(user: ticks(Int32(CPU_STATE_USER)), system: ticks(Int32(CPU_STATE_SYSTEM)),
                         idle: ticks(Int32(CPU_STATE_IDLE)), nice: ticks(Int32(CPU_STATE_NICE)))
    }

    private func wiredBytes(_ host: host_t) -> UInt64? {
        var info = vm_statistics64_data_t()
        let words = MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.stride
        var count = mach_msg_type_number_t(words)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: words) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS, count > 0 else { return nil }
        return UInt64(info.wire_count) * UInt64(getpagesize())
    }

    private func processIDs() -> [Int32]? {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return nil }
        var capacity = Int(estimate) + 64
        for _ in 0..<4 {
            var buffer = [Int32](repeating: 0, count: capacity)
            let count = buffer.withUnsafeMutableBytes {
                proc_listallpids($0.baseAddress, Int32($0.count))
            }
            guard count > 0 else { return nil }
            if Int(count) < capacity {
                return Array(Set(buffer.prefix(Int(count))))
            }
            capacity *= 2
        }
        return nil
    }

    func identity(_ info: proc_bsdinfo) -> ProcessID {
        ProcessID(pid: Int32(bitPattern: info.pbi_pid), startSeconds: info.pbi_start_tvsec,
                  startMicroseconds: info.pbi_start_tvusec)
    }

    func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let bytes = Int32(MemoryLayout.size(ofValue: info))
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, bytes) == bytes,
              info.pbi_pid == UInt32(bitPattern: pid) else { return nil }
        return info
    }

    func name<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private func readProcess(_ pid: Int32) -> ProcessReading? {
        var all = proc_taskallinfo()
        let bytes = Int32(MemoryLayout.size(ofValue: all))
        let hasTask = proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &all, bytes) == bytes
        guard let bsd = hasTask ? all.pbsd : bsdInfo(pid),
              bsd.pbi_pid == UInt32(bitPattern: pid) else { return kernelReading(pid) }
        let longName = name(bsd.pbi_name)
        let shortName = name(bsd.pbi_comm)
        let display = longName.isEmpty ? shortName : longName
        let task = all.ptinfo
        return ProcessReading(id: identity(bsd), parent: Int32(bitPattern: bsd.pbi_ppid),
                              uid: bsd.pbi_uid, name: display.isEmpty ? "PID \(pid)" : display,
                              residentBytes: hasTask ? task.pti_resident_size : nil,
                              threads: hasTask ? Int(task.pti_threadnum) : nil,
                              cpuTicks: hasTask ? task.pti_total_user + task.pti_total_system : nil)
    }

    /// PID and start time of whatever process holds this PID now, from the richest readable source.
    func currentIdentity(_ pid: Int32) -> ProcessID? {
        bsdInfo(pid).map { identity($0) } ?? kernelReading(pid)?.id
    }

    /// Check ownership and identity from the same kernel record before sending Quit.
    func isCurrentUserAppProcess(_ id: ProcessID) -> Bool {
        if let info = bsdInfo(id.pid) {
            return identity(info) == id && info.pbi_uid == getuid()
        }
        guard let reading = kernelReading(id.pid) else { return false }
        return reading.id == id && reading.uid == getuid()
    }

    /// Identity of a process that libproc will not describe, typically one owned by another user.
    /// The kernel process table gives parent, owner, start time and a short name, and no counters.
    private func kernelReading(_ pid: Int32) -> ProcessReading? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0,
              info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        var label = name(info.kp_proc.p_comm)
        // The short name is cut at 16 bytes. The executable's file name is complete when it is readable.
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        if length > 0, let path = String(bytes: buffer.prefix { $0 != 0 }, encoding: .utf8),
           let file = path.split(separator: "/").last {
            label = String(file)
        }
        return ProcessReading(id: ProcessID(pid: pid, startSeconds: UInt64(max(0, start.tv_sec)),
                                            startMicroseconds: UInt64(max(0, start.tv_usec))),
                              parent: info.kp_eproc.e_ppid, uid: info.kp_eproc.e_ucred.cr_uid,
                              name: label.isEmpty ? "PID \(pid)" : label,
                              residentBytes: nil, threads: nil, cpuTicks: nil)
    }

    private func networkCounters() -> [InterfaceReading]? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(first) }
        var seen: Set<String> = []
        var rows: [InterfaceReading] = []
        var address: UnsafeMutablePointer<ifaddrs>? = first
        while let item = address {
            let entry = item.pointee
            address = entry.ifa_next
            let flags = Int32(bitPattern: entry.ifa_flags)
            guard (flags & Int32(IFF_UP)) != 0, (flags & Int32(IFF_LOOPBACK)) == 0,
                  let cName = entry.ifa_name else { continue }
            let name = String(cString: cName)
            guard seen.insert(name).inserted else { continue }
            let index = if_nametoindex(cName)
            guard index > 0 else { continue }
            var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, Int32(bitPattern: index), IFDATA_GENERAL]
            var info = ifmibdata()
            var length = MemoryLayout.size(ofValue: info)
            let status = mib.withUnsafeMutableBufferPointer {
                sysctl($0.baseAddress, u_int($0.count), &info, &length, nil, 0)
            }
            guard status == 0, length == MemoryLayout<ifmibdata>.size,
                  self.name(info.ifmd_name) == name else { continue }
            rows.append(InterfaceReading(id: InterfaceID(index: index, name: name),
                                         received: info.ifmd_data.ifi_ibytes, sent: info.ifmd_data.ifi_obytes))
        }
        if !seen.isEmpty && rows.isEmpty { return nil }
        return rows.sorted { $0.id.name < $1.id.name }
    }
}
