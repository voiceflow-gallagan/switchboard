import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct PluginInProjectSwitchesTests {
  private func apply(_ change: Switch, _ home: FixtureHome) -> SwitchOutcome {
    Switches.apply(change, home: home.url, supportFolder: home.support)
  }

  private func load(_ home: FixtureHome) -> Inventory {
    Inventory.load(home: home.url, supportFolder: home.support)
  }

  private func path(_ home: FixtureHome, _ project: String) -> String {
    home.url.appending(path: "work/\(project)").path
  }

  private func settings(_ home: FixtureHome, _ project: String) -> String {
    "work/\(project)/" + Switches.projectSettingsFile
  }

  @Test func aValueInAnExistingPersonalFileIsChangedAndUndoneExactly() throws {
    let home = try FixtureHome()
    let alpha = path(home, "alpha")
    let original = try home.data(settings(home, "alpha"))
    let change = try #require(
      Switches.offered(for: load(home).row("styler", .plugin), in: home.project("alpha")))
    #expect(change == .pluginInProject(id: "styler@market", project: alpha, on: false))

    let outcome = apply(change, home)
    #expect(outcome.applied)
    #expect(outcome.created == [])
    #expect(try load(home).row("styler", .plugin).state(in: home.project("alpha")) == .off)
    #expect(Switches.isInEffect(change, home: home.url) == true)
    #expect(apply(try #require(outcome.undo), home).applied)
    #expect(try home.data(settings(home, "alpha")) == original)
  }

  @Test func aPluginOnOnlyAtUserLevelIsSwitchedOffByWritingFalse() throws {
    let home = try FixtureHome()
    let alpha = path(home, "alpha")
    let file = settings(home, "alpha")
    let original = try home.data(file)
    let change = try #require(
      Switches.offered(for: load(home).row("helper", .plugin), in: home.project("alpha")))
    #expect(change == .pluginInProject(id: "helper@market", project: alpha, on: false))

    let outcome = apply(change, home)
    #expect(outcome.applied)
    #expect(outcome.created == [.key])
    #expect(try home.text(file).contains("\"helper@market\": false"))
    #expect(try load(home).row("helper", .plugin).state(in: home.project("alpha")) == .off)
    #expect(try load(home).row("helper", .plugin).state(in: .claudeCode) == .on)

    let undo = try #require(outcome.undo)
    #expect(
      undo == .pluginInProject(id: "helper@market", project: alpha, on: true, removing: [.key]))
    #expect(apply(undo, home).applied)
    #expect(try home.data(file) == original)
    #expect(Switches.isInEffect(undo, home: home.url) == true)
  }

  @Test func aMissingPersonalFileIsCreatedOverTheSharedFileAndRemovedByUndo() throws {
    let home = try FixtureHome()
    let beta = path(home, "beta")
    let file = settings(home, "beta")
    let shared = try home.data("work/beta/.claude/settings.json")
    let change = try #require(
      Switches.offered(for: load(home).row("helper", .plugin), in: home.project("beta")))
    #expect(change == .pluginInProject(id: "helper@market", project: beta, on: true))

    let outcome = apply(change, home)
    #expect(outcome.applied)
    #expect(outcome.created == [.file, .key])
    #expect(
      try home.text(file) == "{\n  \"enabledPlugins\": {\n    \"helper@market\": true\n  }\n}")
    #expect(try load(home).row("helper", .plugin).state(in: home.project("beta")) == .on)

    #expect(apply(try #require(outcome.undo), home).applied)
    #expect(!FileManager.default.fileExists(atPath: home.url.appending(path: file).path))
    #expect(try home.data("work/beta/.claude/settings.json") == shared)
    #expect(try load(home).row("helper", .plugin).state(in: home.project("beta")) == .off)
  }

  @Test func aMissingFolderIsCreatedAndRemovedByUndo() throws {
    let home = try FixtureHome()
    let gamma = home.url.appending(path: "work/gamma")
    try FileManager.default.createDirectory(at: gamma, withIntermediateDirectories: false)
    let outcome = apply(.pluginInProject(id: "styler@market", project: gamma.path, on: true), home)
    #expect(outcome.applied)
    #expect(outcome.created == [.folder, .file, .key])
    #expect(
      home.backups.contains {
        $0.file == settings(home, "gamma").replacingOccurrences(of: "work/gamma", with: gamma.path)
      })

    #expect(apply(try #require(outcome.undo), home).applied)
    #expect(try FileManager.default.contentsOfDirectory(atPath: gamma.path).isEmpty)
  }

  @Test func aMissingProjectFolderIsRefused() throws {
    let home = try FixtureHome()
    let outcome = apply(.pluginInProject(id: "a@b", project: path(home, "nowhere"), on: true), home)
    #expect(!outcome.applied)
    #expect(!FileManager.default.fileExists(atPath: path(home, "nowhere")))
  }

  @Test func onlyThatProjectsSessionsMustRestart() {
    let processes = [
      RunningProcess(
        id: 20, parent: 1, footprint: 0, programPath: "/opt/homebrew/bin/claude", target: nil,
        workingFolder: "/work/alpha"),
      RunningProcess(
        id: 21, parent: 1, footprint: 0, programPath: "/opt/homebrew/bin/claude", target: nil,
        workingFolder: "/work/beta"),
    ]
    let inventory = Inventory(
      rows: [], issues: [], projects: ["/work/alpha", "/work/beta"], cloudHistory: [])
    let needs = RestartNeeds.needs(
      for: .pluginInProject(id: "a@b", project: "/work/alpha", on: false), processes: processes,
      inventory: inventory)
    #expect(needs.map(\.id) == [20])
  }
}

@Suite struct ProjectSettingsLinkTests {
  private func apply(_ change: Switch, _ home: FixtureHome) -> SwitchOutcome {
    Switches.apply(change, home: home.url, supportFolder: home.support)
  }

  private func gamma(_ home: FixtureHome) throws -> URL {
    let folder = home.url.appending(path: "work/gamma")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    return folder
  }

  @Test func aLinkedSettingsFileIsRefused() throws {
    let home = try FixtureHome()
    let project = try gamma(home)
    let claude = project.appending(path: ".claude")
    try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(
      at: claude.appending(path: "settings.local.json"),
      withDestinationURL: home.url.appending(path: ".claude.json"))
    let original = try home.data(".claude.json")

    let outcome = apply(.pluginInProject(id: "a@b", project: project.path, on: true), home)
    #expect(!outcome.applied)
    #expect(
      outcome.issues.map(\.message)
        == ["Is a symbolic link or leaves the project. Nothing was changed."])
    #expect(outcome.issues.map(\.source) == ["settings.local.json in gamma"])
    #expect(try home.data(".claude.json") == original)
    #expect(home.backups.isEmpty)
    #expect(
      Switches.isInEffect(
        .pluginInProject(id: "a@b", project: project.path, on: true), home: home.url) == nil)
  }

  @Test func aLinkedClaudeFolderIsRefused() throws {
    let home = try FixtureHome()
    let project = try gamma(home)
    let elsewhere = home.url.appending(path: "elsewhere")
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(
      at: project.appending(path: ".claude"), withDestinationURL: elsewhere)

    let outcome = apply(.pluginInProject(id: "a@b", project: project.path, on: true), home)
    #expect(!outcome.applied)
    #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)

    let added = Switches.addProject(
      folder: project, copyingFrom: home.url.appending(path: "work/alpha").path, home: home.url,
      supportFolder: home.support)
    #expect(!added.applied)
    #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    #expect(
      !Inventory.load(home: home.url).projects.contains(Paths.realPath(project.path) ?? ""))
  }

  @Test func aLinkSwappedInAfterTheFirstCheckIsRefusedAtTheRename() throws {
    let home = try FixtureHome()
    let alpha = home.url.appending(path: "work/alpha")
    let settings = alpha.appending(path: Switches.projectSettingsFile)
    let original = try home.data(".claude.json")
    let fileManager = FileManager.default

    let outcome = Switches.pluginInProject(
      "a@b", project: alpha.path, on: true, removing: [], home: home.url, support: home.support,
      beforeCompare: {
        try? fileManager.removeItem(at: settings)
        try? fileManager.createSymbolicLink(
          at: settings, withDestinationURL: home.url.appending(path: ".claude.json"))
      })

    #expect(!outcome.applied)
    #expect(
      outcome.issues.map(\.message)
        == ["Is a symbolic link or leaves the project. Nothing was changed."])
    #expect(try home.data(".claude.json") == original)
    #expect(home.backups.isEmpty)
    for folder in [home.url, alpha.appending(path: ".claude")] {
      let left = try fileManager.contentsOfDirectory(atPath: folder.path)
      #expect(!left.contains { $0.contains(ConfigWriter.temporaryMarker) })
    }
  }

  @Test func aNormalProjectIsWritten() throws {
    let home = try FixtureHome()
    let project = try gamma(home)
    let outcome = apply(.pluginInProject(id: "a@b", project: project.path, on: true), home)
    #expect(outcome.applied)
    #expect(Switches.safeSettingsURL(project.path) != nil)
  }
}

@Suite struct AddProjectUndoOrderTests {
  @Test func theEntryIsRemovedBeforeThePluginSettings() throws {
    let home = try FixtureHome()
    let folder = home.url.appending(path: "work/gamma")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let added = try #require(
      Switches.addProject(
        folder: folder, copyingFrom: home.url.appending(path: "work/alpha").path,
        home: home.url, supportFolder: home.support
      ).added)
    let settings = try Data(contentsOf: Switches.settingsURL(added.path))
    let changed = try #require(
      JSONText.addString(
        "x", toArrayAt: ["projects", added.path, "disabledMcpServers"],
        in: try home.text(".claude.json")))
    try home.write(changed, to: ".claude.json")

    #expect(!Switches.removeProject(added, home: home.url, supportFolder: home.support).applied)
    #expect(try Data(contentsOf: Switches.settingsURL(added.path)) == settings)
  }
}

@Suite struct AddProjectTests {
  private func gamma(_ home: FixtureHome) throws -> URL {
    let folder = home.url.appending(path: "work/gamma")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    return folder
  }

  @Test func anEmptyProjectIsAddedListedAndUndoneExactly() throws {
    let home = try FixtureHome()
    let folder = try gamma(home)
    let real = try #require(Paths.realPath(folder.path))
    let original = try home.data(".claude.json")

    let outcome = Switches.addProject(
      folder: folder, copyingFrom: nil, home: home.url, supportFolder: home.support)
    #expect(outcome.applied)
    #expect(outcome.issues.isEmpty)
    let added = try #require(outcome.added)
    #expect(added.path == real)
    #expect(try Data(contentsOf: try #require(outcome.backup)) == original)
    #expect(
      try home.text(".claude.json").contains(
        "\"\(real)\": {\n      \"disabledMcpServers\": []\n    }"))
    #expect(Inventory.load(home: home.url).projects.contains(real))
    #expect(!FileManager.default.fileExists(atPath: folder.appending(path: ".claude").path))

    let removed = Switches.removeProject(added, home: home.url, supportFolder: home.support)
    #expect(removed.applied)
    #expect(try home.data(".claude.json") == original)
    #expect(!Inventory.load(home: home.url).projects.contains(real))
  }

  @Test func copyingTakesTheOffListAndPersonalPluginSettings() throws {
    let home = try FixtureHome()
    let folder = try gamma(home)
    let real = try #require(Paths.realPath(folder.path))
    let alpha = home.url.appending(path: "work/alpha").path
    let original = try home.data(".claude.json")

    let outcome = Switches.addProject(
      folder: folder, copyingFrom: alpha, home: home.url, supportFolder: home.support)
    #expect(outcome.applied)
    let inventory = Inventory.load(home: home.url)
    let place = Place.project(path: real)
    #expect(inventory.projects.contains(real))
    #expect(try inventory.row("search").state(in: place) == .off)
    #expect(try inventory.row("helper-api").state(in: place) == .off)
    #expect(try inventory.row("tracker").state(in: .claudeCode) == .on)
    #expect(try inventory.row("styler", .plugin).state(in: place) == .on)
    #expect(
      try String(contentsOf: Switches.settingsURL(real), encoding: .utf8)
        == "{\n  \"enabledPlugins\": {\n    \"styler@market\": true\n  }\n}")

    let added = try #require(outcome.added)
    #expect(Switches.removeProject(added, home: home.url, supportFolder: home.support).applied)
    #expect(try home.data(".claude.json") == original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
  }

  @Test func aFolderThatHasAnEntryOrDoesNotExistIsRefused() throws {
    let home = try FixtureHome()
    let original = try home.data(".claude.json")
    for folder in [
      home.url.appending(path: "work/alpha"), home.url.appending(path: "work/missing"),
      home.url.appending(path: ".claude.json"),
    ] {
      let outcome = Switches.addProject(
        folder: folder, copyingFrom: nil, home: home.url, supportFolder: home.support)
      #expect(!outcome.applied)
      #expect(outcome.added == nil)
    }
    let missingSource = Switches.addProject(
      folder: try gamma(home), copyingFrom: "/nowhere", home: home.url,
      supportFolder: home.support)
    #expect(!missingSource.applied)
    #expect(try home.data(".claude.json") == original)
    #expect(home.backups.isEmpty)
  }

  @Test func aLinkedFolderIsKeyedByItsRealPath() throws {
    let home = try FixtureHome()
    let folder = try gamma(home)
    let link = home.url.appending(path: "work/gamma-link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
    let outcome = Switches.addProject(
      folder: link, copyingFrom: nil, home: home.url, supportFolder: home.support)
    #expect(outcome.added?.path == Paths.realPath(folder.path))
    let again = Switches.addProject(
      folder: folder, copyingFrom: nil, home: home.url, supportFolder: home.support)
    #expect(!again.applied)
  }

  @Test func anEntryClaudeCodeChangedIsNotRemoved() throws {
    let home = try FixtureHome()
    let folder = try gamma(home)
    let added = try #require(
      Switches.addProject(
        folder: folder, copyingFrom: nil, home: home.url, supportFolder: home.support
      ).added)
    let changed = try #require(
      JSONText.addString(
        "x", toArrayAt: ["projects", added.path, "disabledMcpServers"],
        in: try home.text(".claude.json")))
    try home.write(changed, to: ".claude.json")

    let removed = Switches.removeProject(added, home: home.url, supportFolder: home.support)
    #expect(!removed.applied)
    #expect(try home.text(".claude.json") == changed)
  }

  @Test func issuesNameProjectsWithoutTheirPath() throws {
    let home = try FixtureHome()
    let other = home.url.appending(path: "elsewhere/alpha")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    var issues = Switches.addProject(
      folder: home.url.appending(path: "work/alpha"), copyingFrom: nil, home: home.url,
      supportFolder: home.support
    ).issues
    issues +=
      Switches.addProject(
        folder: try gamma(home), copyingFrom: "/nowhere/beta", home: home.url,
        supportFolder: home.support
      ).issues
    issues +=
      Switches.apply(
        .pluginInProject(id: "a@b", project: other.appending(path: "gone").path, on: true),
        home: home.url, supportFolder: home.support
      ).issues
    try home.write("{ damaged", to: "work/alpha/" + Switches.projectSettingsFile)
    issues +=
      Switches.apply(
        .pluginInProject(id: "a@b", project: home.url.appending(path: "work/alpha").path, on: true),
        home: home.url, supportFolder: home.support
      ).issues
    issues += Inventory.load(home: home.url).issues

    #expect(
      Switches.apply(
        .pluginInProject(
          id: "a@b", project: home.url.appending(path: "work/beta").path, on: true),
        home: home.url, supportFolder: home.support
      ).applied)
    let projectBackups = home.backups.filter { $0.file.hasPrefix("/") }
    #expect(projectBackups.map(\.label) == ["settings.local.json in beta"])
    #expect(home.backups.allSatisfy { $0.label.hasPrefix("~/") || !$0.label.contains("/") })
    #expect(issues.count >= 4)
    #expect(issues.map(\.source).contains("alpha"))
    #expect(issues.map(\.source).contains("settings.local.json in alpha"))
    for issue in issues {
      #expect(!issue.source.contains("/"))
      #expect(!issue.message.contains("/"))
    }
  }

  @Test func aMissingProjectListIsCreatedAndUndoneExactly() throws {
    let home = try FixtureHome()
    let folder = try gamma(home)
    let real = try #require(Paths.realPath(folder.path))
    let text = try home.text(".claude.json")
    try home.write(
      try #require(JSONText.removeMember(at: ["projects"], in: text)).text, to: ".claude.json")
    let original = try home.data(".claude.json")

    let outcome = Switches.addProject(
      folder: folder, copyingFrom: nil, home: home.url, supportFolder: home.support)
    #expect(outcome.applied)
    #expect(
      try home.text(".claude.json").hasSuffix(
        "\"projects\": {\n    \"\(real)\": {\n      \"disabledMcpServers\": []\n    }\n  }\n}\n"))
    #expect(Inventory.load(home: home.url).projects == [real])

    let removed = Switches.removeProject(
      try #require(outcome.added), home: home.url, supportFolder: home.support)
    #expect(removed.applied)
    #expect(try home.data(".claude.json") == original)
  }

  @Test func undoThatCannotEditTheFileFailsAndKeepsThePluginSettings() throws {
    let home = try FixtureHome()
    let added = try #require(
      Switches.addProject(
        folder: try gamma(home), copyingFrom: home.url.appending(path: "work/alpha").path,
        home: home.url, supportFolder: home.support
      ).added)
    let settings = try Data(contentsOf: Switches.settingsURL(added.path))
    let text = try home.text(".claude.json")
    let key = "\"\(added.path)\": {"
    let duplicated = text.replacingOccurrences(of: key, with: "\"\(added.path)\": {},\n    " + key)
    #expect(duplicated != text)
    try home.write(duplicated, to: ".claude.json")

    let removed = Switches.removeProject(added, home: home.url, supportFolder: home.support)
    #expect(!removed.applied)
    #expect(
      removed.issues.map(\.message)
        == ["Does not have the expected shape. The project was not removed."])
    #expect(try home.text(".claude.json") == duplicated)
    #expect(try Data(contentsOf: Switches.settingsURL(added.path)) == settings)

    let gone = try #require(JSONText.removeMember(at: ["projects", added.path], in: text)).text
    try home.write(gone, to: ".claude.json")
    #expect(Switches.removeProject(added, home: home.url, supportFolder: home.support).applied)
    try home.write(
      try #require(JSONText.removeMember(at: ["projects"], in: gone)).text, to: ".claude.json")
    #expect(Switches.removeProject(added, home: home.url, supportFolder: home.support).applied)
  }

  @Test func aProjectGoneBeforeItIsReadBackIsReported() throws {
    let home = try FixtureHome()
    let folder = try gamma(home)
    let original = try home.data(".claude.json")
    let outcome = Switches.addProject(
      folder: folder, copyingFrom: nil, home: home.url, supportFolder: home.support,
      beforeReadingBack: { try? original.write(to: home.url.appending(path: ".claude.json")) })
    #expect(!outcome.applied)
    #expect(outcome.added == nil)
    #expect(outcome.backup != nil)
    #expect(
      outcome.issues.map(\.message) == [
        "Was added, but could not be read back. A running Claude Code session may have removed it."
      ])
    #expect(outcome.issues.map(\.source) == ["gamma"])
  }

  @Test func aRealPathIsAbsoluteWithLinksResolved() throws {
    let home = try FixtureHome()
    let folder = try gamma(home)
    let link = home.url.appending(path: "work/gamma-link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
    let real = try #require(Paths.realPath(folder.path))
    #expect(Paths.realPath(link.path) == real)
    #expect(Paths.realPath(link.path + "/../gamma") == real)
    #expect(Paths.realPath("work/gamma") == nil)
    #expect(Paths.realPath(home.url.appending(path: "work/missing").path) == nil)
  }

  @Test func projectsWithTheSameFolderNameGetTheirParentsName() {
    let projects = ["/a/work/alpha", "/b/home/alpha", "/c/beta"]
    #expect(SourceFiles.projectName("/a/work/alpha", among: projects) == "alpha (work)")
    #expect(SourceFiles.projectName("/c/beta", among: projects) == "beta")
  }
}
