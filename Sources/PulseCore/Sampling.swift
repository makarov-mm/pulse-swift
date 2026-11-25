import Foundation

public struct Snapshot: Sendable {
    public let raw: RawSample
    public let hostCPU: Double?
    public let processes: [ProcessRow]
    public let interfaces: [InterfaceRow]
    /// Busy percentage of each logical core, 0 to 100.
    public let cores: [Double?]
    public let disks: [DiskRow]
    public let startsSegment: Bool
    /// Awake seconds covered since the previous usable sample.
    public let elapsed: TimeInterval?

    public init(current: RawSample, previous: RawSample?, interval: TimeInterval) {
        raw = current
        let prior = previous.flatMap { last -> RawSample? in
            let awake = current.uptime - last.uptime
            let wall = current.date.timeIntervalSince(last.date)
            let limit = max(4, interval * 3)
            guard awake > 0, awake <= limit, wall > 0, wall <= limit,
                  current.machTime > last.machTime else { return nil }
            return last
        }
        startsSegment = prior == nil
        elapsed = prior.map { current.uptime - $0.uptime }
        hostCPU = prior?.host.flatMap { old in current.host.flatMap { Self.busy(from: old, to: $0) } }
        if let old = prior?.cores, let now = current.cores, old.count == now.count {
            cores = zip(old, now).map { Self.busy(from: $0, to: $1) }
        } else {
            cores = (current.cores ?? []).map { _ in nil }
        }

        let totals = Dictionary((prior?.processes ?? []).compactMap { row in
            row.cpuTicks.map { (row.id, $0) }
        }, uniquingKeysWith: { _, newer in newer })
        processes = current.processes.map { reading in
            var percent: Double?
            if let prior, let old = totals[reading.id], let now = reading.cpuTicks, now >= old {
                // Both operands are Mach absolute ticks. One fully busy core is 100%.
                percent = 100 * Double(now - old) / Double(current.machTime - prior.machTime)
            }
            return ProcessRow(reading: reading, cpu: percent)
        }
        let counters = Dictionary((prior?.interfaces ?? []).map { ($0.id, $0) },
                                  uniquingKeysWith: { _, newer in newer })
        interfaces = (current.interfaces ?? []).map { reading in
            func rate(_ key: KeyPath<InterfaceReading, UInt64>) -> Double? {
                guard let prior, let old = counters[reading.id],
                      reading[keyPath: key] >= old[keyPath: key] else { return nil }
                return Double(reading[keyPath: key] - old[keyPath: key]) / (current.uptime - prior.uptime)
            }
            return InterfaceRow(reading: reading, receiveRate: rate(\.received), sendRate: rate(\.sent))
        }
        let devices = Dictionary((prior?.disks ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        disks = (current.disks ?? []).map { reading in
            func rate(_ key: KeyPath<DiskReading, UInt64?>) -> Double? {
                guard let prior, let old = devices[reading.id]?[keyPath: key],
                      let now = reading[keyPath: key], now >= old else { return nil }
                return Double(now - old) / (current.uptime - prior.uptime)
            }
            return DiskRow(reading: reading, readRate: rate(\.read), writeRate: rate(\.written))
        }
    }

    /// Busy share between two cumulative tick readings. Nil after a counter went backwards.
    static func busy(from a: HostTicks, to b: HostTicks) -> Double? {
        guard b.user >= a.user, b.system >= a.system, b.idle >= a.idle, b.nice >= a.nice else { return nil }
        let busy = Double(b.user - a.user) + Double(b.system - a.system) + Double(b.nice - a.nice)
        let total = busy + Double(b.idle - a.idle)
        return total > 0 ? 100 * busy / total : nil
    }
}

public enum ProcessSearch {
    public static func matches(_ row: ProcessRow, text: String) -> Bool {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return true }
        if query.lowercased().hasPrefix("pid:") {
            return Int32(query.dropFirst(4).trimmingCharacters(in: .whitespaces)) == row.pid
        }
        if let number = Int32(query) { return number == row.pid }
        return row.name.localizedCaseInsensitiveContains(query)
    }
}
