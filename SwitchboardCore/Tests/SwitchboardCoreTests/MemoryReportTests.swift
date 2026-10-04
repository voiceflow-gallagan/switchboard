import Foundation
import Testing

@testable import SwitchboardCore

/// Invented processes and configuration for grouping and matching.
struct ProcessFixture {
  static let secret = "SWB-FAKE-PROCESS-SECRET"
  static let desktopApp = "/Applications/Claude.app/Contents/MacOS/Claude"
  static let electronHelper =
    "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"
  static let extensionHost =
    "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Plugin).app/Contents/MacOS/Claude Helper (Plugin)"
  static let disclaimer = "/Applications/Claude.app/Contents/Helpers/disclaimer"
  static let session = "/Users/someone/.local/share/claude/versions/2.1.0"
  static let megabyte: UInt64 = 1_048_576

  static func process(
    _ id: Int32,
    parent: Int32,
    megabytes: UInt64,
    arguments: [String],
    folder: String? = nil
  ) -> RunningProcess {
    RunningProcess(
      id: id,
      parent: parent,
      footprint: megabytes * megabyte,
      programPath: arguments[0],
      target: Duplicates.target(launchArguments: arguments),
      workingFolder: folder
    )
  }

  static func owner(_ id: Int32, path: String, folder: String? = nil) -> RunningProcess {
    RunningProcess(
      id: id, parent: 1, footprint: 500 * megabyte, programPath: path, target: nil,
      workingFolder: folder)
  }

  static func server(_ name: String, _ place: Place, _ json: String, state: Presence = .on)
    -> Entry
  {
    let config =
      (try? JSONDecoder().decode(ServerConfig.self, from: Data(json.utf8))) ?? ServerConfig()
    let launch = Duplicates.launch(of: config)
    return Entry(
      name: name, kind: .server, place: place, origin: "test", state: state,
      target: launch.target, typeLabel: launch.typeLabel)
  }

  static let inventory: Inventory = {
    let entries = [
      server(
        "files", .desktop,
        #"{"command": "npx", "args": ["-y", "@acme/files-server@1.2.0", "/srv/share"]}"#),
      server(
        "notes-bridge", .desktop,
        #"{"command": "npx", "args": ["-y", "mcp-remote", "https://notes.example.test/mcp", "--header", "Authorization: Bearer x"]}"#
      ),
      server(
        "files", .claudeCode,
        #"{"command": "npx", "args": ["@acme/files-server@latest", "/srv/share"]}"#),
      server("tool", .claudeCode, #"{"command": "/usr/bin/python3", "args": ["tool.py"]}"#),
      server("memory", .claudeCode, #"{"command": "node", "args": ["/opt/memory.js"]}"#),
      server("context", .claudeCode, #"{"command": "node", "args": ["/opt/context.js"]}"#),
      server(
        "db", .project(path: "/work/alpha"),
        #"{"command": "uvx", "args": ["db-mcp", "--password", "invented"]}"#),
    ]
    return Inventory(
      rows: Duplicates.rows(from: entries), issues: [], projects: ["/work/alpha"], cloudHistory: [])
  }()

  static let processes: [RunningProcess] = [
    owner(100, path: desktopApp),
    process(101, parent: 100, megabytes: 300, arguments: [electronHelper, "--type=renderer"]),
    process(106, parent: 100, megabytes: 40, arguments: [extensionHost, "--type=utility"]),
    process(107, parent: 100, megabytes: 60, arguments: [extensionHost, "--type=utility"]),
    process(108, parent: 107, megabytes: 2, arguments: ["node", "child.js"]),
    process(
      102, parent: 100, megabytes: 1,
      arguments: [
        disclaimer, "--pgroup", "--", "/opt/homebrew/bin/npx", "-y", "@acme/files-server@1.2",
        "/srv/share",
      ]
    ),
    process(103, parent: 102, megabytes: 10, arguments: ["node", "/cache/files/index.js"]),
    process(104, parent: 103, megabytes: 5, arguments: ["node", "/cache/files/worker.js"]),
    process(
      105, parent: 100, megabytes: 20,
      arguments: [
        disclaimer, "--pgroup", "--", "npx", "-y", "mcp-remote",
        "https://user:\(secret)@notes.example.test/mcp/?token=\(secret)", "--header",
        "Authorization: Bearer \(secret)",
      ]),

    owner(200, path: session, folder: "/work/alpha"),
    process(
      201, parent: 200, megabytes: 2, arguments: ["/bin/zsh", "-c", "export TOKEN=\(secret)"]),
    process(202, parent: 200, megabytes: 1, arguments: ["/usr/bin/caffeinate", "-i"]),
    process(
      203, parent: 200, megabytes: 30,
      arguments: ["uvx", "db-mcp", "--password", "invented"]),
    process(
      204, parent: 200, megabytes: 40,
      arguments: ["/usr/local/bin/npx", "@acme/files-server", "/srv/share"]),
    process(205, parent: 200, megabytes: 7, arguments: ["python3", "tool.py", "--token", secret]),
    process(206, parent: 200, megabytes: 9, arguments: ["node", "/elsewhere/server.js", secret]),

    owner(300, path: session, folder: "/somewhere/else"),
    process(
      301, parent: 300, megabytes: 40, arguments: ["npx", "@acme/files-server@2", "/srv/share"]),
    process(
      302, parent: 300, megabytes: 30, arguments: ["uvx", "db-mcp", "--password", "invented"]),
    process(303, parent: 300, megabytes: 1, arguments: ["/bin/zsh"]),
    owner(304, path: session, folder: "/work/alpha").withParent(303),
    process(
      305, parent: 304, megabytes: 3, arguments: ["env", "API_KEY=\(secret)", "node", "x.js"]),
  ]

  static func report() -> MemoryReport {
    MemoryReport.build(processes: processes, inventory: inventory)
  }
}

extension RunningProcess {
  fileprivate func withParent(_ parent: Int32) -> RunningProcess {
    var copy = self
    copy.parent = parent
    return copy
  }
}

extension MemoryReport {
  fileprivate func usage(_ rootID: Int32) throws -> ServerUsage {
    try #require(usages.first { $0.id.hasSuffix("|\(rootID)") })
  }
}

@Suite struct MemoryReportTests {
  private let megabyte = ProcessFixture.megabyte

  @Test func desktopHelpersAreLeftOutAndTheWrapperIsSkipped() throws {
    let report = ProcessFixture.report()
    let desktop = report.usages.filter { $0.owner == .desktop && $0.matchedBy != .extensionHosts }
    #expect(desktop.count == 2)
    let files = try report.usage(102)
    #expect(files.matchedBy == .target)
    #expect(files.label == "npx @acme/files-server")
  }

  @Test func extensionHostsFormOneGroupWithoutRow() throws {
    let report = ProcessFixture.report()
    let hosts = report.usages.filter { $0.matchedBy == .extensionHosts }
    #expect(hosts.count == 1)
    let group = try #require(hosts.first)
    #expect(group.owner == .desktop)
    #expect(group.label == "Desktop extensions")
    #expect(group.rowID == nil)
    #expect(group.processCount == 3)
    #expect(group.footprint == 102 * megabyte)
    let desktop = try #require(report.ownerTotals.first { $0.owner == .desktop })
    #expect(desktop.footprint == (16 + 20 + 102) * megabyte)
  }

  @Test func groupSumsTheWholeTree() throws {
    let files = try ProcessFixture.report().usage(102)
    #expect(files.footprint == 16 * megabyte)
    #expect(files.processCount == 3)
  }

  @Test func mcpRemoteBridgeMatchesByAddress() throws {
    let bridge = try ProcessFixture.report().usage(105)
    #expect(bridge.matchedBy == .target)
    #expect(bridge.label == "notes.example.test")
  }

  @Test func sessionUsesTheServersOnForItsProject() throws {
    let report = ProcessFixture.report()
    let db = try report.usage(203)
    #expect(db.owner == .session(id: 200, project: "/work/alpha"))
    #expect(db.matchedBy == .target)
    #expect(try report.usage(204).matchedBy == .target)
  }

  @Test func shellsAndKeepAwakeAreNotServers() {
    let ids = ProcessFixture.report().usages.map(\.id)
    #expect(!ids.contains { $0.hasSuffix("|201") || $0.hasSuffix("|202") || $0.hasSuffix("|303") })
  }

  @Test func uniqueLabelMatchesAndSharedLabelStaysUnmatched() throws {
    let report = ProcessFixture.report()
    #expect(try report.usage(205).matchedBy == .label)
    let node = try report.usage(206)
    #expect(node.matchedBy == nil)
    #expect(node.rowID == nil)
    #expect(node.label == "node")
  }

  @Test func unknownFolderUsesOnlyUserLevelServers() throws {
    let report = ProcessFixture.report()
    #expect(try report.usage(301).matchedBy == .target)
    #expect(try report.usage(302).matchedBy == nil)
  }

  @Test func sessionInsideAnotherSessionIsItsOwnOwner() throws {
    let report = ProcessFixture.report()
    let nested = try report.usage(305)
    #expect(nested.owner == .session(id: 304, project: "/work/alpha"))
    #expect(
      !report.usages.contains {
        $0.owner == .session(id: 300, project: "/somewhere/else") && $0.processCount > 1
      })
  }

  @Test func sameServerUnderSeveralOwnersCountsEachCopy() throws {
    let report = ProcessFixture.report()
    let files = try report.usage(204)
    #expect(try report.usage(301).rowID == files.rowID)
    #expect(try report.usage(102).rowID == files.rowID)
    let total = try #require(report.serverTotals.first { $0.rowID == files.rowID })
    #expect(total.copies == 3)
    #expect(total.footprint == 96 * megabyte)
  }

  @Test func totalsPerOwner() {
    let report = ProcessFixture.report()
    #expect(report.totalFootprint == report.ownerTotals.reduce(0) { $0 + $1.footprint })
    #expect(report.ownerTotals.first?.owner == .desktop)
  }
}

@Suite struct MemoryReportEdgeTests {
  private let megabyte = ProcessFixture.megabyte

  @Test func serverLeftRunningByAnExitedOwnerIsOrphaned() throws {
    let processes = [
      ProcessFixture.process(
        400, parent: 1, megabytes: 40, arguments: ["npx", "@acme/files-server", "/srv/share"]),
      ProcessFixture.process(401, parent: 400, megabytes: 2, arguments: ["node", "w.js"]),
      ProcessFixture.process(402, parent: 1, megabytes: 90, arguments: ["/usr/bin/some-app"]),
      ProcessFixture.process(
        403, parent: 1, megabytes: 30, arguments: ["python3", "tool.py", "x"]),
    ]
    let report = MemoryReport.build(processes: processes, inventory: ProcessFixture.inventory)
    #expect(report.usages.count == 1)
    let orphan = try #require(report.usages.first)
    #expect(orphan.owner == .orphaned)
    #expect(orphan.matchedBy == .target)
    #expect(orphan.footprint == 42 * megabyte)
  }

  @Test func sessionInASubfolderUsesTheNearestProject() throws {
    let processes = [
      ProcessFixture.owner(500, path: ProcessFixture.session, folder: "/work/alpha/packages/api"),
      ProcessFixture.process(
        501, parent: 500, megabytes: 30, arguments: ["uvx", "db-mcp", "--password", "invented"]),
    ]
    let usage = try #require(
      MemoryReport.build(processes: processes, inventory: ProcessFixture.inventory).usages.first)
    #expect(usage.matchedBy == .target)
  }

  @Test func sessionInALinkedFolderUsesItsProject() throws {
    var inventory = ProcessFixture.inventory
    inventory.projectAliases = ["/real/alpha": "/work/alpha"]
    let processes = [
      ProcessFixture.owner(510, path: ProcessFixture.session, folder: "/real/alpha/sub"),
      ProcessFixture.process(
        511, parent: 510, megabytes: 30, arguments: ["uvx", "db-mcp", "--password", "invented"]),
    ]
    let usage = try #require(
      MemoryReport.build(processes: processes, inventory: inventory).usages.first)
    #expect(usage.matchedBy == .target)
  }

  @Test func rootProjectMatchesOnlyItself() {
    let known: Set = ["/", "/work/alpha"]
    #expect(MemoryReport.project(containing: "/tmp/x", known: known, aliases: [:]) == nil)
    #expect(MemoryReport.project(containing: "/", known: known, aliases: [:]) == "/")
    #expect(
      MemoryReport.project(containing: "/work/alpha/a/b", known: known, aliases: [:])
        == "/work/alpha")
  }

  @Test func cyclicParentsDoNotLoop() throws {
    let processes = [
      ProcessFixture.owner(600, path: ProcessFixture.session, folder: "/work/alpha"),
      ProcessFixture.process(601, parent: 600, megabytes: 1, arguments: ["node", "a.js"]),
      ProcessFixture.process(602, parent: 601, megabytes: 1, arguments: ["node", "b.js"]),
      ProcessFixture.process(601, parent: 602, megabytes: 1, arguments: ["node", "c.js"]),
    ]
    let report = MemoryReport.build(processes: processes, inventory: ProcessFixture.inventory)
    #expect(report.usages.count == 1)
    #expect(report.usages.first?.processCount == 2)
  }
}

@Suite struct ServerChartTests {
  private let megabyte = ProcessFixture.megabyte

  @Test func topHoldsMatchedServersAndExtensionHostsLargestFirst() throws {
    let chart = ProcessFixture.report().serverChart()
    #expect(chart.top.map(\.footprint) == chart.top.map(\.footprint).sorted(by: >))
    #expect(chart.top.allSatisfy { $0.rowID != nil || $0.isExtensionHosts })
    let hosts = try #require(chart.top.first)
    #expect(hosts.isExtensionHosts)
    #expect(hosts.footprint == 102 * megabyte)
    #expect(chart.top.filter(\.isExtensionHosts).count == 1)
    #expect(chart.top.count == 5)
  }

  @Test func limitCutsTheTop() {
    let report = ProcessFixture.report()
    #expect(
      report.serverChart(limit: 2).top.map(\.id) == report.serverChart().top.prefix(2).map(\.id))
    #expect(report.serverChart(limit: 0).top.isEmpty)
  }

  @Test func unmatchedGroupsFoldIntoOneFigure() throws {
    let unmatched = try #require(ProcessFixture.report().serverChart().unmatched)
    #expect(unmatched.groups == 3)
    #expect(unmatched.footprint == (9 + 30 + 3) * megabyte)
    #expect(unmatched.labels == ["env", "node", "uvx db-mcp"])
  }

  @Test func unmatchedIsNilWhenEverythingMatches() {
    let matched = ProcessFixture.processes.filter { ![206, 302, 305].contains($0.id) }
    let report = MemoryReport.build(processes: matched, inventory: ProcessFixture.inventory)
    #expect(report.serverChart().unmatched == nil)
    #expect(!report.serverChart().top.isEmpty)
  }
}

@Suite struct CredentialTests {
  @Test func noProcessCredentialIsReachable() throws {
    let report = ProcessFixture.report()
    var strings: [String] = []
    collectStrings(in: ProcessFixture.processes, into: &strings)
    collectStrings(in: report, into: &strings)
    collectStrings(in: report.serverTotals, into: &strings)
    collectStrings(in: report.ownerTotals, into: &strings)

    let folder = FileManager.default.temporaryDirectory.appending(
      path: "switchboard-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    var store = MeasurementStore.load(folder: folder, now: Date(timeIntervalSince1970: 1_000)).store
    store.record(report, at: Date(timeIntervalSince1970: 1_000))
    #expect(store.saveIfDue(at: Date(timeIntervalSince1970: 1_000)).isEmpty)
    let saved = try Data(contentsOf: folder.appending(path: MeasurementStore.fileName))
    strings.append(String(decoding: saved, as: UTF8.self))
    strings += store.savedKeys

    #expect(strings.count > 50)
    let leaks = strings.filter { $0.contains(ProcessFixture.secret) }
    #expect(leaks.isEmpty, "\(leaks.count) strings hold an invented credential")
  }

  private func collectStrings(in value: Any, into strings: inout [String]) {
    if let string = value as? String {
      strings.append(string)
      return
    }
    for child in Mirror(reflecting: value).children {
      collectStrings(in: child.value, into: &strings)
    }
  }
}

@Suite struct ProcessReaderTests {
  @Test func readsTheTestProcessItself() throws {
    let id = getpid()
    #expect((ProcessReader.footprint(id) ?? 0) > 0)
    let path = try #require(ProcessReader.programPath(id))
    #expect(path.hasPrefix("/"))
    #expect(ProcessReader.workingFolder(id) != nil)
    let info = try #require(ProcessReader.bsdInfo(id))
    #expect(info.pbi_ppid == UInt32(getppid()))
    let argumentCount = ProcessReader.withArguments(id) { $0.count }
    #expect((argumentCount ?? 0) >= 1)
  }

}
