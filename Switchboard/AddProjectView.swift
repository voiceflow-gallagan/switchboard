import AppKit
import SwiftUI

/// The standard folder picker, limited to folders.
@MainActor
enum FolderPicker {
  static func chooseProjectFolder() async -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Add to Switchboard"
    panel.message = "Choose a folder to add as a Claude Code project."
    return await panel.begin() == .OK ? panel.url : nil
  }
}

/// Confirms a folder to add as a Claude Code project, with a project to copy switches from.
struct AddProjectView: View {
  let folder: URL
  let projects: [String]
  let add: (_ source: String?) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var source: String?

  var body: some View {
    let labels = ProjectPicker.shortLabels(for: projects)
    VStack(alignment: .leading, spacing: 14) {
      Text("Add project")
        .font(.title2.weight(.semibold))
      Form {
        LabeledContent("Folder") {
          Text(folder.lastPathComponent)
        }
        Picker("Copy switches from", selection: $source) {
          Text("None").tag(String?.none)
          if !projects.isEmpty {
            Divider()
          }
          ForEach(projects, id: \.self) { path in
            Text(labels[path] ?? URL(filePath: path).lastPathComponent).tag(Optional(path))
          }
        }
      }
      Text(
        source == nil
          ? "Switchboard adds an entry for this folder to Claude Code's file, ~/.claude.json."
          : "Switchboard adds an entry for this folder to Claude Code's file, ~/.claude.json. When that project has plugin settings, it also writes .claude/settings.local.json in this folder."
      )
      .font(.callout)
      .foregroundStyle(Theme.secondaryText)
      .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Add") {
          add(source)
          dismiss()
        }
        .buttonStyle(PillButtonStyle())
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 460)
  }
}
