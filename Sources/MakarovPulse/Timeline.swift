import SwiftUI
import PulseCore

/// Ranks the recorded CPU leaders of a graph interval, including processes that have exited.
struct IntervalPanel: View {
    let summary: IntervalSummary
    let running: Set<ProcessID>
    let select: (ProcessID) -> Void
    let clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Selected interval").font(.headline)
                Text(caption)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Clear", action: clear)
            }
            if summary.leaders.isEmpty {
                Text("No process CPU was recorded in this interval.").font(.callout).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                    GridRow {
                        heading("Process"); heading("PID"); heading("Started")
                        heading("Average CPU"); heading("CPU time"); heading("State")
                    }
                    ForEach(summary.leaders.prefix(5)) { item in
                        GridRow {
                            Text(item.name).lineLimit(1)
                            Text(String(item.id.pid)).monospacedDigit()
                            Text(item.id.started.formatted(date: .abbreviated, time: .standard))
                            Text(Display.percent(item.averageCPU)).monospacedDigit()
                            Text(Display.seconds(item.cpuSeconds)).monospacedDigit()
                            if running.contains(item.id) {
                                Button("Select") { select(item.id) }.buttonStyle(.link)
                            } else {
                                Text("Exited").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .font(.callout)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.secondary.opacity(0.25)) }
    }

    private var caption: String {
        let range = Display.clock(summary.start) + " – " + Display.clock(summary.end)
        let measured = Display.seconds(summary.measuredSeconds) + " measured"
        return range + " · " + measured + " · host CPU " + Display.percent(summary.hostCPU)
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

/// CPU timelines of pinned process instances. A series stays after its process exits.
struct PinnedStrip: View {
    let pinned: [PinnedSeries]
    let window: TimeInterval
    let now: Date?
    let select: (ProcessID) -> Void
    let unpin: (ProcessID) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(pinned) { series in card(series) }
            }
        }
    }

    private func card(_ series: PinnedSeries) -> some View {
        let samples = series.samples.map { ChartSample(time: $0.time, value: $0.cpu, breaks: $0.startsSegment) }
        let state = series.exited.map { "exited \(Display.clock($0))" }
            ?? Display.percent(series.samples.last?.cpu)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "pin.fill").foregroundStyle(.secondary)
                Button(series.name) { select(series.id) }
                    .buttonStyle(.plain).lineLimit(1).disabled(series.exited != nil)
                Spacer()
                Button { unpin(series.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).accessibilityLabel("Unpin \(series.name)")
            }
            LineChart(series: [ChartSeries(color: .green, samples: samples)], window: window,
                      now: now, ceiling: max(100, series.samples.compactMap(\.cpu).max() ?? 0))
                .frame(height: 24).accessibilityHidden(true)
            Text("PID \(String(series.id.pid)) · \(state)").font(.caption).foregroundStyle(.secondary)
        }
        .padding(8).frame(width: 230)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.secondary.opacity(0.25)) }
    }
}
