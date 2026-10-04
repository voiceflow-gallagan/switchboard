import Foundation
import Testing

@testable import SwitchboardCore

struct InventedDataTests {
  private static let megabyte: UInt64 = 1 << 20

  @Test func inventedProcessesBuildAReportWithTheExpectedOwners() {
    let processes = [
      InventedData.process(
        id: 10, parent: 1, footprint: 1,
        programPath: "/Applications/Claude.app/Contents/MacOS/Claude"),
      InventedData.process(
        id: 11, parent: 10, footprint: 300 * Self.megabyte, programPath: "/opt/demo/bin/deno"),
      InventedData.process(
        id: 20, parent: 1, footprint: 1, programPath: "/opt/demo/claude/versions/1.0.0/claude",
        workingFolder: "/work/alpha"),
      InventedData.process(
        id: 21, parent: 20, footprint: 200 * Self.megabyte, programPath: "/opt/demo/bin/ruby"),
    ]
    let inventory = Inventory(rows: [], issues: [], projects: ["/work/alpha"], cloudHistory: [])

    let report = MemoryReport.build(processes: processes, inventory: inventory)

    #expect(
      Set(report.ownerTotals.map(\.owner))
        == [.desktop, .session(id: 20, project: "/work/alpha")])
    #expect(report.totalFootprint == 500 * Self.megabyte)
    #expect(report.serverChart().unmatched?.labels == ["deno", "ruby"])
  }

  @Test func inventedDiskReportKeepsItsSizes() {
    let report = InventedData.diskReport(sizes: [.plugins: 5, .skills: 2], linkedSkills: 1)

    #expect(report.sizes == [.plugins: 5, .skills: 2])
    #expect(report.linkedSkills == 1)
    #expect(report.issues.isEmpty)
  }
}
