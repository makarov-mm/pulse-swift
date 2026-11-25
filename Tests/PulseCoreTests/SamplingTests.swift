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
            // The worker burns one core from t=10 to t=30, then its PID is reused by an idle process.
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
        let start = Date(timeIntervalSince1970: 1010), end = Date(timeIntervalSince1970: 1030)
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

    func testSelectedIntervalClipsCPUTimeInLiveAndSavedHistory() throws {
        func sample(at time: Double, ticks: UInt64, busy: UInt32, idle: UInt32) -> RawSample {
            var reading = raw(time)
            reading.processes = [process(ticks)]
            reading.host = .init(user: busy, system: 0, idle: idle, nice: 0)
            return reading
        }
        let baseline = sample(at: 5, ticks: 0, busy: 0, idle: 0)
        var afterGap = sample(at: 65, ticks: 2250, busy: 200, idle: 200)
        afterGap.date = afterGap.date.addingTimeInterval(5) // Five awake seconds over ten wall-clock seconds.
        let readings = [
            sample(at: 10, ticks: 1000, busy: 50, idle: 50),  // 200% process, 50% host
            sample(at: 15, ticks: 1500, busy: 70, idle: 130), // 100% process, 20% host
            sample(at: 20, ticks: 1750, busy: 150, idle: 150), // 50% process, 80% host
            sample(at: 60, ticks: 1750, busy: 150, idle: 150), // gap
            afterGap
        ]
        var live = History()
        var previous = baseline // A rolling history can start with an already measured sample.
        for reading in readings {
            live.add(Snapshot(current: reading, previous: previous, interval: 5), interface: nil)
            previous = reading
        }
        let capture = Capture(history: live, intervalSeconds: 5,
                              machine: .init(osVersion: "14", architecture: "arm64", model: nil,
                                             logicalCores: 4, memoryBytes: 1024),
                              coverage: .init(readableProcesses: 1, listedProcesses: 1,
                                              leadersPerSample: History.leaderCount),
                              executables: nil, app: "Test")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try capture.encoded().write(to: file, options: .atomic)
        let reopened = History(replaying: try Capture.decode(Data(contentsOf: file)))

        for (source, history) in [("live", live), ("reopened", reopened)] {
            func summary(_ start: Double, _ end: Double) -> IntervalSummary {
                history.summary(from: raw(start).date, to: raw(end).date)
            }
            XCTAssertEqual(history.startTime, baseline.date, source)
            let cases: [(start: Double, end: Double, measured: Double, cpuSeconds: Double, host: Double, peak: Double)] = [
                (8, 10, 2, 4, 50, 200),           // first retained sample
                (10, 11, 1, 1, 20, 100),          // starts exactly on a sample
                (11.25, 13.75, 2.5, 2.5, 20, 100), // both bounds between observations
                (10, 15, 5, 5, 20, 100),          // both bounds on observations
                (13, 18, 5, 3.5, 56, 100),        // two seconds at 100%, three at 50%
                (62, 66, 2, 2, 50, 100)           // four wall-clock seconds, two awake seconds
            ]
            for item in cases {
                let label = "\(source) \(item.start)...\(item.end)"
                let result = summary(item.start, item.end)
                XCTAssertEqual(result.measuredSeconds, item.measured, accuracy: 1e-6, label)
                XCTAssertEqual(try XCTUnwrap(result.hostCPU, label), item.host, accuracy: 1e-6, label)
                let worker = try XCTUnwrap(result.leaders.first, label)
                XCTAssertEqual(worker.cpuSeconds, item.cpuSeconds, accuracy: 1e-6, label)
                XCTAssertEqual(worker.averageCPU, 100 * item.cpuSeconds / item.measured, accuracy: 1e-6, label)
                XCTAssertEqual(worker.peakCPU, item.peak, accuracy: 1e-6, label)
            }
            for empty in [summary(10, 10), summary(20, 60)] {
                XCTAssertEqual(empty.measuredSeconds, 0, source)
                XCTAssertNil(empty.hostCPU, source)
                XCTAssertTrue(empty.leaders.isEmpty, source)
            }
        }
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

    func testTreemapCoversTheAreaInProportion() {
        let weights: [Double] = [6, 6, 4, 3, 2, 2, 1, 0]
        let rects = Treemap.layout(weights, width: 6, height: 4)
        XCTAssertEqual(rects.count, weights.count)
        for (weight, rect) in zip(weights, rects) {
            XCTAssertEqual(rect.width * rect.height, weight, accuracy: 1e-9)
            XCTAssertGreaterThanOrEqual(rect.x, -1e-9)
            XCTAssertGreaterThanOrEqual(rect.y, -1e-9)
            XCTAssertLessThanOrEqual(rect.x + rect.width, 6 + 1e-9)
            XCTAssertLessThanOrEqual(rect.y + rect.height, 4 + 1e-9)
        }
        // The two largest entries share the first column of the classic squarified example.
        XCTAssertEqual(rects[0], TreemapRect(x: 0, y: 0, width: 3, height: 2))
        XCTAssertEqual(rects[1], TreemapRect(x: 0, y: 2, width: 3, height: 2))
        XCTAssertTrue(Treemap.layout([], width: 6, height: 4).isEmpty)
    }

    func testCaptureRoundTripKeepsGapsIdentityAndRejectsBadFiles() throws {
        var history = History()
        var last: RawSample?
        for i in 1...40 {
            // A sleep after sample 20 moves the wall clock by ten minutes, which stays inside the
            // retention window. PID 42 is reused after sample 30.
            var sample = raw(Double(i))
            if i > 20 { sample.date = sample.date.addingTimeInterval(600) }
            sample.processes = [i <= 30 ? process(UInt64(i) * 100) : process(UInt64(i) * 50, birth: 2)]
            sample.host = .init(user: UInt32(i) * 10, system: 0, idle: UInt32(i) * 30, nice: 0)
            history.add(Snapshot(current: sample, previous: last, interval: 1), interface: nil)
            last = sample
        }
        let machine = Capture.Machine(osVersion: "14.5", architecture: "arm64", model: "Mac15,6",
                                      logicalCores: 12, memoryBytes: 1 << 34)
        let capture = Capture(history: history, intervalSeconds: 1, machine: machine,
                              coverage: .init(readableProcesses: 1, listedProcesses: 2,
                                              leadersPerSample: History.leaderCount),
                              executables: nil, app: "Test")
        let data = try capture.encoded()
        let loaded = try Capture.decode(data)
        XCTAssertEqual(loaded.machine, machine)
        XCTAssertEqual(loaded.samples.count, 40)
        XCTAssertEqual(loaded.samples.filter(\.gap).count, 2)
        XCTAssertEqual(loaded.samples[20].offset, 20, accuracy: 1e-9)
        XCTAssertEqual(loaded.measuredSeconds, 38, accuracy: 1e-9)
        XCTAssertNil(loaded.executables)

        // Rankings are reproducible without live process access.
        let replay = History(replaying: loaded)
        let live = history.summary(from: .distantPast, to: .distantFuture)
        let offline = replay.summary(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(offline.leaders.map(\.id), live.leaders.map(\.id))
        XCTAssertEqual(offline.leaders.count, 2)
        XCTAssertEqual(offline.leaders[0].cpuSeconds, live.leaders[0].cpuSeconds, accuracy: 1e-6)
        XCTAssertEqual(offline.hostCPU ?? 0, 25, accuracy: 1e-6)

        XCTAssertThrowsError(try Capture.decode(data.prefix(data.count / 2))) {
            XCTAssertEqual($0 as? CaptureError, .unreadable)
        }
        var future = loaded
        future.schema = 99
        XCTAssertThrowsError(try Capture.decode(try future.encoded())) {
            XCTAssertEqual($0 as? CaptureError, .unsupportedSchema(99))
        }

        var other = loaded
        other.machine.logicalCores = 8
        other.intervalSeconds = 5
        XCTAssertEqual(CaptureComparison.notes(loaded, other).count, 2)
        XCTAssertEqual(CaptureComparison.rows(loaded, other).first?.name, "Build Worker")
        XCTAssertEqual(CaptureComparison.rows(loaded, other).first?.first, CaptureComparison.rows(loaded, other).first?.second)
    }
}
