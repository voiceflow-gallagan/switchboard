import Foundation

/// Servers Switchboard took out of a configuration and keeps, so they can be put back.
///
/// Each definition is the exact text that was removed and holds live credentials. The file is
/// readable only by its owner. A definition reaches the model only through
/// `Duplicates.launch(of:)`, which keeps a safe label and a digest.
enum ParkedServers {
  static let fileName = "kept-servers.json"
  static let source = "Kept servers"
  /// Version 2 adds removed servers. A build that knows only version 1 refuses the file, so it
  /// never mistakes a removed server for a switched-off one and cleans it up. Version 1 loads.
  static let version = 2

  enum App: String, Codable {
    case desktop, claudeCode

    var place: Place {
      switch self {
      case .desktop: .desktop
      case .claudeCode: .claudeCode
      }
    }

    var file: String {
      switch self {
      case .desktop: Switches.desktopFile
      case .claudeCode: Switches.claudeCodeFile
      }
    }
  }

  struct Server: Codable {
    var id: UUID
    var name: String
    var app: App
    var date: Date
    /// The exact text of the removed value.
    var definition: String
    /// The member that followed it, so it goes back in the same place.
    var following: String?
    /// When it was last put back. The copy is kept until the server has held in the file for
    /// `holdTime`, because a session started while it was off may write the file without it.
    var putBackDate: Date?
    /// The project whose own servers it came from. Nil for a server of the whole app.
    var project: String?
    /// True for a server the user removed, which is listed apart. It is cleaned up only after it
    /// was restored and has held for `holdTime`.
    var removed: Bool?

    var isRemoved: Bool { removed == true }

    /// A server switched off in its app, as opposed to a removed one or a project's own.
    var isSwitchedOff: Bool { !isRemoved && project == nil }

    /// The object in its app's file that holds it.
    var parentPath: [String] {
      project.map { ["projects", $0, "mcpServers"] } ?? ["mcpServers"]
    }

    var place: Place {
      project.map { .project(path: $0) } ?? app.place
    }
  }

  static let holdTime: TimeInterval = 600

  /// How a kept server compares with its app's file now.
  enum Presence {
    case identical, different, absent, unknown
  }

  private struct File: Codable {
    var version: Int
    var servers: [Server]
  }

  /// A missing file loads as empty. A file that cannot be read loads as nil with an issue, and
  /// must then never be overwritten.
  static func load(supportFolder: URL) -> (servers: [Server]?, issues: [SourceIssue]) {
    var files = SourceFiles(home: supportFolder)
    let url = supportFolder.appending(path: fileName)
    guard files.fileExists(url) else { return ([], []) }
    let file = files.decode(File.self, at: url)
    var issues = files.issues.map { SourceIssue(source: source, message: $0.message) }
    if let file, !(1...version).contains(file.version) {
      issues.append(SourceIssue(source: source, message: "Written by a newer Switchboard"))
      return (nil, issues)
    }
    return (file?.servers, issues)
  }

  static func save(_ servers: [Server], supportFolder: URL) -> [SourceIssue] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    do {
      try ConfigWriter.writePrivately(
        try encoder.encode(File(version: version, servers: servers)),
        to: supportFolder.appending(path: fileName), folders: [supportFolder])
      return []
    } catch {
      return [SourceIssue(source: source, message: "Could not be saved")]
    }
  }

  /// How each kept server compares with its app's file, which is parsed once per app.
  static func presence(of servers: [Server], home: URL) -> [UUID: Presence] {
    var texts: [App: String] = [:]
    for app in Set(servers.map(\.app)) {
      if let data = ConfigWriter.contents(of: home.appending(path: app.file), home: home) {
        texts[app] = String(data: data, encoding: .utf8)
      }
    }
    var configured: [App: [[String]: [(name: String, value: String)]]] = [:]
    for (app, text) in texts {
      let paths = Set(servers.filter { $0.app == app }.map(\.parentPath))
      configured[app] = JSONText.members(atEach: Array(paths), in: text)
    }
    var result: [UUID: Presence] = [:]
    for server in servers {
      guard let members = configured[server.app]?[server.parentPath] else {
        result[server.id] = .unknown
        continue
      }
      let matches = members.filter { $0.name.isIdentical(to: server.name) }
      if matches.isEmpty {
        result[server.id] = .absent
      } else if matches.count == 1, matches[0].value.isIdentical(to: server.definition) {
        result[server.id] = .identical
      } else {
        result[server.id] = .different
      }
    }
    return result
  }

  /// Tidies the kept copies of `app`. A copy whose identical definition is in the file is
  /// removed only when the later of its kept date and its put-back time is at least `holdTime`
  /// old, because a stale session may write the file without the server until then. A copy put
  /// back whose server has gone from the file again loses its put-back time, so it shows as off.
  /// A copy put back whose server was edited since is a leftover: the edit wins, and the copy is
  /// removed once `holdTime` has passed. The same rules apply to a removed server only once it is
  /// restored: until then it is never touched, and when it goes from the file again it returns to
  /// the removed list.
  /// A kept file that cannot be read is left alone.
  static func tidy(_ app: App, home: URL, supportFolder: URL, now: Date) -> [SourceIssue] {
    guard let servers = load(supportFolder: supportFolder).servers else { return [] }
    let presence = presence(of: servers.filter { $0.app == app }, home: home)
    var changed = false
    let tidied = servers.compactMap { server -> Server? in
      if server.isRemoved, server.putBackDate == nil {
        return server
      }
      switch presence[server.id] {
      case .identical?:
        let latest = max(server.date, server.putBackDate ?? server.date)
        if now.timeIntervalSince(latest) < holdTime {
          return server
        }
        changed = true
        return nil
      case .absent? where server.putBackDate != nil:
        changed = true
        var cleared = server
        cleared.putBackDate = nil
        return cleared
      case .different? where server.putBackDate != nil:
        let latest = max(server.date, server.putBackDate ?? server.date)
        if now.timeIntervalSince(latest) < holdTime {
          return server
        }
        changed = true
        return nil
      default:
        return server
      }
    }
    return changed ? save(tidied, supportFolder: supportFolder) : []
  }

  /// One entry per server switched off and kept, off in its app, and the removed servers. A copy
  /// whose identical definition is in the file is not shown, because that server is on. Nor is a
  /// copy put back whose server was edited since, which `tidy` removes.
  static func read(supportFolder: URL, files: inout SourceFiles) -> (
    entries: [Entry], removed: [RemovedServer]
  ) {
    let loaded = load(supportFolder: supportFolder)
    files.issues += loaded.issues
    let servers = loaded.servers ?? []
    let presence = presence(of: servers, home: files.home)
    var removed: [RemovedServer] = []
    var entries: [Entry] = []
    for server in servers {
      switch presence[server.id] {
      case .identical?: continue
      case .different? where server.putBackDate != nil: continue
      default: break
      }
      let config: ServerConfig
      do {
        config = try JSONDecoder().decode(ServerConfig.self, from: Data(server.definition.utf8))
      } catch {
        files.issues.append(
          SourceIssue(
            source: source,
            message: "Skipped kept server \"\(server.name)\": \(SourceFiles.message(for: error))"))
        continue
      }
      let launch = Duplicates.launch(of: config, isProgramFile: files.isProgramFile)
      if server.isRemoved {
        removed.append(
          RemovedServer(
            id: server.id.uuidString, name: server.name, place: server.place,
            typeLabel: launch.typeLabel, removedAt: server.date))
        continue
      }
      entries.append(
        Entry(
          name: server.name,
          kind: .server,
          place: server.app.place,
          origin: "kept",
          state: .off,
          target: launch.target,
          secretNames: launch.secretNames,
          typeLabel: launch.typeLabel,
          switchName: server.name
        ))
    }
    return (entries, removed.sorted { $0.removedAt > $1.removedAt })
  }
}
