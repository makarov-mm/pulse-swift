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
        for i in 1...100 {
            var sample = raw(Double(i))
            sample.processes = [process(UInt64(i))]
            let frame = Snapshot(current: sample, previous: last, interval: 1)
            history.add(frame, interface: nil)
            last = sample
        }
        XCTAssertEqual(history.points.count, 61)
        let row = try XCTUnwrap(Snapshot(current: try XCTUnwrap(last), previous: nil, interval: 1).processes.first)
        XCTAssertTrue(ProcessSearch.matches(row, text: "wOrK"))
        XCTAssertTrue(ProcessSearch.matches(row, text: "pid: 42"))
        XCTAssertTrue(ProcessSearch.matches(row, text: "42"))
        XCTAssertFalse(ProcessSearch.matches(row, text: "4"))
        XCTAssertFalse(ProcessSearch.matches(row, text: "pid:"))
    }
}
