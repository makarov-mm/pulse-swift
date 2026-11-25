import Foundation

public struct ProcessNode: Identifiable, Sendable {
    public let row: ProcessRow
    public let children: [ProcessNode]
    /// False for an ancestor kept only to show the chain to a matching descendant.
    public let matches: Bool
    public var id: ProcessID { row.id }
}

/// One visible row of the flattened tree.
public struct TreeLine: Identifiable, Sendable {
    public let row: ProcessRow
    public let depth: Int
    public let hasChildren: Bool
    public let collapsed: Bool
    public let matches: Bool
    public var id: ProcessID { row.id }
}

public enum ProcessTree {
    /// Links children by parent PID. A parent must be older than its child,
    /// which rejects a recycled parent PID and makes cycles impossible.
    public static func build(_ rows: [ProcessRow], matching text: String = "") -> [ProcessNode] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let byPID = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [ProcessID: [ProcessRow]] = [:]
        var roots: [ProcessRow] = []
        for row in rows {
            if let parent = byPID[row.parent], precedes(parent.id, row.id) {
                children[parent.id, default: []].append(row)
            } else {
                roots.append(row)
            }
        }
        func node(_ row: ProcessRow) -> ProcessNode? {
            let kept = (children[row.id] ?? []).sorted { $0.pid < $1.pid }.compactMap { node($0) }
            let hit = ProcessSearch.matches(row, text: query)
            guard query.isEmpty || hit || !kept.isEmpty else { return nil }
            return ProcessNode(row: row, children: kept, matches: hit)
        }
        return roots.sorted { $0.pid < $1.pid }.compactMap { node($0) }
    }

    public static func lines(_ nodes: [ProcessNode], collapsed: Set<ProcessID> = []) -> [TreeLine] {
        var result: [TreeLine] = []
        func visit(_ node: ProcessNode, depth: Int) {
            let folded = !node.children.isEmpty && collapsed.contains(node.id)
            result.append(TreeLine(row: node.row, depth: depth, hasChildren: !node.children.isEmpty,
                                   collapsed: folded, matches: node.matches))
            guard !folded else { return }
            for child in node.children { visit(child, depth: depth + 1) }
        }
        for node in nodes { visit(node, depth: 0) }
        return result
    }

    private static func precedes(_ a: ProcessID, _ b: ProcessID) -> Bool {
        (a.startSeconds, a.startMicroseconds, a.pid) < (b.startSeconds, b.startMicroseconds, b.pid)
    }
}
