import Foundation

public enum CaptureError: Error, Equatable {
    /// The file is truncated, damaged, or not a Pulse capture.
    case unreadable
    case unsupportedSchema(Int)
}

/// A saved investigation: host samples with the busiest processes of each, plus what is needed to read them later.
public struct Capture: Codable, Sendable {
    public static let currentSchema = 1

    public struct Machine: Codable, Sendable, Equatable {
        public var osVersion: String
        public var architecture: String
        public var model: String?
        public var logicalCores: Int
        public var memoryBytes: UInt64

        public init(osVersion: String, architecture: String, model: String?, logicalCores: Int, memoryBytes: UInt64) {
            self.osVersion = osVersion
            self.architecture = architecture
            self.model = model
            self.logicalCores = logicalCores
            self.memoryBytes = memoryBytes
        }
    }

    public struct Coverage: Codable, Sendable {
        /// Processes whose counters were readable in the last sample, of those the system listed.
        public var readableProcesses: Int?
        public var listedProcesses: Int?
        /// Only this many of the busiest processes are kept per sample.
        public var leadersPerSample: Int

        public init(readableProcesses: Int?, listedProcesses: Int?, leadersPerSample: Int) {
            self.readableProcesses = readableProcesses
            self.listedProcesses = listedProcesses
            self.leadersPerSample = leadersPerSample
        }
    }

    public struct Executable: Codable, Sendable {
        public var process: ProcessID
        public var path: String
        public init(process: ProcessID, path: String) {
            self.process = process
            self.path = path
        }
    }

    public struct Sample: Codable, Sendable {
        /// Awake seconds since the first sample, from the monotonic clock.
        public var offset: TimeInterval
        public var wallClock: Date
        /// True when no rate could be formed against the previous sample: first sample, sleep, clock change.
        public var gap: Bool
        public var elapsed: TimeInterval?
        public var hostCPU: Double?
        public var wiredBytes: Double?
        public var networkBytesPerSecond: Double?
        public var leaders: [Leader]
    }

    public var schema: Int
    public var app: String
    public var exported: Date
    public var intervalSeconds: Double
    public var units: [String: String]
    public var machine: Machine
    public var coverage: Coverage
    /// Present only when the user chose to include executable paths.
    public var executables: [Executable]?
    public var samples: [Sample]

    public init(history: History, intervalSeconds: Double, machine: Machine, coverage: Coverage,
                executables: [Executable]?, app: String, exported: Date = Date()) {
        schema = Self.currentSchema
        self.app = app
        self.exported = exported
        self.intervalSeconds = intervalSeconds
        self.machine = machine
        self.coverage = coverage
        self.executables = executables
        units = ["offset": "seconds awake since the first sample",
                 "elapsed": "seconds awake since the previous sample",
                 "hostCPU": "percent of all logical cores, 0 to 100",
                 "leaders.cpu": "percent of one logical core",
                 "wiredBytes": "bytes",
                 "networkBytesPerSecond": "bytes per second on the busiest interface, receive plus send"]
        let start = history.points.first?.uptime ?? 0
        samples = history.points.map {
            Sample(offset: $0.uptime - start, wallClock: $0.time, gap: $0.startsSegment, elapsed: $0.elapsed,
                   hostCPU: $0.cpu, wiredBytes: $0.wired, networkBytesPerSecond: $0.network, leaders: $0.leaders)
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.formatter().string(from: date))
        }
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Capture {
        struct Header: Decodable { let schema: Int }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = formatter().date(from: text) else { throw CaptureError.unreadable }
            return date
        }
        guard let header = try? decoder.decode(Header.self, from: data) else { throw CaptureError.unreadable }
        guard header.schema == currentSchema else { throw CaptureError.unsupportedSchema(header.schema) }
        guard let capture = try? decoder.decode(Capture.self, from: data) else { throw CaptureError.unreadable }
        return capture
    }

    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    /// Seconds backed by rate samples. Gaps are excluded.
    public var measuredSeconds: TimeInterval {
        var total: TimeInterval = 0
        for sample in samples where !sample.gap { total += sample.elapsed ?? 0 }
        return total
    }

    /// CPU seconds per process name. Names are used because PIDs differ between runs and machines.
    public func cpuSecondsByName() -> [String: Double] {
        var totals: [String: Double] = [:]
        for sample in samples where !sample.gap {
            guard let span = sample.elapsed, span > 0 else { continue }
            for leader in sample.leaders { totals[leader.name, default: 0] += leader.cpu / 100 * span }
        }
        return totals
    }
}

public struct ComparisonRow: Identifiable, Sendable {
    public let name: String
    /// Average percent of one logical core over each run's measured time. Nil when the name never led.
    public let first, second: Double?
    public var id: String { name }
    public var firstSort: Double { first ?? -1 }
    public var secondSort: Double { second ?? -1 }
    public var changeSort: Double { (second ?? 0) - (first ?? 0) }
}

public enum CaptureComparison {
    public static func rows(_ a: Capture, _ b: Capture) -> [ComparisonRow] {
        let first = a.cpuSecondsByName(), second = b.cpuSecondsByName()
        let spanA = a.measuredSeconds, spanB = b.measuredSeconds
        func share(_ seconds: Double?, _ span: Double) -> Double? {
            guard let seconds, span > 0 else { return nil }
            return 100 * seconds / span
        }
        var rows: [ComparisonRow] = []
        for name in Set(first.keys).union(second.keys) {
            rows.append(ComparisonRow(name: name, first: share(first[name], spanA),
                                      second: share(second[name], spanB)))
        }
        rows.sort { (a: ComparisonRow, b: ComparisonRow) -> Bool in
            let lhs: Double = max(a.firstSort, a.secondSort), rhs: Double = max(b.firstSort, b.secondSort)
            if lhs == rhs { return a.name < b.name }
            return lhs > rhs
        }
        return rows
    }

    /// Differences that change how the two runs can be read side by side.
    public static func notes(_ a: Capture, _ b: Capture) -> [String] {
        var notes: [String] = []
        if a.machine.logicalCores != b.machine.logicalCores {
            notes.append("Core counts differ (\(a.machine.logicalCores) and \(b.machine.logicalCores)). Host CPU is a share of all cores, so equal host percentages mean different amounts of work. Process CPU is per logical core.")
        }
        if a.machine.architecture != b.machine.architecture {
            notes.append("Architectures differ (\(a.machine.architecture) and \(b.machine.architecture)). The same CPU time is not the same amount of work.")
        }
        if a.intervalSeconds != b.intervalSeconds {
            notes.append("Sampling intervals differ (\(a.intervalSeconds) s and \(b.intervalSeconds) s). A longer interval averages short bursts away.")
        }
        if a.machine.osVersion != b.machine.osVersion {
            notes.append("System versions differ (\(a.machine.osVersion) and \(b.machine.osVersion)).")
        }
        if a.coverage.leadersPerSample != b.coverage.leadersPerSample {
            notes.append("The runs keep a different number of leading processes per sample.")
        }
        return notes
    }
}
