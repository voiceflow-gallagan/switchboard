import Foundation
import SwitchboardCore

@MainActor @Observable
final class InventoryStore {
  private(set) var inventory: Inventory?
  private(set) var isLoading = false
  /// False while only the quick load, which skips project folders, is on screen.
  private(set) var includesProjects = false
  private let paths: AppPaths
  private var latestLoad = 0

  init(paths: AppPaths) {
    self.paths = paths
  }

  func reload() {
    Task { await refresh() }
  }

  /// Reads the configuration again. When loads overlap, only the latest one is kept, so a load
  /// that started before a change never replaces one that started after it.
  func refresh() async {
    latestLoad += 1
    let load = latestLoad
    isLoading = true
    let home = paths.home
    let supportFolder = paths.offersSwitches ? paths.supportFolder : nil
    if inventory == nil {
      let quick = await Task.detached {
        Inventory.load(home: home, includingProjects: false, supportFolder: supportFolder)
      }.value
      if load == latestLoad, !includesProjects {
        inventory = quick
      }
    }
    let full = await Task.detached { Inventory.load(home: home, supportFolder: supportFolder) }
      .value
    guard load == latestLoad else { return }
    inventory = full
    includesProjects = true
    isLoading = false
  }
}
