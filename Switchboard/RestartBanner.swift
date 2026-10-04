import SwiftUI
import SwitchboardCore

/// What must restart before the latest changes take effect.
struct RestartBanner: View {
  let needs: [RestartNeed]
  let dismiss: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "arrow.clockwise.circle.fill")
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.orange)
        .font(.title3)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text("For the change to take effect:")
          .fontWeight(.semibold)
        ForEach(Self.steps(for: needs), id: \.self) { step in
          Text("•  \(step)")
        }
        Text("Switchboard never restarts anything itself.")
          .font(.caption)
          .foregroundStyle(Theme.secondaryText)
      }
      Spacer(minLength: 0)
      Button("Dismiss", systemImage: "xmark", action: dismiss)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("Hide this list")
        .accessibilityLabel("Dismiss the restart list")
    }
    .font(.callout)
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .toast()
  }

  /// One line per app or folder, in the order of `needs`. A folder is named by its last part.
  static func steps(for needs: [RestartNeed]) -> [String] {
    var steps: [String] = []
    var counts: [String: Int] = [:]
    for need in needs {
      let step =
        switch need.owner {
        case .desktop: "Restart Claude Desktop"
        case .session(_, let folder?):
          "Start a new session in \(URL(filePath: folder).lastPathComponent)"
        case .session, .orphaned: "Start a new Claude Code session"
        }
      if counts[step] == nil {
        steps.append(step)
      }
      counts[step, default: 0] += 1
    }
    return steps.map { step in
      let count = counts[step, default: 1]
      return count > 1 ? "\(step) (\(count) sessions)" : step
    }
  }
}

/// What a slow action is doing, while it runs.
struct ProgressNotice: View {
  let message: String

  var body: some View {
    HStack(spacing: 12) {
      ProgressView()
        .controlSize(.small)
      Text(message)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .toast()
    .padding(16)
    .accessibilityElement(children: .combine)
    .task(id: message) {
      AccessibilityNotification.Announcement(message).post()
    }
  }
}

/// A short notice after a change, with Undo while the notice shows.
struct ChangeNotice: View {
  let notice: SwitchStore.Notice
  let canUndo: Bool
  let undo: () -> Void
  let dismiss: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "checkmark.circle.fill")
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.green)
        .accessibilityHidden(true)
      Text(notice.message)
        .fixedSize(horizontal: false, vertical: true)
      if notice.undo != nil {
        Button(notice.undoTitle, action: undo)
          .buttonStyle(PillButtonStyle())
          .controlSize(.small)
          .disabled(!canUndo)
          .accessibilityLabel(
            notice.undoTitle == "Undo" ? "Undo the last change" : notice.undoTitle)
      }
      Button("Dismiss", systemImage: "xmark", action: dismiss)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .accessibilityLabel("Dismiss the notice")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .frame(maxWidth: 560)
    .toast()
    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    .padding(16)
    .transition(.move(edge: .bottom).combined(with: .opacity))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Change notice")
    .task(id: notice.id) {
      AccessibilityNotification.Announcement(notice.message).post()
    }
  }
}
