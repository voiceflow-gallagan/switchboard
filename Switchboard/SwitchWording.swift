import Foundation
import SwitchboardCore

extension Switch {
  /// The state the change asks for.
  var turnsOn: Bool {
    switch self {
    case .serverInProject(_, _, let on), .claudeCodeServer(_, let on), .desktopServer(_, let on),
      .desktopExtension(_, let on), .plugin(_, let on), .pluginInProject(_, _, let on, _):
      on
    }
  }

  /// Where the change applies, in words. A project is named by its folder name only.
  var placeName: String {
    switch self {
    case .serverInProject(_, let project, _), .pluginInProject(_, let project, _, _):
      "project \(URL(filePath: project).lastPathComponent)"
    case .claudeCodeServer: "Claude Code, every project"
    case .plugin: "Claude Code"
    case .desktopServer, .desktopExtension: "Claude Desktop"
    }
  }

  /// What a control that applies this change does, for its help tag.
  func actionLabel(name: String) -> String {
    "Switch \(turnsOn ? "on" : "off") \(name) in \(placeName)"
  }

  /// The item and place a switch controls, for assistive technologies. The switch's value
  /// carries the state.
  func placeLabel(name: String) -> String {
    "\(name) in \(placeName)"
  }

  /// What the change did, in words, for the notice after it.
  func summary(name: String) -> String {
    let state = turnsOn ? "on" : "off"
    switch self {
    case .claudeCodeServer, .desktopServer:
      return turnsOn
        ? "\(name) is back on in \(placeName)."
        : "\(name) is off in \(placeName). Switchboard keeps its settings to put it back."
    case .plugin, .pluginInProject:
      return "Plugin \(name) is \(state) in \(placeName)."
    case .serverInProject, .desktopExtension:
      return "\(name) is \(state) in \(placeName)."
    }
  }
}

extension Place {
  /// Where an item is configured, in words. A project is named by its folder name only.
  var spokenName: String {
    switch self {
    case .desktop: "Claude Desktop"
    case .claudeCode: "Claude Code"
    case .project(let path): "project \(URL(filePath: path).lastPathComponent)"
    }
  }

  /// The menu item that copies a server to this app.
  var copyTitle: String {
    "Copy to \(spokenName)…"
  }

  /// Where a new server goes in this app's file, above a preview of it.
  var additionCaption: String {
    self == .desktop
      ? "Added under mcpServers in claude_desktop_config.json"
      : "Added under mcpServers in ~/.claude.json, for every project"
  }

  /// What copying a server to this app does, for the copy sheet.
  var copyExplanation: String {
    let file = self == .desktop ? "claude_desktop_config.json" : "~/.claude.json"
    return
      "Switchboard adds this server under the same name to \(spokenName)'s file, \(file). Values that can hold credentials are hidden here."
  }
}

extension AddedServer {
  /// The apps the server was added to, in words.
  var appNames: String {
    places.count > 1 ? "Claude Desktop and Claude Code" : places.first?.spokenName ?? "no app"
  }

  var addedSummary: String { "\(name) was added to \(appNames)." }
  var copiedSummary: String { "\(name) was copied to \(appNames)." }
  var undoneSummary: String { "\(name) was taken out of \(appNames)." }

  /// The message when a running Claude Code session wrote its main file without the server.
  var sessionRemoved: SourceIssue {
    SourceIssue(
      source: "Claude Code",
      message:
        "A running Claude Code session removed \(name) right after it was added. Close that session, then try again."
    )
  }
}

extension Additions {
  /// Shown under the command line while it cannot be split into words.
  static let unclosedQuote = "A quote is not closed."
  /// Shown in a sheet when the store is busy with another change.
  static let busy = "Another change is being applied. Try again in a moment."
}

extension Removal {
  /// The menu item that applies this removal.
  var actionTitle: String {
    switch self {
    case .server(_, let place): "Remove from \(place.spokenName)"
    case .plugin: "Uninstall…"
    }
  }

  /// What the removal did, for the notice after it.
  func summary(name: String) -> String {
    switch self {
    case .server(_, let place):
      "\(name) was removed from \(place.spokenName). It is in the Removed list."
    case .plugin: "Plugin \(name) was uninstalled."
    }
  }
}

extension RemovalUndo {
  /// True when the change it reverses edited Claude Code's main file, which running sessions
  /// rewrite.
  var changesClaudeCodeFile: Bool {
    switch reach {
    case .server(_, .desktop), .plugin: false
    case .server: true
    }
  }

  /// The removal with the same reach, to know what must restart.
  var reach: Removal {
    switch self {
    case .restore(let server): .server(name: server.name, place: server.place)
    case .remove(let removal): removal
    case .reinstall(let id): .plugin(id: id)
    }
  }

  /// What applying this undo does, in words.
  func summary(name: String) -> String {
    switch self {
    case .restore(let server): RemovedServer.restoredSummary(name: name, place: server.place)
    case .remove(let removal): removal.summary(name: name)
    case .reinstall: "Plugin \(name) was installed again."
    }
  }
}

extension RemovedServer {
  static func restoredSummary(name: String, place: Place) -> String {
    "\(name) is back in \(place.spokenName)."
  }

  /// The help text for Uninstall when Claude Code's program cannot be run.
  static let programNotFound =
    "Claude Code's program was not found, so plugins cannot be uninstalled."
}

/// Words from the library's values, as the interface shows them.
enum DisplayText {
  /// Written in upper case.
  static let acronyms: Set<String> = ["http", "sse"]
  /// Written in lower case, as their makers write them.
  static let tools: Set<String> = ["npx", "uvx", "bunx", "pnpx", "mcp-remote", "python", "node"]

  /// A type label for display: each part between commas starts with a capital, acronyms are in
  /// upper case, and tool names stay as their makers write them. The rest of a part, such as the
  /// name in "plugin ecc", is kept as configured.
  static func typeLabel(_ label: String) -> String {
    label.components(separatedBy: ", ").map(part).joined(separator: ", ")
  }

  private static func part(_ part: String) -> String {
    let end = part.firstIndex(of: " ") ?? part.endIndex
    return word(String(part[..<end])) + part[end...]
  }

  private static func word(_ word: String) -> String {
    guard !tools.contains(word) else { return word }
    let written = word.split(separator: "-", omittingEmptySubsequences: false)
      .map { acronyms.contains(String($0)) ? $0.uppercased() : String($0) }
      .joined(separator: "-")
    return written.prefix(1).uppercased() + written.dropFirst()
  }
}

extension Row {
  /// The type column's text and tooltip. A row with entries in projects names them after
  /// "Project ·", by `projectLabels`, three at most and then "and N more", with every project in
  /// the tooltip. A server keeps its own type before them, such as "Local, Project · alpha".
  func typeDescription(projectLabels: [String: String]) -> (text: String, help: String?) {
    let type = kind == .plugin ? typeLabel : DisplayText.typeLabel(typeLabel)
    var projects: [String] = []
    for entry in entries {
      guard case .project(let path) = entry.place else { continue }
      let label = projectLabels[path] ?? URL(filePath: path).lastPathComponent
      if !projects.contains(label) {
        projects.append(label)
      }
    }
    guard !projects.isEmpty else { return (type, nil) }
    let shown =
      projects.prefix(3).joined(separator: " · ")
      + (projects.count > 3 ? " and \(projects.count - 3) more" : "")
    let parts = type.components(separatedBy: ", ").filter { $0 != "Project" }
    return (
      (parts + ["Project · \(shown)"]).joined(separator: ", "), projects.joined(separator: "\n")
    )
  }
}
