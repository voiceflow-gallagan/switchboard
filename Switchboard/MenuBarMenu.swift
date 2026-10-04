import AppKit
import SwiftUI
import SwitchboardCore

/// The menu bar item: a memory chip and the total MCP server memory, such as "4,0 GB".
///
/// A click opens the window, or closes it when it is already in front. A right click, or a
/// control click, shows the total, one line per owner, when it was sampled, then Open, Settings,
/// and Quit. SwiftUI's own menu bar item cannot tell a click from a menu request, so this one is
/// built with AppKit.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let menu = NSMenu()
  private let usage: UsageStore
  var openWindow: @MainActor () -> Void = StatusItemController.showExistingWindow
  var openSettings: @MainActor () -> Void = {}

  /// Until the window has told the item how to open it, brings an existing one to the front.
  private static func showExistingWindow() {
    mainWindow?.makeKeyAndOrderFront(nil)
  }

  private static var mainWindow: NSWindow? {
    NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
  }

  init(usage: UsageStore) {
    self.usage = usage
    super.init()
    menu.delegate = self
    if let button = item.button {
      button.image = NSImage(
        systemSymbolName: "memorychip", accessibilityDescription: "MCP server memory")
      button.imagePosition = .imageLeading
      button.target = self
      button.action = #selector(clicked)
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    refresh()
  }

  @objc private func clicked() {
    let event = NSApp.currentEvent
    if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
      item.menu = menu
      item.button?.performClick(nil)
    } else if let window = Self.mainWindow, window.isVisible, NSApp.isActive {
      window.close()
    } else {
      open()
    }
  }

  func menuDidClose(_ menu: NSMenu) {
    item.menu = nil
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    if let report = usage.report, usage.isClaudeRunning {
      menu.addItem(disabled("MCP server memory: \(Format.memory(report.totalFootprint))"))
      let labels = Owner.labels(for: report.ownerTotals.map(\.owner))
      for total in report.ownerTotals {
        let name = labels[total.owner] ?? total.owner.title
        menu.addItem(disabled("\(name): \(Format.memory(total.footprint))"))
      }
    } else if usage.report != nil {
      menu.addItem(disabled("No Claude app is running"))
    } else {
      menu.addItem(disabled("Measuring memory"))
    }
    if let sampledAt = usage.sampledAt {
      menu.addItem(
        disabled("Sampled at \(sampledAt.formatted(date: .omitted, time: .standard))"))
    }
    menu.addItem(.separator())
    menu.addItem(action("Open Switchboard", #selector(open), key: ""))
    menu.addItem(action("Settings…", #selector(settings), key: ","))
    menu.addItem(action("Quit Switchboard", #selector(quit), key: "q"))
  }

  /// Activates first and orders the window front regardless: a click on a status item does not
  /// activate the app by itself, and a window opened by an inactive app stays behind the others.
  @objc private func open() {
    NSApp.activate()
    openWindow()
    Self.mainWindow?.orderFrontRegardless()
  }

  @objc private func settings() {
    NSApp.activate()
    openSettings()
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }

  /// Shows the current total and asks to be told when the next sample lands.
  private func refresh() {
    withObservationTracking {
      let total =
        usage.isClaudeRunning ? usage.report.map { Format.compactMemory($0.totalFootprint) } : nil
      item.button?.title = total ?? "–"
      item.button?.setAccessibilityValue(total ?? "not measured")
    } onChange: {
      Task { @MainActor in self.refresh() }
    }
  }

  private func disabled(_ title: String) -> NSMenuItem {
    let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    menuItem.isEnabled = false
    return menuItem
  }

  private func action(_ title: String, _ selector: Selector, key: String) -> NSMenuItem {
    let menuItem = NSMenuItem(title: title, action: selector, keyEquivalent: key)
    menuItem.target = self
    return menuItem
  }
}

extension Format {
  /// One decimal in gigabytes, whole megabytes below a gigabyte, such as "4,0 GB" or "512 MB".
  static func compactMemory(_ bytes: UInt64) -> String {
    let gigabytes = Double(bytes) / 1_073_741_824
    if gigabytes >= 1 {
      return "\(gigabytes.formatted(.number.precision(.fractionLength(1)))) GB"
    }
    let megabytes = Double(bytes) / 1_048_576
    return "\(megabytes.formatted(.number.precision(.fractionLength(0)))) MB"
  }
}
