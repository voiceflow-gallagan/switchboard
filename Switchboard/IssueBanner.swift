import SwiftUI
import SwitchboardCore

struct IssueBanner: View {
  let issues: [SourceIssue]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Self.messagesBySource(issues), id: \.source) { source, messages in
          Label {
            Text("\(source): \(messages)")
              .textSelection(.enabled)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
              .accessibilityLabel("Issue")
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
    }
    .font(.callout)
    .frame(maxHeight: 96)
    .fixedSize(horizontal: false, vertical: true)
    .toast()
  }

  /// One line per source, in first-seen order, so each line has a stable identity.
  private static func messagesBySource(_ issues: [SourceIssue]) -> [(
    source: String, messages: String
  )] {
    var sources: [String] = []
    var messages: [String: [String]] = [:]
    for issue in issues {
      if messages[issue.source] == nil {
        sources.append(issue.source)
      }
      messages[issue.source, default: []].append(issue.message)
    }
    return sources.map { ($0, messages[$0, default: []].joined(separator: "; ")) }
  }
}
