import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct OffButRunningTests {
  private static let desktopApp = "/Applications/Claude.app/Contents/MacOS/Claude"
  private static let claude = "/opt/homebrew/bin/claude"

  private func process(
    _ id: Int32, parent: Int32, _ path: String, arguments: [String] = [], folder: String? = nil,
    bytes: UInt64 = 100
  ) -> RunningProcess {
    RunningProcess(
      id: id, parent: parent, footprint: bytes, programPath: path,
      target: arguments.isEmpty ? nil : Duplicates.target(launchArguments: arguments),
      workingFolder: folder)
  }

  private func apply(_ change: Switch, _ home: FixtureHome) {
    #expect(Switches.apply(change, home: home.url, supportFolder: home.support).applied)
  }

  private func report(_ home: FixtureHome, _ processes: [RunningProcess]) -> MemoryReport {
    MemoryReport.build(
      processes: processes,
      inventory: Inventory.load(home: home.url, supportFolder: home.support))
  }

  private func usage(_ report: MemoryReport, root: Int32) throws -> ServerUsage {
    try #require(report.usages.first { $0.id.hasSuffix("|\(root)") })
  }

  @Test func aKeptDesktopServerStillRunningIsMatchedAndOff() throws {
    let home = try FixtureHome()
    apply(.desktopServer(name: "files", on: false), home)
    let report = report(
      home,
      [
        process(10, parent: 1, Self.desktopApp, bytes: 1000),
        process(
          11, parent: 10, "/usr/local/bin/npx",
          arguments: ["/usr/local/bin/npx", "-y", "@acme/files-server@1.2.0", "/srv/share"]),
        process(
          12, parent: 10, "/usr/local/bin/docker",
          arguments: ["docker", "run", "-i", "--rm", "-e", "TRACKER_KEY", "acme/tracker"],
          bytes: 50),
      ])
    let files = try usage(report, root: 11)
    #expect(files.rowID == (try Inventory.load(home: home.url).row("files").id))
    #expect(files.matchedBy == .target)
    #expect(files.isOffButRunning)
    #expect(try !usage(report, root: 12).isOffButRunning)
    #expect(report.offButRunningFootprint == 100)
    let total = try #require(report.serverTotals.first { $0.rowID == files.rowID })
    #expect(total.offButRunningCopies == 1)
    #expect(total.offButRunningFootprint == 100)
    #expect(report.ownerTotals.first { $0.owner == .desktop }?.offButRunningFootprint == 100)
  }

  @Test func aServerOffInOneProjectIsOffOnlyInThatProjectsSession() throws {
    let home = try FixtureHome()
    let alpha = home.url.appending(path: "work/alpha").path
    let beta = home.url.appending(path: "work/beta").path
    apply(.serverInProject(name: "tracker", project: alpha, on: false), home)
    let tracker = ["node", "/opt/other-tracker.js"]
    let report = report(
      home,
      [
        process(20, parent: 1, Self.claude, folder: alpha),
        process(21, parent: 20, "/usr/local/bin/node", arguments: tracker, bytes: 300),
        process(30, parent: 1, Self.claude, folder: beta),
        process(31, parent: 30, "/usr/local/bin/node", arguments: tracker, bytes: 200),
      ])
    let inAlpha = try usage(report, root: 21)
    let inBeta = try usage(report, root: 31)
    #expect(inAlpha.rowID != nil)
    #expect(inAlpha.rowID == inBeta.rowID)
    #expect(inAlpha.isOffButRunning)
    #expect(!inBeta.isOffButRunning)
    let total = try #require(report.serverTotals.first { $0.rowID == inAlpha.rowID })
    #expect(total.copies == 2)
    #expect(total.offButRunningCopies == 1)
    #expect(total.offButRunningFootprint == 300)
    #expect(
      report.ownerTotals.first { $0.owner == .session(id: 20, project: alpha) }?
        .offButRunningFootprint == 300)
    #expect(
      report.ownerTotals.first { $0.owner == .session(id: 30, project: beta) }?
        .offButRunningFootprint == 0)
  }

  @Test func aSwitchedOffPluginsServerStillRunningIsOff() throws {
    let home = try FixtureHome()
    apply(.plugin(id: "helper@market", on: false), home)
    let report = report(
      home,
      [
        process(40, parent: 1, Self.claude, folder: "/elsewhere"),
        process(
          41, parent: 40, "/usr/local/bin/npx",
          arguments: ["npx", "-y", "mcp-remote", "https://api.helper.test/mcp"]),
      ])
    let helper = try usage(report, root: 41)
    #expect(helper.rowID == (try Inventory.load(home: home.url).row("helper-api").id))
    #expect(helper.isOffButRunning)
  }

  @Test func aServerOnEverywhereIsNotFlagged() throws {
    let home = try FixtureHome()
    let tracker = ["node", "/opt/other-tracker.js"]
    let report = report(
      home,
      [
        process(50, parent: 1, Self.claude, folder: "/elsewhere"),
        process(51, parent: 50, "/usr/local/bin/node", arguments: tracker),
        process(60, parent: 1, Self.claude, folder: home.url.appending(path: "work/beta").path),
        process(61, parent: 60, "/usr/local/bin/node", arguments: tracker),
      ])
    #expect(try usage(report, root: 51).rowID != nil)
    #expect(report.usages.allSatisfy { !$0.isOffButRunning })
    #expect(report.offButRunningFootprint == 0)
    #expect(report.serverTotals.allSatisfy { $0.offButRunningCopies == 0 })
  }
}
