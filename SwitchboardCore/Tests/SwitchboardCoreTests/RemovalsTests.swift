import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct RemovalsTests {
  private func remove(_ name: String, _ place: Place, _ home: FixtureHome) -> RemovalOutcome {
    Removals.remove(
      .server(name: name, place: place), home: home.url, supportFolder: home.support, claude: nil)
  }

  private func undo(_ outcome: RemovalOutcome, _ home: FixtureHome) throws -> RemovalOutcome {
    Removals.undo(
      try #require(outcome.undo), home: home.url, supportFolder: home.support, claude: nil)
  }

  private func load(_ home: FixtureHome) -> Inventory {
    Inventory.load(home: home.url, supportFolder: home.support)
  }

  private func expectRemovedAndUndone(
    _ name: String, place: Place, file: String, typeLabel: String, home: FixtureHome
  ) throws {
    let original = try home.data(file)
    let outcome = remove(name, place, home)
    #expect(outcome.applied)
    #expect(outcome.issues.isEmpty)
    #expect(try Data(contentsOf: try #require(outcome.backup)) == original)

    let inventory = load(home)
    let listed = try #require(inventory.removed.first)
    #expect(inventory.removed.count == 1)
    #expect(listed.name == name)
    #expect(listed.place == place)
    #expect(listed.typeLabel == typeLabel)
    #expect(
      !inventory.rows.flatMap(\.entries).contains {
        $0.name == name && ($0.place == place || $0.origin == "kept")
      })
    #expect(outcome.undo == .restore(listed))

    let restored = try undo(outcome, home)
    #expect(restored.applied)
    #expect(try home.data(file) == original)
    #expect(load(home).removed.isEmpty)
    #expect(restored.undo == .remove(.server(name: name, place: place)))
  }

  @Test func aDesktopServerIsRemovedAndRestoredByteForByte() throws {
    let home = try FixtureHome()
    try expectRemovedAndUndone(
      "tracker", place: .desktop, file: Switches.desktopFile, typeLabel: "docker", home: home)
  }

  @Test func aClaudeCodeUserServerIsRemovedAndRestoredByteForByte() throws {
    let home = try FixtureHome()
    try expectRemovedAndUndone(
      "notes", place: .claudeCode, file: Switches.claudeCodeFile, typeLabel: "http", home: home)
  }

  @Test func aProjectsOwnServerIsRemovedAndRestoredByteForByte() throws {
    let home = try FixtureHome()
    try expectRemovedAndUndone(
      "local-db", place: home.project("alpha"), file: Switches.claudeCodeFile, typeLabel: "uvx",
      home: home)
    #expect(try load(home).row("local-db").entries.count == 2)
  }

  @Test func undoOfARestoreRemovesAgain() throws {
    let home = try FixtureHome()
    let removed = remove("scratch", home.project("beta"), home)
    let restored = try undo(removed, home)
    let again = try undo(restored, home)
    #expect(again.applied)
    #expect(load(home).removed.map(\.name) == ["scratch"])
    #expect(ParkedServers.load(supportFolder: home.support).servers?.count == 1)
  }

  @Test func restoreIsRefusedWhenTheNameExistsAgain() throws {
    let home = try FixtureHome()
    let file = Switches.desktopFile
    let outcome = remove("browser", .desktop, home)
    let readded = try #require(
      JSONText.insertMember(
        "{\"command\": \"other\"}", named: "browser", at: ["mcpServers"], in: try home.text(file)))
    try home.write(readded, to: file)

    let restored = try undo(outcome, home)
    #expect(!restored.applied)
    #expect(
      restored.issues.map(\.message)
        == ["A server with this name exists again. The removed server was not restored."])
    #expect(try home.text(file) == readded)
    #expect(load(home).removed.map(\.name) == ["browser"])
  }

  @Test func deleteForGoodDeletesOnlyTheKeptEntry() throws {
    let home = try FixtureHome()
    _ = remove("notes", .claudeCode, home)
    let config = try home.data(Switches.claudeCodeFile)
    let listed = try #require(load(home).removed.first)

    let deleted = Removals.deleteForGood(listed, supportFolder: home.support)
    #expect(deleted.applied)
    #expect(deleted.undo == nil)
    #expect(load(home).removed.isEmpty)
    #expect(try home.data(Switches.claudeCodeFile) == config)
    #expect(ParkedServers.load(supportFolder: home.support).servers?.isEmpty == true)
    #expect(!Removals.deleteForGood(listed, supportFolder: home.support).applied)
  }

  @Test func removedServersAreNeverRowsDuplicatesOrCleanedUp() throws {
    let home = try FixtureHome()
    #expect(try load(home).row("files").isDuplicate)
    _ = Removals.removeServer(
      "files", place: .desktop, home: home.url, supportFolder: home.support,
      now: Date(timeIntervalSince1970: 1_800_000_000))
    #expect(try !load(home).row("files").isDuplicate)

    let muchLater = Date(timeIntervalSince1970: 1_800_000_000 + 30 * 86_400)
    #expect(
      Switches.apply(
        .desktopExtension(id: "acme.notes", on: true), home: home.url,
        supportFolder: home.support, now: muchLater
      ).applied)
    #expect(load(home).removed.map(\.name) == ["files"])
  }

  @Test func aSwitchedOffRowAndOtherSourcesOfferNoRemoval() throws {
    let home = try FixtureHome()
    let inventory = load(home)
    let alpha = home.project("alpha")
    let desktopTracker = try #require(
      inventory.rows.first { $0.entries.contains { $0.name == "tracker" && $0.place == .desktop } })
    #expect(Removals.offered(for: desktopTracker) == [.server(name: "tracker", place: .desktop)])
    #expect(
      Set(Removals.offered(for: try inventory.row("files")))
        == [.server(name: "files", place: .desktop), .server(name: "files", place: .claudeCode)])
    #expect(
      Removals.offered(for: try inventory.row("local-db"))
        .contains(.server(name: "local-db", place: alpha)))
    #expect(Removals.offered(for: try inventory.row("helper-api")).isEmpty)
    #expect(Removals.offered(for: try inventory.row("approved")).isEmpty)
    #expect(Removals.offered(for: try inventory.row("Weather")).isEmpty)
    #expect(Removals.offered(for: try inventory.row("writing", .skill)).isEmpty)
    #expect(
      Removals.offered(for: try inventory.row("helper", .plugin)) == [.plugin(id: "helper@market")])

    #expect(
      Switches.apply(
        .claudeCodeServer(name: "positional", on: false), home: home.url,
        supportFolder: home.support
      ).applied)
    #expect(Removals.offered(for: try load(home).row("positional")).isEmpty)
  }

  @Test func noRemovedCredentialIsReachable() throws {
    let home = try FixtureHome()
    let outcomes = [
      remove("notes", .claudeCode, home), remove("files", .desktop, home),
      remove("local-db", home.project("alpha"), home),
    ]
    let kept = try String(
      contentsOf: home.support.appending(path: ParkedServers.fileName), encoding: .utf8)
    #expect(kept.contains("SWB-FAKE-SECRET-kept-code"))
    #expect(kept.contains("SWB-FAKE-SECRET-kept-desktop"))
    let inventory = load(home)
    #expect(inventory.removed.count == 3)
    let strings = reachableStrings(in: inventory) + reachableStrings(in: outcomes)
    #expect(!strings.contains { $0.contains(FixtureHome.secret) })
  }

  @Test func restartNeedsFollowThePlace() {
    let processes = [
      RunningProcess(
        id: 10, parent: 1, footprint: 0,
        programPath: "/Applications/Claude.app/Contents/MacOS/Claude", target: nil,
        workingFolder: nil),
      RunningProcess(
        id: 20, parent: 1, footprint: 0, programPath: "/opt/homebrew/bin/claude", target: nil,
        workingFolder: "/work/alpha"),
      RunningProcess(
        id: 21, parent: 1, footprint: 0, programPath: "/opt/homebrew/bin/claude", target: nil,
        workingFolder: "/work/beta"),
    ]
    let inventory = Inventory(
      rows: [], issues: [], projects: ["/work/alpha", "/work/beta"], cloudHistory: [])
    func ids(_ removal: Removal) -> [Int32] {
      RestartNeeds.needs(for: removal, processes: processes, inventory: inventory).map(\.id)
    }
    #expect(ids(.server(name: "a", place: .desktop)) == [10])
    #expect(ids(.server(name: "a", place: .claudeCode)) == [20, 21])
    #expect(ids(.server(name: "a", place: .project(path: "/work/beta"))) == [21])
    #expect(ids(.plugin(id: "a@b")) == [20, 21])
  }

  @Test func aRestoredServerDroppedAgainCanBeRestoredAtOnce() throws {
    let home = try FixtureHome()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let original = try home.data(Switches.desktopFile)
    let removed = Removals.removeServer(
      "tracker", place: .desktop, home: home.url, supportFolder: home.support, now: start)
    let without = try home.data(Switches.desktopFile)
    let listed = try #require(load(home).removed.first)
    #expect(
      Removals.restore(listed, home: home.url, supportFolder: home.support, now: start + 1)
        .applied)
    try without.write(to: home.url.appending(path: Switches.desktopFile))

    let again = try #require(load(home).removed.first)
    let restored = Removals.restore(
      again, home: home.url, supportFolder: home.support, now: start + 60)
    #expect(restored.applied)
    #expect(try home.data(Switches.desktopFile) == original)
    #expect(removed.applied)
  }

  @Test func restoringIntoAProjectThatIsGoneSaysSo() throws {
    let home = try FixtureHome()
    let alpha = home.url.appending(path: "work/alpha").path
    let outcome = remove("scratch", home.project("alpha"), home)
    try home.edit(".claude.json") { config in
      var projects = config["projects"] as? [String: Any] ?? [:]
      projects[alpha] = nil
      config["projects"] = projects
    }
    let restored = try undo(outcome, home)
    #expect(!restored.applied)
    #expect(
      restored.issues.map(\.message)
        == ["The project it came from is no longer in this file. Nothing was changed."])
    #expect(load(home).removed.map(\.name) == ["scratch"])
  }

  @Test func theKeptFileIsVersionTwoAndVersionOneStillLoads() throws {
    let home = try FixtureHome()
    _ = remove("notes", .claudeCode, home)
    let file = home.support.appending(path: ParkedServers.fileName)
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text.contains("\"version\" : 2"))
    try text.replacingOccurrences(of: "\"version\" : 2", with: "\"version\" : 1")
      .write(to: file, atomically: true, encoding: .utf8)
    #expect(ParkedServers.load(supportFolder: home.support).servers?.count == 1)
    try text.replacingOccurrences(of: "\"version\" : 2", with: "\"version\" : 3")
      .write(to: file, atomically: true, encoding: .utf8)
    #expect(ParkedServers.load(supportFolder: home.support).servers == nil)
  }

  @Test func aRemovalAndARestoreAreCheckedOnDisk() throws {
    let home = try FixtureHome()
    let removed = remove("scratch", home.project("beta"), home)
    let afterRemoval = try #require(removed.undo)
    #expect(Removals.isInEffect(afterRemoval, home: home.url) == true)

    let restored = try undo(removed, home)
    let afterRestore = try #require(restored.undo)
    #expect(Removals.isInEffect(afterRestore, home: home.url) == true)
    #expect(Removals.isInEffect(afterRemoval, home: home.url) == false)

    let text = try home.text(Switches.claudeCodeFile)
    let dropped = try #require(
      JSONText.removeMember(
        at: ["projects", home.url.appending(path: "work/beta").path, "mcpServers", "scratch"],
        in: text))
    try home.write(dropped.text, to: Switches.claudeCodeFile)
    #expect(Removals.isInEffect(afterRestore, home: home.url) == false)

    try home.write("{ damaged", to: Switches.claudeCodeFile)
    #expect(Removals.isInEffect(afterRestore, home: home.url) == nil)
    #expect(Removals.isInEffect(.reinstall(pluginID: "a@b"), home: home.url) == nil)
  }
}
