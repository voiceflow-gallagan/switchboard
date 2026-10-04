import AppKit
import Sparkle
import SwiftUI

/// Checks GitHub for a newer release and installs it, through Sparkle.
///
/// Off in debug builds, whose build number is always 1, and in test mode. Sparkle asks the user
/// once, on the second launch, before the first check. Every download is checked against the
/// feed's signature and against this app's own code signature before it replaces the bundle.
@MainActor @Observable
final class Updater {
  let isEnabled: Bool
  private let controller: SPUStandardUpdaterController
  private(set) var canCheck = false
  private(set) var lastCheck: Date?

  init(isEnabled: Bool) {
    self.isEnabled = isEnabled
    controller = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    guard isEnabled else { return }
    controller.startUpdater()
    observe()
  }

  var checksAutomatically: Bool {
    get { controller.updater.automaticallyChecksForUpdates }
    set { controller.updater.automaticallyChecksForUpdates = newValue }
  }

  var installsAutomatically: Bool {
    get { controller.updater.automaticallyDownloadsUpdates }
    set { controller.updater.automaticallyDownloadsUpdates = newValue }
  }

  func check() {
    controller.checkForUpdates(nil)
  }

  static var version: String {
    let info = Bundle.main.infoDictionary ?? [:]
    let short = info["CFBundleShortVersionString"] as? String ?? "?"
    let build = info["CFBundleVersion"] as? String ?? "?"
    return "\(short) (\(build))"
  }

  /// The GitHub release that shipped this version, which holds its notes.
  static var releaseNotes: URL? {
    guard let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    else { return nil }
    return URL(string: "https://github.com/voiceflow-gallagan/switchboard/releases/tag/v\(short)")
  }

  /// Sparkle's updater is KVO-observable, not Observable; this bridges the two properties the
  /// Settings screen shows.
  private var observers: [NSKeyValueObservation] = []

  private func observe() {
    let updater = controller.updater
    observers = [
      updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
        MainActor.assumeIsolated { self?.canCheck = updater.canCheckForUpdates }
      },
      updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] updater, _ in
        MainActor.assumeIsolated { self?.lastCheck = updater.lastUpdateCheckDate }
      },
    ]
  }
}
