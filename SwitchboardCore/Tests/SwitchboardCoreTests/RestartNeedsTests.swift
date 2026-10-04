import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct RestartNeedsTests {
  private let projects = ["/work/alpha", "/work/beta"]

  private func process(_ id: Int32, _ path: String, folder: String? = nil) -> RunningProcess {
    RunningProcess(
      id: id, parent: 1, footprint: 0, programPath: path, target: nil, workingFolder: folder)
  }

  private var processes: [RunningProcess] {
    [
      process(10, "/Applications/Claude.app/Contents/MacOS/Claude"),
      process(11, "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/x"),
      process(20, "/Users/me/.local/share/claude/versions/2.0.0", folder: "/work/alpha"),
      process(21, "/opt/homebrew/bin/claude", folder: "/work/alpha/src"),
      process(22, "/opt/homebrew/bin/claude", folder: "/work/beta"),
      process(23, "/opt/homebrew/bin/claude", folder: "/elsewhere"),
      process(24, "/opt/homebrew/bin/claude"),
      process(30, "/usr/local/bin/node"),
    ]
  }

  private var inventory: Inventory {
    Inventory(rows: [], issues: [], projects: projects, cloudHistory: [])
  }

  private func ids(_ change: Switch, _ running: [RunningProcess]? = nil) -> [Int32] {
    RestartNeeds.needs(for: change, processes: running ?? processes, inventory: inventory)
      .map(\.id)
  }

  @Test func aRestoreNeedsTheAppOrSessionsThatReadTheFile() {
    func ids(restoring file: String) -> [Int32] {
      let backup = Backup(
        url: URL(fileURLWithPath: "/backups/x.json"), file: file, label: file, date: Date())
      return RestartNeeds.needs(forRestoreOf: backup, processes: processes, inventory: inventory)
        .map(\.id)
    }
    #expect(ids(restoring: Switches.desktopFile) == [10])
    #expect(ids(restoring: Switches.extensionSettingsFolder + "/acme.notes.json") == [10])
    #expect(ids(restoring: Switches.claudeCodeFile) == [20, 21, 22, 23, 24])
    #expect(ids(restoring: Switches.settingsFile) == [20, 21, 22, 23, 24])
    #expect(ids(restoring: "/work/beta/" + Switches.projectSettingsFile) == [22, 24])
  }

  @Test func aProjectChangeNeedsThatProjectsSessionsAndUnknownOnes() {
    #expect(ids(.serverInProject(name: "a", project: "/work/alpha", on: false)) == [20, 21, 24])
    #expect(ids(.serverInProject(name: "a", project: "/work/beta", on: true)) == [22, 24])
    #expect(ids(.serverInProject(name: "a", project: "/elsewhere", on: true)) == [23, 24])
  }

  @Test func userLevelAndPluginChangesNeedEverySession() {
    #expect(ids(.claudeCodeServer(name: "a", on: false)) == [20, 21, 22, 23, 24])
    #expect(ids(.plugin(id: "a@b", on: true)) == [20, 21, 22, 23, 24])
  }

  @Test func desktopChangesNeedClaudeDesktop() {
    #expect(ids(.desktopServer(name: "a", on: false)) == [10])
    #expect(ids(.desktopExtension(id: "a", on: true)) == [10])
    let need = RestartNeeds.needs(
      for: .desktopServer(name: "a", on: true), processes: processes, inventory: inventory)
    #expect(need.map(\.owner) == [.desktop])
  }

  @Test func nothingIsNeededWhenTheOwnerIsNotRunning() {
    let sessionsOnly = processes.filter { $0.id >= 20 }
    #expect(ids(.desktopServer(name: "a", on: false), sessionsOnly).isEmpty)
    let desktopOnly = processes.filter { $0.id < 20 }
    #expect(ids(.plugin(id: "a@b", on: false), desktopOnly).isEmpty)
  }

  @Test func aNeedGoesAwayWhenItsProcessEnds() {
    let needs = RestartNeeds.needs(
      for: .claudeCodeServer(name: "a", on: true), processes: processes, inventory: inventory)
    var later = processes.filter { $0.id != 21 }
    later.append(process(40, "/opt/homebrew/bin/claude", folder: "/work/alpha"))
    later[later.firstIndex { $0.id == 22 } ?? 0].workingFolder = "/work/alpha"
    #expect(RestartNeeds.remaining(needs, processes: later).map(\.id) == [20, 23, 24])
  }
}
