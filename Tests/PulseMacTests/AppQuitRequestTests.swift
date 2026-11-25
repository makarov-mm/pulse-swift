import AppKit
import Darwin
import PulseCore
import XCTest
@testable import PulseMac

final class AppQuitRequestTests: XCTestCase {
    private final class Application: QuitApplication {
        let id: ProcessID
        var processIdentifier: pid_t { id.pid }
        let activationPolicy = NSApplication.ActivationPolicy.regular
        let isTerminated = false
        var acceptsQuit = true
        private(set) var quitCalls = 0

        init(pid: pid_t, microseconds: UInt64) {
            id = ProcessID(pid: pid, startSeconds: 1_700_000_000, startMicroseconds: microseconds)
        }

        func terminate() -> Bool {
            quitCalls += 1
            return acceptsQuit
        }
    }

    private final class Fixture {
        let original: Application
        let replacement: Application
        var current: Application
        private(set) var lookups = 0

        init() {
            let pid: pid_t = getpid() == 4321 ? 4322 : 4321
            let first = Application(pid: pid, microseconds: 500)
            original = first
            replacement = Application(pid: pid, microseconds: 501)
            current = first
        }

        func lookup(_ pid: pid_t) -> (any QuitApplication)? {
            lookups += 1
            return current.processIdentifier == pid ? current : nil
        }

        @MainActor func makeRequest() throws -> AppQuitRequest {
            var raw = RawSample(date: Date(timeIntervalSince1970: 1_700_000_001),
                                machTime: 1, uptime: 1, totalRAM: 1)
            raw.processes = [ProcessReading(id: original.id, parent: 1, uid: getuid(), name: "Test App",
                                            residentBytes: nil, threads: nil, cpuTicks: nil)]
            let row = try XCTUnwrap(Snapshot(current: raw, previous: nil, interval: 1).processes.first)
            return try XCTUnwrap(AppQuitRequest(row: row, lookup: lookup))
        }
    }

    @MainActor func testQuitReachesConfirmedApplication() async throws {
        let fixture = Fixture()
        let request = try fixture.makeRequest()
        let outcome = await request.send { id in
            XCTAssertEqual(id, fixture.original.id)
            return id == fixture.current.id
        }
        XCTAssertEqual(outcome, .requested)
        XCTAssertEqual(fixture.lookups, 1)
        XCTAssertEqual(fixture.original.quitCalls, 1)
        XCTAssertEqual(fixture.replacement.quitCalls, 0)
    }

    @MainActor func testReuseWhileConfirmationIsOpenAbortsQuit() async throws {
        let fixture = Fixture()
        let request = try fixture.makeRequest()
        fixture.current = fixture.replacement

        let outcome = await request.send { id in
            XCTAssertEqual(id, fixture.original.id)
            return id == fixture.current.id
        }
        XCTAssertEqual(outcome, .changed)
        XCTAssertEqual(fixture.lookups, 1)
        XCTAssertEqual(fixture.original.quitCalls, 0)
        XCTAssertEqual(fixture.replacement.quitCalls, 0)
    }

    @MainActor func testStaleSelectedRowCannotQuitApplicationFoundAtLookup() async throws {
        let fixture = Fixture()
        // The selected row survives a refresh. The PID already belongs to the second app
        // when the dialog resolves its handle.
        fixture.current = fixture.replacement
        let request = try fixture.makeRequest()
        let outcome = await request.send { id in
            XCTAssertEqual(id, fixture.original.id)
            return id == fixture.current.id
        }
        XCTAssertEqual(outcome, .changed)
        XCTAssertEqual(fixture.lookups, 1)
        XCTAssertEqual(fixture.original.quitCalls, 0)
        XCTAssertEqual(fixture.replacement.quitCalls, 0)
    }

    @MainActor func testReuseImmediatelyAfterPositiveCheckCannotRedirectQuit() async throws {
        let fixture = Fixture()
        let request = try fixture.makeRequest()
        let outcome = await request.send { id in
            let wasCurrent = id == fixture.current.id
            XCTAssertTrue(wasCurrent)
            // Model reuse after the identity read. AppKit's isTerminated still reports false
            // for the old handle, but terminate on it can no longer deliver the request.
            fixture.original.acceptsQuit = false
            fixture.current = fixture.replacement
            return wasCurrent
        }
        XCTAssertEqual(outcome, .refused)
        XCTAssertEqual(fixture.lookups, 1)
        XCTAssertEqual(fixture.original.quitCalls, 1)
        XCTAssertEqual(fixture.replacement.quitCalls, 0)
    }
}
