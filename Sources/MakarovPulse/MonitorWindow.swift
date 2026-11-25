import SwiftUI
import PulseCore

private enum Pane: String, CaseIterable, Identifiable {
    case processes = "Processes", tree = "Tree", details = "Details", network = "Network"
    var id: Self { self }
}

struct MonitorWindow: View {
    @StateObject private var monitor = Monitor()
    @State private var pane = Pane.processes
    @State private var query = ""
    @State private var interfaceQuery = ""
    @State private var selected: ProcessID?
    @State private var span: ClosedRange<Date>?
    @FocusState private var searching: Bool

    private var processes: [ProcessRow] {
        (monitor.snapshot?.processes ?? []).filter { ProcessSearch.matches($0, text: query) }
    }

    private var window: TimeInterval { TimeInterval(monitor.window) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("System overview").font(.largeTitle.weight(.semibold))
                Spacer()
                if monitor.paused { Label("Paused", systemImage: "pause.fill").foregroundStyle(.secondary) }
            }
            overview
            if let span {
                IntervalPanel(summary: monitor.history.summary(from: span.lowerBound, to: span.upperBound),
                              running: Set((monitor.snapshot?.processes ?? []).map(\.id)),
                              select: { show($0) }, clear: { self.span = nil })
            }
            if !monitor.history.pinned.isEmpty {
                PinnedStrip(pinned: monitor.history.pinned, window: window,
                            now: monitor.history.points.last?.time,
                            select: { show($0) }, unpin: { monitor.unpin($0) })
            }
            controls
            content
            status
        }
        .padding(18)
        .frame(minWidth: 840, minHeight: 510)
        .toolbar {
            Picker("History", selection: $monitor.window) {
                Text("1 min").tag(60)
                Text("5 min").tag(300)
                Text("15 min").tag(900)
            }
            .help("Time span of the graphs")
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

    private func show(_ id: ProcessID) {
        if pane == .network { pane = .processes }
        query = ""
        selected = id
    }

    private var controls: some View {
        HStack {
            Picker("View", selection: $pane) {
                ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 420)
            Spacer()
            TextField(pane == .network ? "Find an interface" : "Find a name or PID",
                      text: pane == .network ? $interfaceQuery : $query)
                .textFieldStyle(.roundedBorder).frame(width: 202)
                .focused($searching).accessibilityLabel("Filter table")
            Button { searching = true } label: { Image(systemName: "magnifyingglass") }
                .keyboardShortcut("f", modifiers: .command).help("Find in the current table")
                .accessibilityLabel("Find")
        }
    }

    @ViewBuilder private var content: some View {
        if pane == .network {
            NetworkTable(rows: (monitor.snapshot?.interfaces ?? []).filter {
                interfaceQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(interfaceQuery)
            })
        } else {
            HSplitView {
                processList.frame(minWidth: 430)
                if let selected, let row = monitor.snapshot?.processes.first(where: { $0.id == selected }) {
                    ProcessInspector(row: row, sampler: monitor.sampler,
                                     pinned: monitor.history.isPinned(row.id),
                                     togglePin: {
                                         if monitor.history.isPinned(row.id) { monitor.unpin(row.id) }
                                         else { monitor.pin(row) }
                                     },
                                     close: { self.selected = nil })
                        .frame(minWidth: 205, idealWidth: 235, maxWidth: 320)
                }
            }
        }
    }

    @ViewBuilder private var processList: some View {
        if pane == .tree {
            ProcessTreeTable(nodes: ProcessTree.build(monitor.snapshot?.processes ?? [], matching: query),
                             filtering: !query.trimmingCharacters(in: .whitespaces).isEmpty,
                             selection: $selected)
        } else {
            ProcessTable(rows: processes, details: pane == .details, selection: $selected)
        }
    }

    private var status: some View {
        HStack {
            if let frame = monitor.snapshot {
                if pane == .network {
                    Text(frame.raw.interfaces == nil ? "Interface counters unavailable"
                         : "\(frame.interfaces.count) readable interfaces")
                } else if let total = frame.raw.listedProcesses {
                    Text("\(processes.count) matching · \(frame.processes.count) readable of \(total) listed")
                } else {
                    Text("Process list unavailable")
                }
                Spacer()
                Text("Updated \(Display.clock(frame.raw.date))")
            } else {
                Text("Collecting the first sample…")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func samples(_ field: KeyPath<HistoryPoint, Double?>) -> [ChartSample] {
        monitor.history.points.map {
            ChartSample(time: $0.time, value: $0[keyPath: field], breaks: $0.startsSegment)
        }
    }

    /// The network graph follows the busiest interface, so it also breaks when that interface changes.
    private var networkSamples: [ChartSample] {
        var prior: InterfaceID?
        return monitor.history.points.map { point in
            defer { prior = point.networkID }
            return ChartSample(time: point.time, value: point.network,
                               breaks: point.startsSegment || point.networkID != prior)
        }
    }

    private var overview: some View {
        let raw = monitor.snapshot?.raw
        let fastest = monitor.busiest
        return HStack(spacing: 10) {
            MetricCard(title: "CPU", value: Display.percent(monitor.snapshot?.hostCPU),
                       detail: "Whole machine · drag to inspect an interval", color: .accentColor,
                       samples: samples(\.cpu), window: window, ceiling: 100, selection: $span)
            MetricCard(title: "Wired memory", value: Display.bytes(raw?.wiredBytes),
                       detail: "of \(Display.bytes(raw?.totalRAM)) RAM", color: .purple,
                       samples: samples(\.wired), window: window, ceiling: raw.map { Double($0.totalRAM) })
            MetricCard(title: "Disk space", value: Display.bytes(raw?.volumeFreeBytes),
                       detail: "Available on startup data volume", color: .teal,
                       samples: samples(\.volumeFree), window: window,
                       ceiling: raw?.volumeTotalBytes.map { Double($0) })
            MetricCard(title: "Network", value: Display.rate(fastest?.combinedRate),
                       detail: fastest.map { "\($0.name) · receive + send" } ?? "Waiting for rates",
                       color: .orange, samples: networkSamples, window: window, ceiling: nil)
        }
    }
}
