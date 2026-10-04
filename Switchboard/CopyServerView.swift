import SwiftUI
import SwitchboardCore

/// A server row the user asked to copy to the other app.
struct PendingCopy: Identifiable {
  let row: Row
  let app: Place
  var id: String { row.id }
}

/// Shows what copying a server to the other app writes, with credentials masked, then copies it.
struct CopyServerView: View {
  let pending: PendingCopy
  let switches: SwitchStore
  let inventory: Inventory?
  @Environment(\.dismiss) private var dismiss
  /// The preview for each bridge choice.
  @State private var previews: [Bool: (text: String?, issues: [SourceIssue])] = [:]
  @State private var usesInstalledBridge = false
  @State private var isCopying = false
  @State private var failure: [String] = []

  var body: some View {
    let preview = previews[usesInstalledBridge]
    let issues = (preview?.issues ?? []).map { "\($0.source): \($0.message)" }
    VStack(alignment: .leading, spacing: 14) {
      Text("Copy \(name) to \(pending.app.spokenName)")
        .font(.title2.weight(.semibold))
      Text(pending.app.copyExplanation)
        .font(.callout)
        .foregroundStyle(Theme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
      if offersBridgeChoice {
        Form {
          BridgePicker(usesInstalledBridge: $usesInstalledBridge)
        }
      }
      if let preview {
        if let text = preview.text {
          PreviewBlock(text: text)
        }
      } else {
        ProgressView("Reading the server")
          .controlSize(.small)
      }
      FieldIssues(messages: issues + failure)
      HStack {
        if isCopying {
          ProgressView()
            .controlSize(.small)
          Text("Copying…")
        }
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Copy") {
          Task { await copy() }
        }
        .buttonStyle(PillButtonStyle())
        .keyboardShortcut(.defaultAction)
        .disabled(preview?.text == nil || !issues.isEmpty || switches.isApplying)
      }
    }
    .padding(20)
    .frame(width: 540)
    .disabled(isCopying)
    .interactiveDismissDisabled(isCopying)
    .task { await loadPreviews() }
  }

  private var name: String {
    pending.row.entries.first?.name ?? pending.row.name
  }

  /// Whether the bridge choice changes what is written, which is so only for a remote server
  /// copied to Claude Desktop.
  private var offersBridgeChoice: Bool {
    guard pending.app == .desktop, let npx = previews[false], let installed = previews[true]
    else { return false }
    return npx.text != installed.text
  }

  private func loadPreviews() async {
    guard let inventory else { return }
    for usesInstalledBridge in [false, true] {
      previews[usesInstalledBridge] = await switches.copyPreview(
        of: pending.row, to: pending.app, usesInstalledBridge: usesInstalledBridge,
        inventory: inventory)
    }
  }

  private func copy() async {
    failure = []
    isCopying = true
    let outcome = await switches.copy(
      pending.row, to: pending.app, usesInstalledBridge: usesInstalledBridge)
    isCopying = false
    guard let outcome else {
      failure = [Additions.busy]
      return
    }
    if outcome.applied {
      dismiss()
    } else {
      failure = outcome.issues.map { "\($0.source): \($0.message)" }
    }
  }
}

/// How Claude Desktop starts the bridge to a remote server.
struct BridgePicker: View {
  @Binding var usesInstalledBridge: Bool

  var body: some View {
    Picker("Claude Desktop starts it with", selection: $usesInstalledBridge) {
      Text("npx -y mcp-remote").tag(false)
      Text("Installed mcp-remote").tag(true)
    }
    .help("Claude Desktop reaches a remote server through the mcp-remote program")
  }
}

/// Messages shown under a field.
struct FieldIssues: View {
  let messages: [String]

  init(messages: [String]) {
    self.messages = messages
  }

  /// The messages of `issues` whose source is `source`, when `isShown`.
  init(_ issues: [SourceIssue]?, _ source: String, isShown: Bool = true) {
    messages = isShown ? (issues ?? []).filter { $0.source == source }.map(\.message) : []
  }

  var body: some View {
    ForEach(messages, id: \.self) { message in
      Label {
        Text(message)
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .accessibilityHidden(true)
      }
      .font(.callout)
    }
  }
}

/// A preview of what will be written, as monospaced text that scrolls sideways instead of
/// wrapping. The library's note about masked arguments wraps below it as plain text.
struct PreviewBlock: View {
  let text: String

  var body: some View {
    let note = Additions.argumentsNote
    let code =
      text.hasSuffix(note)
      ? text.dropLast(note.count).trimmingCharacters(in: .whitespacesAndNewlines) : text
    VStack(alignment: .leading, spacing: 6) {
      ScrollView(.horizontal) {
        Text(code)
          .font(.system(.callout, design: .monospaced))
          .textSelection(.enabled)
          .fixedSize()
          .padding(10)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        .quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      if code != text {
        Text(note)
          .font(.caption)
          .foregroundStyle(Theme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// The header of the collapsed preview. A disclosure group inside a grouped form offers
/// assistive technologies no way to open it, so this is a plain button.
struct PreviewToggle: View {
  @Binding var isExpanded: Bool

  var body: some View {
    Button {
      isExpanded.toggle()
    } label: {
      HStack {
        Text("What will be written")
        Spacer()
        Image(systemName: "chevron.right")
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .foregroundStyle(Theme.secondaryText)
          .accessibilityHidden(true)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityValue(isExpanded ? "Shown" : "Hidden")
  }
}

/// The words a typed line splits into, in labelled groups such as the command and its
/// arguments.
struct ParsedWords: View {
  let groups: [(label: String, words: [String])]

  var body: some View {
    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 3) {
      ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
        ForEach(Array(group.words.enumerated()), id: \.offset) { index, word in
          GridRow {
            Text(index == 0 ? group.label : "")
              .foregroundStyle(Theme.secondaryText)
              .accessibilityHidden(index > 0)
            Text(word)
              .monospaced()
          }
        }
      }
    }
    .font(.callout)
    .textSelection(.enabled)
  }
}
