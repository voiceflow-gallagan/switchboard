import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct DiskUsageTests {
  private let fileManager = FileManager.default

  private func write(_ bytes: Int, to url: URL) throws {
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 7, count: bytes).write(to: url)
  }

  @Test func measuresEachCategoryWithoutFollowingLinks() throws {
    let home = fileManager.temporaryDirectory.appending(path: "switchboard-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: home) }
    let cache = home.appending(path: ".claude/plugins/cache/market/helper")
    try write(100_000, to: cache.appending(path: "2.0.0/skills/a/SKILL.md"))
    try write(300_000, to: cache.appending(path: "1.0.0/skills/a/SKILL.md"))
    let installed = """
      {"plugins": {"helper@market": [{"scope": "user", "installPath": "\(cache.appending(path: "2.0.0").path)"}]}}
      """
    try Data(installed.utf8).write(
      to: home.appending(path: ".claude/plugins/installed_plugins.json"))
    try write(
      50_000,
      to: home.appending(path: "Library/Application Support/Claude/Claude Extensions/x/a.js"))
    try write(20_000, to: home.appending(path: ".claude/skills/own/SKILL.md"))
    try write(2_000_000, to: home.appending(path: "elsewhere/big/SKILL.md"))
    try fileManager.createSymbolicLink(
      at: home.appending(path: ".claude/skills/linked"),
      withDestinationURL: home.appending(path: "elsewhere/big"))

    let report = DiskReport.scan(home: home)
    let sizes = report.sizes
    #expect(report.issues.isEmpty)
    #expect((100_000..<300_000).contains(sizes[.plugins] ?? 0))
    #expect((300_000..<1_000_000).contains(sizes[.oldPluginVersions] ?? 0))
    #expect((50_000..<300_000).contains(sizes[.extensions] ?? 0))
    #expect((20_000..<300_000).contains(sizes[.skills] ?? 0))
    #expect(report.linkedSkills == 1)
  }

  @Test func installPathOutsideThePluginsFolderIsSkipped() throws {
    let home = fileManager.temporaryDirectory.appending(path: "switchboard-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: home) }
    try write(500_000, to: home.appending(path: "Documents/private.bin"))
    let installed = """
      {"plugins": {"wide@market": [{"scope": "user", "installPath": "\(home.path)"}]}}
      """
    try write(0, to: home.appending(path: ".claude/plugins/cache/.keep"))
    try Data(installed.utf8).write(
      to: home.appending(path: ".claude/plugins/installed_plugins.json"))
    let report = DiskReport.scan(home: home)
    #expect(report.sizes[.plugins] == 0)
    #expect(
      report.issues.map(\.message) == ["1 plugin folders outside the plugins folder were skipped"])
  }
}
