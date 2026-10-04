import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct SwitchesTests {
  private func apply(_ change: Switch, _ home: FixtureHome) -> SwitchOutcome {
    Switches.apply(change, home: home.url, supportFolder: home.support)
  }

  private func load(_ home: FixtureHome) -> Inventory {
    Inventory.load(home: home.url, supportFolder: home.support)
  }

  @Test func aKeptServerIsPutBackIntoAFileWithoutAServerList() throws {
    let home = try FixtureHome()
    #expect(apply(.desktopServer(name: "browser", on: false), home).applied)
    try home.write(
      "{\n  \"preferences\": {\n    \"theme\": \"dark\"\n  }\n}\n", to: Switches.desktopFile)

    let outcome = apply(.desktopServer(name: "browser", on: true), home)
    #expect(outcome.applied)
    #expect(outcome.issues.isEmpty)
    #expect(
      JSONText.hasMember(at: ["mcpServers", "browser"], in: try home.text(Switches.desktopFile))
        == true)
    #expect(try load(home).row("browser").state(in: .desktop) == .on)
  }

  @Test func serverOffInOneProjectAndUndo() throws {
    let home = try FixtureHome()
    let beta = home.url.appending(path: "work/beta").path
    let original = try home.data(".claude.json")
    let change = try #require(
      Switches.offered(for: load(home).row("search"), in: home.project("beta")))
    #expect(change == .serverInProject(name: "search", project: beta, on: false))

    let outcome = apply(change, home)
    #expect(outcome.applied)
    #expect(outcome.issues.isEmpty)
    #expect(outcome.undo == .serverInProject(name: "search", project: beta, on: true))
    #expect(try Data(contentsOf: try #require(outcome.backup)) == original)
    let search = try load(home).row("search")
    #expect(search.state(in: home.project("beta")) == .off)
    #expect(search.state(in: .claudeCode) == .on)
    #expect(Switches.isInEffect(change, home: home.url) == true)

    let undone = apply(try #require(outcome.undo), home)
    #expect(undone.applied)
    #expect(try home.data(".claude.json") == original)
    #expect(Switches.isInEffect(change, home: home.url) == false)
  }

  @Test func pluginServerOnInAProjectUsesThePluginForm() throws {
    let home = try FixtureHome()
    let alpha = home.url.appending(path: "work/alpha").path
    let row = try load(home).row("helper-api")
    let change = try #require(Switches.offered(for: row, in: home.project("alpha")))
    #expect(change == .serverInProject(name: "plugin:helper:helper-api", project: alpha, on: true))
    #expect(apply(change, home).applied)
    #expect(try load(home).row("helper-api").state(in: home.project("alpha")) == .on)
    #expect(try !home.text(".claude.json").contains("plugin:helper:helper-api"))
  }

  @Test func pluginOnAndOff() throws {
    let home = try FixtureHome()
    let original = try home.data(Switches.settingsFile)
    let change = try #require(
      Switches.offered(for: load(home).row("styler", .plugin), in: .claudeCode))
    #expect(change == .plugin(id: "styler@market", on: true))
    let outcome = apply(change, home)
    #expect(outcome.applied)
    #expect(try load(home).row("styler", .plugin).state(in: .claudeCode) == .on)
    #expect(apply(try #require(outcome.undo), home).applied)
    #expect(try home.data(Switches.settingsFile) == original)
  }

  @Test func desktopExtensionOnAndOff() throws {
    let home = try FixtureHome()
    let file = Switches.extensionSettingsFolder + "/acme.notes.json"
    let original = try home.data(file)
    let change = try #require(
      Switches.offered(for: load(home).row("Notes Extension"), in: .desktop))
    #expect(change == .desktopExtension(id: "acme.notes", on: true))
    let outcome = apply(change, home)
    #expect(outcome.applied)
    #expect(try load(home).row("Notes Extension").state(in: .desktop) == .on)
    #expect(apply(try #require(outcome.undo), home).applied)
    #expect(try home.data(file) == original)
  }

  @Test(arguments: [
    (Switch.serverInProject(name: "notes", project: "work/beta", on: false), ".claude.json"),
    (.plugin(id: "styler@market", on: false), Switches.settingsFile),
    (
      .desktopExtension(id: "acme.notes", on: false),
      Switches.extensionSettingsFolder + "/acme.notes.json"
    ),
  ])
  func switchingToTheCurrentStateWritesNothing(change: Switch, file: String) throws {
    let home = try FixtureHome()
    var change = change
    if case .serverInProject(let name, let project, let on) = change {
      change = .serverInProject(
        name: name, project: home.url.appending(path: project).path, on: on)
    }
    let original = try home.data(file)
    let outcome = apply(change, home)
    #expect(outcome.applied)
    #expect(outcome.issues.isEmpty)
    #expect(outcome.undo == nil)
    #expect(outcome.backup == nil)
    #expect(!outcome.wrote)
    #expect(home.backups.isEmpty)
    #expect(try home.data(file) == original)

    let opposite = apply(change.opposite, home)
    #expect(opposite.applied)
    #expect(opposite.wrote)
    #expect(try home.data(file) != original)
    #expect(Switches.isInEffect(change.opposite, home: home.url) == true)
    #expect(apply(try #require(opposite.undo), home).applied)
    #expect(try home.data(file) == original)
  }

  @Test func anUnexpectedShapeIsRefused() throws {
    let home = try FixtureHome()
    let beta = home.url.appending(path: "work/beta").path
    try home.edit(".claude.json") { config in
      var projects = config["projects"] as? [String: Any] ?? [:]
      projects[beta] = ["disabledMcpServers": "notes"]
      config["projects"] = projects
    }
    let before = try home.data(".claude.json")
    let outcome = apply(.serverInProject(name: "search", project: beta, on: false), home)
    #expect(!outcome.applied)
    #expect(
      outcome.issues.map(\.message) == ["Does not have the expected shape. Nothing was changed."])
    #expect(try home.data(".claude.json") == before)
    let unknownProject = apply(
      .serverInProject(name: "search", project: "/nowhere", on: false), home)
    #expect(!unknownProject.applied)
    #expect(try home.data(".claude.json") == before)
  }

  @Test func anExtensionIdentifierThatLeavesItsFolderIsRefused() throws {
    let home = try FixtureHome()
    for id in ["../../../../.claude/settings", "", ".hidden", "a/b"] {
      let outcome = apply(.desktopExtension(id: id, on: false), home)
      #expect(!outcome.applied)
      #expect(Switches.isInEffect(.desktopExtension(id: id, on: false), home: home.url) == nil)
    }
    #expect(home.backups.isEmpty)
  }

  @Test func cellsOfferSwitchesOnlyWhereOneEntryDecides() throws {
    let home = try FixtureHome()
    let inventory = load(home)
    let alpha = home.url.appending(path: "work/alpha").path
    #expect(
      Switches.offered(for: try inventory.row("Weather"), in: .desktop)
        == .desktopExtension(id: "acme.weather", on: false))
    #expect(
      Switches.offered(for: try inventory.row("positional"), in: .claudeCode)
        == .claudeCodeServer(name: "positional", on: false))
    #expect(
      Switches.offered(for: try inventory.row("search"), in: home.project("alpha"))
        == .serverInProject(name: "search", project: alpha, on: true))
    #expect(
      Switches.offered(for: try inventory.row("local-db"), in: home.project("alpha"))
        == .serverInProject(name: "local-db", project: alpha, on: false))
    #expect(
      Switches.offered(for: try inventory.row("approved"), in: home.project("alpha"))
        == .serverInProject(name: "approved", project: alpha, on: false))
    #expect(Switches.offered(for: try inventory.row("pending"), in: home.project("alpha")) == nil)
    #expect(Switches.offered(for: try inventory.row("helper-api"), in: .claudeCode) == nil)
    #expect(Switches.offered(for: try inventory.row("helper-api"), in: home.project("beta")) == nil)
    #expect(Switches.offered(for: try inventory.row("files"), in: .desktop) != nil)
    #expect(Switches.offered(for: try inventory.row("search"), in: .desktop) == nil)
    #expect(Switches.offered(for: try inventory.row("writing", .skill), in: .claudeCode) == nil)
    #expect(
      Switches.offered(for: try inventory.row("helper", .plugin), in: home.project("beta"))
        == .pluginInProject(
          id: "helper@market", project: home.url.appending(path: "work/beta").path, on: true))
  }

  @Test func onlyClaudeCodeMainFileChangesNeedADelayedCheck() {
    #expect(Switch.serverInProject(name: "a", project: "/p", on: true).needsDelayedCheck)
    #expect(Switch.claudeCodeServer(name: "a", on: true).needsDelayedCheck)
    #expect(!Switch.desktopServer(name: "a", on: true).needsDelayedCheck)
    #expect(!Switch.plugin(id: "a@b", on: true).needsDelayedCheck)
    #expect(Switch.plugin(id: "a@b", on: true).opposite == .plugin(id: "a@b", on: false))
  }
}
