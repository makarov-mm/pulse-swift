import AppKit
import Foundation
import PulseCore
import PulseMac
import SwiftUI

@MainActor
final class Monitor: ObservableObject {
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var history = History()
    @Published var paused = false
    @Published var interval = 2
    /// Visible history in seconds: 1, 5 or 15 minutes.
    @Published var window = 60
    let sampler = MacSampler()

    var busiest: InterfaceRow? { Self.busiest(in: snapshot?.interfaces ?? []) }

    private static func busiest(in rows: [InterfaceRow]) -> InterfaceRow? {
        rows.filter { $0.combinedRate != nil }.max { a, b in
            let lhs = a.combinedRate ?? 0, rhs = b.combinedRate ?? 0
            return lhs == rhs ? a.name > b.name : lhs < rhs
        }
    }

    func run() async {
        guard !paused else { return }
        var previous: RawSample?
        let seconds = interval
        while !Task.isCancelled {
            let raw = await sampler.sample()
            guard !Task.isCancelled else { return }
            let next = Snapshot(current: raw, previous: previous, interval: Double(seconds))
            previous = raw
            history.add(next, interface: Self.busiest(in: next.interfaces))
            snapshot = next
            do { try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000) }
            catch { return }
        }
    }

    /// Packages the retained history for export. Paths are resolved only when the user asked for them.
    func capture(includePaths: Bool) async -> Capture {
        let system = ProcessInfo.processInfo
        let version = system.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        var size = 0
        var model: String?
        if sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 { model = String(cString: buffer) }
        }
        let machine = Capture.Machine(
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            architecture: architecture, model: model, logicalCores: system.activeProcessorCount,
            memoryBytes: system.physicalMemory)
        let saved = history
        var executables: [Capture.Executable]?
        if includePaths {
            var found: [Capture.Executable] = []
            for id in Set(saved.points.flatMap { $0.leaders.map(\.id) }) {
                if let url = await sampler.executable(for: id) { found.append(.init(process: id, path: url.path)) }
            }
            executables = found.sorted { $0.process.pid < $1.process.pid }
        }
        return Capture(history: saved, intervalSeconds: Double(interval), machine: machine,
                       coverage: .init(readableProcesses: snapshot?.processes.count,
                                       listedProcesses: snapshot?.raw.listedProcesses,
                                       leadersPerSample: History.leaderCount),
                       executables: executables, app: "Makarov Pulse \(Display.version)")
    }

    func pin(_ row: ProcessRow) { history.pin(row) }
    func unpin(_ id: ProcessID) { history.unpin(id) }
}

enum Display {
    /// Bundle version when packaged, otherwise the development version.
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(1))) + "%"
    }

    static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    static func rate(_ value: Double?) -> String {
        guard let value else { return "—" }
        return bytes(UInt64(max(0, value).rounded())) + "/s"
    }

    private static var users: [UInt32: String] = [:]

    /// Short user name for a numeric user ID. Falls back to the number.
    @MainActor static func user(_ uid: UInt32) -> String {
        if let known = users[uid] { return known }
        var name = String(uid)
        if let entry = getpwuid(uid), let raw = entry.pointee.pw_name { name = String(cString: raw) }
        users[uid] = name
        return name
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    static func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + " s"
    }
}
