import SwiftUI
import SwitchboardCore

/// Servers the user removed, with Restore and Delete for good.
struct RemovedView: View {
  let removed: [RemovedServer]
  let switches: SwitchStore
  @State private var pendingDelete: RemovedServer?

  var body: some View {
    List {
      Section {
        ForEach(removed) { server in
          row(server)
        }
      } header: {
        Text(
          "Removed servers keep their definition, with its credentials, in Switchboard's private file until you delete them for good."
        )
      }
    }
    .scrollContentBackground(.hidden)
    .overlay {
      if removed.isEmpty {
        ContentUnavailableView(
          "Nothing removed", systemImage: "trash",
          description: Text("Servers you remove appear here, ready to restore."))
      }
    }
    .confirmationDialog(
      "Delete \(pendingDelete?.name ?? "this server") for good?",
      isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
      presenting: pendingDelete
    ) { server in
      Button("Delete for good", role: .destructive) { switches.deleteForGood(server) }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text(
        "Its definition and its credentials will be deleted from Switchboard. Only an older backup could still hold it."
      )
    }
  }

  private func row(_ server: RemovedServer) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(server.name)
        Text(
          "From \(server.place.spokenName) · \(DisplayText.typeLabel(server.typeLabel)) · removed \(server.removedAt.formatted(.relative(presentation: .named)))"
        )
        .font(.caption)
        .foregroundStyle(Theme.secondaryText)
      }
      Spacer()
      Button("Restore") { switches.restore(server) }
        .buttonStyle(PillButtonStyle())
        .controlSize(.small)
        .accessibilityLabel("Restore \(server.name) to \(server.place.spokenName)")
      Button("Delete for good…") { pendingDelete = server }
        .accessibilityLabel("Delete \(server.name) for good")
    }
    .disabled(switches.isApplying)
    .padding(.vertical, 2)
  }
}
