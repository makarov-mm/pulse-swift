import SwiftUI
import PulseCore

private enum Pane: String, CaseIterable, Identifiable {
    case processes = "Processes", tree = "Tree", details = "Details"
    case cores = "Cores", disks = "Disks", network = "Network", folder = "Folder", startup = "Startup"
    case captures = "Captures"

    var listsProcesses: Bool { self == .processes || self == .tree || self == .details }
    var id: Self { self }
}

struct MonitorWindow: View {
    @StateObject private var monitor = Monitor()
    @StateObject private var folder = FolderModel()
    @StateObject private var captures = CaptureModel()
    @State private var pane = Pane.processes
    @State private var query = ""
    @State private var interfaceQuery = ""
    @State private var selected: ProcessID?
    @State private var span: ClosedRange<Date>?
    @State private var diskQuery = ""
    @State private var startupQuery = ""
    @State private var pinnedInterface: InterfaceID?
    @State private var pinnedDisk: DiskID?
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
        .frame(minWidth: 900, minHeight: 510)
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
        if !pane.listsProcesses { pane = .processes }
        query = ""
        selected = id
    }

    private var controls: some View {
        HStack {
            Picker("View", selection: $pane) {
                ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 800)
            Spacer()
            if pane != .cores && pane != .folder && pane != .captures {
                TextField(filterPrompt, text: filterText)
                    .textFieldStyle(.roundedBorder).frame(width: 202)
                    .focused($searching).accessibilityLabel("Filter table")
                Button { searching = true } label: { Image(systemName: "magnifyingglass") }
                    .keyboardShortcut("f", modifiers: .command).help("Find in the current table")
                    .accessibilityLabel("Find")
            }
        }
    }

    private var filterPrompt: String {
        switch pane {
        case .network: return "Find an interface"
        case .disks: return "Find a device"
        case .startup: return "Find a label or program"
        default: return "Find a name or PID"
        }
    }

    private var filterText: Binding<String> {
        switch pane {
        case .network: return $interfaceQuery
        case .disks: return $diskQuery
        case .startup: return $startupQuery
        default: return $query
        }
    }

    private var interfaces: [InterfaceRow] {
        (monitor.snapshot?.interfaces ?? []).filter {
            interfaceQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(interfaceQuery)
        }
    }

    private var disks: [DiskRow] {
        (monitor.snapshot?.disks ?? []).filter {
            diskQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(diskQuery)
        }
    }

    @ViewBuilder private var content: some View {
        switch pane {
        case .network:
            if let id = pinnedInterface {
                let flow = monitor.history.points.flow(\.interfaces, id)
                FlowPanel(title: id.name, incomingLabel: "Receive", outgoingLabel: "Send",
                          incoming: flow.incoming, outgoing: flow.outgoing, window: window,
                          unpin: { pinnedInterface = nil })
            }
            NetworkTable(rows: interfaces, selection: $pinnedInterface)
        case .disks:
            if let id = pinnedDisk {
                let flow = monitor.history.points.flow(\.disks, id)
                FlowPanel(title: id.name, incomingLabel: "Read", outgoingLabel: "Write",
                          incoming: flow.incoming, outgoing: flow.outgoing, window: window,
                          unpin: { pinnedDisk = nil })
            }
            DiskTable(rows: disks, selection: $pinnedDisk)
        case .folder:
            FolderPane(model: folder)
        case .startup:
            StartupPane(query: startupQuery)
        case .captures:
            CapturesPane(model: captures, monitor: monitor)
        case .cores:
            CoreGrid(points: monitor.history.points, latest: monitor.snapshot?.cores ?? [], window: window)
        default:
            HSplitView {
                processList.frame(minWidth: 430)
                if let selected, let row = monitor.snapshot?.processes.first(where: { $0.id == selected }) {
                    ProcessInspector(row: row, tick: monitor.snapshot?.raw.date, sampler: monitor.sampler,
                                     pinned: monitor.history.isPinned(row.id),
                                     togglePin: {
                                         if monitor.history.isPinned(row.id) { monitor.unpin(row.id) }
                                         else { monitor.pin(row) }
                                     },
                                     close: { self.selected = nil })
                        .frame(minWidth: 225, idealWidth: 270, maxWidth: 380)
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
                Text(summary(frame))
                Spacer()
                Text("Updated \(Display.clock(frame.raw.date))")
            } else {
                Text("Collecting the first sample…")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func summary(_ frame: Snapshot) -> String {
        switch pane {
        case .network:
            return frame.raw.interfaces == nil ? "Interface counters unavailable"
                : "\(frame.interfaces.count) readable interfaces · select one to graph receive and send"
        case .disks:
            return frame.raw.disks == nil ? "Storage counters unavailable"
                : "\(frame.disks.count) storage devices · select one to graph read and write"
        case .cores:
            return "\(frame.cores.count) logical cores"
        case .startup:
            return "Job definitions are shown as written on disk · Pulse does not load, edit or remove jobs"
        case .captures:
            return "Captures hold host samples and the busiest processes of each · endpoint addresses are never saved"
        case .folder:
            return "Sizes come from file metadata · links are not followed · other volumes are not entered"
        default:
            guard let total = frame.raw.listedProcesses else { return "Process list unavailable" }
            return "\(processes.count) matching · \(frame.processes.count) readable of \(total) listed"
        }
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
