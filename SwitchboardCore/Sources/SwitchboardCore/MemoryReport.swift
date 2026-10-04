import Foundation

/// Who started a server: the Claude Desktop app, or one Claude Code session.
public enum Owner: Hashable, Sendable {
  case desktop
  /// `project` is the session's working folder, whether or not Claude Code knows it as a project.
  case session(id: Int32, project: String?)
  /// Servers still running after the owner that started them exited.
  case orphaned
}

/// One server group: a process started by an owner, with everything that process started.
public struct ServerUsage: Identifiable, Sendable {
  public var id: String
  public var owner: Owner
  /// The matched server's target label, or the group's own label when unmatched.
  public var label: String
  /// The inventory row of the matched server. Nil when unmatched.
  public var rowID: Row.ID?
  /// How the group was matched. Nil when unmatched.
  public var matchedBy: MatchStep?
  public var footprint: UInt64
  public var processCount: Int
  /// The matched row is not on where the owner runs it: kept aside, or switched off there.
  /// Its processes run until the owner restarts. Always true for a matched orphan.
  public var isOffButRunning = false
}

public enum MatchStep: Sendable {
  /// The group's target equals a configured server's target.
  case target
  /// Exactly one configured server has the group's label.
  case label
  /// Claude Desktop's extension host processes, totalled as one group. The extensions they run
  /// cannot be told apart, so the group has no row.
  case extensionHosts
}

/// Memory used by one owner.
public struct OwnerTotal: Sendable {
  public var owner: Owner
  public var footprint: UInt64
  /// Memory of this owner's servers that are off but still running, which a restart frees.
  public var offButRunningFootprint: UInt64 = 0
}

/// Memory used by one server across every owner that runs it. Unmatched groups are
/// totalled per label.
public struct ServerTotal: Identifiable, Sendable {
  public var id: String
  public var label: String
  public var rowID: Row.ID?
  public var footprint: UInt64
  /// The number of groups, that is, how many copies of the server run.
  public var copies: Int
  /// How the first group of this server was matched. Nil when unmatched.
  public var matchedBy: MatchStep? = nil
  /// How many of `copies` are off but still running, and the memory they hold.
  public var offButRunningCopies = 0
  public var offButRunningFootprint: UInt64 = 0

  public var isExtensionHosts: Bool {
    matchedBy == .extensionHosts
  }
}

/// Every unmatched group folded into one figure.
public struct UnmatchedTotal: Sendable {
  public var footprint: UInt64
  public var groups: Int
  /// Distinct labels of the unmatched groups, sorted.
  public var labels: [String]
}

/// The data for a "most expensive servers" chart.
public struct ServerChart: Sendable {
  /// The largest matched servers and the extension hosts group, largest first.
  public var top: [ServerTotal]
  /// Nil when every group is matched.
  public var unmatched: UnmatchedTotal?
}

public struct MemoryReport: Sendable {
  public var usages: [ServerUsage]
  public var issues: [SourceIssue]

  public var totalFootprint: UInt64 {
    usages.reduce(0) { $0 + $1.footprint }
  }

  /// Memory held by servers that are off but still running.
  public var offButRunningFootprint: UInt64 {
    usages.filter(\.isOffButRunning).reduce(0) { $0 + $1.footprint }
  }

  /// Owners sorted by memory, largest first.
  public var ownerTotals: [OwnerTotal] {
    var totals: [Owner: OwnerTotal] = [:]
    for usage in usages {
      totals[usage.owner, default: OwnerTotal(owner: usage.owner, footprint: 0)].footprint +=
        usage.footprint
      if usage.isOffButRunning {
        totals[usage.owner]?.offButRunningFootprint += usage.footprint
      }
    }
    return totals.values.sorted { $0.footprint > $1.footprint }
  }

  /// Servers sorted by memory, largest first.
  public var serverTotals: [ServerTotal] {
    var totals: [String: ServerTotal] = [:]
    for usage in usages {
      let key = usage.rowID ?? "unmatched|\(usage.label)"
      totals[
        key,
        default: ServerTotal(
          id: key, label: usage.label, rowID: usage.rowID, footprint: 0, copies: 0,
          matchedBy: usage.matchedBy)
      ]
      .footprint += usage.footprint
      totals[key]?.copies += 1
      if usage.isOffButRunning {
        totals[key]?.offButRunningCopies += 1
        totals[key]?.offButRunningFootprint += usage.footprint
      }
    }
    return totals.values.sorted { ($0.footprint, $1.id) > ($1.footprint, $0.id) }
  }

  /// At most `limit` matched servers and the extension hosts group, with the unmatched groups
  /// folded into one figure.
  public func serverChart(limit: Int = 10) -> ServerChart {
    let top = serverTotals.filter { $0.rowID != nil || $0.isExtensionHosts }.prefix(max(limit, 0))
    let unmatched = usages.filter { $0.matchedBy == nil }
    return ServerChart(
      top: Array(top),
      unmatched: unmatched.isEmpty
        ? nil
        : UnmatchedTotal(
          footprint: unmatched.reduce(0) { $0 + $1.footprint },
          groups: unmatched.count,
          labels: Set(unmatched.map(\.label)).sorted()
        )
    )
  }

  enum OwnerKind {
    case desktop, session
  }

  /// Claude Desktop runs its extensions in Electron's Node utility processes, which are
  /// started from this helper app.
  private static let extensionHostApp = "/Claude Helper (Plugin).app/"
  private static let shells: Set = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh"]
  private static let nonServers: Set = ["caffeinate"]

  static func ownerKind(programPath path: String) -> OwnerKind? {
    if path.hasSuffix("/Claude.app/Contents/MacOS/Claude") { return .desktop }
    if path.contains("/claude/versions/") || Duplicates.programName(path) == "claude" {
      return .session
    }
    return nil
  }

  /// Groups each owner's processes into servers and matches them to the inventory.
  /// Pure: the same processes and inventory always give the same report.
  public static func build(
    processes: [RunningProcess],
    inventory: Inventory,
    issues: [SourceIssue] = []
  ) -> MemoryReport {
    var children: [Int32: [RunningProcess]] = [:]
    for process in processes {
      children[process.parent, default: []].append(process)
    }
    let serverEntries = inventory.rows.filter { $0.kind == .server }.flatMap { row in
      row.entries.map { (entry: $0, rowID: row.id) }
    }
    let desktopCandidates = serverEntries.filter { $0.entry.place == .desktop }
    let userCandidates = serverEntries.filter {
      $0.entry.place == .claudeCode && $0.entry.state == .on
    }
    let userOffCandidates = serverEntries.filter {
      $0.entry.place == .claudeCode && $0.entry.state == .off
    }
    var projectCandidates: [String: [(entry: Entry, rowID: Row.ID)]] = [:]
    var projectOffCandidates: [String: [(entry: Entry, rowID: Row.ID)]] = [:]
    let knownProjects = Set(inventory.projects)
    let rows = Dictionary(uniqueKeysWithValues: inventory.rows.map { ($0.id, $0) })

    func group(_ root: RunningProcess) -> [RunningProcess] {
      var members = [root]
      var visited: Set<Int32> = [root.id]
      var index = 0
      while index < members.count {
        for child in children[members[index].id] ?? []
        where ownerKind(programPath: child.programPath) == nil && visited.insert(child.id).inserted
        {
          members.append(child)
        }
        index += 1
      }
      return members
    }

    var usages: [ServerUsage] = []
    /// Servers that are off where they run are matched by target only. An equal target among
    /// the servers that are on wins, then one among those that are off, then a label among those
    /// that are on, so a switched-off or kept server is still recognized while it runs.
    func add(
      _ roots: [RunningProcess], owner: Owner, place: Place?,
      candidates: [(entry: Entry, rowID: Row.ID)],
      offCandidates: [(entry: Entry, rowID: Row.ID)] = []
    ) {
      for root in roots {
        let members = group(root)
        let onMatch = match(root.target, among: candidates)
        let offMatch = offCandidates.first {
          root.target != nil && $0.entry.target == root.target
        }.map { ($0.entry, $0.rowID, MatchStep.target) }
        let match = onMatch?.step == .target ? onMatch : offMatch ?? onMatch
        let isOn = place.flatMap { place in
          match.flatMap { rows[$0.rowID]?.state(in: place) }
        }
        let label = root.target?.label ?? Duplicates.programName(root.programPath)
        usages.append(
          ServerUsage(
            id: "\(owner)|\(root.id)",
            owner: owner,
            label: match?.entry.target?.label ?? label,
            rowID: match?.rowID,
            matchedBy: match?.step,
            footprint: members.reduce(0) { $0 + $1.footprint },
            processCount: members.count,
            isOffButRunning: match != nil && isOn != .on
          )
        )
      }
    }

    for owner in processes {
      switch ownerKind(programPath: owner.programPath) {
      case .desktop:
        let direct = children[owner.id] ?? []
        let hosts = direct.filter { $0.programPath.contains(extensionHostApp) }
        if !hosts.isEmpty {
          let members = hosts.flatMap(group)
          usages.append(
            ServerUsage(
              id: "\(Owner.desktop)|extensions",
              owner: .desktop,
              label: "Desktop extensions",
              rowID: nil,
              matchedBy: .extensionHosts,
              footprint: members.reduce(0) { $0 + $1.footprint },
              processCount: members.count
            )
          )
        }
        let roots = direct.filter {
          !$0.programPath.contains(".app/Contents/Frameworks/")
            && ownerKind(programPath: $0.programPath) == nil
        }
        add(roots, owner: .desktop, place: .desktop, candidates: desktopCandidates)
      case .session:
        let roots = (children[owner.id] ?? []).filter {
          let name = Duplicates.programName($0.programPath)
          return !shells.contains(name) && !nonServers.contains(name)
            && ownerKind(programPath: $0.programPath) == nil
        }
        let candidates: [(entry: Entry, rowID: Row.ID)]
        let offCandidates: [(entry: Entry, rowID: Row.ID)]
        let place: Place
        if let folder = owner.workingFolder,
          let project = project(
            containing: folder, known: knownProjects, aliases: inventory.projectAliases)
        {
          if projectCandidates[project] == nil {
            projectCandidates[project] = serverEntries.filter {
              $0.entry.state(in: .project(path: project)) == .on
            }
          }
          if projectOffCandidates[project] == nil {
            projectOffCandidates[project] = serverEntries.filter {
              $0.entry.state(in: .project(path: project)) == .off
            }
          }
          candidates = projectCandidates[project] ?? []
          offCandidates = projectOffCandidates[project] ?? []
          place = .project(path: project)
        } else {
          candidates = userCandidates
          offCandidates = userOffCandidates
          place = .claudeCode
        }
        add(
          roots, owner: .session(id: owner.id, project: owner.workingFolder), place: place,
          candidates: candidates, offCandidates: offCandidates)
      case nil:
        break
      }
    }

    let orphans = children[launchd]?.filter { process in
      ownerKind(programPath: process.programPath) == nil
        && serverEntries.contains { $0.entry.target != nil && $0.entry.target == process.target }
    }
    add(
      orphans ?? [], owner: .orphaned, place: nil,
      candidates: serverEntries.filter { $0.entry.target != nil })
    return MemoryReport(usages: usages, issues: issues)
  }

  private static let launchd: Int32 = 1

  /// The nearest known project at or above `folder`. The root folder counts only as itself.
  static func project(containing folder: String, known: Set<String>, aliases: [String: String])
    -> String?
  {
    var current = URL(fileURLWithPath: folder).standardizedFileURL.path
    while true {
      if let project = aliases[current] ?? (known.contains(current) ? current : nil),
        project != "/" || current == folder
      {
        return project
      }
      guard current != "/" else { return nil }
      current = URL(fileURLWithPath: current).deletingLastPathComponent().standardizedFileURL.path
    }
  }

  /// Step 1: an equal target. Step 2: exactly one candidate with the same label.
  /// Otherwise unmatched.
  private static func match(
    _ target: Target?,
    among candidates: [(entry: Entry, rowID: Row.ID)]
  ) -> (entry: Entry, rowID: Row.ID, step: MatchStep)? {
    guard let target else { return nil }
    if let exact = candidates.first(where: { $0.entry.target == target }) {
      return (exact.entry, exact.rowID, .target)
    }
    let sameLabel = candidates.filter { $0.entry.target?.label == target.label }
    guard let first = sameLabel.first, Set(sameLabel.map(\.rowID)).count == 1 else { return nil }
    return (first.entry, first.rowID, .label)
  }
}
