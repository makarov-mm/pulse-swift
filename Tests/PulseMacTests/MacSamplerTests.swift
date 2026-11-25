import Foundation
import XCTest
import PulseCore
import PulseMac

final class MacSamplerTests: XCTestCase {
    func testOwnProcessAndExecutableIdentity() async throws {
        let sampler = MacSampler()
        let snapshot = await sampler.sample()
        let own = try XCTUnwrap(snapshot.processes.first { $0.id.pid == ProcessInfo.processInfo.processIdentifier })
        XCTAssertFalse(own.name.isEmpty)
        XCTAssertGreaterThan(try XCTUnwrap(own.residentBytes), 0)
        XCTAssertGreaterThan(try XCTUnwrap(own.threads), 0)
        XCTAssertNotNil(snapshot.host)
        XCTAssertGreaterThan(try XCTUnwrap(snapshot.wiredBytes), 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(snapshot.listedProcesses), snapshot.processes.count)
        let path = await sampler.executable(for: own.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(path).path))
        let reused = ProcessID(pid: own.id.pid, startSeconds: own.id.startSeconds + 1,
                               startMicroseconds: own.id.startMicroseconds)
        let mismatched = await sampler.executable(for: reused)
        XCTAssertNil(mismatched)
    }
}
