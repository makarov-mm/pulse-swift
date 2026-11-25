import Foundation

/// One entry of a folder size survey.
public struct FolderNode: Identifiable, Sendable {
    public enum Kind: Sendable, Equatable {
        case folder, file, symlink
        /// Files below the per-folder limit, merged into one entry.
        case smallerFiles
        /// A folder on a different volume. It is listed and not entered.
        case otherVolume
        /// A cloud folder whose contents are not downloaded. It is listed and not entered.
        case cloudOnly
        case unreadable
    }

    public let id: Int
    public let name: String
    public let kind: Kind
    /// File lengths. A sparse or cloud-only file can be far larger here than on disk.
    public var logicalBytes: UInt64 = 0
    /// Blocks allocated on disk. APFS clones share blocks, so this can overstate reclaimable space.
    public var allocatedBytes: UInt64 = 0
    /// Files and links counted beneath this entry.
    public var items = 0
    /// Locations beneath this entry that could not be read. Totals are partial when above zero.
    public var unreadable = 0
    /// A hard link whose data was already counted at another path.
    public var linkedElsewhere = false
    public var children: [FolderNode] = []

    public var isPartial: Bool { unreadable > 0 }
    public var isContainer: Bool { kind == .folder && !children.isEmpty }

    public init(id: Int, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public mutating func adopt(_ child: FolderNode) {
        logicalBytes += child.logicalBytes
        allocatedBytes += child.allocatedBytes
        items += child.items
        unreadable += child.unreadable
        children.append(child)
    }

    /// Follows child identifiers from this node. Returns the nodes passed, this one first.
    public func trail(_ path: [Int]) -> [FolderNode] {
        var result = [self]
        for id in path {
            guard let next = result[result.count - 1].children.first(where: { $0.id == id }) else { break }
            result.append(next)
        }
        return result
    }
}

public struct TreemapRect: Equatable, Sendable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum Treemap {
    /// Squarified layout. Returns one rectangle per weight, in the order given.
    /// A weight that is not positive gets an empty rectangle.
    public static func layout(_ weights: [Double], width: Double, height: Double) -> [TreemapRect] {
        var result = [TreemapRect](repeating: TreemapRect(x: 0, y: 0, width: 0, height: 0), count: weights.count)
        let total = weights.reduce(0) { $0 + max(0, $1) }
        guard total > 0, width > 0, height > 0 else { return result }
        let scale = width * height / total
        let order = weights.indices.filter { weights[$0] > 0 }.sorted { weights[$0] > weights[$1] }
        var free = TreemapRect(x: 0, y: 0, width: width, height: height)
        var row: [Int] = []
        var rowArea = 0.0

        func worst(_ area: Double, _ smallest: Double, _ largest: Double, _ side: Double) -> Double {
            let square = side * side, areaSquare = area * area
            return max(square * largest / areaSquare, areaSquare / (square * smallest))
        }

        func place() {
            guard !row.isEmpty, rowArea > 0 else { return }
            let alongHeight = free.width >= free.height
            let side = alongHeight ? free.height : free.width
            let thickness = side > 0 ? rowArea / side : 0
            var offset = 0.0
            for index in row {
                let length = thickness > 0 ? weights[index] * scale / thickness : 0
                result[index] = alongHeight
                    ? TreemapRect(x: free.x, y: free.y + offset, width: thickness, height: length)
                    : TreemapRect(x: free.x + offset, y: free.y, width: length, height: thickness)
                offset += length
            }
            if alongHeight {
                free.x += thickness
                free.width = max(0, free.width - thickness)
            } else {
                free.y += thickness
                free.height = max(0, free.height - thickness)
            }
            row.removeAll()
            rowArea = 0
        }

        for index in order {
            let area = weights[index] * scale
            let side = min(free.width, free.height)
            if let first = row.first, let last = row.last, side > 0 {
                let largest = weights[first] * scale, smallest = weights[last] * scale
                if worst(rowArea + area, min(smallest, area), largest, side) > worst(rowArea, smallest, largest, side) {
                    place()
                }
            }
            row.append(index)
            rowArea += area
        }
        place()
        return result
    }
}
