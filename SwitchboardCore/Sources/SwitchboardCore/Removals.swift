import Foundation

/// Something the user can remove.
public enum Removal: Hashable, Sendable {
  /// A server of Claude Desktop, of Claude Code at user level, or a project's own server.
  case server(name: String, place: Place)
  /// A plugin, uninstalled through Claude Code's own command. `id` is `<plugin>@<marketplace>`.
  case plugin(id: String)
}

/// A server in the Removed list. Its definition stays in Switchboard's kept file.
public struct RemovedServer: Identifiable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let place: Place
  public let typeLabel: String
  public let removedAt: Date
}

/// The opposite of a removal or a restore, for Undo.
public enum RemovalUndo: Hashable, Sendable {
  case restore(RemovedServer)
  case remove(Removal)
  case reinstall(pluginID: String)
}

public struct RemovalOutcome: Sendable {
  public var applied: Bool
  public var issues: [SourceIssue]
  /// The copy of the configuration file taken before the change. Nil when nothing was written,
  /// and for plugins, whose files Claude Code writes itself.
  public var backup: URL?
  /// The opposite action. Nil when nothing changed or nothing can undo it.
  public var undo: RemovalUndo?
  /// Claude Code's command finished, but its answer could not be read, so whether it did its
  /// work is not known. `applied` is false and `issues` says to check the plugin list.
  public var isUnconfirmed = false
}

/// Removes servers into the Removed list, restores them, deletes them for good, and uninstalls
/// or reinstalls plugins through Claude Code's own command.
public enum Removals: Sendable {
  /// What can be removed from `row`: one removal per server the user configured in Claude
  /// Desktop, at Claude Code's user level, or in a project's own list. Never a plugin's server,
  /// a `.mcp.json` server, an extension, or a row with a switched-off server. A plugin row offers
  /// its uninstall when it is installed at user level.
  public static func offered(for row: Row) -> [Removal] {
    guard !row.entries.contains(where: { $0.origin == "kept" }) else { return [] }
    return row.entries.compactMap { entry in
      switch (entry.kind, entry.origin, entry.place) {
      case (.server, "config", .desktop), (.server, "user", .claudeCode),
        (.server, "project", .project):
        .server(name: entry.name, place: entry.place)
      case (.plugin, _, .claudeCode):
        entry.switchName.map { .plugin(id: $0) }
      default:
        nil
      }
    }
  }

  /// Removes a server into the Removed list, or uninstalls a plugin with the Claude Code program
  /// at `claude`. A server's definition is saved before it leaves its file. An uninstall blocks
  /// the calling thread for up to `ClaudeCommand.timeLimit`: from async code, use the async
  /// version.
  public static func remove(
    _ removal: Removal, home: URL, supportFolder: URL, claude: URL?
  ) -> RemovalOutcome {
    switch removal {
    case .server(let name, let place):
      return removeServer(name, place: place, home: home, supportFolder: supportFolder, now: Date())
    case .plugin(let id):
      guard let claude else {
        return RemovalOutcome(
          applied: false, issues: [ClaudeCommand.notFound], backup: nil, undo: nil)
      }
      let result = ClaudeCommand.uninstall(pluginID: id, program: claude, home: home)
      return RemovalOutcome(
        applied: result.issues.isEmpty, issues: result.issues, backup: nil,
        undo: result.issues.isEmpty ? .reinstall(pluginID: id) : nil,
        isUnconfirmed: result.isUnconfirmed)
    }
  }

  /// Installs a plugin again with the Claude Code program at `claude`. It needs the network and
  /// may bring a newer version. It blocks like `remove`.
  public static func reinstall(pluginID: String, home: URL, claude: URL) -> RemovalOutcome {
    let result = ClaudeCommand.install(pluginID: pluginID, program: claude, home: home)
    return RemovalOutcome(
      applied: result.issues.isEmpty, issues: result.issues, backup: nil,
      undo: result.issues.isEmpty ? .remove(.plugin(id: pluginID)) : nil,
      isUnconfirmed: result.isUnconfirmed)
  }

  /// `remove`, run on a dispatch queue so no cooperative thread waits on Claude Code.
  public static func remove(
    _ removal: Removal, home: URL, supportFolder: URL, claude: URL?
  ) async -> RemovalOutcome {
    await offPool { remove(removal, home: home, supportFolder: supportFolder, claude: claude) }
  }

  /// `reinstall`, run on a dispatch queue so no cooperative thread waits on Claude Code.
  public static func reinstall(pluginID: String, home: URL, claude: URL) async -> RemovalOutcome {
    await offPool { reinstall(pluginID: pluginID, home: home, claude: claude) }
  }

  /// `undo`, run on a dispatch queue so no cooperative thread waits on Claude Code.
  public static func undo(_ undo: RemovalUndo, home: URL, supportFolder: URL, claude: URL?)
    async -> RemovalOutcome
  {
    await offPool { self.undo(undo, home: home, supportFolder: supportFolder, claude: claude) }
  }

  private static func offPool(_ work: @escaping @Sendable () -> RemovalOutcome) async
    -> RemovalOutcome
  {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async { continuation.resume(returning: work()) }
    }
  }

  /// Whether the change that `undo` would reverse still holds on disk: after a removal, the
  /// server is absent from its place; after a restore, it is present. Nil for plugins, and when
  /// the file cannot be read or lacks the expected shape.
  public static func isInEffect(_ undo: RemovalUndo, home: URL) -> Bool? {
    let name: String
    let place: Place
    let isRemoval: Bool
    switch undo {
    case .restore(let removed):
      (name, place, isRemoval) = (removed.name, removed.place, true)
    case .remove(.server(let server, let serverPlace)):
      (name, place, isRemoval) = (server, serverPlace, false)
    case .remove(.plugin), .reinstall:
      return nil
    }
    let (_, file, project) = location(of: place)
    let path = (project.map { ["projects", $0, "mcpServers"] } ?? ["mcpServers"]) + [name]
    guard let text = Switches.text(of: file, home: home),
      let present = JSONText.hasMember(at: path, in: text)
    else { return nil }
    return present != isRemoval
  }

  /// Applies an Undo.
  public static func undo(_ undo: RemovalUndo, home: URL, supportFolder: URL, claude: URL?)
    -> RemovalOutcome
  {
    switch undo {
    case .restore(let server):
      return restore(server, home: home, supportFolder: supportFolder)
    case .remove(let removal):
      return remove(removal, home: home, supportFolder: supportFolder, claude: claude)
    case .reinstall(let id):
      guard let claude else {
        return RemovalOutcome(
          applied: false, issues: [ClaudeCommand.notFound], backup: nil, undo: nil)
      }
      return reinstall(pluginID: id, home: home, claude: claude)
    }
  }

  /// Puts a removed server back into the file it came from, in its old place. Refused when a
  /// server with that name exists there again. The kept copy stays until the server has held.
  public static func restore(_ removed: RemovedServer, home: URL, supportFolder: URL)
    -> RemovalOutcome
  {
    restore(removed, home: home, supportFolder: supportFolder, now: Date())
  }

  /// Deletes a removed server's kept definition. Nothing else changes. Backups may still hold it.
  public static func deleteForGood(_ removed: RemovedServer, supportFolder: URL) -> RemovalOutcome {
    let loaded = ParkedServers.load(supportFolder: supportFolder)
    guard var kept = loaded.servers else {
      return RemovalOutcome(applied: false, issues: loaded.issues, backup: nil, undo: nil)
    }
    let count = kept.count
    kept.removeAll { $0.id.uuidString == removed.id && $0.isRemoved }
    guard kept.count < count else {
      return failure(ParkedServers.source, "Not in the removed list. Nothing was changed.")
    }
    let issues = ParkedServers.save(kept, supportFolder: supportFolder)
    return RemovalOutcome(applied: issues.isEmpty, issues: issues, backup: nil, undo: nil)
  }

  private static func location(of place: Place) -> (
    app: ParkedServers.App, file: String, project: String?
  ) {
    switch place {
    case .desktop: (.desktop, Switches.desktopFile, nil)
    case .claudeCode: (.claudeCode, Switches.claudeCodeFile, nil)
    case .project(let path): (.claudeCode, Switches.claudeCodeFile, path)
    }
  }

  /// `afterReplace` lets tests damage the file right after it is written.
  static func removeServer(
    _ name: String, place: Place, home: URL, supportFolder: URL, now: Date,
    afterReplace: () -> Void = {}
  ) -> RemovalOutcome {
    let (app, file, project) = location(of: place)
    let tidyIssues = ParkedServers.tidy(app, home: home, supportFolder: supportFolder, now: now)
    let parent = project.map { ["projects", $0, "mcpServers"] } ?? ["mcpServers"]
    let path = parent + [name]
    let projects = Switches.knownProjects(home: home)
    var files = SourceFiles(home: home)
    files.projects = projects
    guard let current = ConfigWriter.readJSON(files.url(file), files: &files) else {
      return RemovalOutcome(applied: false, issues: files.issues, backup: nil, undo: nil)
    }
    let loaded = ParkedServers.load(supportFolder: supportFolder)
    guard var kept = loaded.servers else {
      return RemovalOutcome(applied: false, issues: loaded.issues, backup: nil, undo: nil)
    }
    guard let removal = JSONText.removeMember(at: path, in: current.text) else {
      let message =
        JSONText.hasMember(at: path, in: current.text) == false
        ? "No server with this name. Nothing was changed."
        : "Does not have the expected shape. Nothing was changed."
      return failure("~/" + file, message)
    }

    let previous = kept
    var server = ParkedServers.Server(
      id: UUID(), name: name, app: app, date: now, definition: removal.removed,
      following: removal.following, project: project, removed: true)
    if let index = kept.lastIndex(where: {
      $0.name.isIdentical(to: name) && $0.app == app && $0.project == project
        && $0.definition.isIdentical(to: removal.removed)
    }) {
      server.id = kept[index].id
      kept[index] = server
    } else {
      kept.append(server)
    }
    let saveIssues = ParkedServers.save(kept, supportFolder: supportFolder)
    guard saveIssues.isEmpty else {
      return RemovalOutcome(applied: false, issues: saveIssues, backup: nil, undo: nil)
    }

    let result = ConfigWriter.change(
      file, home: home, supportFolder: supportFolder, projects: projects,
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
        Switches.text(of: file, home: home).flatMap {
          JSONText.removeMember(at: path, in: $0)?.removed.isIdentical(to: server.definition)
        } == true
      let rollbackIssues =
        isStillConfigured
        ? ParkedServers.save(previous, supportFolder: supportFolder).map {
          SourceIssue(
            source: $0.source,
            message: "The server stayed in its file, but its removed copy could not be taken back")
        } : []
      return RemovalOutcome(
        applied: false, issues: result.issues + rollbackIssues, backup: result.backup, undo: nil)
    }
    let listed = RemovedServer(
      id: server.id.uuidString, name: name, place: place, typeLabel: typeLabel(of: server),
      removedAt: now)
    return RemovalOutcome(
      applied: true, issues: tidyIssues, backup: result.backup, undo: .restore(listed))
  }

  static func restore(_ removed: RemovedServer, home: URL, supportFolder: URL, now: Date)
    -> RemovalOutcome
  {
    let app: ParkedServers.App = removed.place == .desktop ? .desktop : .claudeCode
    let tidyIssues = ParkedServers.tidy(app, home: home, supportFolder: supportFolder, now: now)
    let loaded = ParkedServers.load(supportFolder: supportFolder)
    guard var kept = loaded.servers else {
      return RemovalOutcome(applied: false, issues: loaded.issues, backup: nil, undo: nil)
    }
    guard
      let index = kept.firstIndex(where: { $0.id.uuidString == removed.id && $0.isRemoved }),
      kept[index].putBackDate == nil
    else {
      return failure(ParkedServers.source, "Not in the removed list. Nothing was changed.")
    }
    let server = kept[index]
    let file = server.app.file
    let path = server.parentPath + [server.name]
    let projects = Switches.knownProjects(home: home)

    let previous = kept
    kept[index].putBackDate = now
    let markIssues = ParkedServers.save(kept, supportFolder: supportFolder)
    guard markIssues.isEmpty else {
      return RemovalOutcome(applied: false, issues: markIssues, backup: nil, undo: nil)
    }

    var existsAgain = false
    var isPlaceGone = false
    let result = ConfigWriter.change(
      file, home: home, supportFolder: supportFolder, projects: projects,
      edit: { text in
        var edited = text
        if let project = server.project {
          guard JSONText.hasMember(at: ["projects", project], in: edited) == true else {
            isPlaceGone = true
            return nil
          }
          if JSONText.hasMember(at: server.parentPath, in: edited) == false {
            guard
              let withList = JSONText.insertMember(
                "{}", named: "mcpServers", at: ["projects", project], in: edited)
            else { return nil }
            edited = withList
          }
        }
        switch JSONText.hasMember(at: path, in: edited) {
        case false?:
          return JSONText.insertMember(
            server.definition, named: server.name, at: server.parentPath,
            following: server.following, in: edited)
        case true?:
          existsAgain = true
          return nil
        case nil:
          return nil
        }
      },
      isInEffect: { JSONText.hasMember(at: path, in: $0) == true })
    guard result.issues.isEmpty, !existsAgain else {
      let rollbackIssues = ParkedServers.save(previous, supportFolder: supportFolder)
      if existsAgain {
        return failure(
          "~/" + file, "A server with this name exists again. The removed server was not restored.")
      }
      if isPlaceGone {
        return failure(
          "~/" + file, "The project it came from is no longer in this file. Nothing was changed.")
      }
      return RemovalOutcome(
        applied: false, issues: result.issues + rollbackIssues, backup: result.backup, undo: nil)
    }
    return RemovalOutcome(
      applied: true, issues: tidyIssues, backup: result.backup,
      undo: .remove(.server(name: server.name, place: server.place)))
  }

  private static func typeLabel(of server: ParkedServers.Server) -> String {
    guard
      let config = try? JSONDecoder().decode(
        ServerConfig.self, from: Data(server.definition.utf8))
    else { return "unknown" }
    return Duplicates.launch(of: config).typeLabel
  }

  private static func failure(_ source: String, _ message: String) -> RemovalOutcome {
    RemovalOutcome(
      applied: false, issues: [SourceIssue(source: source, message: message)], backup: nil,
      undo: nil)
  }
}
