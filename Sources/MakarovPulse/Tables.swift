import AppKit
import SwiftUI
import PulseCore
import PulseMac

struct ProcessTable: View {
    let rows: [ProcessRow]
    let details: Bool
    @Binding var selection: ProcessID?
    @State private var processSort = [KeyPathComparator(\ProcessRow.cpuSort, order: .reverse)]
    @State private var detailSort = [KeyPathComparator(\ProcessRow.name)]

    var body: some View {
        if details {
            Table(ordered(detailSort), selection: $selection, sortOrder: $detailSort) {
                TableColumn("Name", value: \.name).width(min: 150, ideal: 220)
                TableColumn("PID", value: \.pid) { Text(String($0.pid)) }.width(min: 45, ideal: 60)
                TableColumn("Parent PID", value: \.parent) { Text(String($0.parent)) }
                TableColumn("UID", value: \.uid) { Text(String($0.uid)) }
                TableColumn("Threads", value: \.threadSort) { Text($0.reading.threads.map { String($0) } ?? "—") }
                TableColumn("Resident memory", value: \.memorySort) { Text(Display.bytes($0.reading.residentBytes)) }
            }
        } else {
            Table(ordered(processSort), selection: $selection, sortOrder: $processSort) {
                TableColumn("Name", value: \.name).width(min: 150, ideal: 235)
                TableColumn("PID", value: \.pid) { Text(String($0.pid)) }.width(min: 45, ideal: 65)
                TableColumn("CPU %", value: \.cpuSort) { Text(Display.percent($0.cpu)) }
                TableColumn("Resident memory", value: \.memorySort) { Text(Display.bytes($0.reading.residentBytes)) }
                TableColumn("Threads", value: \.threadSort) { Text($0.reading.threads.map { String($0) } ?? "—") }
            }
        }
    }

    private func ordered(_ order: [KeyPathComparator<ProcessRow>]) -> [ProcessRow] {
        rows.sorted(using: order + [KeyPathComparator(\ProcessRow.pid)])
    }
}

struct NetworkTable: View {
    let rows: [InterfaceRow]
    @State private var order = [KeyPathComparator(\InterfaceRow.receiveSort, order: .reverse)]
    var body: some View {
        Table(rows.sorted(using: order + [KeyPathComparator(\InterfaceRow.name)]), sortOrder: $order) {
            TableColumn("Interface", value: \.name).width(min: 135, ideal: 200)
            TableColumn("Receive rate", value: \.receiveSort) { Text(Display.rate($0.receiveRate)) }
            TableColumn("Send rate", value: \.sendSort) { Text(Display.rate($0.sendRate)) }
            TableColumn("Bytes received", value: \.received) { Text(Display.bytes($0.received)) }
            TableColumn("Bytes sent", value: \.sent) { Text(Display.bytes($0.sent)) }
        }
    }
}

struct ProcessInspector: View {
    let row: ProcessRow
    let sampler: MacSampler
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
                LabeledContent("UID", value: String(row.uid))
                LabeledContent("CPU", value: Display.percent(row.cpu))
                LabeledContent("Resident memory", value: Display.bytes(row.reading.residentBytes))
                LabeledContent("Threads", value: row.reading.threads.map { String($0) } ?? "—")
                LabeledContent("Started", value: Date(timeIntervalSince1970: Double(row.id.startSeconds))
                    .formatted(date: .abbreviated, time: .standard))
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
