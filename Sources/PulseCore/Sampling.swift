import Foundation

public struct Snapshot: Sendable {
    public let raw: RawSample
    public let hostCPU: Double?
    public let processes: [ProcessRow]
    public let interfaces: [InterfaceRow]
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
        if let a = prior?.host, let b = current.host,
           b.user >= a.user, b.system >= a.system, b.idle >= a.idle, b.nice >= a.nice {
            let busy = Double(b.user - a.user) + Double(b.system - a.system) + Double(b.nice - a.nice)
            let total = busy + Double(b.idle - a.idle)
            hostCPU = total > 0 ? 100 * busy / total : nil
        } else {
            hostCPU = nil
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
