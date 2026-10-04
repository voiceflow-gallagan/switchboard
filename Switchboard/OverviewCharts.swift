import Charts
import SwiftUI
import SwitchboardCore

/// MCP server memory over the last minutes, stacked per owner. Each run of samples is its own
/// series, so nothing is drawn across the time the window was hidden.
struct LiveMemoryChart: View {
  let history: MemoryHistory
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let points = history.points
    let owners = history.owners
    let labels = Owner.labels(for: owners)
    let series = Self.seriesKeys(points)
    Group {
      if history.samples.count < 3 {
        Text("The chart fills in as samples arrive, one every 5 seconds.")
          .font(.callout)
          .foregroundStyle(Theme.secondaryText)
          .frame(maxWidth: .infinity, minHeight: 140)
      } else {
        Chart(points) { point in
          AreaMark(
            x: .value("Time", point.date),
            y: .value("Memory", Double(point.footprint)),
            stacking: .standard
          )
          .foregroundStyle(by: .value("Series", Self.key(point)))
          .interpolationMethod(.monotone)
          .accessibilityLabel(labels[point.owner] ?? point.owner.title)
          .accessibilityValue(
            "\(Format.memory(point.footprint)) at \(point.date.formatted(date: .omitted, time: .standard))"
          )
        }
        .chartForegroundStyleScale(
          domain: series.map(\.key),
          range: series.map { Palette.color(for: $0.owner).gradient }
        )
        .chartLegend(.hidden)
        .chartXScale(
          domain: Self.domain(history), range: .plotDimension(startPadding: 20, endPadding: 20)
        )
        .chartXAxis {
          AxisMarks(values: .stride(by: .minute, count: Self.minuteStride(history))) { _ in
            AxisGridLine().foregroundStyle(.quaternary)
            AxisValueLabel(
              format: .dateTime.hour().minute(), collisionResolution: .greedy(minimumSpacing: 8)
            )
            .foregroundStyle(Theme.secondaryText)
          }
        }
        .chartYAxis {
          AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
            AxisGridLine().foregroundStyle(.quaternary)
            AxisValueLabel {
              if let bytes = value.as(Double.self) {
                Text(bytes > 0 ? Format.memory(UInt64(bytes)) : "0")
              }
            }
            .foregroundStyle(Theme.secondaryText)
          }
        }
        .frame(height: 150)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: history.samples.count)
        .accessibilityLabel("MCP server memory over the last 10 minutes, by owner")
      }
    }
  }

  /// The time axis covers at least two minutes from the first sample, so the chart fills from
  /// the left instead of squeezing the first samples into a sliver.
  private static func domain(_ history: MemoryHistory) -> ClosedRange<Date> {
    let last = history.samples.last?.date ?? .now
    let first = history.samples.first?.date ?? last
    return first...max(last, first.addingTimeInterval(120))
  }

  private static func minuteStride(_ history: MemoryHistory) -> Int {
    let range = domain(history)
    return range.upperBound.timeIntervalSince(range.lowerBound) > 300 ? 2 : 1
  }

  private static func key(_ point: MemoryHistory.Point) -> String {
    "\(point.segment)|\(point.owner)"
  }

  private static func seriesKeys(_ points: [MemoryHistory.Point]) -> [(key: String, owner: Owner)] {
    var seen: Set<String> = []
    var keys: [(key: String, owner: Owner)] = []
    for point in points where seen.insert(key(point)).inserted {
      keys.append((key(point), point.owner))
    }
    return keys
  }
}

struct OwnerDonut: View {
  let totals: [OwnerTotal]
  let total: UInt64
  /// Draws the glow behind the donut, moving when true. No glow when nil.
  var glowIsAnimated: Bool?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 24) {
        donut
        legend
      }
      VStack(alignment: .leading, spacing: 16) {
        donut
          .frame(maxWidth: .infinity)
        legend
      }
    }
  }

  private var donut: some View {
    let labels = Owner.labels(for: totals.map(\.owner))
    return Chart(totals, id: \.owner) { total in
      SectorMark(
        angle: .value("Memory", Double(total.footprint)),
        innerRadius: .ratio(0.64),
        angularInset: 1.5
      )
      .cornerRadius(5)
      .foregroundStyle(Palette.color(for: total.owner).gradient)
      .accessibilityLabel(labels[total.owner] ?? total.owner.title)
      .accessibilityValue(Format.memory(total.footprint))
    }
    .chartBackground { proxy in
      GeometryReader { geometry in
        if let plot = proxy.plotFrame {
          let frame = geometry[plot]
          VStack(spacing: 0) {
            Text(Format.memory(total))
              .font(.system(.title3, design: .rounded, weight: .bold).monospacedDigit())
            Text("Total")
              .font(.caption)
              .foregroundStyle(Theme.secondaryText)
          }
          .position(x: frame.midX, y: frame.midY)
        }
      }
    }
    .frame(width: 150, height: 150)
    .background {
      if let glowIsAnimated {
        DonutGlow(isAnimated: glowIsAnimated)
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: total)
    .accessibilityLabel("MCP server memory by owner")
  }

  private var legend: some View {
    let labels = Owner.labels(for: totals.map(\.owner))
    return VStack(alignment: .leading, spacing: 10) {
      ForEach(totals, id: \.owner) { total in
        LegendRow(
          color: Palette.color(for: total.owner), title: labels[total.owner] ?? total.owner.title,
          value: Format.memory(total.footprint),
          detail: total.offButRunningFootprint > 0
            ? "A restart frees \(Format.memory(total.offButRunningFootprint))" : nil)
      }
    }
  }
}

struct LegendRow: View {
  let color: Color
  let title: String
  let value: String
  /// Quiet text under the title.
  var detail: String?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Circle()
        .fill(color.gradient)
        .frame(width: 9, height: 9)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .lineLimit(1)
          .minimumScaleFactor(0.85)
          .truncationMode(.tail)
          .help(title)
        if let detail {
          Text(detail)
            .font(.caption)
            .foregroundStyle(Theme.secondaryText)
        }
      }
      .layoutPriority(1)
      Spacer(minLength: 12)
      Text(value)
        .monospacedDigit()
        .fixedSize()
        .foregroundStyle(Theme.secondaryText)
    }
    .font(.callout)
    .accessibilityElement(children: .combine)
  }
}

/// Each disk category's share as one segmented capsule.
struct DiskCapsule: View {
  let sizes: [DiskReport.Category: UInt64]

  var body: some View {
    let categories = DiskReport.Category.allCases.filter { (sizes[$0] ?? 0) > 0 }
    let total = Double(max(categories.reduce(0) { $0 + (sizes[$1] ?? 0) }, 1))
    GeometryReader { geometry in
      let spacing = 2.0
      let usable = geometry.size.width - spacing * Double(max(categories.count - 1, 0))
      HStack(spacing: spacing) {
        ForEach(categories, id: \.self) { category in
          Rectangle()
            .fill((Palette.disk[category] ?? .gray).gradient)
            .frame(width: max(usable * Double(sizes[category] ?? 0) / total, 3))
        }
      }
      .clipShape(Capsule())
    }
    .frame(height: 14)
    .accessibilityHidden(true)
  }
}
