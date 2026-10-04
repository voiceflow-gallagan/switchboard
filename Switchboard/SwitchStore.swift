import Foundation
import SwitchboardCore

/// Applies switches off the main thread and holds what follows a change: a notice with Undo,
/// the apps and sessions that must restart, and the issues of a change that failed.
///
/// Projects, removals, and additions live in extensions, which reach the state only through
/// `run`, `finish`, `checkLater`, and `cancelChecks`.
@MainActor @Observable
final class SwitchStore {
  struct Notice: Identifiable {
    let id = UUID()
    let message: String
    /// What Undo does, or nil when the notice offers no Undo.
    let undo: UndoAction?
    let name: String
    var undoTitle = "Undo"
  }

  enum UndoAction {
    case change(Switch)
    case removeProject(AddedProject)
    case removal(RemovalUndo)
    case removeAddition(AddedServer)
    /// Reads the configuration again, when the outcome of an action is unknown.
    case reload
  }

  /// What an action needs off the main thread.
  struct Context: Sendable {
    let home: URL
    let supportFolder: URL
    let claude: URL?
    let inventory: Inventory
    let isDemo: Bool

    /// The running processes, from this Mac or invented in demo mode.
    var processes: [RunningProcess] {
      MeasurementSource.processes(inventory: inventory, isDemo: isDemo).processes
    }

    func needs(for change: Switch) -> [RestartNeed] {
      RestartNeeds.needs(
        for: change, processes: processes,
        inventory: inventory)
    }

    func needs(for removal: Removal) -> [RestartNeed] {
      RestartNeeds.needs(
        for: removal, processes: processes,
        inventory: inventory)
    }

    func needs(forRestoreOf backup: Backup) -> [RestartNeed] {
      RestartNeeds.needs(
        forRestoreOf: backup, processes: processes,
        inventory: inventory)
    }
  }

  static let noticeDuration: Duration = .seconds(8)
  static let delayedCheck: Duration = .seconds(5)

  private(set) var isApplying = false
  private(set) var notice: Notice?
  /// What a slow action is doing, such as running Claude Code's program.
  private(set) var progress: String?
  private(set) var restartNeeds: [RestartNeed] = []
  private(set) var issues: [SourceIssue] = []
  let paths: AppPaths
  private let inventoryStore: InventoryStore
  private var noticeTask: Task<Void, Never>?
  /// Checks that a change is still on disk a few seconds later, by the change they check. A check
  /// removes its own entry when it ends, unless a newer check for the same change replaced it.
  private var pendingChecks: [AnyHashable: (id: UUID, task: Task<Void, Never>)] = [:]

  init(paths: AppPaths, inventoryStore: InventoryStore) {
    self.paths = paths
    self.inventoryStore = inventoryStore
  }

  /// Applies `change` to the item shown as `name`.
  func apply(_ change: Switch, name: String) {
    Task { await apply(change, name: name, isUndo: false) }
  }

  /// Applies the notice's Undo. Does nothing, and keeps the notice, while another change is
  /// being written.
  func undo() {
    guard !isApplying, let notice, let action = notice.undo else { return }
    self.notice = nil
    Task {
      switch action {
      case .change(let change): await apply(change, name: notice.name, isUndo: true)
      case .removeProject(let added): await removeProject(added, name: notice.name)
      case .removal(let undo): await undoRemoval(undo, name: notice.name)
      case .removeAddition(let added): await undoAddition(added, name: notice.name)
      case .reload: await reloadInventory()
      }
    }
  }

  func dismissNotice() {
    notice = nil
  }

  func dismissRestartNeeds() {
    restartNeeds = []
  }

  /// Drops the needs whose app or session has ended. Called after each memory sample.
  func refreshRestartNeeds(processes: [RunningProcess]) {
    guard !restartNeeds.isEmpty else { return }
    restartNeeds = RestartNeeds.remaining(restartNeeds, processes: processes)
  }

  func reloadInventory() async {
    await inventoryStore.refresh()
  }

  /// Runs `work` off the main thread while the store is busy, after clearing the last issues.
  /// Nil when switches are not offered or another action runs.
  func run<Result: Sendable>(
    progress: String? = nil, _ work: @escaping @Sendable (Context) async -> Result
  ) async -> Result? {
    guard paths.offersSwitches, !isApplying, let supportFolder = paths.supportFolder,
      let inventory = inventoryStore.inventory
    else { return nil }
    isApplying = true
    issues = []
    self.progress = progress
    let context = Context(
      home: paths.home, supportFolder: supportFolder, claude: paths.claudeProgram,
      inventory: inventory, isDemo: paths.isDemo)
    let result = await Task.detached { await work(context) }.value
    self.progress = nil
    isApplying = false
    return result
  }

  /// Shows an action's issues, its notice when set, and what must restart.
  func finish(issues: [SourceIssue], notice: Notice?, needs: [RestartNeed] = []) {
    self.issues = issues
    if let notice {
      show(notice)
    }
    restartNeeds = Array(Set(restartNeeds).union(needs)).sorted { $0.id < $1.id }
  }

  /// After a few seconds, asks `isInEffect` off the main thread whether a change is still on
  /// disk. When it is not, drops a notice whose Undo `dropsUndo` matches and shows `issue`.
  func checkLater(
    _ key: AnyHashable, issue: SourceIssue,
    dropsUndo: @escaping (UndoAction) -> Bool = { _ in false },
    isInEffect: @escaping @Sendable () -> Bool?
  ) {
    pendingChecks[key]?.task.cancel()
    let id = UUID()
    let task = Task {
      defer {
        if pendingChecks[key]?.id == id {
          pendingChecks[key] = nil
        }
      }
      try? await Task.sleep(for: Self.delayedCheck)
      guard !Task.isCancelled else { return }
      let inEffect = await Task.detached(operation: isInEffect).value
      guard !Task.isCancelled, inEffect == false else { return }
      if let undo = notice?.undo, dropsUndo(undo) {
        notice = nil
      }
      issues.append(issue)
      await inventoryStore.refresh()
    }
    pendingChecks[key] = (id, task)
  }

  /// Cancels the pending check for `key`, or every pending check when `key` is nil.
  func cancelChecks(_ key: AnyHashable? = nil) {
    if let key {
      pendingChecks.removeValue(forKey: key)?.task.cancel()
      return
    }
    for check in pendingChecks.values {
      check.task.cancel()
    }
    pendingChecks = [:]
  }

  /// Every backup, newest first, read off the main thread.
  func backups() async -> [Backup] {
    guard paths.offersSwitches, let supportFolder = paths.supportFolder else { return [] }
    return await Task.detached { Backups.list(supportFolder: supportFolder) }.value
  }

  /// Puts `backup`, shown as `title`, in place of its file. A restore replaces whatever the
  /// last change did, so the notice with its Undo and every pending check are dropped.
  func restore(_ backup: Backup, title: String) async -> SwitchOutcome? {
    guard !isApplying else { return nil }
    noticeTask?.cancel()
    notice = nil
    cancelChecks()
    guard
      let (outcome, needs) = await run({ context in
        let outcome = Backups.restore(
          backup, home: context.home, supportFolder: context.supportFolder)
        return (outcome, outcome.wrote ? context.needs(forRestoreOf: backup) : [])
      })
    else { return nil }
    finish(issues: outcome.issues, notice: nil, needs: needs)
    if outcome.wrote, let supportFolder = paths.supportFolder {
      let home = paths.home
      let writer =
        backup.file.hasPrefix("Library/Application Support/Claude/")
        ? "Claude Desktop or another program" : "A running Claude Code session"
      checkLater(
        "restore",
        issue: SourceIssue(
          source: title,
          message:
            "\(writer) changed the file again after the restore. Close it, then restore again.")
      ) {
        Backups.isRestored(backup, home: home, supportFolder: supportFolder)
      }
    }
    Task { await inventoryStore.refresh() }
    return outcome
  }

  private func apply(_ change: Switch, name: String, isUndo: Bool) async {
    guard !isApplying else { return }
    cancelChecks(change.opposite)
    cancelChecks("restore")
    guard
      let (outcome, needs) = await run({ context in
        let outcome = Switches.apply(
          change, home: context.home, supportFolder: context.supportFolder)
        return (outcome, outcome.applied && outcome.undo != nil ? context.needs(for: change) : [])
      })
    else { return }
    if outcome.applied, let undo = outcome.undo {
      let message = change.summary(name: name)
      finish(
        issues: outcome.issues,
        notice: Notice(
          message: isUndo ? "Undone. \(message)" : message, undo: isUndo ? nil : .change(undo),
          name: name),
        needs: needs)
      if change.needsDelayedCheck {
        let home = paths.home
        checkLater(
          change, issue: Self.sessionRemoved(name),
          dropsUndo: {
            if case .change(let undo) = $0 { undo == change.opposite } else { false }
          },
          isInEffect: { Switches.isInEffect(change, home: home) })
      }
    } else {
      finish(issues: outcome.issues, notice: nil)
    }
    await inventoryStore.refresh()
  }

  /// The message when a running Claude Code session wrote its main file over a change.
  static func sessionRemoved(_ name: String) -> SourceIssue {
    SourceIssue(
      source: "Claude Code",
      message:
        "A running Claude Code session removed the change to \(name). Close that session, then try again."
    )
  }

  private func show(_ notice: Notice) {
    self.notice = notice
    noticeTask?.cancel()
    noticeTask = Task {
      try? await Task.sleep(for: Self.noticeDuration)
      guard !Task.isCancelled, self.notice?.id == notice.id else { return }
      self.notice = nil
    }
  }
}
