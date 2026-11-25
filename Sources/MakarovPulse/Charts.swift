import SwiftUI

struct ChartSample {
    let time: Date
    let value: Double?
    /// True when this sample must not be joined to the previous one.
    let breaks: Bool
}

struct ChartSeries {
    let color: Color
    let samples: [ChartSample]
}

/// Lines over a trailing time window that ends at `now`.
struct LineChart: View {
    let series: [ChartSeries]
    let window: TimeInterval
    let now: Date?
    let ceiling: Double?
    var band: ClosedRange<Date>?

    var body: some View {
        Canvas { context, size in
            guard let now, window > 0 else { return }
            func x(_ time: Date) -> CGFloat {
                size.width * CGFloat(1 - now.timeIntervalSince(time) / window)
            }
            func visible(_ sample: ChartSample) -> Bool {
                let age = now.timeIntervalSince(sample.time)
                return age >= 0 && age <= window
            }
            if let band {
                let left = max(0, x(band.lowerBound)), right = min(size.width, x(band.upperBound))
                if right > 0, left < size.width {
                    let area = CGRect(x: left, y: 0, width: max(2, right - left), height: size.height)
                    context.fill(Path(area), with: .color(Color.accentColor.opacity(0.2)))
                }
            }
            var peak = 0.0
            for item in series {
                for sample in item.samples where visible(sample) { peak = max(peak, sample.value ?? 0) }
            }
            let top = max(1, ceiling ?? peak)
            for item in series {
                var line = Path()
                var connect = false
                for sample in item.samples {
                    guard visible(sample), let value = sample.value else { connect = false; continue }
                    let position = CGPoint(x: x(sample.time),
                                           y: 1 + (size.height - 2) * CGFloat(1 - min(1, value / top)))
                    if connect && !sample.breaks { line.addLine(to: position) } else { line.move(to: position) }
                    connect = true
                }
                context.stroke(line, with: .color(item.color), lineWidth: 1.75)
            }
        }
    }
}

struct MetricCard: View {
    let title, value, detail: String
    let color: Color
    let samples: [ChartSample]
    let window: TimeInterval
    let ceiling: Double?
    /// When set, dragging across the graph selects a time range.
    var selection: Binding<ClosedRange<Date>?>?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            chart.frame(height: 30).accessibilityHidden(true)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(detail)
        }
        .padding(11).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.secondary.opacity(0.25)) }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var chart: some View {
        let now = samples.last?.time
        let line = LineChart(series: [ChartSeries(color: color, samples: samples)], window: window,
                             now: now, ceiling: ceiling, band: selection?.wrappedValue)
        if let selection, let now {
            line.overlay {
                GeometryReader { geometry in
                    Color.clear.contentShape(Rectangle()).gesture(
                        DragGesture(minimumDistance: 0).onChanged { drag in
                            let width = max(1, geometry.size.width)
                            func time(_ x: CGFloat) -> Date {
                                let fraction = Double(min(1, max(0, x / width)))
                                return now.addingTimeInterval(-window * (1 - fraction))
                            }
                            var first = time(drag.startLocation.x), second = time(drag.location.x)
                            if abs(drag.translation.width) < 3 {
                                // A click selects a short span around the pointer.
                                first = first.addingTimeInterval(-window / 40)
                                second = second.addingTimeInterval(window / 40)
                            }
                            selection.wrappedValue = min(first, second)...max(first, second)
                        })
                }
            }
            .help("Drag across the graph to rank the processes in that interval")
        } else {
            line
        }
    }
}
