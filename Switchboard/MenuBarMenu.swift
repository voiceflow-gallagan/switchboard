import AppKit
import SwiftUI
import SwitchboardCore

/// The menu bar item: a memory chip and the total MCP server memory, such as "4,0 GB".
struct MenuBarLabel: View {
  let usage: UsageStore

  var body: some View {
    let total =
      usage.isClaudeRunning ? usage.report.map { Format.compactMemory($0.totalFootprint) } : nil
    HStack(spacing: 4) {
      Image(systemName: "memorychip")
      Text(total ?? "–")
    }
    .accessibilityLabel("MCP server memory, \(total ?? "not measured")")
  }
}

/// The menu bar item's menu: the total, one line per owner, when it was sampled, then Open and
/// Quit.
struct MenuBarMenu: View {
  let usage: UsageStore
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    if let report = usage.report, usage.isClaudeRunning {
      Text("MCP server memory: \(Format.memory(report.totalFootprint))")
      let labels = Owner.labels(for: report.ownerTotals.map(\.owner))
      ForEach(report.ownerTotals, id: \.owner) { total in
        Text("\(labels[total.owner] ?? total.owner.title): \(Format.memory(total.footprint))")
      }
    } else if usage.report != nil {
      Text("No Claude app is running")
    } else {
      Text("Measuring memory")
    }
    if let sampledAt = usage.sampledAt {
      Text("Sampled at \(sampledAt.formatted(date: .omitted, time: .standard))")
    }
    Divider()
    Button("Open Switchboard") {
      openWindow(id: "main")
      NSApp.activate()
    }
    Button("Quit Switchboard") {
      NSApp.terminate(nil)
    }
    .keyboardShortcut("q")
  }
}

extension Format {
  /// One decimal in gigabytes, whole megabytes below a gigabyte, such as "4,0 GB" or "512 MB".
  static func compactMemory(_ bytes: UInt64) -> String {
    let gigabytes = Double(bytes) / 1_073_741_824
    if gigabytes >= 1 {
      return "\(gigabytes.formatted(.number.precision(.fractionLength(1)))) GB"
    }
    let megabytes = Double(bytes) / 1_048_576
    return "\(megabytes.formatted(.number.precision(.fractionLength(0)))) MB"
  }
}
