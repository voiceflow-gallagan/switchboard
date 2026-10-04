import SwiftUI
import SwitchboardCore

/// A plugin the user asked to uninstall.
struct PendingUninstall: Identifiable {
  let id: String
  let name: String
}

/// Confirms an uninstall, runs it with a progress state, and shows a failure.
struct UninstallView: View {
  let plugin: PendingUninstall
  let switches: SwitchStore
  @Environment(\.dismiss) private var dismiss
  @State private var phase = Phase.confirming

  enum Phase: Equatable {
    case confirming, running
    case failed(String)
    /// The command finished, but whether the plugin was uninstalled is not known.
    case unconfirmed(String)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Uninstall plugin \(plugin.name)?")
        .font(.title2.weight(.semibold))
      VStack(alignment: .leading, spacing: 6) {
        Text("Switchboard runs Claude Code's own uninstall command.")
        Text("Reinstalling needs the network and may bring a newer version.")
        Text("Whether the plugin's data is kept is up to Claude Code.")
      }
      .foregroundStyle(Theme.secondaryText)
      .fixedSize(horizontal: false, vertical: true)
      switch phase {
      case .confirming:
        EmptyView()
      case .running:
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Uninstalling. This can take a few seconds.")
        }
      case .failed(let message), .unconfirmed(let message):
        Label {
          Text(message)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        }
      }
      HStack {
        Spacer()
        Button(phase == .confirming ? "Cancel" : "Close", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
          .disabled(phase == .running)
        if phase == .confirming {
          Button("Uninstall", role: .destructive) {
            Task { await uninstall() }
          }
          .buttonStyle(PillButtonStyle(isDestructive: true))
          .keyboardShortcut(.defaultAction)
        }
        if case .unconfirmed = phase {
          Button("Reload plugin list") {
            Task {
              await switches.reloadInventory()
              dismiss()
            }
          }
          .buttonStyle(PillButtonStyle())
          .keyboardShortcut(.defaultAction)
          .help("Read the plugin list again")
        }
      }
    }
    .padding(20)
    .frame(width: 460)
    .interactiveDismissDisabled(phase == .running)
    .onChange(of: phase) {
      if phase == .running {
        AccessibilityNotification.Announcement("Uninstalling plugin \(plugin.name)").post()
      }
    }
  }

  private func uninstall() async {
    phase = .running
    guard let outcome = await switches.uninstall(pluginID: plugin.id, name: plugin.name) else {
      phase = .failed("Another change is being applied. Try again in a moment.")
      return
    }
    if outcome.applied {
      dismiss()
      return
    }
    let issues = outcome.issues.map(\.message).joined(separator: " ")
    phase =
      outcome.isUnconfirmed
      ? .unconfirmed("\(issues) The uninstall may still have happened.")
      : .failed(
        "\(issues) The uninstall may still have happened. Check the plugin list in Claude Code.")
  }
}
