import AppKit
import SwiftUI
import PulseCore
import PulseMac

/// Threads, descriptors and internet sockets of the selected instance, refreshed with every sample.
struct ProcessDetailsView: View {
    let id: ProcessID
    let tick: Date?
    let sampler: MacSampler
    @State private var details: ProcessDetails?
    @State private var loaded: ProcessID?

    private struct Key: Hashable {
        let id: ProcessID
        let tick: Date?
    }

    /// Results of another instance are never shown, even while a slow read is in flight.
    private var current: ProcessDetails? { details?.id == id ? details : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let current {
                threads(current)
                Divider()
                descriptors(current)
                Divider()
                sockets(current)
            } else {
                Text(loaded == id ? "This process does not allow inspection." : "Reading threads and sockets…")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .task(id: Key(id: id, tick: tick)) {
            let wanted = id
            let fresh = await sampler.details(for: wanted)
            guard !Task.isCancelled, wanted == id else { return }
            details = fresh
            loaded = wanted
        }
    }

    @ViewBuilder private func threads(_ details: ProcessDetails) -> some View {
        Text("Threads").font(.headline)
        if let threads = details.threads {
            ForEach(busiest(threads)) { thread in
                HStack {
                    Text(thread.name.isEmpty ? "Thread \(thread.number)" : thread.name).lineLimit(1)
                    Spacer()
                    Text("\(thread.state) · \(Display.percent(thread.cpu))").foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            if threads.count > 8 {
                Text("\(threads.count - 8) more threads").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("Threads are not readable for this process.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func busiest(_ threads: [ThreadDetail]) -> [ThreadDetail] {
        let ordered = threads.sorted { (a: ThreadDetail, b: ThreadDetail) -> Bool in
            if a.cpu == b.cpu { return a.id < b.id }
            return a.cpu > b.cpu
        }
        return Array(ordered.prefix(8))
    }

    @ViewBuilder private func descriptors(_ details: ProcessDetails) -> some View {
        Text("Open descriptors").font(.headline)
        if let kinds = details.descriptors {
            Text(kinds.isEmpty ? "None" : kinds.map { "\($0.kind) \($0.count)" }.joined(separator: " · "))
                .font(.callout).textSelection(.enabled)
        } else {
            Text("Descriptors are not readable for this process.").font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func sockets(_ details: ProcessDetails) -> some View {
        Text("Internet sockets").font(.headline)
        if details.sockets.isEmpty {
            Text(details.descriptors == nil ? "Not readable" : "None").font(.callout).foregroundStyle(.secondary)
        }
        ForEach(details.sockets.prefix(12)) { socket in
            VStack(alignment: .leading, spacing: 1) {
                Text("\(socket.transport) \(socket.family)\(socket.state.isEmpty ? "" : " · " + socket.state)")
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(socket.local) → \(socket.remote)").font(.callout).textSelection(.enabled)
            }
        }
        if details.sockets.count > 12 {
            Text("\(details.sockets.count - 12) more sockets").font(.caption).foregroundStyle(.secondary)
        }
        if details.partial {
            Text("Partial snapshot: some descriptors closed or refused inspection during the read.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Text("A snapshot can miss short-lived sockets. Traffic rates stay per interface.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// Asks an app of the current user to quit, the way its Quit menu command would.
struct QuitButton: View {
    let row: ProcessRow
    let sampler: MacSampler
    @State private var confirming = false
    @State private var message: String?

    /// Only regular apps owned by the current user. An app registers with the system some time after
    /// its process starts, so a launch date before the process start means the PID changed hands.
    private var application: NSRunningApplication? {
        guard row.uid == getuid(), let app = NSRunningApplication(processIdentifier: row.pid),
              app.activationPolicy == .regular, !app.isTerminated,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        if let launched = app.launchDate, launched.timeIntervalSince(row.id.started) < -5 { return nil }
        return app
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Quit App…") { confirming = true }
                .disabled(application == nil)
                .help("Available for apps you own. The app can ask to save changes or refuse.")
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .confirmationDialog("Quit \(row.name)?", isPresented: $confirming) {
            Button("Quit", role: .destructive) { quit() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pulse asks PID \(String(row.pid)) to quit normally. Unsaved changes are the app's to handle.")
        }
        .onChange(of: row.id) { _, _ in message = nil }
    }

    private func quit() {
        let id = row.id
        Task { @MainActor in
            // Identity is checked again right before acting. A reused PID is rejected.
            guard await sampler.isCurrent(id), id == row.id, let app = application else {
                message = "The process changed or exited. Nothing was sent."
                return
            }
            message = app.terminate() ? "Quit requested." : "The app refused the request."
        }
    }
}

/// Read-only list of launchd job definitions.
struct StartupPane: View {
    let query: String
    @State private var items: [LaunchItem] = []
    @State private var loaded = false
    @State private var selection: String?
    @State private var order = [KeyPathComparator(\LaunchItem.domain)]

    private var rows: [LaunchItem] {
        items.filter {
            query.isEmpty || $0.label.localizedCaseInsensitiveContains(query)
                || $0.program.localizedCaseInsensitiveContains(query)
        }
        .sorted(using: order + [KeyPathComparator(\LaunchItem.label)])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(loaded ? "\(rows.count) launchd job definitions, read-only" : "Reading job definitions…")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reload") { Task { await load() } }
                Button("Reveal in Finder") {
                    if let item = items.first(where: { $0.id == selection }) {
                        NSWorkspace.shared.activateFileViewerSelecting([item.file])
                    }
                }
                .disabled(selection == nil)
                Button("Open Login Items Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .help("Login items and background items are managed by macOS")
            }
            Table(rows, selection: $selection, sortOrder: $order) {
                TableColumn("Label", value: \.label) { Text($0.label).lineLimit(1).help($0.label) }
                    .width(min: 180, ideal: 280)
                TableColumn("Domain", value: \.domain).width(min: 90, ideal: 120)
                TableColumn("Program", value: \.program) { Text($0.program).lineLimit(1).help($0.program) }
                    .width(min: 180, ideal: 320)
                TableColumn("Run at load") { (item: LaunchItem) in Text(item.runAtLoad ? "Yes" : "No") }
                TableColumn("Disabled key") { (item: LaunchItem) in Text(item.disabled ? "Yes" : "No") }
            }
        }
        .task { await load() }
    }

    private func load() async {
        let fresh = await Task.detached(priority: .utility) { LaunchItems.read() }.value
        items = fresh
        loaded = true
    }
}
