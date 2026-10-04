import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct ParkedServersTests {
  private static let codeSecret = "SWB-FAKE-SECRET-kept-code"
  private static let desktopSecret = "SWB-FAKE-SECRET-kept-desktop"

  private func apply(_ change: Switch, _ home: FixtureHome) -> SwitchOutcome {
    Switches.apply(change, home: home.url, supportFolder: home.support)
  }

  private func load(_ home: FixtureHome) -> Inventory {
    Inventory.load(home: home.url, supportFolder: home.support)
  }

  private func keptFile(_ home: FixtureHome) -> URL {
    home.support.appending(path: ParkedServers.fileName)
  }

  private func keptText(_ home: FixtureHome) throws -> String {
    try String(contentsOf: keptFile(home), encoding: .utf8)
  }

  @Test func claudeCodeServerIsKeptAndComesBackByteForByte() throws {
    try expectKeptAndBack(
      .claudeCodeServer(name: "notes", on: false), file: ".claude.json", place: .claudeCode,
      secret: Self.codeSecret)
  }

  @Test func desktopServerIsKeptAndComesBackByteForByte() throws {
    try expectKeptAndBack(
      .desktopServer(name: "files", on: false), file: Switches.desktopFile, place: .desktop,
      secret: Self.desktopSecret)
  }

  private func expectKeptAndBack(_ change: Switch, file: String, place: Place, secret: String)
    throws
  {
    let home = try FixtureHome()
    let original = try home.data(file)
    #expect(try home.text(file).contains(secret))

    let kept = apply(change, home)
    #expect(kept.applied)
    #expect(kept.issues.isEmpty)
    #expect(kept.undo == change.opposite)
    #expect(try !home.text(file).contains(secret))
    #expect(try keptText(home).contains(secret))
    #expect(try home.mode(keptFile(home).path) == 0o600)
    #expect(try home.mode(home.support.path) == 0o700)

    let inventory = load(home)
    let entry = try #require(inventory.rows.flatMap(\.entries).first { $0.origin == "kept" })
    #expect(entry.place == place)
    #expect(entry.state == .off)
    #expect(entry.target != nil)
    #expect(Switches.offered(for: try inventory.row(entry.name), in: place) == change.opposite)
    #expect(Switches.isInEffect(change, home: home.url) == true)

    let back = apply(try #require(kept.undo), home)
    #expect(back.applied)
    #expect(back.issues.isEmpty)
    #expect(try home.data(file) == original)
    #expect(try keptText(home).contains(secret))
    #expect(!load(home).rows.flatMap(\.entries).contains { $0.origin == "kept" })
  }

  @Test func noKeptCredentialIsReachableFromTheModelOrOutcomes() throws {
    let home = try FixtureHome()
    var outcomes = [
      apply(.claudeCodeServer(name: "notes", on: false), home),
      apply(.desktopServer(name: "files", on: false), home),
    ]
    try home.write(
      try #require(
        JSONText.insertMember(
          "{}", named: "notes", at: ["mcpServers"], in: try home.text(".claude.json"))),
      to: ".claude.json")
    outcomes.append(apply(.claudeCodeServer(name: "notes", on: true), home))
    let inventory = load(home)
    #expect(try keptText(home).contains(Self.codeSecret))
    #expect(try keptText(home).contains(Self.desktopSecret))

    let strings = reachableStrings(in: inventory) + reachableStrings(in: outcomes)
    #expect(strings.count > 100)
    #expect(!strings.contains { $0.contains(Self.codeSecret) || $0.contains(Self.desktopSecret) })
    #expect(outcomes.last?.issues.isEmpty == false)
  }

  @Test func puttingBackFailsWhenTheNameExistsAgain() throws {
    let home = try FixtureHome()
    #expect(apply(.desktopServer(name: "files", on: false), home).applied)
    let file = Switches.desktopFile
    let readded = try #require(
      JSONText.insertMember(
        "{\"command\": \"other\"}", named: "files", at: ["mcpServers"], in: try home.text(file)))
    try home.write(readded, to: file)

    let outcome = apply(.desktopServer(name: "files", on: true), home)
    #expect(!outcome.applied)
    #expect(
      outcome.issues.map(\.message)
        == ["A server with this name exists again. The kept server was not put back."])
    #expect(try home.text(file) == readded)
    #expect(try keptText(home).contains(Self.desktopSecret))
  }

  @Test func keepingWhatIsAlreadyKeptWritesNothing() throws {
    let home = try FixtureHome()
    #expect(apply(.claudeCodeServer(name: "notes", on: false), home).applied)
    let config = try home.data(".claude.json")
    let kept = try Data(contentsOf: keptFile(home))
    let backups = home.backups

    let again = apply(.claudeCodeServer(name: "notes", on: false), home)
    #expect(again.applied)
    #expect(again.undo == nil)
    #expect(try home.data(".claude.json") == config)
    #expect(try Data(contentsOf: keptFile(home)) == kept)
    #expect(home.backups == backups)

    let missing = apply(.claudeCodeServer(name: "never-there", on: false), home)
    #expect(!missing.applied)
    let onAlready = apply(.claudeCodeServer(name: "files", on: true), home)
    #expect(onAlready.applied)
    #expect(onAlready.backup == nil)
  }

  @Test func aDamagedKeptFileIsNeverOverwritten() throws {
    let home = try FixtureHome()
    try FileManager.default.createDirectory(at: home.support, withIntermediateDirectories: true)
    try Data("{ damaged".utf8).write(to: keptFile(home))
    let config = try home.data(".claude.json")

    let outcome = apply(.claudeCodeServer(name: "notes", on: false), home)
    #expect(!outcome.applied)
    #expect(outcome.issues.map(\.source) == [ParkedServers.source])
    #expect(try home.data(".claude.json") == config)
    #expect(try Data(contentsOf: keptFile(home)) == Data("{ damaged".utf8))
    #expect(load(home).issues.map(\.source) == [ParkedServers.source])
  }

  @Test func aFailedRemovalTakesTheKeptCopyBackOut() throws {
    let home = try FixtureHome()
    let folder = home.url.appending(path: "Library/Application Support/Claude")
    let config = try home.data(Switches.desktopFile)
    #expect(chmod(folder.path, 0o500) == 0)
    defer { chmod(folder.path, 0o755) }

    let outcome = apply(.desktopServer(name: "files", on: false), home)
    #expect(!outcome.applied)
    #expect(try home.data(Switches.desktopFile) == config)
    #expect(try !keptText(home).contains(Self.desktopSecret))
    #expect(ParkedServers.load(supportFolder: home.support).servers?.isEmpty == true)
  }

  @Test func aLeftoverOfAnInterruptedChangeHealsItself() throws {
    let home = try FixtureHome()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let original = try home.data(Switches.desktopFile)
    #expect(apply(.desktopServer(name: "files", on: false), home, at: start).applied)
    try original.write(to: home.url.appending(path: Switches.desktopFile))
    let codeKept = apply(.claudeCodeServer(name: "notes", on: false), home, at: start)
    #expect(codeKept.applied)

    let inventory = load(home)
    #expect(
      inventory.rows.flatMap(\.entries).filter { $0.origin == "kept" }.map(\.name) == ["notes"])
    #expect(try inventory.row("files").entries.filter { $0.place == .desktop }.count == 1)
    #expect(try keptText(home).contains(Self.desktopSecret))

    let early = apply(
      .desktopExtension(id: "acme.notes", on: true), home, at: start + ParkedServers.holdTime - 1)
    #expect(early.applied)
    #expect(try keptText(home).contains(Self.desktopSecret))
    #expect(
      !load(home).rows.flatMap(\.entries).contains { $0.origin == "kept" && $0.name == "files" })

    let other = apply(
      .desktopExtension(id: "acme.notes", on: false), home, at: start + ParkedServers.holdTime)
    #expect(other.applied)
    #expect(other.issues.isEmpty)
    #expect(try !keptText(home).contains(Self.desktopSecret))
    #expect(try keptText(home).contains(Self.codeSecret))
    #expect(try home.text(Switches.desktopFile).contains(Self.desktopSecret))
  }

  @Test func aDifferentDefinitionUnderTheSameNameIsAConflictNotALeftover() throws {
    let home = try FixtureHome()
    #expect(apply(.desktopServer(name: "files", on: false), home).applied)
    let file = Switches.desktopFile
    let readded = try #require(
      JSONText.insertMember(
        "{\"command\": \"other\"}", named: "files", at: ["mcpServers"], in: try home.text(file)))
    try home.write(readded, to: file)

    #expect(apply(.desktopExtension(id: "acme.notes", on: true), home).applied)
    #expect(try keptText(home).contains(Self.desktopSecret))
    let kept = load(home).rows.flatMap(\.entries).filter { $0.origin == "kept" }
    #expect(kept.map(\.name) == ["files"])
    #expect(!apply(.desktopServer(name: "files", on: true), home).applied)
  }

  @Test func theKeptCopyStaysWhenTheConfigurationMayBeDamaged() throws {
    let home = try FixtureHome()
    let folder = home.url.appending(path: "Library/Application Support/Claude")
    defer { chmod(folder.path, 0o755) }

    let outcome = Switches.applyChange(
      .desktopServer(name: "files", on: false), home: home.url, supportFolder: home.support,
      afterReplace: {
        try? Data("{ damaged".utf8).write(to: home.url.appending(path: Switches.desktopFile))
        chmod(folder.path, 0o500)
      })

    #expect(!outcome.applied)
    #expect(
      outcome.issues.map(\.message)
        == ["Could not be verified after saving, and the backup could not be restored."])
    #expect(try home.text(Switches.desktopFile) == "{ damaged")
    #expect(try keptText(home).contains(Self.desktopSecret))
    #expect(try Data(contentsOf: try #require(outcome.backup)).count > 0)
  }

  private func kept(_ home: FixtureHome) -> [ParkedServers.Server] {
    ParkedServers.load(supportFolder: home.support).servers ?? []
  }

  private func apply(_ change: Switch, _ home: FixtureHome, at now: Date) -> SwitchOutcome {
    Switches.apply(change, home: home.url, supportFolder: home.support, now: now)
  }

  @Test func aPutBackKeepsTheCopyUntilTheServerHasHeldTenMinutes() throws {
    let home = try FixtureHome()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(apply(.claudeCodeServer(name: "notes", on: false), home, at: start).applied)
    #expect(apply(.claudeCodeServer(name: "notes", on: true), home, at: start).applied)
    #expect(kept(home).map(\.putBackDate) == [start])
    #expect(!load(home).rows.flatMap(\.entries).contains { $0.origin == "kept" })

    let plugin = Switch.plugin(id: "styler@market", on: true)
    #expect(apply(plugin, home, at: start + ParkedServers.holdTime - 1).applied)
    #expect(kept(home).count == 1)
    #expect(apply(plugin.opposite, home, at: start + ParkedServers.holdTime).applied)
    #expect(kept(home).isEmpty)
    #expect(try home.text(".claude.json").contains(Self.codeSecret))
  }

  @Test func aServerRewrittenAwayAfterAPutBackShowsOffAndComesBackIdentical() throws {
    let home = try FixtureHome()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let original = try home.data(".claude.json")
    #expect(apply(.claudeCodeServer(name: "notes", on: false), home, at: start).applied)
    let without = try home.data(".claude.json")
    #expect(apply(.claudeCodeServer(name: "notes", on: true), home, at: start).applied)
    try without.write(to: home.url.appending(path: ".claude.json"))

    let entry = try #require(load(home).rows.flatMap(\.entries).first { $0.origin == "kept" })
    #expect(entry.name == "notes")
    #expect(entry.state == .off)

    let later = start + ParkedServers.holdTime * 3
    #expect(apply(.claudeCodeServer(name: "notes", on: true), home, at: later).applied)
    #expect(try home.data(".claude.json") == original)
    #expect(kept(home).map(\.putBackDate) == [later])
  }

  @Test func theServerCanBeSwitchedOffAgainRightAfterAPutBack() throws {
    let home = try FixtureHome()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let original = try home.data(Switches.desktopFile)
    let off = apply(.desktopServer(name: "files", on: false), home, at: start)
    let on = apply(try #require(off.undo), home, at: start)
    #expect(on.applied)
    #expect(apply(try #require(on.undo), home, at: start + 1).applied)
    #expect(kept(home).count == 1)
    #expect(kept(home).first?.putBackDate == nil)
    #expect(try !home.text(Switches.desktopFile).contains(Self.desktopSecret))
    #expect(apply(.desktopServer(name: "files", on: true), home, at: start + 2).applied)
    #expect(try home.data(Switches.desktopFile) == original)
    #expect(apply(.desktopServer(name: "files", on: true), home, at: start + 3).backup == nil)
  }

  @Test func aPutBackWritesNothingWhenThePutBackTimeCannotBeSaved() throws {
    let home = try FixtureHome()
    #expect(apply(.desktopServer(name: "files", on: false), home).applied)
    let config = try home.data(Switches.desktopFile)
    let keptBefore = try Data(contentsOf: keptFile(home))
    let locked = keptFile(home).path
    #expect(chflags(locked, UInt32(UF_IMMUTABLE)) == 0)
    defer { chflags(locked, 0) }

    let outcome = Switches.applyChange(
      .desktopServer(name: "files", on: true), home: home.url, supportFolder: home.support)

    #expect(!outcome.applied)
    #expect(!outcome.wrote)
    #expect(outcome.issues.map(\.source) == [ParkedServers.source])
    #expect(try home.data(Switches.desktopFile) == config)
    #expect(try Data(contentsOf: keptFile(home)) == keptBefore)
    #expect(kept(home).first?.putBackDate == nil)
  }

  @Test func aFailedPutBackWriteClearsThePutBackTime() throws {
    let home = try FixtureHome()
    #expect(apply(.desktopServer(name: "files", on: false), home).applied)
    let config = try home.data(Switches.desktopFile)
    let folder = home.url.appending(path: "Library/Application Support/Claude")
    #expect(chmod(folder.path, 0o500) == 0)
    defer { chmod(folder.path, 0o755) }

    let outcome = apply(.desktopServer(name: "files", on: true), home)

    #expect(!outcome.applied)
    #expect(try home.data(Switches.desktopFile) == config)
    #expect(kept(home).count == 1)
    #expect(kept(home).first?.putBackDate == nil)
  }
}

@Suite struct PutBackLeftoverTests {
  private let start = Date(timeIntervalSince1970: 1_800_000_000)

  private func apply(_ change: Switch, _ home: FixtureHome, at seconds: TimeInterval)
    -> SwitchOutcome
  {
    Switches.apply(change, home: home.url, supportFolder: home.support, now: start + seconds)
  }

  private func tidy(_ home: FixtureHome, at seconds: TimeInterval) -> [SourceIssue] {
    ParkedServers.tidy(.desktop, home: home.url, supportFolder: home.support, now: start + seconds)
  }

  private func keptCount(_ home: FixtureHome) -> Int? {
    ParkedServers.load(supportFolder: home.support).servers?.count
  }

  private func browser(_ home: FixtureHome) throws -> Row {
    try Inventory.load(home: home.url, supportFolder: home.support).row("browser")
  }

  /// Gives the browser server an environment, which keeps its target and so its row.
  private func editBrowser(_ home: FixtureHome) throws {
    let text = try home.text(Switches.desktopFile)
    try home.write(
      try #require(
        JSONText.insertMember(
          #"{"EDITED": "1"}"#, named: "env", at: ["mcpServers", "browser"], in: text)),
      to: Switches.desktopFile)
  }

  @Test func aServerEditedAfterItWasPutBackWinsOverItsKeptCopy() throws {
    let home = try FixtureHome()
    #expect(apply(.desktopServer(name: "browser", on: false), home, at: 0).applied)
    #expect(apply(.desktopServer(name: "browser", on: true), home, at: 60).applied)
    try editBrowser(home)

    let row = try browser(home)
    #expect(row.entries.map(\.origin) == ["config"])
    #expect(Switches.offered(for: row, in: .desktop) == .desktopServer(name: "browser", on: false))
    #expect(Removals.offered(for: row) == [.server(name: "browser", place: .desktop)])
    #expect(Additions.offeredCopy(for: row) == .claudeCode)

    #expect(tidy(home, at: 120).isEmpty)
    #expect(keptCount(home) == 1)
    #expect(tidy(home, at: 60 + ParkedServers.holdTime).isEmpty)
    #expect(keptCount(home) == 0)
    #expect(try browser(home).entries.map(\.origin) == ["config"])
  }

  @Test func aRestoredServerEditedSinceLeavesTheRemovedList() throws {
    let home = try FixtureHome()
    #expect(
      Removals.removeServer(
        "browser", place: .desktop, home: home.url, supportFolder: home.support, now: start
      ).applied)
    let listed = try #require(
      Inventory.load(home: home.url, supportFolder: home.support).removed.first)
    #expect(
      Removals.restore(listed, home: home.url, supportFolder: home.support, now: start + 60)
        .applied)
    try editBrowser(home)

    #expect(Inventory.load(home: home.url, supportFolder: home.support).removed.isEmpty)
    #expect(try browser(home).entries.map(\.origin) == ["config"])
    #expect(tidy(home, at: 60 + ParkedServers.holdTime).isEmpty)
    #expect(keptCount(home) == 0)
  }

  @Test func aKeptCopyNeverPutBackStillConflictsWithAnEditedServer() throws {
    let home = try FixtureHome()
    let original = try home.text(Switches.desktopFile)
    #expect(apply(.desktopServer(name: "browser", on: false), home, at: 0).applied)
    try home.write(original, to: Switches.desktopFile)
    try editBrowser(home)

    #expect(Set(try browser(home).entries.map(\.origin)) == ["config", "kept"])
    #expect(tidy(home, at: 30 * 86_400).isEmpty)
    #expect(keptCount(home) == 1)
  }
}
