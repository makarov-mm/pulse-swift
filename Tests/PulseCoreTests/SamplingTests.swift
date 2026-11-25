import Foundation
import XCTest
import PulseCore

final class SamplingTests: XCTestCase {
    private func raw(_ time: Double) -> RawSample {
        RawSample(date: Date(timeIntervalSince1970: 1000 + time), machTime: UInt64(time * 100),
                  uptime: time, totalRAM: 1024)
    }

    private func process(_ ticks: UInt64?, birth: UInt64 = 1) -> ProcessReading {
        ProcessReading(id: .init(pid: 42, startSeconds: 100, startMicroseconds: birth),
                       parent: 1, uid: 501, name: "Build Worker", residentBytes: 44,
                       threads: 2, cpuTicks: ticks)
    }

    private func interface(_ rx: UInt64, _ tx: UInt64, index: UInt32 = 3) -> InterfaceReading {
        InterfaceReading(id: .init(index: index, name: "en0"), received: rx, sent: tx)
    }

    func testCPUUsesOneCoreForProcessesAndWholeMachineForHost() {
        var a = raw(1), b = raw(3)
        a.processes = [process(12)]
        b.processes = [process(312)]
        a.host = .init(user: 20, system: 10, idle: 40, nice: 0)
        b.host = .init(user: 25, system: 14, idle: 70, nice: 1)
        let frame = Snapshot(current: b, previous: a, interval: 2)
        XCTAssertEqual(frame.processes.first?.cpu, 150)
        XCTAssertEqual(frame.hostCPU, 25)
        XCTAssertNil(Snapshot(current: b, previous: nil, interval: 2).processes.first?.cpu)
    }

    func testPIDReuseAndCounterRegression() {
        var a = raw(1), b = raw(3)
        a.processes = [process(100)]
        for row in [process(200, birth: 2), process(80), process(nil)] {
            b.processes = [row]
            XCTAssertNil(Snapshot(current: b, previous: a, interval: 2).processes.first?.cpu)
        }
        a.host = .init(user: .max, system: 5, idle: 10, nice: 0)
        b.host = .init(user: 1, system: 6, idle: 11, nice: 0)
        XCTAssertNil(Snapshot(current: b, previous: a, interval: 2).hostCPU)
    }

    func testInterfaceRatesAndReattachment() {
        var a = raw(1), b = raw(3)
        a.interfaces = [interface(1000, 500)]
        b.interfaces = [interface(1240, 560)]
        var row = Snapshot(current: b, previous: a, interval: 2).interfaces.first
        XCTAssertEqual(row?.receiveRate, 120)
        XCTAssertEqual(row?.sendRate, 30)
        b.interfaces = [interface(1, 560)]
        row = Snapshot(current: b, previous: a, interval: 2).interfaces.first
        XCTAssertNil(row?.receiveRate)
        XCTAssertEqual(row?.sendRate, 30)
        b.interfaces = [interface(1300, 590, index: 7)]
        XCTAssertNil(Snapshot(current: b, previous: a, interval: 2).interfaces.first?.combinedRate)
    }

    func testSleepAndBackwardsClockBreakTheSeries() {
        var a = raw(1), b = raw(3)
        a.interfaces = [interface(100, 100)]
        b.interfaces = [interface(200, 200)]
        for shift in [3600.0, -30.0] {
            var shifted = b
            shifted.date = b.date.addingTimeInterval(shift)
            let frame = Snapshot(current: shifted, previous: a, interval: 2)
            XCTAssertTrue(frame.startsSegment)
            XCTAssertNil(frame.interfaces.first?.receiveRate)
        }
    }

    func testHistoryRetentionAndSearch() throws {
        var history = History()
        var last: RawSample?
        for i in 1...1000 {
            var sample = raw(Double(i))
            sample.processes = [process(UInt64(i))]
            let frame = Snapshot(current: sample, previous: last, interval: 1)
            history.add(frame, interface: nil)
            last = sample
        }
        XCTAssertEqual(history.points.count, 901)
        let row = try XCTUnwrap(Snapshot(current: try XCTUnwrap(last), previous: nil, interval: 1).processes.first)
        XCTAssertTrue(ProcessSearch.matches(row, text: "wOrK"))
        XCTAssertTrue(ProcessSearch.matches(row, text: "pid: 42"))
        XCTAssertTrue(ProcessSearch.matches(row, text: "42"))
        XCTAssertFalse(ProcessSearch.matches(row, text: "4"))
        XCTAssertFalse(ProcessSearch.matches(row, text: "pid:"))
    }

    func testIntervalRankingSurvivesExitAndPIDReuse() {
        var history = History()
        var last: RawSample?
        let worker = ProcessID(pid: 42, startSeconds: 100, startMicroseconds: 1)
        for i in 1...60 {
            var sample = raw(Double(i))
            sample.listedProcesses = 1
            // The worker burns one core during seconds 11...30, then its PID is reused by an idle process.
            if i <= 30 {
                sample.processes = [process(i <= 10 ? 0 : UInt64(i - 10) * 100)]
            } else {
                sample.processes = [process(UInt64(i), birth: 2)]
            }
            if i == 10, let frame = last.map({ Snapshot(current: sample, previous: $0, interval: 1) }) {
                history.pin(frame.processes[0])
            }
            history.add(Snapshot(current: sample, previous: last, interval: 1), interface: nil)
            last = sample
        }
        let start = Date(timeIntervalSince1970: 1011), end = Date(timeIntervalSince1970: 1030)
        let summary = history.summary(from: start, to: end)
        XCTAssertEqual(summary.measuredSeconds, 20, accuracy: 0.001)
        XCTAssertEqual(summary.leaders.first?.id, worker)
        XCTAssertEqual(summary.leaders.first?.cpuSeconds ?? 0, 20, accuracy: 0.001)
        XCTAssertEqual(summary.leaders.first?.averageCPU ?? 0, 100, accuracy: 0.001)
        XCTAssertFalse(history.summary(from: end.addingTimeInterval(1), to: end.addingTimeInterval(30))
            .leaders.contains { $0.id == worker })
        let series = history.pinned[0]
        XCTAssertEqual(series.id, worker)
        XCTAssertEqual(series.samples.last?.time, Date(timeIntervalSince1970: 1030))
        XCTAssertEqual(series.exited, Date(timeIntervalSince1970: 1031))
    }

    func testTreeKeepsParentChainAndRejectsYoungerParent() {
        func row(_ pid: Int32, parent: Int32, start: UInt64, _ name: String) -> ProcessRow {
            var sample = raw(1)
            sample.processes = [ProcessReading(id: .init(pid: pid, startSeconds: start, startMicroseconds: 0),
                                               parent: parent, uid: 501, name: name, residentBytes: nil,
                                               threads: nil, cpuTicks: nil)]
            return Snapshot(current: sample, previous: nil, interval: 1).processes[0]
        }
        let rows = [row(1, parent: 0, start: 1, "launchd"), row(10, parent: 1, start: 5, "shell"),
                    row(11, parent: 10, start: 6, "worker"), row(12, parent: 1, start: 7, "other"),
                    // PID 20 claims a parent that started after it: a recycled parent PID.
                    row(20, parent: 30, start: 8, "orphan"), row(30, parent: 1, start: 9, "late")]
        let all = ProcessTree.lines(ProcessTree.build(rows))
        XCTAssertEqual(all.map(\.row.pid), [1, 10, 11, 12, 30, 20])
        XCTAssertEqual(all.map(\.depth), [0, 1, 2, 1, 1, 0])
        let found = ProcessTree.lines(ProcessTree.build(rows, matching: "work"))
        XCTAssertEqual(found.map(\.row.pid), [1, 10, 11])
        XCTAssertEqual(found.map(\.matches), [false, false, true])
        let folded = ProcessTree.lines(ProcessTree.build(rows), collapsed: [rows[1].id])
        XCTAssertEqual(folded.map(\.row.pid), [1, 10, 12, 30, 20])
    }

    func testPerCoreLoadAndDiskRatesKeepDeviceIdentity() {
        var a = raw(1), b = raw(3)
        a.cores = [.init(user: 10, system: 0, idle: 10, nice: 0), .init(user: 0, system: 0, idle: 50, nice: 0)]
        b.cores = [.init(user: 30, system: 0, idle: 10, nice: 0), .init(user: 0, system: 5, idle: 65, nice: 0)]
        let disk = DiskID(entry: 7, name: "disk0")
        a.disks = [.init(id: disk, read: 1000, written: 400), .init(id: .init(entry: 9, name: "disk4"), read: nil, written: nil)]
        b.disks = [.init(id: disk, read: 5000, written: 400), .init(id: .init(entry: 9, name: "disk4"), read: nil, written: nil)]
        var frame = Snapshot(current: b, previous: a, interval: 2)
        XCTAssertEqual(frame.cores, [100, 25])
        XCTAssertEqual(frame.disks[0].readRate, 2000)
        XCTAssertEqual(frame.disks[0].writeRate, 0)
        XCTAssertNil(frame.disks[1].readRate)
        var history = History()
        history.add(frame, interface: nil)
        XCTAssertEqual(history.points.last?.disks.first?.incoming, 2000)
        // The same BSD name on a new registry entry is a reattached device and needs a new baseline.
        b.disks = [.init(id: .init(entry: 8, name: "disk0"), read: 9000, written: 900)]
        b.cores = [b.cores![0]]
        frame = Snapshot(current: b, previous: a, interval: 2)
        XCTAssertNil(frame.disks[0].readRate)
        XCTAssertEqual(frame.cores, [nil])
    }
}
