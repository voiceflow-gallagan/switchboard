import SwiftUI
import SwitchboardCore

/// The copies Switchboard took before each change, with Restore.
struct BackupsView: View {
  let switches: SwitchStore
  @Environment(\.dismiss) private var dismiss
  @State private var backups: [Backup]?
  @State private var pendingRestore: Backup?
  @State private var result: (message: String, isFailure: Bool)?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Backups")
        .font(.title2.weight(.semibold))
      Text(
        "Switchboard copies a file before every change and keeps the last \(Backups.limit) copies of each file. Backups hold the same credentials as the original files. Only your user account can read them."
      )
      .font(.callout)
      .foregroundStyle(Theme.secondaryText)
      .fixedSize(horizontal: false, vertical: true)
      list
      if let result {
        Label {
          Text(result.message)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(
            systemName: result.isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
          )
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(result.isFailure ? .orange : .green)
        }
      }
      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .buttonStyle(PillButtonStyle())
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 600, height: 460)
    .task { backups = await switches.backups() }
    .confirmationDialog(
      "Restore this backup?",
      isPresented: Binding(
        get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
      presenting: pendingRestore
    ) { backup in
      Button("Restore", role: .destructive) {
        Task { await restore(backup) }
      }
      Button("Cancel", role: .cancel) {}
    } message: { backup in
      Text(
        "\(backup.label) will be replaced as a whole by the copy from \(Self.date(of: backup)). The current file is backed up first."
      )
    }
  }

  @ViewBuilder private var list: some View {
    if let backups {
      List(backups) { backup in
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 2) {
            Text(backup.label)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          Spacer()
          Text(Self.date(of: backup))
            .monospacedDigit()
            .foregroundStyle(Theme.secondaryText)
          Button("Restore") { pendingRestore = backup }
            .disabled(switches.isApplying)
            .accessibilityLabel(
              "Restore \(backup.label) from \(Self.date(of: backup))")
        }
        .padding(.vertical, 2)
      }
      .listStyle(.bordered)
      .overlay {
        if backups.isEmpty {
          ContentUnavailableView(
            "No backups", systemImage: "archivebox",
            description: Text("A backup is taken before every change."))
        }
      }
    } else {
      ProgressView("Reading backups")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func restore(_ backup: Backup) async {
    let title = backup.label
    guard let outcome = await switches.restore(backup, title: title) else { return }
    if !outcome.applied {
      result = (outcome.issues.map { "\($0.source): \($0.message)" }.joined(separator: "\n"), true)
    } else if !outcome.wrote {
      result = ("\(title) already matches this backup. Nothing was changed.", false)
    } else if outcome.backup == nil {
      result = (
        "\(title) was missing and was created from the copy from \(Self.date(of: backup)). Restart the app that uses it for the change to take effect.",
        false
      )
    } else {
      result = (
        "\(title) was restored from \(Self.date(of: backup)). The replaced file is now the newest backup. Restart the app that uses it for the change to take effect.",
        false
      )
    }
    backups = await switches.backups()
  }

  private static func date(of backup: Backup) -> String {
    backup.date.formatted(date: .abbreviated, time: .standard)
  }
}
