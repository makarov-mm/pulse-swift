import SwiftUI
import PulseCore

/// One small graph per logical core, in the kernel's processor order.
struct CoreGrid: View {
    let points: [HistoryPoint]
    let latest: [Double?]
    let window: TimeInterval

    var body: some View {
        if latest.isEmpty {
            Text("Per-core counters are unavailable.").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(latest.indices, id: \.self) { core in
                        MetricCard(title: "Core \(core)", value: Display.percent(latest[core]),
                                   detail: "Busy share of this logical core", color: .accentColor,
                                   samples: samples(core), window: window, ceiling: 100,
                                   spoken: { Display.percent($0) })
                    }
                }
            }
        }
    }

    private func samples(_ core: Int) -> [ChartSample] {
        points.map {
            ChartSample(time: $0.time, value: core < $0.cores.count ? $0.cores[core] : nil,
                        breaks: $0.startsSegment)
        }
    }
}

/// Two directional rates of one pinned device over the history window.
struct FlowPanel: View {
    let title: String
    let incomingLabel, outgoingLabel: String
    let incoming, outgoing: [ChartSample]
    let window: TimeInterval
    let unpin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                Text(title).font(.headline)
                legend(incomingLabel, .blue, incoming)
                legend(outgoingLabel, .orange, outgoing)
                Spacer()
                Button(action: unpin) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).accessibilityLabel("Close \(title) graph")
            }
            LineChart(series: [ChartSeries(color: .blue, samples: incoming),
                               ChartSeries(color: .orange, samples: outgoing)],
                      window: window, now: incoming.last?.time, ceiling: nil)
                .frame(height: 54).accessibilityHidden(true)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.secondary.opacity(0.25)) }
    }

    private func legend(_ label: String, _ color: Color, _ samples: [ChartSample]) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(label) \(Display.rate(samples.last?.value))").font(.callout).monospacedDigit()
        }
    }
}

extension Array where Element == HistoryPoint {
    /// Rate series of one device. A sample that follows a gap or the device's absence starts a new segment.
    func flow<ID>(_ field: KeyPath<HistoryPoint, [Flow<ID>]>, _ id: ID)
        -> (incoming: [ChartSample], outgoing: [ChartSample]) {
        var incoming: [ChartSample] = [], outgoing: [ChartSample] = []
        var present = false
        for point in self {
            let flow = point[keyPath: field].first { $0.id == id }
            let breaks = point.startsSegment || !present
            incoming.append(ChartSample(time: point.time, value: flow?.incoming, breaks: breaks))
            outgoing.append(ChartSample(time: point.time, value: flow?.outgoing, breaks: breaks))
            present = flow != nil
        }
        return (incoming, outgoing)
    }
}
