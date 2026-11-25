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

    func pin(_ row: ProcessRow) { history.pin(row) }
    func unpin(_ id: ProcessID) { history.unpin(id) }
}

enum Display {
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
