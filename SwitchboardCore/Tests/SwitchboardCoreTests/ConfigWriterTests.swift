import Foundation
import Testing

@testable import SwitchboardCore

extension FixtureHome {
  /// Switchboard's support folder inside the copy, so it is removed with it.
  var support: URL {
    url.appending(path: "Library/Application Support/Switchboard")
  }

  func data(_ relativePath: String) throws -> Data {
    try Data(contentsOf: url.appending(path: relativePath))
  }

  func text(_ relativePath: String) throws -> String {
    try String(contentsOf: url.appending(path: relativePath), encoding: .utf8)
  }

  func write(_ text: String, to relativePath: String) throws {
    try Data(text.utf8).write(to: url.appending(path: relativePath))
  }

  func mode(_ path: String) throws -> Int {
    try #require(
      FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
  }

  var backups: [Backup] {
    Backups.list(supportFolder: support)
  }
}

/// Every string reachable from `value` through its stored properties.
func reachableStrings(in value: Any) -> [String] {
  if let string = value as? String {
    return [string]
  }
  if let url = value as? URL {
    return [url.path]
  }
  return Mirror(reflecting: value).children.flatMap { reachableStrings(in: $0.value) }
}

@Suite struct ConfigWriterTests {
  private let file = Switches.settingsFile
  private let path = ["enabledPlugins", "styler@market"]

  private func turnStylerOn(_ text: String) -> String? {
    JSONText.setBool(true, at: path, in: text)
  }

  @Test func changesOnlyTheValueAfterAnOwnerOnlyBackup() throws {
    let home = try FixtureHome()
    let original = try home.text(file)
    let settings = home.url.appending(path: file)
    #expect(chmod(settings.path, 0o640) == 0)

    let result = ConfigWriter.change(
      file, home: home.url, supportFolder: home.support, edit: turnStylerOn)

    #expect(result.issues.isEmpty)
    #expect(
      try home.text(file)
        == original.replacingOccurrences(
          of: "\"styler@market\": false", with: "\"styler@market\": true"))
    #expect(try home.mode(settings.path) == 0o640)
    let backup = try #require(result.backup)
    #expect(try Data(contentsOf: backup) == Data(original.utf8))
    #expect(try home.mode(backup.path) == 0o600)
    for folder in [
      home.support, home.support.appending(path: "Backups"), backup.deletingLastPathComponent(),
    ] {
      #expect(try home.mode(folder.path) == 0o700)
    }
    #expect(home.backups.map(\.file) == [file])
  }

  @Test func aChangeAlreadyInPlaceWritesNothingAndMakesNoBackup() throws {
    let home = try FixtureHome()
    let original = try home.data(file)
    let result = ConfigWriter.change(
      file, home: home.url, supportFolder: home.support,
      edit: { JSONText.setBool(false, at: path, in: $0) })
    #expect(result.issues.isEmpty)
    #expect(result.backup == nil)
    #expect(try home.data(file) == original)
    #expect(!FileManager.default.fileExists(atPath: home.support.path))
  }

  @Test func aFileThatDoesNotParseIsNeverWritten() throws {
    let home = try FixtureHome()
    try home.write("{ \"enabledPlugins\": ", to: file)
    let result = ConfigWriter.change(
      file, home: home.url, supportFolder: home.support, edit: turnStylerOn)
    #expect(result.issues.map(\.message) == ["Not valid JSON. Nothing was changed."])
    #expect(result.issues.map(\.source) == ["~/.claude/settings.json"])
    #expect(try home.text(file) == "{ \"enabledPlugins\": ")
    #expect(home.backups.isEmpty)
  }

  @Test func anUnexpectedShapeIsNeverWritten() throws {
    let home = try FixtureHome()
    try home.write("{ \"enabledPlugins\": [] }", to: file)
    let result = ConfigWriter.change(
      file, home: home.url, supportFolder: home.support, edit: turnStylerOn)
    #expect(
      result.issues.map(\.message) == ["Does not have the expected shape. Nothing was changed."])
    #expect(try home.text(file) == "{ \"enabledPlugins\": [] }")
    #expect(home.backups.isEmpty)
  }

  @Test func aMissingFileIsAnIssue() throws {
    let home = try FixtureHome()
    try FileManager.default.removeItem(at: home.url.appending(path: file))
    let result = ConfigWriter.change(
      file, home: home.url, supportFolder: home.support, edit: turnStylerOn)
    #expect(result.issues.map(\.message) == ["File not found"])
  }

  @Test func aFileChangedBetweenReadAndWriteIsReadAgain() throws {
    let home = try FixtureHome()
    var changes = 0
    let result = ConfigWriter.change(
      file, home: home.url, supportFolder: home.support, edit: turnStylerOn,
      beforeCompare: {
        changes += 1
        if changes == 1 {
          try? home.write(
            "{ \"enabledPlugins\": { \"styler@market\": false }, \"other\": 1 }", to: file)
        }
      })
    #expect(result.issues.isEmpty)
    #expect(changes == 2)
    #expect(
      try home.text(file) == "{ \"enabledPlugins\": { \"styler@market\": true }, \"other\": 1 }")
    #expect(home.backups.count == 1)
    #expect(try Data(contentsOf: try #require(result.backup)).count > 0)
  }

  @Test func aFileThatKeepsChangingIsLeftAlone() throws {
    let home = try FixtureHome()
    var changes = 0
    let result = ConfigWriter.change(
      file, home: home.url, supportFolder: home.support, edit: turnStylerOn,
      beforeCompare: {
        changes += 1
        try? home.write(
          "{ \"enabledPlugins\": { \"styler@market\": false }, \"n\": \(changes) }", to: file)
      })
    #expect(result.issues.map(\.message) == ["Kept changing while saving. Nothing was changed."])
    #expect(changes == ConfigWriter.attempts)
    #expect(try home.text(file) == "{ \"enabledPlugins\": { \"styler@market\": false }, \"n\": 3 }")
    #expect(home.backups.isEmpty)
  }

  @Test func aSymbolicLinkStaysAndItsTargetIsReplaced() throws {
    let home = try FixtureHome()
    let link = home.url.appending(path: file)
    let target = home.url.appending(path: "dotfiles/settings.json")
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: link, to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    let result = ConfigWriter.change(
      file, home: home.url, supportFolder: home.support, edit: turnStylerOn)

    #expect(result.issues.isEmpty)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
    #expect(try String(contentsOf: target, encoding: .utf8).contains("\"styler@market\": true"))
  }

  @Test func aReadBackThatDoesNotParseRestoresTheBackup() throws {
    let home = try FixtureHome()
    let original = try home.data(file)
    let result = ConfigWriter.change(
      file, home: home.url, supportFolder: home.support, edit: turnStylerOn,
      afterReplace: { try? home.write("{ damaged", to: file) })
    #expect(
      result.issues.map(\.message)
        == ["Could not be verified after saving. The backup was restored."])
    #expect(try home.data(file) == original)
    #expect(result.backup != nil)
  }

  @Test func aReadBackWithoutTheChangeIsReportedAndNotOverwritten() throws {
    let home = try FixtureHome()
    let rewritten = "{ \"enabledPlugins\": { \"styler@market\": false }, \"n\": 1 }"
    let result = ConfigWriter.change(
      file, home: home.url, supportFolder: home.support, edit: turnStylerOn,
      afterReplace: { try? home.write(rewritten, to: file) })
    #expect(
      result.issues.map(\.message)
        == ["Another program rewrote the file while saving. The change did not stay."])
    #expect(try home.text(file) == rewritten)
  }

  @Test func aFailedWriteLeavesTheFileAndNoBackup() throws {
    let home = try FixtureHome()
    let folder = home.url.appending(path: ".claude")
    let original = try home.data(file)
    #expect(chmod(folder.path, 0o500) == 0)
    defer { chmod(folder.path, 0o755) }
    let result = ConfigWriter.change(
      file, home: home.url, supportFolder: home.support, edit: turnStylerOn)
    #expect(result.issues.map(\.message) == ["Could not be written. Nothing was changed."])
    #expect(try home.data(file) == original)
    #expect(home.backups.isEmpty)
  }

  @Test func theCompareComesAfterTheNewTextIsWrittenAndRightBeforeTheRename() throws {
    let home = try FixtureHome()
    let folder = home.url.appending(path: ".claude")
    var waitingFiles: [String] = []
    let result = ConfigWriter.change(
      file, home: home.url, supportFolder: home.support, edit: turnStylerOn,
      beforeCompare: {
        waitingFiles =
          ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
          .filter { $0.contains(ConfigWriter.temporaryMarker) }
      })
    #expect(result.issues.isEmpty)
    #expect(waitingFiles.count == 1)
    let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    #expect(!left.contains { $0.contains(ConfigWriter.temporaryMarker) })
  }

  @Test func staleTemporaryFilesOfThisTargetAreRemoved() throws {
    let home = try FixtureHome()
    let fileManager = FileManager.default
    let folder = home.url.appending(path: ".claude")
    func temporary(_ target: String) -> URL {
      folder.appending(path: ".\(target)\(ConfigWriter.temporaryMarker)\(UUID().uuidString)")
    }
    let old = Date(timeIntervalSinceNow: -3600)
    let stale = temporary("settings.json")
    let fresh = temporary("settings.json")
    let otherTarget = temporary("other.json")
    let staleLink = temporary("settings.json")
    let staleFolder = temporary("settings.json")
    for url in [stale, fresh, otherTarget] {
      try Data("{}".utf8).write(to: url)
    }
    try fileManager.createSymbolicLink(at: staleLink, withDestinationURL: stale)
    try fileManager.createDirectory(at: staleFolder, withIntermediateDirectories: false)
    for url in [stale, otherTarget, staleFolder] {
      try fileManager.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
    }
    #expect(
      utimensat(
        AT_FDCWD, staleLink.path,
        [timespec(tv_sec: 0, tv_nsec: 0), timespec(tv_sec: 0, tv_nsec: 0)], AT_SYMLINK_NOFOLLOW)
        == 0)

    let result = ConfigWriter.change(
      file, home: home.url, supportFolder: home.support, edit: turnStylerOn)

    #expect(result.issues.isEmpty)
    #expect(!fileManager.fileExists(atPath: stale.path))
    for url in [fresh, otherTarget, staleFolder] {
      #expect(fileManager.fileExists(atPath: url.path))
    }
    #expect((try? fileManager.destinationOfSymbolicLink(atPath: staleLink.path)) != nil)
  }
}
