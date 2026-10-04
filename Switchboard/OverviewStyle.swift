import SwiftUI
import SwitchboardCore

enum Format {
  static func memory(_ bytes: UInt64) -> String {
    Int64(clamping: bytes).formatted(.byteCount(style: .memory))
  }

  static func file(_ bytes: UInt64) -> String {
    Int64(clamping: bytes).formatted(.byteCount(style: .file))
  }
}

/// One colour per owner, the same in every chart. Sessions take a colour from their process ID,
/// so a session keeps its colour while it runs.
enum Palette {
  private static let sessions: [Color] = [.purple, .teal, .orange, .pink, .indigo, .mint]
  static let disk: [DiskReport.Category: Color] = [
    .plugins: .blue, .oldPluginVersions: .indigo, .extensions: .teal, .skills: .orange,
  ]

  static func color(for owner: Owner) -> Color {
    switch owner {
    case .desktop: .blue
    case .session(let id, _): sessions[Int(id.magnitude % UInt32(sessions.count))]
    case .orphaned: .gray
    }
  }
}

extension Owner {
  var title: String {
    switch self {
    case .desktop: "Claude Desktop"
    case .session(_, let project?): "Session \(URL(filePath: project).lastPathComponent)"
    case .session: "Session"
    case .orphaned: "Orphaned servers"
    }
  }

  /// Titles for `owners`. Owners whose titles collide, such as two sessions in one folder,
  /// also show the process ID.
  static func labels(for owners: [Owner]) -> [Owner: String] {
    let titleCounts = Dictionary(grouping: owners, by: \.title).mapValues(\.count)
    var labels: [Owner: String] = [:]
    for owner in owners {
      var label = owner.title
      if titleCounts[label, default: 0] > 1, case .session(let id, _) = owner {
        label += " (\(id))"
      }
      labels[owner] = label
    }
    return labels
  }
}

extension DiskReport.Category {
  var title: String {
    switch self {
    case .plugins: "Plugins"
    case .oldPluginVersions: "Old plugin versions"
    case .extensions: "Extensions"
    case .skills: "Skills"
    }
  }
}

/// A rounded translucent panel over the section's gradient, with a title.
struct Card<Content: View>: View {
  let title: String
  let accessory: AnyView
  let content: Content

  init(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) {
    self.init(title, accessory: { EmptyView() }, content: content)
  }

  init<Accessory: View>(
    _ title: String,
    @ViewBuilder accessory: () -> Accessory,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.accessory = AnyView(accessory())
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if !title.isEmpty {
        HStack(spacing: 8) {
          Text(title)
            .font(.headline)
          Spacer(minLength: 0)
          accessory
        }
      }
      content
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .panel()
  }
}
