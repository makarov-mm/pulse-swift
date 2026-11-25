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

    func testDetailsListOwnThreadsAndLoopbackSockets() async throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 1), 0)

        let sampler = MacSampler()
        let snapshot = await sampler.sample()
        let own = try XCTUnwrap(snapshot.processes.first { $0.id.pid == ProcessInfo.processInfo.processIdentifier })
        let read = await sampler.details(for: own.id)
        let details = try XCTUnwrap(read)
        XCTAssertFalse(try XCTUnwrap(details.threads).isEmpty)
        XCTAssertFalse(try XCTUnwrap(details.descriptors).isEmpty)
        let found = try XCTUnwrap(details.sockets.first { $0.id == listener })
        XCTAssertEqual(found.transport, "TCP")
        XCTAssertEqual(found.family, "IPv4")
        XCTAssertEqual(found.state, "Listen")
        XCTAssertTrue(found.local.hasPrefix("127.0.0.1:"))
        // A recycled PID must not be inspected under the old identity.
        let reused = ProcessID(pid: own.id.pid, startSeconds: own.id.startSeconds + 1,
                               startMicroseconds: own.id.startMicroseconds)
        let stale = await sampler.details(for: reused)
        XCTAssertNil(stale)
        XCTAssertFalse(LaunchItems.read().isEmpty)
    }
}
