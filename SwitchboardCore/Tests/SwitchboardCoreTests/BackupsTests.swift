import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct BackupsTests {
  @Test func listsBackupsNewestFirstWithTheirFile() throws {
    let home = try FixtureHome()
    let first = try Backups.save(
      Data("{}".utf8), of: Switches.settingsFile, supportFolder: home.support,
      date: Date(timeIntervalSince1970: 1_700_000_000))
    let second = try Backups.save(
      Data("{}".utf8), of: Switches.claudeCodeFile, supportFolder: home.support,
      date: Date(timeIntervalSince1970: 1_700_000_100))
    try Data().write(to: first.deletingLastPathComponent().appending(path: "notes.txt"))

    let backups = home.backups
    #expect(backups.map(\.url) == [second, first])
    #expect(backups.map(\.file) == [Switches.claudeCodeFile, Switches.settingsFile])
    #expect(backups.map(\.date.timeIntervalSince1970) == [1_700_000_100, 1_700_000_000])
  }

  @Test func keepsTheNewestTwentyPerFile() throws {
    let home = try FixtureHome()
    for second in 0..<25 {
      _ = try Backups.save(
        Data("{}".utf8), of: Switches.settingsFile, supportFolder: home.support,
        date: Date(timeIntervalSince1970: 1_700_000_000 + Double(second)))
    }
    _ = try Backups.save(Data("{}".utf8), of: Switches.desktopFile, supportFolder: home.support)
    let settings = home.backups.filter { $0.file == Switches.settingsFile }
    #expect(settings.count == Backups.limit)
    #expect(settings.last?.date.timeIntervalSince1970 == 1_700_000_005)
    #expect(home.backups.filter { $0.file == Switches.desktopFile }.count == 1)
  }

  @Test func refusesToSaveAFileThatIsNotAConfigurationFile() {
    #expect(throws: (any Error).self) {
      try Backups.save(
        Data("{}".utf8), of: "../outside.json", supportFolder: URL(fileURLWithPath: "/nonexistent"))
    }
  }

  @Test func restoreBringsTheFileBackAfterBackingUpTheCurrentOne() throws {
    let home = try FixtureHome()
    let original = try home.data(".claude.json")
    let outcome = Switches.apply(
      .claudeCodeServer(name: "notes", on: false), home: home.url, supportFolder: home.support)
    let changed = try home.data(".claude.json")
    let backup = try #require(home.backups.first { $0.url == outcome.backup })

    let restored = Backups.restore(backup, home: home.url, supportFolder: home.support)
    #expect(restored.applied)
    #expect(restored.issues.isEmpty)
    #expect(try home.data(".claude.json") == original)
    #expect(try Data(contentsOf: try #require(restored.backup)) == changed)
    #expect(home.backups.count == 2)

    let again = Backups.restore(backup, home: home.url, supportFolder: home.support)
    #expect(again.applied)
    #expect(again.backup == nil)
  }

  @Test func restoreRepairsAFileThatNoLongerParses() throws {
    let home = try FixtureHome()
    let original = try home.data(Switches.settingsFile)
    let backup = try Backups.save(original, of: Switches.settingsFile, supportFolder: home.support)
    try home.write("{ damaged", to: Switches.settingsFile)
    let listed = try #require(home.backups.first { $0.url == backup })

    let restored = Backups.restore(listed, home: home.url, supportFolder: home.support)
    #expect(restored.applied)
    #expect(try home.data(Switches.settingsFile) == original)
    #expect(try Data(contentsOf: try #require(restored.backup)) == Data("{ damaged".utf8))
  }

  @Test func restoreRefusesABackupOutsideTheBackupsFolder() throws {
    let home = try FixtureHome()
    let before = try home.data(".claude.json")
    let stray = Backup(
      url: home.url.appending(path: ".claude/settings.json"), file: Switches.claudeCodeFile,
      label: "", date: Date())
    let outcome = Backups.restore(stray, home: home.url, supportFolder: home.support)
    #expect(!outcome.applied)
    #expect(try home.data(".claude.json") == before)
  }

  @Test func aSymbolicLinkNamedLikeABackupIsNeitherListedNorRestored() throws {
    let home = try FixtureHome()
    let real = try Backups.save(
      Data("{}".utf8), of: Switches.claudeCodeFile, supportFolder: home.support,
      date: Date(timeIntervalSince1970: 1_700_000_000))
    let link = real.deletingLastPathComponent().appending(path: "1800000000000-0123abcd.json")
    try FileManager.default.createSymbolicLink(
      at: link, withDestinationURL: home.url.appending(path: Switches.settingsFile))
    #expect(home.backups.map(\.url) == [real])

    let before = try home.data(".claude.json")
    let forged = Backup(url: link, file: Switches.claudeCodeFile, label: "", date: Date())
    #expect(!Backups.restore(forged, home: home.url, supportFolder: home.support).applied)
    #expect(try home.data(".claude.json") == before)
  }

  @Test func restoreTakesTheTargetFromTheBackupsLocationNotItsFileProperty() throws {
    let home = try FixtureHome()
    let settings = try home.data(Switches.settingsFile)
    let claudeCode = try home.data(".claude.json")
    let saved = try Backups.save(settings, of: Switches.settingsFile, supportFolder: home.support)
    try home.write("{}", to: Switches.settingsFile)

    let mislabelled = Backup(url: saved, file: Switches.claudeCodeFile, label: "", date: Date())
    #expect(Backups.restore(mislabelled, home: home.url, supportFolder: home.support).applied)
    #expect(try home.data(Switches.settingsFile) == settings)
    #expect(try home.data(".claude.json") == claudeCode)
  }

  @Test func theBackupJustTakenIsKeptWhenTheClockIsBehind() throws {
    let home = try FixtureHome()
    for second in 0..<Backups.limit {
      _ = try Backups.save(
        Data("{}".utf8), of: Switches.settingsFile, supportFolder: home.support,
        date: Date(timeIntervalSince1970: 1_800_000_000 + Double(second)))
    }
    let behind = try Backups.save(
      Data("{\"new\": 1}".utf8), of: Switches.settingsFile, supportFolder: home.support,
      date: Date(timeIntervalSince1970: 1_700_000_000))
    #expect(FileManager.default.fileExists(atPath: behind.path))
    let settings = home.backups.filter { $0.file == Switches.settingsFile }
    #expect(settings.count == Backups.limit)
    #expect(settings.contains { $0.url == behind })
    #expect(!settings.contains { $0.date.timeIntervalSince1970 == 1_800_000_000 })
  }

  @Test func restoringAMissingFileCreatesItAndIsTellableFromNothingToDo() throws {
    let home = try FixtureHome()
    let original = try home.data(Switches.settingsFile)
    let saved = try Backups.save(original, of: Switches.settingsFile, supportFolder: home.support)
    let backup = try #require(home.backups.first { $0.url == saved })
    try FileManager.default.removeItem(at: home.url.appending(path: Switches.settingsFile))
    #expect(Backups.isRestored(backup, home: home.url, supportFolder: home.support) == false)

    let created = Backups.restore(backup, home: home.url, supportFolder: home.support)
    #expect(created.applied)
    #expect(created.wrote)
    #expect(created.backup == nil)
    #expect(try home.data(Switches.settingsFile) == original)
    #expect(Backups.isRestored(backup, home: home.url, supportFolder: home.support) == true)

    let nothing = Backups.restore(backup, home: home.url, supportFolder: home.support)
    #expect(nothing.applied)
    #expect(!nothing.wrote)

    try home.write("{}", to: Switches.settingsFile)
    #expect(Backups.isRestored(backup, home: home.url, supportFolder: home.support) == false)
  }
}

@Suite struct ProjectBackupLinkTests {
  private let settings = "work/alpha/" + Switches.projectSettingsFile

  private func projectBackup(_ home: FixtureHome) throws -> Backup {
    let alpha = home.url.appending(path: "work/alpha").path
    #expect(
      Switches.apply(
        .pluginInProject(id: "styler@market", project: alpha, on: false), home: home.url,
        supportFolder: home.support
      ).applied)
    return try #require(home.backups.first { $0.file.hasPrefix("/") })
  }

  private func restore(_ backup: Backup, _ home: FixtureHome) -> SwitchOutcome {
    Backups.restore(backup, home: home.url, supportFolder: home.support)
  }

  @Test func aProjectBackupIsRestored() throws {
    let home = try FixtureHome()
    let original = try home.data(settings)
    let outcome = restore(try projectBackup(home), home)
    #expect(outcome.applied)
    #expect(try home.data(settings) == original)
  }

  @Test func aLinkedSettingsFileIsNotWrittenThrough() throws {
    let home = try FixtureHome()
    let backup = try projectBackup(home)
    try home.write("{}", to: "outside.json")
    let file = home.url.appending(path: settings)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(
      at: file, withDestinationURL: home.url.appending(path: "outside.json"))
    let count = home.backups.count

    let outcome = restore(backup, home)
    #expect(!outcome.applied)
    #expect(
      outcome.issues.map(\.message)
        == ["Is a symbolic link or leaves the project. Nothing was changed."])
    #expect(outcome.issues.map(\.source) == ["settings.local.json in alpha"])
    #expect(try home.text("outside.json") == "{}")
    #expect(home.backups.count == count)
  }

  @Test func aLinkedClaudeFolderIsNotWrittenThrough() throws {
    let home = try FixtureHome()
    let backup = try projectBackup(home)
    let folder = home.url.appending(path: "work/alpha/.claude")
    let elsewhere = home.url.appending(path: "elsewhere")
    try FileManager.default.moveItem(at: folder, to: elsewhere)
    try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: elsewhere)
    let moved = try home.data("elsewhere/settings.local.json")

    let outcome = restore(backup, home)
    #expect(!outcome.applied)
    #expect(
      outcome.issues.map(\.message)
        == ["Is a symbolic link or leaves the project. Nothing was changed."])
    #expect(try home.data("elsewhere/settings.local.json") == moved)
  }
}
