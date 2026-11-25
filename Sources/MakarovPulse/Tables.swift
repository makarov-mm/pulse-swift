import AppKit
import SwiftUI
import PulseCore
import PulseMac

/// Sortable process columns, used to store each view's sort order between launches.
enum ProcessColumn: String, CaseIterable {
    case name, pid, parent, uid, threads, memory, cpu

    func comparator(_ order: SortOrder) -> KeyPathComparator<ProcessRow> {
        var result: KeyPathComparator<ProcessRow>
        switch self {
        case .name: result = KeyPathComparator(\ProcessRow.name)
        case .pid: result = KeyPathComparator(\ProcessRow.pid)
        case .parent: result = KeyPathComparator(\ProcessRow.parent)
        case .uid: result = KeyPathComparator(\ProcessRow.uid)
        case .threads: result = KeyPathComparator(\ProcessRow.threadSort)
        case .memory: result = KeyPathComparator(\ProcessRow.memorySort)
        case .cpu: result = KeyPathComparator(\ProcessRow.cpuSort)
        }
        result.order = order
        return result
    }

    static func decode(_ text: String) -> [KeyPathComparator<ProcessRow>] {
        let parts = text.split(separator: ":")
        let column = parts.first.flatMap { ProcessColumn(rawValue: String($0)) } ?? .name
        return [column.comparator(parts.last == "reverse" ? .reverse : .forward)]
    }

    static func encode(_ order: [KeyPathComparator<ProcessRow>]) -> String? {
        guard let first = order.first else { return nil }
        let path = first.keyPath as AnyKeyPath
        guard let column = allCases.first(where: { ($0.comparator(.forward).keyPath as AnyKeyPath) == path })
        else { return nil }
        return column.rawValue + (first.order == .reverse ? ":reverse" : ":forward")
    }
}

struct ProcessTable: View {
    let rows: [ProcessRow]
    let details: Bool
    @Binding var selection: ProcessID?
    // Each view keeps its own sort order and column layout.
    @AppStorage("sort.processes") private var processSort = "cpu:reverse"
    @AppStorage("sort.details") private var detailSort = "name:forward"
    @AppStorage("columns.processes") private var processColumns = TableColumnCustomization<ProcessRow>()
    @AppStorage("columns.details") private var detailColumns = TableColumnCustomization<ProcessRow>()

    var body: some View {
        if details {
            Table(ordered(detailSort), selection: $selection, sortOrder: order($detailSort),
                  columnCustomization: $detailColumns) {
                TableColumn("Name", value: \.name) { Text($0.name).lineLimit(1).help($0.name) }
                    .width(min: 150, ideal: 220).customizationID("name")
                TableColumn("PID", value: \.pid) { Text(String($0.pid)) }
                    .width(min: 45, ideal: 60).customizationID("pid")
                TableColumn("Parent PID", value: \.parent) { Text(String($0.parent)) }
                    .customizationID("parent")
                TableColumn("UID", value: \.uid) { Text(String($0.uid)) }
                    .customizationID("uid")
                // Sorting by UID groups the processes of each user.
                TableColumn("User", value: \.uid) { Text(Display.user($0.uid)) }
                    .customizationID("user")
                TableColumn("Threads", value: \.threadSort) { Text($0.reading.threads.map { String($0) } ?? "—") }
                    .customizationID("threads")
                TableColumn("Resident memory", value: \.memorySort) { Text(Display.bytes($0.reading.residentBytes)) }
                    .customizationID("memory")
            }
        } else {
            Table(ordered(processSort), selection: $selection, sortOrder: order($processSort),
                  columnCustomization: $processColumns) {
                TableColumn("Name", value: \.name) { Text($0.name).lineLimit(1).help($0.name) }
                    .width(min: 150, ideal: 235).customizationID("name")
                TableColumn("PID", value: \.pid) { Text(String($0.pid)) }
                    .width(min: 45, ideal: 65).customizationID("pid")
                TableColumn("CPU %", value: \.cpuSort) { Text(Display.percent($0.cpu)) }
                    .customizationID("cpu")
                TableColumn("Resident memory", value: \.memorySort) { Text(Display.bytes($0.reading.residentBytes)) }
                    .customizationID("memory")
                TableColumn("Threads", value: \.threadSort) { Text($0.reading.threads.map { String($0) } ?? "—") }
                    .customizationID("threads")
            }
        }
    }

    private func ordered(_ stored: String) -> [ProcessRow] {
        rows.sorted(using: ProcessColumn.decode(stored) + [KeyPathComparator(\ProcessRow.pid)])
    }

    private func order(_ stored: Binding<String>) -> Binding<[KeyPathComparator<ProcessRow>]> {
        Binding(get: { ProcessColumn.decode(stored.wrappedValue) },
                set: { if let text = ProcessColumn.encode($0) { stored.wrappedValue = text } })
    }
}

/// Parent/child view. Branches collapse; a filter keeps every ancestor of a match visible.
struct ProcessTreeTable: View {
    let nodes: [ProcessNode]
    let filtering: Bool
    @Binding var selection: ProcessID?
    @State private var collapsed: Set<ProcessID> = []

    var body: some View {
        Table(ProcessTree.lines(nodes, collapsed: filtering ? [] : collapsed), selection: $selection) {
            TableColumn("Name") { (line: TreeLine) in name(line) }.width(min: 240, ideal: 360)
            TableColumn("PID") { (line: TreeLine) in Text(String(line.row.pid)) }.width(min: 45, ideal: 65)
            TableColumn("CPU %") { (line: TreeLine) in Text(Display.percent(line.row.cpu)) }
            TableColumn("Resident memory") { (line: TreeLine) in Text(Display.bytes(line.row.reading.residentBytes)) }
            TableColumn("Started") { (line: TreeLine) in
                Text(line.row.id.started.formatted(date: .abbreviated, time: .standard))
            }
        }
    }

    private func name(_ line: TreeLine) -> some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(line.depth) * 14, height: 1)
            if line.hasChildren {
                Button {
                    if collapsed.contains(line.id) { collapsed.remove(line.id) } else { collapsed.insert(line.id) }
                } label: {
                    Image(systemName: line.collapsed ? "chevron.right" : "chevron.down").frame(width: 12)
                }
                .buttonStyle(.plain).disabled(filtering)
                .accessibilityLabel(line.collapsed ? "Expand \(line.row.name)" : "Collapse \(line.row.name)")
            } else {
                Color.clear.frame(width: 12, height: 1)
            }
            Text(line.row.name).lineLimit(1).help(line.row.name)
                .foregroundStyle(line.matches ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.secondary)
        }
    }
}

struct NetworkTable: View {
    let rows: [InterfaceRow]
    @Binding var selection: InterfaceID?
    @State private var order = [KeyPathComparator(\InterfaceRow.receiveSort, order: .reverse)]
    @AppStorage("columns.network") private var columns = TableColumnCustomization<InterfaceRow>()

    var body: some View {
        Table(rows.sorted(using: order + [KeyPathComparator(\InterfaceRow.name)]), selection: $selection,
              sortOrder: $order, columnCustomization: $columns) {
            TableColumn("Interface", value: \.name).width(min: 135, ideal: 200).customizationID("name")
            TableColumn("Receive rate", value: \.receiveSort) { Text(Display.rate($0.receiveRate)) }
                .customizationID("receiveRate")
            TableColumn("Send rate", value: \.sendSort) { Text(Display.rate($0.sendRate)) }
                .customizationID("sendRate")
            TableColumn("Bytes received", value: \.received) { Text(Display.bytes($0.received)) }
                .customizationID("received")
            TableColumn("Bytes sent", value: \.sent) { Text(Display.bytes($0.sent)) }
                .customizationID("sent")
        }
    }
}

struct DiskTable: View {
    let rows: [DiskRow]
    @Binding var selection: DiskID?
    @State private var order = [KeyPathComparator(\DiskRow.writeSort, order: .reverse)]
    @AppStorage("columns.disks") private var columns = TableColumnCustomization<DiskRow>()

    var body: some View {
        Table(rows.sorted(using: order + [KeyPathComparator(\DiskRow.name)]), selection: $selection,
              sortOrder: $order, columnCustomization: $columns) {
            TableColumn("Device", value: \.name).width(min: 135, ideal: 200).customizationID("name")
            TableColumn("Read rate", value: \.readSort) { Text(Display.rate($0.readRate)) }
                .customizationID("readRate")
            TableColumn("Write rate", value: \.writeSort) { Text(Display.rate($0.writeRate)) }
                .customizationID("writeRate")
            TableColumn("Bytes read", value: \.readTotalSort) { Text(Display.bytes($0.reading.read)) }
                .customizationID("read")
            TableColumn("Bytes written", value: \.writtenTotalSort) { Text(Display.bytes($0.reading.written)) }
                .customizationID("written")
        }
    }
}

struct ProcessInspector: View {
    let row: ProcessRow
    let tick: Date?
    let sampler: MacSampler
    let pinned: Bool
    let togglePin: () -> Void
    let close: () -> Void
    @State private var resolved: (id: ProcessID, url: URL?)?
    @State private var message: String?

    private var path: URL? { resolved?.id == row.id ? resolved?.url : nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Process inspector").font(.headline)
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark") }.accessibilityLabel("Close inspector")
                }
                Text(row.name).font(.title3.bold()).textSelection(.enabled)
                LabeledContent("PID", value: String(row.pid))
                LabeledContent("Parent PID", value: String(row.parent))
                LabeledContent("User", value: "\(Display.user(row.uid)) (\(row.uid))")
                LabeledContent("CPU", value: Display.percent(row.cpu))
                LabeledContent("Resident memory", value: Display.bytes(row.reading.residentBytes))
                LabeledContent("Threads", value: row.reading.threads.map { String($0) } ?? "—")
                LabeledContent("Started", value: row.id.started.formatted(date: .abbreviated, time: .standard))
                Button(action: togglePin) {
                    Label(pinned ? "Unpin timeline" : "Pin timeline", systemImage: pinned ? "pin.slash" : "pin")
                }
                .help("Keep this instance's CPU timeline above the table, even after it exits")
                Divider()
                Text("Executable").font(.headline)
                Text(path?.path ?? (resolved?.id == row.id ? "Path unavailable" : "Looking up path…"))
                    .font(.callout).textSelection(.enabled)
                Button("Reveal in Finder") {
                    let id = row.id
                    Task { @MainActor in
                        let fresh = await sampler.executable(for: id)
                        guard resolved?.id == id else { return }
                        if let fresh, fresh == path {
                            NSWorkspace.shared.activateFileViewerSelecting([fresh])
                        } else {
                            resolved = (id, fresh)
                            message = "The executable changed or is no longer available."
                        }
                    }
                }
                .disabled(path == nil)
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                QuitButton(row: row, sampler: sampler)
                Divider()
                ProcessDetailsView(id: row.id, tick: tick, sampler: sampler)
            }
            .padding(12)
        }
        .task(id: row.id) {
            let id = row.id
            resolved = nil
            message = nil
            let url = await sampler.executable(for: id)
            guard !Task.isCancelled else { return }
            resolved = (id, url)
        }
    }
}
