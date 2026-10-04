import SwiftUI
import SwitchboardCore

struct ProjectPicker: View {
  let projects: [String]
  @Binding var selection: String?

  var body: some View {
    let labels = Self.shortLabels(for: projects)
    Picker("Project", selection: $selection) {
      Text("No project").tag(String?.none)
      Divider()
      ForEach(projects, id: \.self) { path in
        Text(labels[path] ?? path)
          .help(path)
          .tag(Optional(path))
      }
    }
    .help(selection ?? "Choose a project to fill the Project column")
    .onChange(of: projects) {
      if let selection, !projects.contains(selection) {
        self.selection = nil
      }
    }
  }

  /// The folder name, with its parent folder when another project has the same folder name.
  static func shortLabels(for paths: [String]) -> [String: String] {
    let urls = paths.map { URL(filePath: $0) }
    let nameCounts = Dictionary(grouping: urls, by: \.lastPathComponent).mapValues(\.count)
    var labels: [String: String] = [:]
    for (path, url) in zip(paths, urls) {
      let name = url.lastPathComponent
      let parent = url.deletingLastPathComponent().lastPathComponent
      labels[path] = nameCounts[name, default: 0] > 1 ? "\(parent)/\(name)" : name
    }
    return labels
  }
}
