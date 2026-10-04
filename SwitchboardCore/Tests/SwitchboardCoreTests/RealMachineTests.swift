import Foundation
import Testing

@testable import SwitchboardCore

/// Runs on the real machine only with `SWITCHBOARD_REAL_HOME=1`. Prints counts, durations,
/// byte totals, labels, and folder names only.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SWITCHBOARD_REAL_HOME"] == "1"))
struct RealMachineTests {
  private static func megabytes(_ bytes: UInt64) -> String {
    String(format: "%.1f MB", Double(bytes) / 1_048_576)
  }

  private static func name(_ owner: Owner) -> String {
    switch owner {
    case .desktop: "Claude Desktop"
    case .orphaned: "left running"
    case .session(_, let project):
      "session \(project.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?")"
    }
  }

  @Test func printMemoryReport() {
    let inventory = Inventory.load(home: FileManager.default.homeDirectoryForCurrentUser)
    var durations: [Double] = []
    var report = MemoryReport(usages: [], issues: [])
    var processCount = 0
    for _ in 1...5 {
      let start = Date()
      let snapshot = ProcessSnapshot.take(inventory: inventory)
      report = MemoryReport.build(
        processes: snapshot.processes, inventory: inventory, issues: snapshot.issues)
      durations.append(Date().timeIntervalSince(start) * 1000)
      processCount = snapshot.processes.count
    }
    print("sample ms: \(durations.map { Int($0.rounded()) })")
    print("processes read: \(processCount), groups: \(report.usages.count)")
    print("total: \(Self.megabytes(report.totalFootprint))")
    for total in report.ownerTotals {
      let groups = report.usages.filter { $0.owner == total.owner }.count
      print(
        "owner \(Self.name(total.owner)): \(Self.megabytes(total.footprint)) in \(groups) groups")
    }
    print("matched by target: \(report.usages.filter { $0.matchedBy == .target }.count)")
    print("matched by label: \(report.usages.filter { $0.matchedBy == .label }.count)")
    for hosts in report.usages where hosts.matchedBy == .extensionHosts {
      print(
        "extension hosts: \(Self.megabytes(hosts.footprint)) in \(hosts.processCount) processes")
    }
    let unmatched = report.usages.filter { $0.matchedBy == nil }
    print("unmatched: \(unmatched.count)")
    for usage in unmatched {
      print(
        "  unmatched \(usage.label) under \(Self.name(usage.owner)), \(Self.megabytes(usage.footprint))"
      )
    }
    let desktop = report.usages.filter { $0.owner == .desktop }
    let desktopRows = Dictionary(grouping: desktop.compactMap(\.rowID), by: { $0 }).mapValues(
      \.count)
    let configured = inventory.rows.flatMap(\.entries).filter {
      $0.kind == .server && $0.place == .desktop
    }
    print(
      "desktop: \(desktop.count) groups, \(desktopRows.count) distinct servers matched, "
        + "\(desktopRows.values.filter { $0 > 1 }.count) servers running more than once, "
        + "\(configured.count) configured, \(configured.filter { $0.state == .on }.count) on, "
        + "\(desktop.reduce(0) { $0 + $1.processCount }) processes")
    for total in report.serverTotals.prefix(8) {
      let name = inventory.rows.first { $0.id == total.rowID }?.name ?? total.label
      print("server \(name) ×\(total.copies): \(Self.megabytes(total.footprint))")
    }
    print("issues: \(report.issues.map(\.message))")
  }

  @Test func printDiskReport() {
    let start = Date()
    let report = DiskReport.scan(home: FileManager.default.homeDirectoryForCurrentUser)
    print("disk scan ms: \(Int(Date().timeIntervalSince(start) * 1000))")
    for category in DiskReport.Category.allCases {
      print("disk \(category): \(Self.megabytes(report.sizes[category] ?? 0))")
    }
    print("linked skills: \(report.linkedSkills), issues: \(report.issues.map(\.message))")
  }
}
