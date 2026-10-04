import SwiftUI
import SwitchboardCore

struct OverviewView: View {
  let usage: UsageStore
  /// Whether the glow behind the donut moves. False while the window is not on screen.
  let isGlowAnimated: Bool
  @State private var showsAllServers = false
  /// The servers listed before "Show all", so the page fits on one screen.
  private static let shownServers = 6

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        header
        if let report = usage.report {
          if usage.isClaudeRunning {
            hero(report)
            ViewThatFits(in: .horizontal) {
              HStack(alignment: .top, spacing: 14) {
                servers(usage.serverChart, bars: usage.serverBars)
                  .frame(minWidth: 380)
                disk
                  .frame(minWidth: 320)
              }
              .fixedSize(horizontal: false, vertical: true)
              VStack(spacing: 14) {
                servers(usage.serverChart, bars: usage.serverBars)
                disk
              }
            }
          } else {
            Card("") {
              Text("No Claude app is running, so there is no memory to show.")
                .foregroundStyle(Theme.secondaryText)
            }
            disk
          }
        } else {
          Card("") {
            ProgressView("Measuring memory")
              .frame(maxWidth: .infinity)
          }
          disk
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 16)
    }
    .scrollContentBackground(.hidden)
    .onAppear(perform: usage.scanDiskIfNeeded)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Memory")
        .font(.system(size: 34, weight: .bold, design: .rounded))
        .accessibilityAddTraits(.isHeader)
      Text(
        "What the MCP servers of Claude Desktop and Claude Code use on this Mac now, and what they keep on disk."
      )
      .foregroundStyle(Theme.secondaryText)
    }
    .padding(.horizontal, 4)
  }

  /// The total and the live chart, with memory by owner beside them, or below them when the
  /// window is narrow.
  private func hero(_ report: MemoryReport) -> some View {
    Card("") {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 28) {
          figures(report)
            .frame(minWidth: 420)
          owners(report)
            .frame(width: 440)
        }
        VStack(alignment: .leading, spacing: 18) {
          figures(report)
          owners(report)
        }
      }
    }
  }

  private func figures(_ report: MemoryReport) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text("MCP server memory now")
          .font(.headline)
          .foregroundStyle(Theme.secondaryText)
        Text(Format.memory(report.totalFootprint))
          .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
          .contentTransition(.numericText())
        if let change = Self.change(in: usage.history) {
          MemoryChange(bytes: change)
        }
        HStack(spacing: 12) {
          Text(
            "\(report.usages.reduce(0) { $0 + $1.processCount }) processes in \(report.usages.count) server groups"
          )
          if let sampledAt = usage.sampledAt {
            Text("Sampled at \(sampledAt.formatted(date: .omitted, time: .standard))")
          }
        }
        .font(.callout)
        .foregroundStyle(Theme.secondaryText)
        if report.offButRunningFootprint > 0 {
          Text(
            "\(Format.memory(report.offButRunningFootprint)) is held by switched-off servers that still run. Restarting their app or session frees it."
          )
          .font(.callout)
          .foregroundStyle(Theme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
      .accessibilityElement(children: .combine)
      LiveMemoryChart(history: usage.history)
        .padding(.top, 10)
    }
  }

  private func owners(_ report: MemoryReport) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("MCP servers by owner")
        .font(.headline)
      OwnerDonut(
        totals: report.ownerTotals, total: report.totalFootprint, glowIsAnimated: isGlowAnimated)
      if report.ownerTotals.contains(where: { $0.owner == .orphaned }) {
        Text("Orphaned servers are still running after the session that started them exited.")
          .font(.caption)
          .foregroundStyle(Theme.secondaryText)
      }
      Text("The Claude apps' own memory is not included.")
        .font(.caption)
        .foregroundStyle(Theme.secondaryText)
    }
  }

  private func servers(_ chart: ServerChart?, bars: [ServerBar]) -> some View {
    Card("Most expensive servers") {
      ServerBars(bars: showsAllServers ? bars : Array(bars.prefix(Self.shownServers)))
      if bars.count > Self.shownServers {
        Button {
          withAnimation(.snappy) { showsAllServers.toggle() }
        } label: {
          Label(
            showsAllServers ? "Show fewer" : "Show all \(bars.count)",
            systemImage: showsAllServers ? "chevron.up" : "chevron.down")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .foregroundStyle(Theme.secondaryText)
      }
      if chart?.top.contains(where: \.isExtensionHosts) == true {
        Text("Desktop extensions share their processes, so they cannot be told apart.")
          .font(.caption)
          .foregroundStyle(Theme.secondaryText)
      }
      if let unmatched = chart?.unmatched {
        DisclosureGroup("Unmatched groups") {
          Text(unmatched.labels.joined(separator: ", "))
            .foregroundStyle(Theme.secondaryText)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
      }
    }
  }

  private var disk: some View {
    Card("Disk") {
      if usage.isScanning {
        HStack(spacing: 6) {
          ProgressView()
            .controlSize(.small)
          Text("Scanning")
            .foregroundStyle(Theme.secondaryText)
        }
        .font(.callout)
      }
    } content: {
      if let disk = usage.disk {
        Text("\(Format.file(disk.sizes.values.reduce(0, +))) in total")
          .font(.system(.title3, design: .rounded, weight: .bold).monospacedDigit())
        DiskCapsule(sizes: disk.sizes)
        VStack(alignment: .leading, spacing: 8) {
          ForEach(DiskReport.Category.allCases, id: \.self) { category in
            LegendRow(
              color: Palette.disk[category] ?? .gray, title: category.title,
              value: Format.file(disk.sizes[category] ?? 0))
          }
        }
        Text("\(disk.linkedSkills) skills are links and count as zero.")
          .font(.caption)
          .foregroundStyle(Theme.secondaryText)
      } else if !usage.isScanning {
        Text("Not scanned yet.")
          .foregroundStyle(Theme.secondaryText)
      }
    }
  }

  /// The total of the last sample minus the total of the one before it, in bytes.
  private static func change(in history: MemoryHistory) -> Int64? {
    let samples = history.samples.suffix(2)
    guard samples.count == 2, let previous = samples.first, let last = samples.last else {
      return nil
    }
    func total(_ sample: MemoryHistory.Sample) -> Int64 {
      sample.footprints.values.reduce(0) { $0 + Int64(clamping: $1) }
    }
    return total(last) - total(previous)
  }
}

/// The change in total memory since the previous sample, in words and with an arrow, coloured
/// green when it went down and red when it went up. A change under 1 MB reads as unchanged, in
/// the quiet style, because the total moves by a few kilobytes between any two samples.
private struct MemoryChange: View {
  let bytes: Int64
  private static let smallest: UInt64 = 1 << 20

  var body: some View {
    let amount = Format.memory(bytes.magnitude)
    if bytes.magnitude < Self.smallest {
      Label("Unchanged since the previous sample", systemImage: "equal")
        .font(.callout)
        .foregroundStyle(Theme.secondaryText)
    } else if bytes < 0 {
      Label("Down \(amount) since the previous sample", systemImage: "arrow.down")
        .font(.callout.weight(.semibold))
        .foregroundStyle(Theme.decrease)
    } else {
      Label("Up \(amount) since the previous sample", systemImage: "arrow.up")
        .font(.callout.weight(.semibold))
        .foregroundStyle(Theme.increase)
    }
  }
}
