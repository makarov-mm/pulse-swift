import Foundation

public struct ProcessID: Hashable, Sendable {
    public let pid: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64

    public init(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }
}

public struct ProcessReading: Identifiable, Sendable {
    public let id: ProcessID
    public let parent: Int32
    public let uid: UInt32
    public let name: String
    public let residentBytes: UInt64?
    public let threads: Int?
    public let cpuTicks: UInt64?

    public init(id: ProcessID, parent: Int32, uid: UInt32, name: String,
                residentBytes: UInt64?, threads: Int?, cpuTicks: UInt64?) {
        self.id = id
        self.parent = parent
        self.uid = uid
        self.name = name
        self.residentBytes = residentBytes
        self.threads = threads
        self.cpuTicks = cpuTicks
    }
}

public struct ProcessRow: Identifiable, Sendable {
    public let reading: ProcessReading
    public let cpu: Double?
    public var id: ProcessID { reading.id }
    public var pid: Int32 { id.pid }
    public var name: String { reading.name }
    public var parent: Int32 { reading.parent }
    public var uid: UInt32 { reading.uid }
    public var cpuSort: Double { cpu ?? -1 }
    public var memorySort: Int64 { reading.residentBytes.map { Int64(clamping: $0) } ?? -1 }
    public var threadSort: Int { reading.threads ?? -1 }
}

public struct InterfaceID: Hashable, Sendable {
    public let index: UInt32
    public let name: String
    public init(index: UInt32, name: String) {
        self.index = index
        self.name = name
    }
}

public struct InterfaceReading: Identifiable, Sendable {
    public let id: InterfaceID
    public let received: UInt64
    public let sent: UInt64
    public init(id: InterfaceID, received: UInt64, sent: UInt64) {
        self.id = id
        self.received = received
        self.sent = sent
    }
}

public struct InterfaceRow: Identifiable, Sendable {
    public let reading: InterfaceReading
    public let receiveRate: Double?
    public let sendRate: Double?
    public var id: InterfaceID { reading.id }
    public var name: String { id.name }
    public var receiveSort: Double { receiveRate ?? -1 }
    public var sendSort: Double { sendRate ?? -1 }
    public var received: UInt64 { reading.received }
    public var sent: UInt64 { reading.sent }
    public var combinedRate: Double? {
        guard let receiveRate, let sendRate else { return nil }
        return receiveRate + sendRate
    }
}

public struct HostTicks: Sendable {
    public let user, system, idle, nice: UInt32
    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

public struct RawSample: Sendable {
    public var date: Date
    public var machTime: UInt64
    public var uptime: TimeInterval
    public var host: HostTicks?
    public var wiredBytes: UInt64?
    public var totalRAM: UInt64
    public var volumeFreeBytes: UInt64?
    public var volumeTotalBytes: UInt64?
    public var listedProcesses: Int?
    public var processes: [ProcessReading]
    public var interfaces: [InterfaceReading]?

    public init(date: Date, machTime: UInt64, uptime: TimeInterval, totalRAM: UInt64) {
        self.date = date
        self.machTime = machTime
        self.uptime = uptime
        self.totalRAM = totalRAM
        self.processes = []
    }
}
