import Darwin
import Foundation
import PulseCore

public struct ScanProgress: Sendable {
    public let items: Int
    public let allocatedBytes: UInt64
    public let path: String
}

/// Sizes a folder tree from file metadata only.
///
/// Policy: symbolic links are counted as links and never followed. Package directories are entered
/// like any folder. Folders on another volume and cloud folders that are not downloaded are listed
/// and not entered. A hard-linked file is counted at the first path that reaches it. A folder that is
/// reachable at several paths (APFS firmlinks such as /Users and /System/Volumes/Data/Users, or the
/// kernel's /.nofollow and /.resolve views of the root) is entered once, at the shallowest path.
public enum FolderScan {
    /// Largest files kept individually per folder. The rest are merged into one entry.
    public static let keptFilesPerFolder = 200

    /// Runs synchronously. Call it from a background task. Cancelling that task stops the scan.
    public static func scan(_ root: URL,
                            progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) throws -> FolderNode {
        let path = root.standardizedFileURL.path
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var walker = Walker(device: info.st_dev, progress: progress)
        walker.folders.insert(Walker.NodeID(device: info.st_dev, inode: info.st_ino))
        return try walker.folder(path, name: root.lastPathComponent, flags: info.st_flags)
    }
}

private struct Walker {
    struct NodeID: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    /// SF_DATALESS: the directory's contents live in cloud storage. Listing it would download them.
    static let dataless: UInt32 = 0x4000_0000

    let device: dev_t
    let progress: @Sendable (ScanProgress) -> Void
    /// Regular files with more than one hard link, already counted.
    var links: Set<NodeID> = []
    /// Folders already entered or claimed by their parent.
    var folders: Set<NodeID> = []
    var nextID = 0
    var items = 0
    var allocated: UInt64 = 0
    var reported = Date()

    init(device: dev_t, progress: @escaping @Sendable (ScanProgress) -> Void) {
        self.device = device
        self.progress = progress
    }

    mutating func make(_ name: String, _ kind: FolderNode.Kind) -> FolderNode {
        nextID += 1
        return FolderNode(id: nextID, name: name, kind: kind)
    }

    mutating func folder(_ path: String, name: String, flags: UInt32) throws -> FolderNode {
        try Task.checkCancellation()
        if flags & Self.dataless != 0 { return make(name, .cloudOnly) }
        let listing = autoreleasepool { try? FileManager.default.contentsOfDirectory(atPath: path) }
        guard let names = listing else {
            var blocked = make(name, .unreadable)
            blocked.unreadable = 1
            return blocked
        }
        var node = make(name, .folder)
        var files: [FolderNode] = []
        var subfolders: [(path: String, name: String, flags: UInt32)] = []
        let prefix = path.hasSuffix("/") ? path : path + "/"
        for entry in names {
            let child = prefix + entry
            var info = stat()
            guard lstat(child, &info) == 0 else {
                node.unreadable += 1
                continue
            }
            let type = info.st_mode & S_IFMT
            if type == S_IFDIR {
                // Claim every subfolder before entering any, so siblings win over aliases deeper down.
                if info.st_dev != device {
                    node.adopt(make(entry, .otherVolume))
                } else if !folders.insert(NodeID(device: info.st_dev, inode: info.st_ino)).inserted {
                    node.adopt(make(entry, .countedElsewhere))
                } else {
                    subfolders.append((path: child, name: entry, flags: info.st_flags))
                }
                continue
            }
            var file = make(entry, type == S_IFLNK ? .symlink : .file)
            file.items = 1
            if type == S_IFREG, info.st_nlink > 1,
               !links.insert(NodeID(device: info.st_dev, inode: info.st_ino)).inserted {
                file.linkedElsewhere = true
            } else {
                file.logicalBytes = UInt64(max(0, info.st_size))
                file.allocatedBytes = UInt64(max(0, info.st_blocks)) * 512
            }
            items += 1
            allocated += file.allocatedBytes
            files.append(file)
        }
        for sub in subfolders {
            node.adopt(try folder(sub.path, name: sub.name, flags: sub.flags))
        }
        files.sort { (a: FolderNode, b: FolderNode) -> Bool in
            if a.allocatedBytes == b.allocatedBytes { return a.logicalBytes > b.logicalBytes }
            return a.allocatedBytes > b.allocatedBytes
        }
        if files.count > FolderScan.keptFilesPerFolder {
            let rest = files[FolderScan.keptFilesPerFolder...]
            var merged = make("\(rest.count) smaller files", .smallerFiles)
            for file in rest {
                merged.logicalBytes += file.logicalBytes
                merged.allocatedBytes += file.allocatedBytes
                merged.items += file.items
            }
            files.removeSubrange(FolderScan.keptFilesPerFolder...)
            files.append(merged)
        }
        for file in files { node.adopt(file) }
        if reported.timeIntervalSinceNow < -0.2 {
            reported = Date()
            progress(ScanProgress(items: items, allocatedBytes: allocated, path: path))
        }
        return node
    }
}
