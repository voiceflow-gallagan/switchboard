import AppKit
import SwiftUI

/// The light or dark choice on the Settings screen. System follows macOS.
enum Appearance: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  static let key = "appearance"

  var id: Self { self }

  var title: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}

enum DockIcon {
  static let hiddenKey = "hidesDockIcon"

  /// A hidden Dock icon also hides the menu bar; the menu bar item is then the only way in.
  @MainActor static func apply(hidden: Bool) {
    NSApp.setActivationPolicy(hidden ? .accessory : .regular)
  }
}

struct SettingsView: View {
  @Bindable var updater: Updater
  @AppStorage(Appearance.key) private var appearance = Appearance.system
  @AppStorage(DockIcon.hiddenKey) private var hidesDockIcon = false

  var body: some View {
    Form {
      Section {
        Picker("Appearance", selection: $appearance) {
          ForEach(Appearance.allCases) { Text($0.title) }
        }
        .pickerStyle(.segmented)
        Toggle("Hide the Dock icon", isOn: $hidesDockIcon)
        Text("Switchboard stays in the menu bar. Open it and its settings from there.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Section("Updates") {
        LabeledContent("Version", value: Updater.version)
        if let notes = Updater.releaseNotes {
          Link("What changed in this version", destination: notes)
        }
        if updater.isEnabled {
          Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
          Toggle("Install updates automatically", isOn: $updater.installsAutomatically)
          LabeledContent {
            Button("Check Now") { updater.check() }
              .disabled(!updater.canCheck)
          } label: {
            Text("Last checked")
            Text(
              updater.lastCheck.map { $0.formatted(date: .abbreviated, time: .shortened) }
                ?? "Never"
            )
            .foregroundStyle(.secondary)
          }
          Text(
            "Updates come from this app's GitHub releases. GitHub sees your IP address and this app's version."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        } else {
          Text("Updates are off in debug builds and in test mode.")
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 400)
    .fixedSize()
    .preferredColorScheme(appearance.colorScheme)
    .onChange(of: hidesDockIcon) { _, hidden in
      DockIcon.apply(hidden: hidden)
      NSApp.activate()
    }
  }
}
