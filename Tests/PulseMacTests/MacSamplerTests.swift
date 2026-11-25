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

    func testFolderScanHandlesLinksSparseFilesAndUnreadableFolders() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("pulse-scan-\(UUID().uuidString)")
        let big = root.appendingPathComponent("big"), locked = root.appendingPathComponent("locked")
        try files.createDirectory(at: big, withIntermediateDirectories: true)
        try files.createDirectory(at: locked, withIntermediateDirectories: true)
        defer {
            chmod(locked.path, 0o700)
            try? files.removeItem(at: root)
        }
        try Data(count: 300_000).write(to: big.appendingPathComponent("data"))
        try Data(count: 10_000).write(to: root.appendingPathComponent("small"))
        try files.linkItem(at: big.appendingPathComponent("data"), to: root.appendingPathComponent("hardlink"))
        try files.createSymbolicLink(at: big.appendingPathComponent("loop"), withDestinationURL: root)
        XCTAssertTrue(files.createFile(atPath: root.appendingPathComponent("sparse").path, contents: nil))
        XCTAssertEqual(truncate(root.appendingPathComponent("sparse").path, 64 << 20), 0)
        try Data(count: 1).write(to: locked.appendingPathComponent("hidden"))
        XCTAssertEqual(chmod(locked.path, 0), 0)

        let node = try FolderScan.scan(root)
        func child(_ name: String) throws -> FolderNode { try XCTUnwrap(node.children.first { $0.name == name }) }
        XCTAssertEqual(node.unreadable, 1)
        XCTAssertTrue(node.isPartial)
        XCTAssertEqual(try child("locked").kind, .unreadable)
        // The symlink back to the root is counted as a link and not followed.
        XCTAssertEqual(try child("big").children.first { $0.name == "loop" }?.kind, .symlink)
        XCTAssertEqual(try child("big").items, 2)
        // One of the two hard-linked paths carries the bytes. The other is flagged.
        let linked = [try child("hardlink"), try XCTUnwrap(try child("big").children.first { $0.name == "data" })]
        XCTAssertEqual(linked.filter(\.linkedElsewhere).count, 1)
        XCTAssertEqual(linked.map(\.logicalBytes).reduce(0, +), 300_000)
        let sparse = try child("sparse")
        XCTAssertEqual(sparse.logicalBytes, 64 << 20)
        XCTAssertLessThan(sparse.allocatedBytes, sparse.logicalBytes)
        XCTAssertGreaterThan(try child("big").allocatedBytes, try child("small").allocatedBytes)
        XCTAssertEqual(node.items, 5)
    }
}
