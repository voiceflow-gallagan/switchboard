import AppKit
import SwiftUI
import SwitchboardCore

/// The state that outlives the window: the configuration, the memory samples, and the switches.
///
/// It samples memory every 5 seconds while the window is on screen and every 30 seconds
/// otherwise, so the menu bar always has a recent figure. It saves the measurements when the app
/// stops being active and before it quits, with or without a window.
@MainActor @Observable
final class AppModel {
  static let shared = AppModel(paths: .current)
  static let visibleInterval: Duration = .seconds(5)
  static let hiddenInterval: Duration = .seconds(30)

  let paths: AppPaths
  let store: InventoryStore
  let usage: UsageStore
  let switches: SwitchStore
  /// Whether the window is on screen. Sampling is fast and the glow moves only then.
  private(set) var isWindowVisible = false
  private var sampling: Task<Void, Never>?

  init(paths: AppPaths) {
    self.paths = paths
    store = InventoryStore(paths: paths)
    usage = UsageStore(paths: paths)
    switches = SwitchStore(paths: paths, inventoryStore: store)
  }

  /// Reads the configuration and the saved measurements, then starts sampling. Runs once.
  func start() {
    guard sampling == nil else { return }
    store.reload()
    Task { await usage.loadStore() }
    let center = NotificationCenter.default
    _ = center.addObserver(
      forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { AppModel.shared.usage.saveInBackground() }
    }
    _ = center.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { AppModel.shared.usage.saveNow() }
    }
    restartSampling()
  }

  /// Switches between the fast and the slow rate. Sampling at once when the window comes back.
  func windowVisibilityChanged(_ isVisible: Bool) {
    guard isVisible != isWindowVisible else { return }
    isWindowVisible = isVisible
    restartSampling()
  }

  func sample() {
    if let inventory = store.inventory {
      usage.sample(inventory: inventory, isComplete: store.includesProjects)
    }
  }

  private func restartSampling() {
    sampling?.cancel()
    let isVisible = isWindowVisible
    sampling = Task {
      if isVisible {
        sample()
      }
      while !Task.isCancelled {
        try? await Task.sleep(for: isVisible ? Self.visibleInterval : Self.hiddenInterval)
        guard !Task.isCancelled else { return }
        sample()
      }
    }
  }
}

/// Keeps the app running, with its menu bar item, after the window closes.
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }
}
