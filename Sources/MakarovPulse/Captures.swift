import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PulseCore

@MainActor
final class CaptureModel: ObservableObject {
    struct Loaded {
        let name: String
        let capture: Capture
        let history: History
    }

    @Published private(set) var first: Loaded?
    @Published private(set) var second: Loaded?
    @Published var note: String?

    func open(asSecond: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = asSecond ? "Choose a capture to compare with" : "Choose a Pulse capture"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let capture = try Capture.decode(try Data(contentsOf: url))
            let loaded = Loaded(name: url.lastPathComponent, capture: capture, history: History(replaying: capture))
            if asSecond { second = loaded } else { first = loaded }
            note = capture.samples.isEmpty ? "\(url.lastPathComponent) contains no samples." : nil
        } catch CaptureError.unsupportedSchema(let version) {
            note = "\(url.lastPathComponent) uses capture format \(version). This version reads format \(Capture.currentSchema)."
        } catch CaptureError.unreadable {
            note = "\(url.lastPathComponent) is incomplete or is not a Pulse capture."
        } catch {
            note = "\(url.lastPathComponent) could not be read."
        }
    }

    func close() {
        first = nil
        second = nil
        note = nil
    }

    func save(_ capture: Capture) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let stamp = capture.exported.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        panel.nameFieldStringValue = "Pulse capture \(stamp).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try capture.encoded().write(to: url, options: .atomic)
            note = "Saved \(capture.samples.count) samples to \(url.lastPathComponent)."
        } catch {
            note = "The capture could not be saved."
        }
    }
}

/// Export the live history, replay a saved capture offline, and compare two runs.
struct CapturesPane: View {
    @ObservedObject var model: CaptureModel
    @ObservedObject var monitor: Monitor
    @AppStorage("capture.includePaths") private var includePaths = false
    @State private var span: ClosedRange<Date>?
    @State private var order = [KeyPathComparator(\ComparisonRow.secondSort, order: .reverse)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Export Live History…") {
                    Task { model.save(await monitor.capture(includePaths: includePaths)) }
                }
                .disabled(monitor.history.points.isEmpty)
                Toggle("Include executable paths", isOn: $includePaths)
                    .help("Off by default. Paths can reveal user names and installed software. Endpoint addresses are never saved.")
                Spacer()
                Button("Open Capture…") { span = nil; model.open(asSecond: false) }
                Button("Compare With…") { model.open(asSecond: true) }.disabled(model.first == nil)
                Button("Close") { span = nil; model.close() }.disabled(model.first == nil)
            }
            if let note = model.note { Text(note).font(.callout).foregroundStyle(.secondary) }
            if let first = model.first {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        replay(first)
                        if let second = model.second { comparison(first, second) }
                    }
                }
            } else {
                Text("Export the last 15 minutes, or open a capture to rank its processes without live access.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func describe(_ loaded: CaptureModel.Loaded) -> String {
        let capture = loaded.capture, machine = capture.machine
        return "\(loaded.name) · \(machine.model ?? "Mac") \(machine.architecture) · \(machine.logicalCores) cores · macOS \(machine.osVersion) · every \(capture.intervalSeconds.formatted()) s · \(Display.seconds(capture.measuredSeconds)) measured · \(capture.samples.filter(\.gap).count) gaps"
    }

    @ViewBuilder private func replay(_ loaded: CaptureModel.Loaded) -> some View {
        let points = loaded.history.points
        let start = loaded.history.startTime ?? .distantPast, end = points.last?.time ?? .distantFuture
        Text(describe(loaded)).font(.callout).textSelection(.enabled)
        MetricCard(title: "Host CPU", value: Display.percent(loaded.history.summary(from: start, to: end).hostCPU),
                   detail: "Average of the whole capture · drag to rank an interval", color: .accentColor,
                   samples: points.map { ChartSample(time: $0.time, value: $0.cpu, breaks: $0.startsSegment) },
                   window: max(1, end.timeIntervalSince(start)), ceiling: 100, selection: $span)
        IntervalPanel(summary: loaded.history.summary(from: span?.lowerBound ?? start, to: span?.upperBound ?? end),
                      running: [], select: { _ in }, clear: { span = nil })
    }

    @ViewBuilder private func comparison(_ first: CaptureModel.Loaded, _ second: CaptureModel.Loaded) -> some View {
        Divider()
        Text("Compared with").font(.headline)
        Text(describe(second)).font(.callout).textSelection(.enabled)
        ForEach(CaptureComparison.notes(first.capture, second.capture), id: \.self) { note in
            Label(note, systemImage: "exclamationmark.triangle").font(.callout)
        }
        Table(CaptureComparison.rows(first.capture, second.capture).sorted(using: order), sortOrder: $order) {
            TableColumn("Process name", value: \.name).width(min: 180, ideal: 280)
            TableColumn("First run", value: \.firstSort) { Text(Display.percent($0.first)) }
            TableColumn("Second run", value: \.secondSort) { Text(Display.percent($0.second)) }
            TableColumn("Change", value: \.changeSort) { row in
                Text(row.changeSort.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always())))
            }
        }
        .frame(minHeight: 220)
        Text("Average percent of one logical core over each run's measured time, by process name.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
