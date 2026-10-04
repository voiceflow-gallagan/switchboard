import Foundation
import SwitchboardCore

/// Removing servers into the Removed list, restoring them, deleting them for good, and
/// uninstalling or reinstalling plugins with Claude Code's own program.
extension SwitchStore {
  /// Removes a server at once, with Undo.
  func remove(_ removal: Removal, name: String) {
    guard case .server = removal else { return }
    Task {
      await perform(name: name, reach: removal, message: removal.summary(name: name)) {
        await Removals.remove(
          removal, home: $0.home, supportFolder: $0.supportFolder, claude: $0.claude)
      }
    }
  }

  /// Uninstalls a plugin with Claude Code's program. The notice offers a reinstall.
  func uninstall(pluginID: String, name: String) async -> RemovalOutcome? {
    let removal = Removal.plugin(id: pluginID)
    return await perform(
      name: name, reach: removal, message: removal.summary(name: name), undoTitle: "Reinstall",
      progress: "Uninstalling plugin \(name)…"
    ) {
      await Removals.remove(
        removal, home: $0.home, supportFolder: $0.supportFolder, claude: $0.claude)
    }
  }

  /// Puts a removed server back where it came from, with Undo.
  func restore(_ removed: RemovedServer) {
    Task {
      await perform(
        name: removed.name, reach: .server(name: removed.name, place: removed.place),
        message: RemovedServer.restoredSummary(name: removed.name, place: removed.place)
      ) {
        Removals.restore(removed, home: $0.home, supportFolder: $0.supportFolder)
      }
    }
  }

  /// Deletes a removed server's definition. Nothing can undo it.
  func deleteForGood(_ removed: RemovedServer) {
    Task {
      await perform(
        name: removed.name, reach: nil, message: "\(removed.name) was deleted for good."
      ) {
        Removals.deleteForGood(removed, supportFolder: $0.supportFolder)
      }
    }
  }

  func undoRemoval(_ undo: RemovalUndo, name: String) async {
    cancelChecks(undo)
    let progress: String? =
      if case .reinstall = undo { "Reinstalling plugin \(name)…" } else { nil }
    await perform(
      name: name, reach: undo.reach, message: undo.summary(name: name), isUndo: true,
      progress: progress
    ) {
      await Removals.undo(
        undo, home: $0.home, supportFolder: $0.supportFolder, claude: $0.claude)
    }
  }

  /// Runs `work` while the store is busy, then shows the notice, adds what must restart, and
  /// reads the configuration again.
  @discardableResult
  private func perform(
    name: String, reach: Removal?, message: String, undoTitle: String = "Undo",
    isUndo: Bool = false, progress: String? = nil,
    _ work: @escaping @Sendable (Context) async -> RemovalOutcome
  ) async -> RemovalOutcome? {
    guard
      let (outcome, needs) = await run(
        progress: progress,
        { context in
          let outcome = await work(context)
          return (outcome, outcome.applied ? reach.map(context.needs(for:)) ?? [] : [])
        })
    else { return nil }
    let notice =
      outcome.applied
      ? Notice(
        message: isUndo ? "Undone. \(message)" : message,
        undo: isUndo ? nil : outcome.undo.map { .removal($0) }, name: name,
        undoTitle: undoTitle)
      : nil
    finish(issues: outcome.issues, notice: notice, needs: needs)
    if outcome.applied, let undo = outcome.undo, undo.changesClaudeCodeFile {
      let home = paths.home
      checkLater(
        undo, issue: Self.sessionRemoved(name),
        dropsUndo: { if case .removal(let pending) = $0 { pending == undo } else { false } },
        isInEffect: { Removals.isInEffect(undo, home: home) })
    }
    await reloadInventory()
    return outcome
  }
}
