import Foundation
import SwitchboardCore

/// Adding a new server, copying a server to the other app, and undoing either.
extension SwitchStore {
  /// Adds `server` to its target apps. Nil when another action runs.
  func add(_ server: NewServer) async -> AdditionOutcome? {
    await perform(summary: \.addedSummary) {
      Additions.add(server, home: $0.home, supportFolder: $0.supportFolder)
    }
  }

  /// Copies the server of `row` to `app`. Nil when another action runs.
  func copy(_ row: Row, to app: Place, usesInstalledBridge: Bool) async -> AdditionOutcome? {
    await perform(summary: \.copiedSummary) {
      Additions.copy(
        row, to: app, usesInstalledBridge: usesInstalledBridge, home: $0.home,
        supportFolder: $0.supportFolder)
    }
  }

  /// What copying `row` to `app` would write, with credentials masked, and what stops it. Read
  /// off the main thread.
  func copyPreview(
    of row: Row, to app: Place, usesInstalledBridge: Bool, inventory: Inventory
  ) async -> (text: String?, issues: [SourceIssue]) {
    let home = paths.home
    return await Task.detached {
      Additions.preview(
        copying: row, to: app, usesInstalledBridge: usesInstalledBridge, home: home,
        inventory: inventory)
    }.value
  }

  func undoAddition(_ added: AddedServer, name: String) async {
    cancelChecks(added)
    guard
      let (outcome, needs) = await run({ context in
        let outcome = Additions.undo(
          added, home: context.home, supportFolder: context.supportFolder)
        return (outcome, outcome.applied ? context.needs(for: added) : [])
      })
    else { return }
    finish(
      issues: outcome.issues,
      notice: outcome.applied
        ? Notice(message: "Undone. \(added.undoneSummary)", undo: nil, name: name) : nil,
      needs: needs)
    await reloadInventory()
  }

  /// Runs `work` while the store is busy, then shows the notice with Undo for whatever stayed
  /// added, adds what must restart, checks Claude Code again a few seconds later, and reads the
  /// configuration again.
  private func perform(
    summary: (AddedServer) -> String,
    _ work: @escaping @Sendable (Context) -> AdditionOutcome
  ) async -> AdditionOutcome? {
    cancelChecks("restore")
    guard
      let (outcome, needs) = await run({ context in
        let outcome = work(context)
        return (outcome, outcome.added.map(context.needs(for:)) ?? [])
      })
    else { return nil }
    let notice = outcome.added.map {
      Notice(message: summary($0), undo: .removeAddition($0), name: $0.name)
    }
    finish(issues: outcome.issues, notice: notice, needs: needs)
    if let added = outcome.added, added.places.contains(.claudeCode) {
      let home = paths.home
      checkLater(
        added, issue: added.sessionRemoved,
        dropsUndo: {
          if case .removeAddition(let pending) = $0 { pending == added } else { false }
        },
        isInEffect: { Additions.isInEffect(added, home: home) })
    }
    Task { await reloadInventory() }
    return outcome
  }
}

extension SwitchStore.Context {
  func needs(for added: AddedServer) -> [RestartNeed] {
    RestartNeeds.needs(
      for: added, processes: processes,
      inventory: inventory)
  }
}
