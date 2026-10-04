import Foundation
import SwitchboardCore

/// Adding a folder as a Claude Code project, and undoing it.
extension SwitchStore {
  /// Gives `folder` an entry in Claude Code's file, copying the off list and plugin settings of
  /// `source` when set. Returns the new project's path, or nil when nothing was added.
  func addProject(_ folder: URL, copyingFrom source: String?) async -> String? {
    cancelChecks("restore")
    guard
      let outcome = await run({ context in
        Switches.addProject(
          folder: folder, copyingFrom: source, home: context.home,
          supportFolder: context.supportFolder)
      })
    else { return nil }
    guard outcome.applied, let added = outcome.added else {
      finish(issues: outcome.issues, notice: nil)
      return nil
    }
    let name = URL(filePath: added.path).lastPathComponent
    finish(
      issues: outcome.issues,
      notice: Notice(
        message: "Project \(name) was added to Claude Code.", undo: .removeProject(added),
        name: name))
    await reloadInventory()
    let home = paths.home
    checkLater(
      "project",
      issue: SourceIssue(
        source: "Claude Code",
        message:
          "A running Claude Code session removed the new project \(name). Close that session, then add it again."
      ),
      dropsUndo: { if case .removeProject = $0 { true } else { false } },
      isInEffect: {
        Inventory.load(home: home, includingProjects: false).projects.contains(added.path)
      })
    return added.path
  }

  func removeProject(_ added: AddedProject, name: String) async {
    cancelChecks("project")
    guard
      let outcome = await run({ context in
        Switches.removeProject(added, home: context.home, supportFolder: context.supportFolder)
      })
    else { return }
    finish(
      issues: outcome.issues,
      notice: outcome.applied
        ? Notice(message: "Undone. Project \(name) was removed.", undo: nil, name: name) : nil)
    await reloadInventory()
  }
}
