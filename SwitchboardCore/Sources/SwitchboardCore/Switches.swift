import Foundation

/// One change the user can ask for.
public enum Switch: Hashable, Sendable {
  /// `name` is the name in the project's off list: the server name, or
  /// `plugin:<plugin>:<server>` for a plugin's server.
  case serverInProject(name: String, project: String, on: Bool)
  /// Off takes the server out of Claude Code's file and keeps it. On puts it back.
  case claudeCodeServer(name: String, on: Bool)
  /// Off takes the server out of Claude Desktop's file and keeps it. On puts it back.
  case desktopServer(name: String, on: Bool)
  /// `id` is the extension's folder name.
  case desktopExtension(id: String, on: Bool)
  /// `id` is `<plugin>@<marketplace>`.
  case plugin(id: String, on: Bool)
  /// Sets the plugin in the project's personal settings file, which wins over the shared file
  /// and the user level. `removing` lists what an earlier change created, which this change
  /// takes away again instead of writing a value. Undo of a change carries it.
  case pluginInProject(id: String, project: String, on: Bool, removing: Created = [])

  public var opposite: Switch {
    switch self {
    case .serverInProject(let name, let project, let on):
      .serverInProject(name: name, project: project, on: !on)
    case .claudeCodeServer(let name, let on): .claudeCodeServer(name: name, on: !on)
    case .desktopServer(let name, let on): .desktopServer(name: name, on: !on)
    case .desktopExtension(let id, let on): .desktopExtension(id: id, on: !on)
    case .plugin(let id, let on): .plugin(id: id, on: !on)
    case .pluginInProject(let id, let project, let on, _):
      .pluginInProject(id: id, project: project, on: !on)
    }
  }

  var app: ParkedServers.App {
    switch self {
    case .desktopServer, .desktopExtension: .desktop
    case .serverInProject, .claudeCodeServer, .plugin, .pluginInProject: .claudeCode
    }
  }

  /// True when the switch changes Claude Code's main file, which running sessions rewrite.
  /// Check such a change again a few seconds later with `Switches.isInEffect`.
  public var needsDelayedCheck: Bool {
    switch self {
    case .serverInProject, .claudeCodeServer: true
    case .desktopServer, .desktopExtension, .plugin, .pluginInProject: false
    }
  }
}

public struct SwitchOutcome: Sendable {
  /// True when the asked-for state is on disk, whether or not anything was written.
  public var applied: Bool
  public var issues: [SourceIssue]
  /// The opposite change. Nil when nothing was written.
  public var undo: Switch?
  /// The copy of the file taken before the change. Nil when nothing was written, and after a
  /// restore that created a missing file.
  public var backup: URL?
  /// True when a configuration file was written.
  public var wrote = false
  /// What the change created, which `undo` removes again.
  public var created: Created = []
}

/// Parts of a project's personal settings that a change created.
public struct Created: OptionSet, Hashable, Sendable {
  public let rawValue: Int

  public init(rawValue: Int) {
    self.rawValue = rawValue
  }

  /// The plugin's key in `enabledPlugins`.
  public static let key = Created(rawValue: 1)
  /// The `enabledPlugins` object.
  public static let object = Created(rawValue: 2)
  /// The settings file.
  public static let file = Created(rawValue: 4)
  /// The `.claude` folder.
  public static let folder = Created(rawValue: 8)
}

/// Turns a `Switch` into one safe edit of one configuration file.
public enum Switches: Sendable {
  static let claudeCodeFile = ".claude.json"
  static let settingsFile = ".claude/settings.json"
  static let desktopFile = "Library/Application Support/Claude/claude_desktop_config.json"
  static let projectSettingsFile = ".claude/settings.local.json"
  static let extensionSettingsFolder =
    "Library/Application Support/Claude/Claude Extensions Settings"

  /// Applies `change` to the files under `home`. Backups and kept servers go in `supportFolder`.
  /// Switching something to the state it already has succeeds without writing.
  /// Kept copies of the same app are tidied first, see `ParkedServers.tidy`.
  public static func apply(_ change: Switch, home: URL, supportFolder: URL) -> SwitchOutcome {
    apply(change, home: home, supportFolder: supportFolder, now: Date())
  }

  static func apply(_ change: Switch, home: URL, supportFolder: URL, now: Date) -> SwitchOutcome {
    let tidyIssues = ParkedServers.tidy(
      change.app, home: home, supportFolder: supportFolder, now: now)
    var outcome = applyChange(change, home: home, supportFolder: supportFolder, now: now)
    outcome.issues += tidyIssues
    return outcome
  }

  /// `afterReplace` lets tests damage a file right after it is written.
  static func applyChange(
    _ change: Switch, home: URL, supportFolder: URL, now: Date = Date(),
    afterReplace: () -> Void = {}
  ) -> SwitchOutcome {
    switch change {
    case .claudeCodeServer(let name, let on):
      return on
        ? putBack(
          name, app: .claudeCode, file: claudeCodeFile, home: home, support: supportFolder,
          now: now)
        : keep(
          name, app: .claudeCode, file: claudeCodeFile, home: home, support: supportFolder,
          now: now, afterReplace: afterReplace)
    case .desktopServer(let name, let on):
      return on
        ? putBack(
          name, app: .desktop, file: desktopFile, home: home, support: supportFolder, now: now)
        : keep(
          name, app: .desktop, file: desktopFile, home: home, support: supportFolder,
          now: now, afterReplace: afterReplace)
    case .pluginInProject(let id, let project, let on, let removing):
      return pluginInProject(
        id, project: project, on: on, removing: removing, home: home, support: supportFolder)
    case .serverInProject, .desktopExtension, .plugin:
      guard let edit = edit(for: change) else {
        return failure("Extension", "Not a valid extension. Nothing was changed.")
      }
      let result = ConfigWriter.change(
        edit.file, home: home, supportFolder: supportFolder, edit: edit.apply)
      return SwitchOutcome(
        applied: result.issues.isEmpty,
        issues: result.issues,
        undo: result.backup == nil ? nil : change.opposite,
        backup: result.backup, wrote: result.backup != nil
      )
    }
  }

  /// Whether the state `change` asks for is on disk now. Nil when the file cannot be read or
  /// does not have the expected shape. Nothing is written.
  public static func isInEffect(_ change: Switch, home: URL) -> Bool? {
    switch change {
    case .claudeCodeServer(let name, let on):
      return text(of: claudeCodeFile, home: home).flatMap {
        JSONText.hasMember(at: ["mcpServers", name], in: $0)
      }.map { $0 == on }
    case .desktopServer(let name, let on):
      return text(of: desktopFile, home: home).flatMap {
        JSONText.hasMember(at: ["mcpServers", name], in: $0)
      }.map { $0 == on }
    case .pluginInProject(let id, let project, let on, let removing):
      return isPluginInProjectInEffect(id, project: project, on: on, removing: removing)
    case .serverInProject, .desktopExtension, .plugin:
      guard let edit = edit(for: change), let text = text(of: edit.file, home: home),
        let edited = edit.apply(text)
      else { return nil }
      return edited == text
    }
  }

  /// The switch a table cell offers for `row` in `place`, or nil when the cell is only a mark.
  ///
  /// A cell offers a switch only when exactly one entry of the row takes part in that place, so
  /// the switch decides what the cell shows.
  public static func offered(for row: Row, in place: Place) -> Switch? {
    let entries = row.entries.filter { $0.state(in: place) != .absent }
    guard entries.count == 1, let entry = entries.first, let name = entry.switchName else {
      return nil
    }
    let isOn = entry.state(in: place) == .on
    let isKept = entry.origin == "kept"
    switch place {
    case .desktop:
      if entry.origin == "extension" {
        return .desktopExtension(id: name, on: !isOn)
      }
      guard entry.kind == .server, entry.origin == "config" || isKept else { return nil }
      return .desktopServer(name: name, on: !isOn)
    case .claudeCode:
      if entry.kind == .plugin {
        return .plugin(id: name, on: !isOn)
      }
      guard entry.kind == .server, entry.origin == "user" || isKept else { return nil }
      return .claudeCodeServer(name: name, on: !isOn)
    case .project(let path):
      if entry.kind == .plugin {
        return .pluginInProject(id: name, project: path, on: !isOn)
      }
      guard entry.kind == .server, !isKept, isOn || entry.listedOffIn.contains(path) else {
        return nil
      }
      return .serverInProject(name: name, project: path, on: !isOn)
    }
  }

  /// Whether `name` can be used as a single folder or file name inside a known folder.
  static func isFolderName(_ name: String) -> Bool {
    !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\u{0}")
  }

  /// The file and the text edit for a switch that sets one value in place.
  private static func edit(for change: Switch) -> (file: String, apply: (String) -> String?)? {
    switch change {
    case .serverInProject(let name, let project, let on):
      let path = ["projects", project, "disabledMcpServers"]
      return (
        claudeCodeFile,
        { text in
          on
            ? JSONText.removeString(name, fromArrayAt: path, in: text)
            : JSONText.addString(name, toArrayAt: path, in: text)
        }
      )
    case .plugin(let id, let on):
      return (settingsFile, { JSONText.setBool(on, at: ["enabledPlugins", id], in: $0) })
    case .desktopExtension(let id, let on):
      guard isFolderName(id) else { return nil }
      return (
        extensionSettingsFolder + "/\(id).json",
        { JSONText.setBool(on, at: ["isEnabled"], in: $0) }
      )
    case .claudeCodeServer, .desktopServer, .pluginInProject:
      return nil
    }
  }

  /// Takes the server out of `file` and keeps it. The kept copy is saved before the file is
  /// changed, so a crash between the two steps leaves the server in both places, never in none.
  /// A kept copy with the identical definition, left from a recent put-back or restore, is
  /// reused, so a just-restored removed server becomes a switched-off one, not both.
  /// When the change fails, the kept file goes back to its earlier state only if the file is
  /// intact and still holds the same server.
  private static func keep(
    _ name: String, app: ParkedServers.App, file: String, home: URL, support: URL, now: Date,
    afterReplace: () -> Void
  ) -> SwitchOutcome {
    let path = ["mcpServers", name]
    let change: Switch =
      app == .desktop
      ? .desktopServer(name: name, on: false) : .claudeCodeServer(name: name, on: false)
    var files = SourceFiles(home: home)
    guard let current = ConfigWriter.readJSON(files.url(file), files: &files) else {
      return SwitchOutcome(applied: false, issues: files.issues, undo: nil, backup: nil)
    }
    let loaded = ParkedServers.load(supportFolder: support)
    guard var kept = loaded.servers else {
      return SwitchOutcome(applied: false, issues: loaded.issues, undo: nil, backup: nil)
    }
    guard let removal = JSONText.removeMember(at: path, in: current.text) else {
      if JSONText.hasMember(at: path, in: current.text) == false {
        return kept.contains(where: {
          $0.name.isIdentical(to: name) && $0.app == app && $0.isSwitchedOff
        })
          ? SwitchOutcome(applied: true, issues: [], undo: nil, backup: nil)
          : failure("~/" + file, "No server with this name. Nothing was changed.")
      }
      return failure("~/" + file, "Does not have the expected shape. Nothing was changed.")
    }

    let previous = kept
    var server = ParkedServers.Server(
      id: UUID(), name: name, app: app, date: now, definition: removal.removed,
      following: removal.following)
    if let index = kept.lastIndex(where: {
      $0.name.isIdentical(to: name) && $0.app == app && $0.project == nil
        && ($0.isSwitchedOff || $0.putBackDate != nil)
        && $0.definition.isIdentical(to: removal.removed)
    }) {
      server.id = kept[index].id
      kept[index] = server
    } else {
      kept.append(server)
    }
    let saveIssues = ParkedServers.save(kept, supportFolder: support)
    guard saveIssues.isEmpty else {
      return SwitchOutcome(applied: false, issues: saveIssues, undo: nil, backup: nil)
    }

    let result = ConfigWriter.change(
      file, home: home, supportFolder: support,
      edit: { text in
        guard let removal = JSONText.removeMember(at: path, in: text),
          removal.removed.isIdentical(to: server.definition)
        else { return nil }
        return removal.text
      },
      isInEffect: { JSONText.hasMember(at: path, in: $0) == false },
      afterReplace: afterReplace)
    guard result.issues.isEmpty else {
      let isStillConfigured =
        text(of: file, home: home).flatMap {
          JSONText.removeMember(at: path, in: $0)?.removed.isIdentical(to: server.definition)
        } == true
      guard isStillConfigured else {
        return SwitchOutcome(
          applied: false, issues: result.issues, undo: nil, backup: result.backup,
          wrote: result.backup != nil)
      }
      let rollbackIssues = ParkedServers.save(previous, supportFolder: support)
      return SwitchOutcome(
        applied: false, issues: result.issues + rollbackIssues, undo: nil, backup: result.backup,
        wrote: result.backup != nil)
    }
    return SwitchOutcome(
      applied: true, issues: [], undo: change.opposite, backup: result.backup,
      wrote: result.backup != nil)
  }

  /// Puts the most recently kept server named `name` back into `file`, in its old place when
  /// the member that followed it is still there. The kept copy stays, marked with the time of the
  /// put-back, until `ParkedServers.tidy` sees that the server has held. The time is saved before
  /// the file is written, and nothing is written when that save fails. A missing `mcpServers`
  /// object is created. When the write fails, the time is cleared again. If even that fails, the server is not in the file, so the copy shows
  /// as off and `tidy` clears the time.
  private static func putBack(
    _ name: String, app: ParkedServers.App, file: String, home: URL, support: URL, now: Date
  ) -> SwitchOutcome {
    let path = ["mcpServers", name]
    let change: Switch =
      app == .desktop
      ? .desktopServer(name: name, on: true) : .claudeCodeServer(name: name, on: true)
    var files = SourceFiles(home: home)
    guard let current = ConfigWriter.readJSON(files.url(file), files: &files) else {
      return SwitchOutcome(applied: false, issues: files.issues, undo: nil, backup: nil)
    }
    let loaded = ParkedServers.load(supportFolder: support)
    guard var kept = loaded.servers else {
      return SwitchOutcome(applied: false, issues: loaded.issues, undo: nil, backup: nil)
    }
    guard
      let index = kept.lastIndex(where: {
        $0.name.isIdentical(to: name) && $0.app == app && $0.isSwitchedOff
      })
    else {
      return JSONText.hasMember(at: path, in: current.text) == true
        ? SwitchOutcome(applied: true, issues: [], undo: nil, backup: nil)
        : failure("~/" + file, "No kept server with this name. Nothing was changed.")
    }
    let server = kept[index]
    if JSONText.removeMember(at: path, in: current.text)?.removed.isIdentical(
      to: server.definition) == true
    {
      return SwitchOutcome(applied: true, issues: [], undo: nil, backup: nil)
    }

    let previous = kept
    kept[index].putBackDate = now
    let markIssues = ParkedServers.save(kept, supportFolder: support)
    guard markIssues.isEmpty else {
      return SwitchOutcome(applied: false, issues: markIssues, undo: nil, backup: nil)
    }

    var existsAgain = false
    let result = ConfigWriter.change(
      file, home: home, supportFolder: support,
      edit: { text in
        var edited = text
        if JSONText.hasMember(at: ["mcpServers"], in: text) == false {
          guard let withList = JSONText.insertMember("{}", named: "mcpServers", at: [], in: text)
          else { return nil }
          edited = withList
        }
        switch JSONText.hasMember(at: path, in: edited) {
        case false?:
          return JSONText.insertMember(
            server.definition, named: name, at: ["mcpServers"], following: server.following,
            in: edited)
        case true?:
          existsAgain = true
          return nil
        case nil:
          return nil
        }
      },
      isInEffect: { JSONText.hasMember(at: path, in: $0) == true })
    guard result.issues.isEmpty, !existsAgain else {
      _ = ParkedServers.save(previous, supportFolder: support)
      if existsAgain {
        return failure(
          "~/" + file, "A server with this name exists again. The kept server was not put back.")
      }
      return SwitchOutcome(
        applied: false, issues: result.issues, undo: nil, backup: result.backup,
        wrote: result.backup != nil)
    }
    return SwitchOutcome(
      applied: true, issues: [], undo: change.opposite, backup: result.backup,
      wrote: result.backup != nil)
  }

  static func text(of file: String, home: URL) -> String? {
    var files = SourceFiles(home: home)
    return ConfigWriter.readJSON(files.url(file), files: &files)?.text
  }

  static func failure(_ source: String, _ message: String) -> SwitchOutcome {
    SwitchOutcome(
      applied: false, issues: [SourceIssue(source: source, message: message)], undo: nil,
      backup: nil)
  }
}
