import SwiftUI
import SwitchboardCore

/// A name and a value typed in the form, such as an environment variable. The value can be a
/// credential, so it lives only in the form's state.
struct TypedPair: Identifiable {
  let id = UUID()
  var name = ""
  var value = ""
}

/// The form that adds a new server to Claude Desktop, Claude Code, or both. Every typed value
/// lives in this view's state only, so it goes when the sheet closes.
struct AddServerView: View {
  let switches: SwitchStore
  let inventory: Inventory?
  let added: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var isRemote = false
  @State private var commandLine = ""
  @State private var environment: [TypedPair] = []
  @State private var address = ""
  @State private var headers: [TypedPair] = []
  @State private var bridgeOptionsLine = ""
  @State private var transport = NewServer.Transport.http
  @State private var usesInstalledBridge = false
  @State private var addsToDesktop = false
  @State private var addsToClaudeCode = false
  @State private var isShowingPreview = false
  @State private var isAdding = false
  @State private var failure: [String] = []

  var body: some View {
    let server = self.server
    let issues = inventory.map { Additions.validate(server, inventory: $0) }
    VStack(alignment: .leading, spacing: 0) {
      Text("Add server")
        .font(.title2.weight(.semibold))
        .padding([.horizontal, .top], 20)
        .padding(.bottom, 8)
      Form {
        Section {
          TextField("Name", text: $name, prompt: Text("my-server"))
            .autocorrectionDisabled()
          FieldIssues(issues, "Name", isShown: !trimmed(name).isEmpty)
          Picker("Runs as", selection: $isRemote) {
            Text("Local command").tag(false)
            Text("Remote address").tag(true)
          }
          .pickerStyle(.segmented)
        }
        if isRemote {
          remoteSections(issues ?? [])
        } else {
          localSections(issues ?? [])
        }
        Section("Add to") {
          Toggle("Claude Desktop", isOn: $addsToDesktop)
          FieldIssues(issues, "Claude Desktop")
          Toggle("Claude Code", isOn: $addsToClaudeCode)
          FieldIssues(issues, "Claude Code")
          FieldIssues(issues, "Apps")
        }
        .toggleStyle(.checkbox)
        Section {
          PreviewToggle(isExpanded: $isShowingPreview)
          if isShowingPreview {
            preview(isComplete ? server : nil)
          }
        }
      }
      .formStyle(.grouped)
      .clipped()
      footer(canAdd: isComplete && issues?.isEmpty == true && !switches.isApplying)
    }
    .frame(width: 580, height: 660)
    .disabled(isAdding)
    .interactiveDismissDisabled(isAdding)
  }

  @ViewBuilder private func localSections(_ issues: [SourceIssue]) -> some View {
    Section {
      TextField("Command line", text: $commandLine, prompt: Text("npx -y @scope/server /path"))
        .labelsHidden()
        .font(.body.monospaced())
        .autocorrectionDisabled()
      if let words = Additions.splitCommandLine(commandLine) {
        if let command = words.first {
          ParsedWords(groups: [("Command", [command]), ("Arguments", Array(words.dropFirst()))])
        }
        FieldIssues(issues, "Command", isShown: !trimmed(commandLine).isEmpty)
      } else {
        FieldIssues(messages: [Additions.unclosedQuote])
      }
    } header: {
      Text("Command line")
    } footer: {
      Text("Spaces separate words. Quotes group them, as in a terminal.")
    }
    Section("Environment variables") {
      PairRows(pairs: $environment, noun: "variable")
      FieldIssues(issues, "Environment")
    }
  }

  @ViewBuilder private func remoteSections(_ issues: [SourceIssue]) -> some View {
    Section("Address") {
      TextField("Address", text: $address, prompt: Text("https://example.com/mcp"))
        .labelsHidden()
        .autocorrectionDisabled()
      FieldIssues(issues, "Address", isShown: !trimmed(address).isEmpty)
    }
    Section {
      Picker("Transport in Claude Code", selection: $transport) {
        Text("HTTP").tag(NewServer.Transport.http)
        Text("SSE").tag(NewServer.Transport.sse)
      }
      .help("SSE is only for older servers")
      BridgePicker(usesInstalledBridge: $usesInstalledBridge)
    }
    Section("Headers") {
      PairRows(pairs: $headers, noun: "header")
      FieldIssues(issues, "Headers")
    }
    if showsBridgeOptions {
      Section {
        TextField(
          "Extra bridge options", text: $bridgeOptionsLine, prompt: Text("--flag value")
        )
        .labelsHidden()
        .font(.body.monospaced())
        .autocorrectionDisabled()
        if let words = Additions.splitCommandLine(bridgeOptionsLine) {
          if !words.isEmpty {
            ParsedWords(groups: [("Options", words)])
          }
          FieldIssues(issues, "Bridge options")
        } else {
          FieldIssues(messages: [Additions.unclosedQuote])
        }
      } header: {
        Text("Extra bridge options")
      } footer: {
        Text(
          "Passed to mcp-remote as given, after the address and headers. Quotes group words, as in a terminal. Not used by Claude Code, which connects directly."
        )
      }
    }
  }

  @ViewBuilder private func preview(_ server: NewServer?) -> some View {
    let apps = [Place.desktop, .claudeCode].filter { server?.targets.contains($0) == true }
    if let server, !apps.isEmpty {
      ForEach(apps, id: \.self) { app in
        VStack(alignment: .leading, spacing: 6) {
          Text(app.additionCaption)
            .font(.caption)
            .foregroundStyle(Theme.secondaryText)
          PreviewBlock(text: Additions.preview(server, for: app))
        }
        .padding(.vertical, 4)
      }
    } else {
      Text("Choose an app, and close every quote.")
        .foregroundStyle(Theme.secondaryText)
    }
  }

  private func footer(canAdd: Bool) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      FieldIssues(messages: failure)
      HStack {
        if isAdding {
          ProgressView()
            .controlSize(.small)
          Text("Adding…")
        }
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Add") {
          Task { await add() }
        }
        .buttonStyle(PillButtonStyle())
        .keyboardShortcut(.defaultAction)
        .disabled(!canAdd)
      }
    }
    .padding(20)
  }

  /// Whether the command line, or the bridge options while shown, has every quote closed.
  private var isComplete: Bool {
    guard isRemote else { return Additions.splitCommandLine(commandLine) != nil }
    return !showsBridgeOptions || Additions.splitCommandLine(bridgeOptionsLine) != nil
  }

  /// The bridge options apply to Claude Desktop only, so they show while it is a target or no
  /// app is chosen yet.
  private var showsBridgeOptions: Bool {
    addsToDesktop || !addsToClaudeCode
  }

  /// The server the form describes. Its command or bridge options are empty while their line
  /// has an open quote, so the other fields are still checked. Rows left fully empty are
  /// ignored, and so are hidden bridge options.
  private var server: NewServer {
    let launch: NewServer.Launch
    if isRemote {
      launch = .remote(address: trimmed(address), headers: Self.filled(headers))
    } else {
      let words = Additions.splitCommandLine(commandLine) ?? []
      launch = .local(
        command: words.first ?? "", arguments: Array(words.dropFirst()),
        environment: Self.filled(environment))
    }
    var targets: Set<Place> = []
    if addsToDesktop { targets.insert(.desktop) }
    if addsToClaudeCode { targets.insert(.claudeCode) }
    let bridgeOptions =
      isRemote && showsBridgeOptions ? Additions.splitCommandLine(bridgeOptionsLine) ?? [] : []
    return NewServer(
      name: trimmed(name), launch: launch, targets: targets, transport: transport,
      usesInstalledBridge: usesInstalledBridge, bridgeOptions: bridgeOptions)
  }

  private func add() async {
    guard isComplete else { return }
    failure = []
    isAdding = true
    let outcome = await switches.add(server)
    isAdding = false
    guard let outcome else {
      failure = [Additions.busy]
      return
    }
    guard outcome.applied else {
      failure = outcome.issues.map { "\($0.source): \($0.message)" }
      return
    }
    clear()
    added()
    dismiss()
  }

  private func clear() {
    name = ""
    commandLine = ""
    environment = []
    address = ""
    headers = []
    bridgeOptionsLine = ""
  }

  private func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func filled(_ pairs: [TypedPair]) -> [(name: String, value: String)] {
    pairs.filter { !$0.name.isEmpty || !$0.value.isEmpty }.map { ($0.name, $0.value) }
  }
}

/// Rows of a name field and a secure value field, with Add and Remove.
private struct PairRows: View {
  @Binding var pairs: [TypedPair]
  let noun: String

  var body: some View {
    ForEach(Array($pairs.enumerated()), id: \.element.wrappedValue.id) { index, $pair in
      let label = "\(noun.capitalized) \(index + 1)"
      HStack {
        TextField("\(label) name", text: $pair.name, prompt: Text("Name"))
          .autocorrectionDisabled()
        SecureField("\(label) value", text: $pair.value, prompt: Text("Value"))
        Button("Remove \(noun) \(index + 1)", systemImage: "minus.circle") {
          pairs.removeAll { $0.id == pair.id }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.secondaryText)
      }
      .labelsHidden()
    }
    Button("Add \(noun)", systemImage: "plus.circle") { pairs.append(TypedPair()) }
      .buttonStyle(.borderless)
  }
}
