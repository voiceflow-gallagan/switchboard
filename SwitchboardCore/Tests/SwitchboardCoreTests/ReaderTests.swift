import Foundation
import Testing

@testable import SwitchboardCore

/// A copy of the fixture home in a temporary folder. Claude Code stores absolute paths,
/// so the copy replaces the `__HOME__` placeholder with its own location.
/// The copy is removed when the value is released.
final class FixtureHome {
  static let secret = "SWB-FAKE-SECRET"

  let url: URL

  init() throws {
    let fileManager = FileManager.default
    let source = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
      .appending(path: "home")
    url = fileManager.temporaryDirectory.appending(path: "switchboard-\(UUID().uuidString)")
    try fileManager.copyItem(at: source, to: url)
    for file in [
      ".claude.json", ".claude/plugins/installed_plugins.json",
      ".claude/plugins/known_marketplaces.json",
    ] {
      let fileURL = url.appending(path: file)
      let text = try String(contentsOf: fileURL, encoding: .utf8)
      try text.replacingOccurrences(of: "__HOME__", with: url.path).write(
        to: fileURL, atomically: true, encoding: .utf8)
    }
    try fileManager.createSymbolicLink(
      at: url.appending(path: ".claude/skills/linked"),
      withDestinationURL: url.appending(path: "skill-store/linked")
    )
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }

  /// Replaces the JSON file at `relativePath` with the result of `change`.
  func edit(_ relativePath: String, _ change: (inout [String: Any]) -> Void) throws {
    let fileURL = url.appending(path: relativePath)
    var object = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
    change(&object)
    try JSONSerialization.data(withJSONObject: object).write(to: fileURL)
  }

  func project(_ name: String) -> Place {
    .project(path: url.appending(path: "work/\(name)").path)
  }

  func load() -> Inventory {
    Inventory.load(home: url)
  }
}

extension Inventory {
  func row(_ name: String, _ kind: Kind = .server) throws -> Row {
    try #require(rows.first { $0.kind == kind && $0.entries.contains { $0.name == name } })
  }
}

@Suite struct DesktopTests {
  @Test func readsConfigServersAndExtensions() throws {
    let inventory = try FixtureHome().load()
    let desktop = inventory.rows.flatMap(\.entries).filter { $0.place == .desktop }
    #expect(desktop.filter { $0.origin == "config" }.count == 4)
    #expect(desktop.filter { $0.origin == "extension" }.count == 2)
    #expect(try inventory.row("Weather").state(in: .desktop) == .on)
    #expect(try inventory.row("Notes Extension").state(in: .desktop) == .off)
    #expect(try inventory.row("Weather").entries[0].secretNames == ["WEATHER_KEY"])
  }

  @Test func keepsOnlyNamesOfCredentials() throws {
    let inventory = try FixtureHome().load()
    let tracker = try #require(
      inventory.rows.flatMap(\.entries).first { $0.name == "tracker" && $0.place == .desktop })
    #expect(tracker.target?.label == "docker")
    #expect(tracker.secretNames == ["TRACKER_KEY"])
    let browser = try inventory.row("browser").entries[0]
    #expect(browser.target?.label == "browser-mcp")
    #expect(browser.secretNames == ["Authorization", "X-Session"])
  }
}

@Suite struct ClaudeCodeServersTests {
  @Test func listsOnlyProjectsThatExist() throws {
    let home = try FixtureHome()
    let inventory = home.load()
    #expect(
      inventory.projects == [
        home.url.appending(path: "work/alpha").path, home.url.appending(path: "work/beta").path,
      ])
    #expect(!inventory.rows.contains { $0.name == "ghost" })
  }

  @Test func userServerIsOffWhereProjectDisablesIt() throws {
    let home = try FixtureHome()
    let inventory = home.load()
    let search = try inventory.row("search")
    #expect(search.state(in: .claudeCode) == .on)
    #expect(search.state(in: home.project("alpha")) == .off)
    #expect(search.state(in: home.project("beta")) == .on)
    #expect(search.state(in: .desktop) == .absent)
  }

  @Test func projectServerIsOnOnlyInItsProject() throws {
    let home = try FixtureHome()
    let localDB = try home.load().row("local-db")
    #expect(localDB.entries.count == 2)
    #expect(localDB.state(in: home.project("alpha")) == .on)
    #expect(localDB.state(in: .claudeCode) == .absent)
    #expect(!localDB.isDuplicate)
  }

  @Test func mcpJSONServerIsOnOnlyWhenApproved() throws {
    let home = try FixtureHome()
    let inventory = home.load()
    #expect(try inventory.row("approved").state(in: home.project("alpha")) == .on)
    #expect(try inventory.row("pending").state(in: home.project("alpha")) == .off)
    #expect(try inventory.row("pending").state(in: home.project("beta")) == .absent)
  }

  @Test func pluginServerFollowsPluginAndProjectLists() throws {
    let home = try FixtureHome()
    let inventory = home.load()
    let helperAPI = try inventory.row("helper-api")
    #expect(helperAPI.typeLabel == "plugin helper")
    #expect(helperAPI.state(in: .claudeCode) == .on)
    #expect(helperAPI.state(in: home.project("alpha")) == .off)
    #expect(helperAPI.state(in: home.project("beta")) == .off)
    let styler = try inventory.row("styler-server")
    #expect(styler.state(in: .claudeCode) == .off)
    #expect(styler.state(in: home.project("alpha")) == .on)
  }
}

@Suite struct PluginsAndSkillsTests {
  @Test func pluginStateComesFromUserAndProjectSettings() throws {
    let home = try FixtureHome()
    let inventory = home.load()
    let helper = try inventory.row("helper", .plugin)
    #expect(helper.typeLabel == "market")
    #expect(helper.state(in: .claudeCode) == .on)
    #expect(helper.state(in: home.project("beta")) == .off)
    let styler = try inventory.row("styler", .plugin)
    #expect(styler.state(in: .claudeCode) == .off)
    #expect(styler.state(in: home.project("alpha")) == .on)
  }

  @Test func readsSkillsFromEverySource() throws {
    let home = try FixtureHome()
    let inventory = home.load()
    let names = Set(inventory.rows.filter { $0.kind == .skill }.map(\.name))
    #expect(
      names == [
        "writing", "review", "linked", "beta-skill", "helper:helping", "helper:lone-skill",
        "styler:styling", "crlf-skill",
      ]
    )
    #expect(
      try inventory.row("linked", .skill).entries[0].description
        == "Reached through a symbolic link.")
    #expect(try inventory.row("writing", .skill).entries[0].description == "Writes clear prose.")
    #expect(
      try inventory.row("helper:helping", .skill).entries[0].description
        == "Helps with several things.")
    #expect(try inventory.row("helper:helping", .skill).state(in: home.project("beta")) == .off)
    #expect(try inventory.row("beta-skill", .skill).state(in: home.project("beta")) == .on)
    #expect(try inventory.row("beta-skill", .skill).state(in: .claudeCode) == .absent)
  }

  @Test func readsFrontMatterWithWindowsLineEndings() throws {
    let crlf = try FixtureHome().load().row("crlf-skill", .skill)
    #expect(crlf.entries[0].description == "Written on Windows.")
  }
}

@Suite struct ProjectAccessTests {
  @Test func loadWithoutProjectsTouchesNoProjectPath() throws {
    let home = try FixtureHome()
    let pipe = home.url.appending(path: "work/alpha/.mcp.json")
    try FileManager.default.removeItem(at: pipe)
    #expect(mkfifo(pipe.path, 0o600) == 0)
    let projectPaths = ["alpha", "beta", "gone"].map { home.url.appending(path: "work/\($0)").path }

    var files = SourceFiles(home: home.url)
    let log = AccessLog()
    files.accessLog = log
    let inventory = Inventory.load(&files, includingProjects: false)

    #expect(!log.paths.isEmpty)
    let touched = log.paths.filter { path in
      projectPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
    #expect(touched.isEmpty, "\(touched.count) project paths were touched")
    #expect(inventory.issues.isEmpty)
    #expect(inventory.projects == projectPaths.sorted())
    #expect(try inventory.row("local-db").entries.count == 2)
    #expect(try inventory.row("search").state(in: home.project("alpha")) == .off)
    #expect(!inventory.rows.contains { $0.name == "beta-skill" })
  }

  @Test func fullLoadStillReadsProjectFiles() throws {
    let home = try FixtureHome()
    let pipe = home.url.appending(path: "work/alpha/.mcp.json")
    try FileManager.default.removeItem(at: pipe)
    #expect(mkfifo(pipe.path, 0o600) == 0)
    #expect(home.load().issues.map(\.message) == ["Not a regular file"])
  }

  @Test func unreadableProjectIsOneIssueAndOthersLoad() throws {
    let home = try FixtureHome()
    let alpha = home.url.appending(path: "work/alpha")
    #expect(chmod(alpha.path, 0) == 0)
    defer { chmod(alpha.path, 0o755) }
    let inventory = home.load()
    #expect(inventory.issues.map(\.message) == ["Project folder could not be read"])
    #expect(inventory.issues.map(\.source) == ["alpha"])
    #expect(try inventory.row("beta-skill", .skill).state(in: home.project("beta")) == .on)
    #expect(inventory.projects.contains(alpha.path))
  }
}

@Suite struct CloudTests {
  @Test func historyListsConnectorNamesWithoutPrefixOnceAndSorted() throws {
    #expect(try FixtureHome().load().cloudHistory == ["Gmail", "Linear"])
  }
}

@Suite struct InventoryTests {
  @Test func fixtureLoadsWithoutIssues() throws {
    let inventory = try FixtureHome().load()
    #expect(inventory.issues.isEmpty)
    #expect(inventory.rows.filter { $0.kind == .server }.count == 32)
    #expect(inventory.rows.filter { $0.kind == .plugin }.count == 2)
  }

  @Test func serverReachedTwoWaysIsOneDuplicateRow() throws {
    let home = try FixtureHome()
    let inventory = home.load()
    let notes = try inventory.row("remote-notes")
    #expect(Set(notes.entries.map(\.name)) == ["remote-notes", "notes"])
    #expect(notes.isDuplicate)
    #expect(notes.state(in: .desktop) == .on)
    #expect(notes.state(in: home.project("beta")) == .off)
    #expect(try inventory.row("files").isDuplicate)
    #expect(inventory.rows.filter(\.isDuplicate).count == 2)
  }

  @Test func sameNameWithDifferentTargetIsConflict() throws {
    let trackers = try FixtureHome().load().rows.filter { $0.name == "tracker" }
    #expect(trackers.count == 2)
    #expect(trackers.allSatisfy { $0.hasNameConflict && !$0.isDuplicate })
  }

  @Test func sameNameInUnrelatedProjectsIsNotConflict() throws {
    let scratch = try FixtureHome().load().rows.filter { $0.name == "scratch" }
    #expect(scratch.count == 2)
    #expect(scratch.allSatisfy { !$0.hasNameConflict && !$0.isDuplicate })
  }

  @Test func serversWithoutTargetStayApart() throws {
    let inventory = try FixtureHome().load()
    #expect(try inventory.row("empty-one").entries.count == 1)
    #expect(try inventory.row("empty-two").entries.count == 1)
    #expect(try inventory.row("empty-one").id != inventory.row("empty-two").id)
  }

  @Test func addressesKeepOnlyHostAndPortInLabel() throws {
    let inventory = try FixtureHome().load()
    let labels = try [
      "path-secret", "hash-password", "question-password", "no-scheme-query", "no-scheme-user",
      "basic-auth",
    ].map { try inventory.row($0).entries[0].target?.label }
    #expect(
      labels == [
        "paths.example.test", "db.example.test", "hub.example.test", "host.example.test:5432",
        "nohost.example.test", "basic.example.test",
      ])
  }

  @Test func commandWithArgumentsIsLabelledByItsFirstWord() throws {
    let inventory = try FixtureHome().load()
    #expect(try inventory.row("command-args").entries[0].target?.label == "node")
    #expect(try inventory.row("split-header").entries[0].secretNames == ["Authorization"])
  }

  @Test func pluginPathOutsideItsFolderIsSkipped() throws {
    let home = try FixtureHome()
    try home.edit(".claude/plugins/cache/market/styler/2.0.0/.claude-plugin/plugin.json") {
      $0["skills"] = ["./extra", "../../../../../../skill-store"]
      $0["mcpServers"] = "../../../../../../.claude.json"
    }
    let inventory = home.load()
    #expect(!inventory.rows.contains { $0.name == "styler:linked" })
    #expect(try inventory.row("styler:styling", .skill).entries.count == 1)
    #expect(
      inventory.issues.map(\.message) == [
        "Skipped a path that leaves the plugin folder",
        "Skipped a path that leaves the plugin folder",
      ])
  }

  @Test func nonRegularFileIsRefusedWithoutBlocking() throws {
    let home = try FixtureHome()
    let pipe = home.url.appending(path: "work/beta/.mcp.json")
    #expect(mkfifo(pipe.path, 0o600) == 0)
    let inventory = home.load()
    #expect(inventory.issues.map(\.message) == ["Not a regular file"])
    #expect(try inventory.row("search").state(in: .claudeCode) == .on)
  }

  @Test func badEntriesAreSkippedOneByOne() throws {
    let home = try FixtureHome()
    let alpha = home.url.appending(path: "work/alpha").path
    try home.edit(".claude.json") { config in
      var servers = config["mcpServers"] as? [String: Any] ?? [:]
      servers["broken"] = ["command": "x", "args": [1]]
      config["mcpServers"] = servers
      var projects = config["projects"] as? [String: Any] ?? [:]
      projects[alpha] = ["mcpServers": 7]
      config["projects"] = projects
    }
    try home.edit(".claude/settings.json") { settings in
      settings["enabledPlugins"] = ["helper@market": true, "styler@market": "SWB-FAKE-SECRET-bad"]
    }
    try home.edit(".claude/plugins/installed_plugins.json") { installed in
      var plugins = installed["plugins"] as? [String: Any] ?? [:]
      plugins["ghost@market"] = "SWB-FAKE-SECRET-bad"
      installed["plugins"] = plugins
    }
    let inventory = home.load()

    #expect(inventory.issues.count == 4)
    #expect(inventory.issues.contains { $0.message.hasPrefix("Skipped server \"broken\"") })
    #expect(inventory.issues.contains { $0.message.hasPrefix("Skipped project \"alpha\"") })
    #expect(
      inventory.issues.contains { $0.message.hasPrefix("Skipped plugin setting \"styler@market\"") }
    )
    #expect(inventory.issues.contains { $0.message.hasPrefix("Skipped plugin \"ghost@market\"") })
    #expect(!inventory.issues.contains { $0.message.contains(FixtureHome.secret) })
    #expect(try inventory.row("search").state(in: .claudeCode) == .on)
    #expect(inventory.projects == [home.url.appending(path: "work/beta").path])
    #expect(inventory.cloudHistory == ["Gmail", "Linear"])
    #expect(try inventory.row("helper", .plugin).state(in: .claudeCode) == .on)
  }

  @Test func noCredentialValueIsReachable() throws {
    let inventory = try FixtureHome().load()
    var strings: [String] = inventory.rows.flatMap { [$0.id, $0.name, $0.typeLabel] }
    collectStrings(in: inventory, into: &strings)
    #expect(strings.count > 100)
    let leaks = strings.filter { $0.contains(FixtureHome.secret) }
    #expect(leaks.isEmpty, "\(leaks.count) strings hold a fixture credential")
  }

  @Test func malformedFileAddsOneIssueAndOthersStillLoad() throws {
    let home = try FixtureHome()
    try Data("{ not json".utf8).write(to: home.url.appending(path: ".claude/settings.json"))
    let inventory = home.load()
    #expect(inventory.issues.map(\.source) == ["~/.claude/settings.json"])
    #expect(try inventory.row("search").state(in: .claudeCode) == .on)
    #expect(try inventory.row("Weather").state(in: .desktop) == .on)
  }

  @Test func missingSourceAddsOneIssueAndOthersStillLoad() throws {
    let home = try FixtureHome()
    try FileManager.default.removeItem(
      at: home.url.appending(path: "Library/Application Support/Claude/claude_desktop_config.json")
    )
    let inventory = home.load()
    #expect(inventory.issues.count == 1)
    #expect(inventory.issues.first?.message == "File not found")
    #expect(try inventory.row("search").state(in: .claudeCode) == .on)
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

@Suite(.enabled(if: ProcessInfo.processInfo.environment["SWITCHBOARD_REAL_HOME"] == "1"))
struct RealHomeTests {
  @Test func printCounts() {
    let inventory = Inventory.load(home: FileManager.default.homeDirectoryForCurrentUser)
    let entries = inventory.rows.flatMap(\.entries)
    for kind in Kind.allCases {
      print("rows \(kind.rawValue): \(inventory.rows.filter { $0.kind == kind }.count)")
    }
    var byPlaceAndOrigin: [String: Int] = [:]
    for entry in entries {
      let place =
        switch entry.place {
        case .desktop: "desktop"
        case .claudeCode: "claudeCode"
        case .project: "project"
        }
      byPlaceAndOrigin[
        "\(entry.kind.rawValue) \(place) \(entry.origin) \(entry.state)", default: 0] += 1
    }
    for (key, count) in byPlaceAndOrigin.sorted(by: { $0.key < $1.key }) {
      print("entries \(key): \(count)")
    }
    for row in inventory.rows where row.isDuplicate {
      print("duplicate: \(row.entries.map { "\($0.name) [\($0.origin)]" }.joined(separator: ", "))")
    }
    print("name conflicts: \(inventory.rows.filter(\.hasNameConflict).map(\.name))")
    print("issues: \(inventory.issues.map { "\($0.source): \($0.message)" })")
    print("projects: \(inventory.projects.count)")
    print("cloud history: \(inventory.cloudHistory.count)")
  }

  /// Fails if any string reachable from the model contains "bearer". Prints where long
  /// credential-shaped runs appear, never the strings themselves. Target keys are digests and
  /// are left out of the long-run check.
  @Test func checkCredentialShapes() {
    let inventory = Inventory.load(home: FileManager.default.homeDirectoryForCurrentUser)
    let longToken = /[A-Za-z0-9_\-]{32,}/
    var bearerHits: [String] = []
    var longRunHits: [String] = []
    for row in inventory.rows {
      let keys = Set(row.entries.compactMap(\.target?.key))
      let rowID = keys.reduce(row.id) { $0.replacingOccurrences(of: $1, with: "") }
      var fields = [("row.id", rowID), ("row.name", row.name), ("row.typeLabel", row.typeLabel)]
      for entry in row.entries {
        fields += [("name", entry.name), ("origin", entry.origin), ("typeLabel", entry.typeLabel)]
        fields += entry.description.map { [("description", $0)] } ?? []
        fields += entry.secretNames.map { ("secretNames", $0) }
        fields += entry.projectOverrides.keys.map { ("projectOverrides", $0) }
        fields += entry.target.map { [("target.label", $0.label)] } ?? []
        for (field, value) in fields {
          let hit = "\(row.kind.rawValue) \(entry.name): \(field)"
          if value.lowercased().contains("bearer") {
            bearerHits.append(hit)
          }
          if value.contains(longToken) {
            longRunHits.append(hit)
          }
        }
        fields = []
      }
    }
    print("strings containing bearer: \(bearerHits.count)")
    for hit in Set(bearerHits).sorted() {
      print("bearer hit \(hit)")
    }
    print("strings with a long run: \(longRunHits.count)")
    for hit in Set(longRunHits).sorted() {
      print("long run hit \(hit)")
    }
    #expect(bearerHits.isEmpty)
  }
}
