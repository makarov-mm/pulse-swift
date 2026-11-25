import Foundation

/// A process that was among the busiest at one sample.
public struct Leader: Hashable, Sendable, Codable {
    public let id: ProcessID
    public let name: String
    public let cpu: Double

    public init(id: ProcessID, name: String, cpu: Double) {
        self.id = id
        self.name = name
        self.cpu = cpu
    }
}

public struct HistoryPoint: Sendable {
    public let time: Date
    public let elapsed: TimeInterval?
    public let cpu, wired, volumeFree, network: Double?
    public let networkID: InterfaceID?
    public let startsSegment: Bool
    public let leaders: [Leader]
    public let cores: [Double?]
    public let interfaces: [Flow<InterfaceID>]
    public let disks: [Flow<DiskID>]
}

/// CPU attributed to one process instance inside a selected interval.
public struct Contribution: Identifiable, Sendable {
    public let id: ProcessID
    public let name: String
    public let cpuSeconds: Double
    /// Percent of one logical core, averaged over the measured part of the interval.
    public let averageCPU: Double
    public let peakCPU: Double
    public let firstSeen, lastSeen: Date
}

public struct IntervalSummary: Sendable {
    public let start, end: Date
    /// Seconds inside the interval that are backed by rate samples. Gaps are excluded.
    public let measuredSeconds: TimeInterval
    public let hostCPU: Double?
    public let leaders: [Contribution]
}

/// CPU timeline of one pinned process instance. It outlives the process.
public struct PinnedSeries: Identifiable, Sendable {
    public struct Sample: Sendable {
        public let time: Date
        public let cpu: Double?
        public let startsSegment: Bool
    }

    public let id: ProcessID
    public let name: String
    public fileprivate(set) var samples: [Sample] = []
    public fileprivate(set) var exited: Date?

    fileprivate init(id: ProcessID, name: String) {
        self.id = id
        self.name = name
    }
}

public struct History: Sendable {
    public static let retention: TimeInterval = 900
    public static let leaderCount = 8
    private static let capacity = 1024

    public private(set) var points: [HistoryPoint] = []
    public private(set) var pinned: [PinnedSeries] = []
    public init() {}

    public mutating func add(_ sample: Snapshot, interface: InterfaceRow?) {
        let time = sample.raw.date
        if let last = points.last, last.time >= time {
            points.removeAll()
            for index in pinned.indices { pinned[index].samples.removeAll() }
        }
        let cutoff = time.addingTimeInterval(-Self.retention)
        points.removeFirst(points.firstIndex { $0.time >= cutoff } ?? points.count)

        let leaders = sample.processes
            .compactMap { row -> Leader? in
                guard let cpu = row.cpu, cpu > 0 else { return nil }
                return Leader(id: row.id, name: row.name, cpu: cpu)
            }
            .sorted { $0.cpu == $1.cpu ? $0.id.pid < $1.id.pid : $0.cpu > $1.cpu }
            .prefix(Self.leaderCount)
        points.append(HistoryPoint(time: time, elapsed: sample.elapsed, cpu: sample.hostCPU,
                                   wired: sample.raw.wiredBytes.map { Double($0) },
                                   volumeFree: sample.raw.volumeFreeBytes.map { Double($0) },
                                   network: interface?.combinedRate, networkID: interface?.id,
                                   startsSegment: sample.startsSegment, leaders: Array(leaders),
                                   cores: sample.cores,
                                   interfaces: sample.interfaces.map {
                                       Flow(id: $0.id, incoming: $0.receiveRate, outgoing: $0.sendRate)
                                   },
                                   disks: sample.disks.map {
                                       Flow(id: $0.id, incoming: $0.readRate, outgoing: $0.writeRate)
                                   }))
        if points.count > Self.capacity { points.removeFirst(points.count - Self.capacity) }

        guard !pinned.isEmpty else { return }
        let rows = Dictionary(sample.processes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in pinned.indices {
            let stale = pinned[index].samples.firstIndex { $0.time >= cutoff } ?? pinned[index].samples.count
            pinned[index].samples.removeFirst(stale)
            if let row = rows[pinned[index].id] {
                pinned[index].samples.append(.init(time: time, cpu: row.cpu, startsSegment: sample.startsSegment))
            } else if pinned[index].exited == nil, sample.raw.listedProcesses != nil {
                pinned[index].exited = time
            }
        }
    }

    /// Pins by PID and start time, so a reused PID never continues this series.
    public mutating func pin(_ row: ProcessRow) {
        guard !isPinned(row.id) else { return }
        pinned.append(PinnedSeries(id: row.id, name: row.name))
    }

    public mutating func unpin(_ id: ProcessID) {
        pinned.removeAll { $0.id == id }
    }

    public func isPinned(_ id: ProcessID) -> Bool {
        pinned.contains { $0.id == id }
    }

    /// Ranks the recorded leaders between two wall-clock times.
    /// Only the busiest processes of each sample are retained, so small contributors can be missing.
    public func summary(from start: Date, to end: Date) -> IntervalSummary {
        struct Total {
            var name: String
            var seconds = 0.0, peak = 0.0
            var first, last: Date
        }
        var measured = 0.0, hostBusy = 0.0, hostSeconds = 0.0
        var totals: [ProcessID: Total] = [:]
        for point in points where point.time >= start && point.time <= end {
            guard let span = point.elapsed, span > 0 else { continue }
            measured += span
            if let cpu = point.cpu {
                hostBusy += cpu * span
                hostSeconds += span
            }
            for leader in point.leaders {
                var total = totals[leader.id] ?? Total(name: leader.name, first: point.time, last: point.time)
                total.seconds += leader.cpu / 100 * span
                total.peak = max(total.peak, leader.cpu)
                total.last = point.time
                totals[leader.id] = total
            }
        }
        let leaders = totals.map { id, total in
            Contribution(id: id, name: total.name, cpuSeconds: total.seconds,
                         averageCPU: measured > 0 ? 100 * total.seconds / measured : 0,
                         peakCPU: total.peak, firstSeen: total.first, lastSeen: total.last)
        }
        .sorted { $0.cpuSeconds == $1.cpuSeconds ? $0.id.pid < $1.id.pid : $0.cpuSeconds > $1.cpuSeconds }
        return IntervalSummary(start: start, end: end, measuredSeconds: measured,
                               hostCPU: hostSeconds > 0 ? hostBusy / hostSeconds : nil, leaders: leaders)
    }
}
