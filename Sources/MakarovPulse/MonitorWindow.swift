import SwiftUI
import PulseCore

private enum Pane: String, CaseIterable, Identifiable {
    case processes = "Processes", details = "Details", network = "Network"
    var id: Self { self }
}

struct MonitorWindow: View {
    @StateObject private var monitor = Monitor()
    @State private var pane = Pane.processes
    @State private var query = ""
    @State private var interfaceQuery = ""
    @State private var selected: ProcessID?
    @FocusState private var searching: Bool

    private var processes: [ProcessRow] {
        (monitor.snapshot?.processes ?? []).filter { ProcessSearch.matches($0, text: query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("System overview").font(.largeTitle.weight(.semibold))
                Spacer()
                if monitor.paused { Label("Paused", systemImage: "pause.fill").foregroundStyle(.secondary) }
            }
            overview
            HStack {
                Picker("View", selection: $pane) {
                    ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 365)
                Spacer()
                TextField(pane == .network ? "Find an interface" : "Find a name or PID",
                          text: pane == .network ? $interfaceQuery : $query)
                    .textFieldStyle(.roundedBorder).frame(width: 202)
                    .focused($searching).accessibilityLabel("Filter table")
                Button { searching = true } label: { Image(systemName: "magnifyingglass") }
                    .keyboardShortcut("f", modifiers: .command).help("Find in the current table")
                    .accessibilityLabel("Find")
            }
            if pane == .network {
                NetworkTable(rows: (monitor.snapshot?.interfaces ?? []).filter {
                    interfaceQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(interfaceQuery)
                })
            } else {
                HSplitView {
                    ProcessTable(rows: processes, details: pane == .details, selection: $selected)
                        .frame(minWidth: 430)
                    if let selected, let row = monitor.snapshot?.processes.first(where: { $0.id == selected }) {
                        ProcessInspector(row: row, sampler: monitor.sampler) { self.selected = nil }
                            .frame(minWidth: 205, idealWidth: 235, maxWidth: 320)
                    }
                }
            }
            HStack {
                if let frame = monitor.snapshot {
                    if pane == .network {
                        Text(frame.raw.interfaces == nil ? "Interface counters unavailable" : "\(frame.interfaces.count) readable interfaces")
                    } else if let total = frame.raw.listedProcesses {
                        Text("\(processes.count) shown · \(frame.processes.count) readable of \(total) listed")
                    } else { Text("Process list unavailable") }
                    Spacer()
                    Text("Updated \(frame.raw.date.formatted(date: .omitted, time: .standard))")
                } else {
                    Text("Collecting the first sample…")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(minWidth: 840, minHeight: 510)
        .toolbar {
            Picker("Refresh interval", selection: $monitor.interval) {
                ForEach([1, 2, 5], id: \.self) { Text("\($0) s").tag($0) }
            }
            .help("Sampling interval")
            Button {
                monitor.paused.toggle()
            } label: {
                Label(monitor.paused ? "Resume" : "Pause",
                      systemImage: monitor.paused ? "play.fill" : "pause.fill")
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
        }
        .task(id: monitor.paused ? 0 : monitor.interval) { await monitor.run() }
        .onChange(of: monitor.snapshot?.raw.date) { _, _ in
            if let selected, monitor.snapshot?.processes.contains(where: { $0.id == selected }) != true {
                self.selected = nil
            }
        }
    }

    private var overview: some View {
        let raw = monitor.snapshot?.raw
        let points = monitor.history.points
        let fastest = monitor.busiest
        return HStack(spacing: 10) {
            MetricCard(title: "CPU", value: Display.percent(monitor.snapshot?.hostCPU),
                       detail: "Whole machine", color: .accentColor, points: points, field: \.cpu, ceiling: 100)
            MetricCard(title: "Wired memory", value: Display.bytes(raw?.wiredBytes),
                       detail: "of \(Display.bytes(raw?.totalRAM)) RAM", color: .purple,
                       points: points, field: \.wired, ceiling: raw.map { Double($0.totalRAM) })
            MetricCard(title: "Disk space", value: Display.bytes(raw?.volumeFreeBytes),
                       detail: "Available on startup data volume", color: .teal, points: points,
                       field: \.volumeFree, ceiling: raw?.volumeTotalBytes.map { Double($0) })
            MetricCard(title: "Network", value: Display.rate(fastest?.combinedRate),
                       detail: fastest.map { "\($0.name) · receive + send" } ?? "Waiting for rates",
                       color: .orange, points: points, field: \.network, ceiling: nil)
        }
    }
}

private struct MetricCard: View {
    let title, value, detail: String
    let color: Color
    let points: [HistoryPoint]
    let field: KeyPath<HistoryPoint, Double?>
    let ceiling: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Canvas { context, size in
                guard let last = points.last else { return }
                let maxY = max(1, ceiling ?? points.compactMap { $0[keyPath: field] }.max() ?? 1)
                var line = Path()
                var connect = false
                var priorInterface: InterfaceID?
                for point in points {
                    guard let y = point[keyPath: field] else { connect = false; continue }
                    let x = 1 - last.time.timeIntervalSince(point.time) / 60
                    let position = CGPoint(x: size.width * CGFloat(x),
                                           y: 1 + (size.height - 2) * CGFloat(1 - min(1, y / maxY)))
                    let changed = field == \HistoryPoint.network && point.networkID != priorInterface
                    if connect && !point.startsSegment && !changed { line.addLine(to: position) }
                    else { line.move(to: position) }
                    priorInterface = point.networkID
                    connect = true
                }
                context.stroke(line, with: .color(color), lineWidth: 1.75)
            }
            .frame(height: 30).accessibilityHidden(true)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(detail)
        }
        .padding(11).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.secondary.opacity(0.25)) }
        .accessibilityElement(children: .combine)
    }
}
