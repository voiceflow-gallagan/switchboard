import Foundation

/// An app or session that must restart before a change takes effect.
public struct RestartNeed: Identifiable, Hashable, Sendable {
  /// The process identifier of the app or session.
  public var id: Int32
  public var owner: Owner
}

/// Who must restart after a switch, from the processes running at the time.
public enum RestartNeeds: Sendable {
  /// Who reads the configuration a change touches.
  enum Reach: Hashable {
    case desktop
    case everySession
    /// The sessions of one project, and those whose folder is unknown.
    case project(String)
  }

  /// The apps or sessions among `processes` that must restart for `change` to take effect.
  /// A change in one project needs that project's sessions, and sessions whose folder is
  /// unknown. A change at user level or to a plugin needs every session. A Desktop change needs
  /// Claude Desktop. Pure.
  public static func needs(
    for change: Switch, processes: [RunningProcess], inventory: Inventory
  ) -> [RestartNeed] {
    let reach: Reach =
      switch change {
      case .desktopServer, .desktopExtension: .desktop
      case .claudeCodeServer, .plugin: .everySession
      case .serverInProject(_, let project, _), .pluginInProject(_, let project, _, _):
        .project(project)
      }
    return needs(for: [reach], processes: processes, inventory: inventory)
  }

  /// The apps or sessions that must restart after a removal or its restore: as for switching
  /// the server off in its place, or the plugin off everywhere.
  public static func needs(
    for removal: Removal, processes: [RunningProcess], inventory: Inventory
  ) -> [RestartNeed] {
    let reach: Reach =
      switch removal {
      case .server(_, .desktop): .desktop
      case .server(_, .claudeCode), .plugin: .everySession
      case .server(_, .project(let path)): .project(path)
      }
    return needs(for: [reach], processes: processes, inventory: inventory)
  }

  /// The apps or sessions that must restart after a server is added or its addition is undone:
  /// as for switching the server on in each app it was added to.
  public static func needs(
    for added: AddedServer, processes: [RunningProcess], inventory: Inventory
  ) -> [RestartNeed] {
    var reaches: Set<Reach> = []
    if added.places.contains(.desktop) {
      reaches.insert(.desktop)
    }
    if added.places.contains(.claudeCode) {
      reaches.insert(.everySession)
    }
    return needs(for: reaches, processes: processes, inventory: inventory)
  }

  /// The apps or sessions that must restart after `backup` is restored: Claude Desktop for its
  /// files, every session for Claude Code's main file and user settings, and for a project's
  /// personal settings file the sessions of that project and those whose folder is unknown.
  public static func needs(
    forRestoreOf backup: Backup, processes: [RunningProcess], inventory: Inventory
  ) -> [RestartNeed] {
    let reach: Reach
    if backup.file.hasPrefix("/") {
      reach = .project(
        URL(fileURLWithPath: backup.file).deletingLastPathComponent()
          .deletingLastPathComponent().path)
    } else if backup.file.hasPrefix("Library/") {
      reach = .desktop
    } else {
      reach = .everySession
    }
    return needs(for: [reach], processes: processes, inventory: inventory)
  }

  /// The running apps and sessions that any of `reaches` covers, in process order.
  static func needs(for reaches: Set<Reach>, processes: [RunningProcess], inventory: Inventory)
    -> [RestartNeed]
  {
    owners(in: processes).filter { need in
      reaches.contains { reach in
        switch (reach, need.owner) {
        case (.desktop, .desktop), (.everySession, .session):
          return true
        case (.project(let project), .session(_, let folder)):
          guard let folder else { return true }
          return MemoryReport.project(
            containing: folder, known: Set(inventory.projects).union([project]),
            aliases: inventory.projectAliases) == project
        default:
          return false
        }
      }
    }
  }

  /// The needs whose app or session still runs. A need goes away when its process ends.
  public static func remaining(_ needs: [RestartNeed], processes: [RunningProcess])
    -> [RestartNeed]
  {
    let running = Set(owners(in: processes))
    return needs.filter(running.contains)
  }

  private static func owners(in processes: [RunningProcess]) -> [RestartNeed] {
    processes.compactMap { process in
      switch MemoryReport.ownerKind(programPath: process.programPath) {
      case .desktop:
        RestartNeed(id: process.id, owner: .desktop)
      case .session:
        RestartNeed(
          id: process.id, owner: .session(id: process.id, project: process.workingFolder))
      case nil:
        nil
      }
    }
    .sorted { $0.id < $1.id }
  }
}
