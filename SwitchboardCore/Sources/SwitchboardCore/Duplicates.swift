import Foundation

/// A server definition as written in any of the configuration files.
/// Values of `env` and `headers` are discarded while decoding.
struct ServerConfig: Decodable {
  var type: String?
  var command: String?
  var args: [String]?
  var url: String?
  var env: [String: Ignored]?
  var headers: [String: Ignored]?
}

struct Ignored: Decodable {
  init(from decoder: any Decoder) throws {}
}

struct Launch {
  var target: Target?
  var typeLabel: String
  var secretNames: [String]
}

/// Builds targets from server definitions and groups entries into rows.
///
/// Nothing from an argument or an address reaches the model except through an allowlist:
/// the host and port of an address, a program's file name, and a package name. Everything else
/// only takes part in the target's digest.
enum Duplicates {
  static let packageRunners: Set = ["npx", "bunx", "pnpx", "uvx"]
  private static let transports: Set = ["http", "sse", "streamable-http"]
  static var packageName: Regex<Substring> {
    /(?:@[A-Za-z0-9._~\-]+\/)?[A-Za-z0-9._~\-]+(?:@[A-Za-z0-9._~^<>=*\-]+)?/
  }
  private static var variableName: Regex<Substring> { /[A-Za-z_][A-Za-z0-9_\-]{0,63}/ }
  private static var hostName: Regex<Substring> { /[a-z0-9._\-]+|\[[0-9a-f:.]+\]/ }

  /// The target of a running process, from its launch arguments with `argv[0]` first.
  /// Claude Desktop's `disclaimer` wrapper is skipped up to its `--`. A process that runs from
  /// a Desktop extension folder gets that extension's target.
  static func target(launchArguments arguments: [String]) -> Target? {
    var launchLine = arguments[...]
    if launchLine.first.map(programName) == "disclaimer", let end = launchLine.firstIndex(of: "--")
    {
      launchLine = launchLine[(end + 1)...]
    }
    for argument in launchLine {
      guard let range = argument.range(of: "/Claude Extensions/") else { continue }
      let folder = argument[range.upperBound...].prefix { $0 != "/" }
      if !folder.isEmpty {
        return Target(mode: .local, label: "extension", identity: ["extension", String(folder)])
      }
    }
    guard let command = launchLine.first else { return nil }
    return launch(of: ServerConfig(args: Array(launchLine.dropFirst())), commandWords: [command])
      .target
  }

  static func programName(_ path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? path
  }

  /// Flags a package runner accepts before the package name that take no value.
  static let runnerFlagsWithoutValue: Set = [
    "-y", "--yes", "-q", "--quiet", "-s", "--silent", "-v", "--verbose", "--no-install",
    "--prefer-offline", "--offline", "--bun", "--isolated", "--no-cache", "--refresh",
  ]

  /// A `command` containing whitespace is one program path only when `isProgramFile` says the
  /// whole string names an existing program file. Otherwise its words are split, the first is
  /// the program, and the rest are arguments.
  static func launch(
    of config: ServerConfig,
    isProgramFile: (String) -> Bool = { _ in false }
  ) -> Launch {
    let command = (config.command ?? "").trimmingCharacters(in: .whitespaces)
    let commandWords =
      command.contains(where: \.isWhitespace) && !isProgramFile(command)
      ? command.split(whereSeparator: \.isWhitespace).map(String.init)
      : (command.isEmpty ? [] : [command])
    return launch(of: config, commandWords: commandWords)
  }

  /// A word shown as a program label must look like a program name. Anything that could be a
  /// value or an address gets a fixed label, and only takes part in the digest.
  private static func programLabel(_ program: String) -> String {
    let word = program.prefix { !$0.isWhitespace }
    let looksLikeValue = word.isEmpty || word.contains { "=:@/".contains($0) }
    return looksLikeValue ? "local" : String(word)
  }

  private static func launch(of config: ServerConfig, commandWords: [String]) -> Launch {
    let arguments = Array(commandWords.dropFirst()) + (config.args ?? [])
    let secretNames =
      (Array((config.env ?? [:]).keys) + Array((config.headers ?? [:]).keys)
      + parsedSecretNames(in: arguments)).sorted()

    if let url = config.url {
      let transport = config.type?.lowercased() ?? "http"
      return Launch(
        target: remoteTarget(url),
        typeLabel: transports.contains(transport) ? transport : "remote",
        secretNames: secretNames
      )
    }

    guard let command = commandWords.first else {
      return Launch(target: nil, typeLabel: "unknown", secretNames: secretNames)
    }
    let program = programName(command)

    let usesMCPRemote =
      program.contains("mcp-remote")
      || arguments.contains {
        !$0.hasPrefix("-") && !$0.contains("://") && $0.contains("mcp-remote")
      }
    if usesMCPRemote,
      let address = arguments.first(where: { $0.hasPrefix("http://") || $0.hasPrefix("https://") })
    {
      return Launch(
        target: remoteTarget(address), typeLabel: "mcp-remote", secretNames: secretNames)
    }

    let leadingFlags = arguments.prefix { $0.hasPrefix("-") }
    if packageRunners.contains(program), leadingFlags.allSatisfy(runnerFlagsWithoutValue.contains) {
      let rest = arguments.dropFirst(leadingFlags.count)
      if let package = rest.first, package.wholeMatch(of: packageName) != nil {
        let name = withoutVersion(package)
        return Launch(
          target: Target(
            mode: .local,
            label: "\(program) \(name)",
            identity: ["package", name] + rest.dropFirst()
          ),
          typeLabel: program,
          secretNames: secretNames
        )
      }
    }

    return Launch(
      target: Target(
        mode: .local,
        label: programLabel(program),
        identity: ["program", program] + arguments
      ),
      typeLabel: packageRunners.contains(program) || program == "docker" ? program : "local",
      secretNames: secretNames
    )
  }

  /// The identity is host, port, and path. The label is host and port only.
  /// A string that cannot be read as an address gets the label `remote` and a digest of itself.
  static func remoteTarget(_ raw: String) -> Target {
    let address = raw.contains("://") ? raw : "unknown://" + raw
    guard let parts = addressParts(address) else {
      return Target(mode: .remote, label: "remote", identity: ["unparsed", raw])
    }
    return Target(mode: .remote, label: parts.authority, identity: [parts.authority + parts.path])
  }

  private static func addressParts(_ address: String) -> (authority: String, path: String)? {
    guard let schemeEnd = address.range(of: "://") else { return nil }
    var rest = address[schemeEnd.upperBound...]
    let firstSlash = rest.firstIndex(of: "/") ?? rest.endIndex
    if let at = rest[..<firstSlash].lastIndex(of: "@") {
      rest = rest[rest.index(after: at)...]
    }
    let authorityEnd = rest.firstIndex { "/?#".contains($0) } ?? rest.endIndex
    let authority = rest[..<authorityEnd].lowercased()
    var path = rest[authorityEnd...]
    if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
      path = path[..<cut]
    }
    guard isHostAndPort(authority), !path.contains("@") else { return nil }
    var trimmedPath = String(path)
    while trimmedPath.hasSuffix("/") {
      trimmedPath.removeLast()
    }
    return (authority, trimmedPath)
  }

  private static func isHostAndPort(_ authority: String) -> Bool {
    var host = Substring(authority)
    if let colon = authority.lastIndex(of: ":"), !authority.hasSuffix("]") {
      let port = authority[authority.index(after: colon)...]
      guard (1...5).contains(port.count), port.allSatisfy(\.isASCII), port.allSatisfy(\.isNumber)
      else { return false }
      host = authority[..<colon]
    }
    return host.wholeMatch(of: hostName) != nil
  }

  /// Names from `--header Name: value`, `-H`, `-e NAME=value`, and `--env NAME=value`.
  private static func parsedSecretNames(in arguments: [String]) -> [String] {
    var names: [String] = []
    var index = arguments.startIndex
    while index < arguments.endIndex {
      let argument = arguments[index]
      index += 1
      guard argument.hasPrefix("-") else { continue }
      let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
      let flag = parts[0].lowercased()
      let isHeader = flag == "-h" || flag.contains("header")
      let isEnvironment = flag == "-e" || flag == "--env"
      guard isHeader || isEnvironment else { continue }
      var value = parts.count == 2 ? parts[1] : nil
      if value == nil, index < arguments.endIndex, !arguments[index].hasPrefix("-") {
        value = arguments[index]
        index += 1
      }
      guard let value, let separator = value.firstIndex(of: isHeader ? ":" : "=") else { continue }
      let name = value[..<separator].trimmingCharacters(in: CharacterSet(charactersIn: "{\"' "))
      if name.wholeMatch(of: variableName) != nil {
        names.append(name)
      }
    }
    return names
  }

  static func withoutVersion(_ package: String) -> String {
    let searchStart =
      package.hasPrefix("@") ? package.index(after: package.startIndex) : package.startIndex
    guard let at = package[searchStart...].firstIndex(of: "@") else { return package }
    return String(package[..<at])
  }

  static func rows(from entries: [Entry]) -> [Row] {
    var groups: [String: [Entry]] = [:]
    for entry in entries {
      groups[groupKey(of: entry), default: []].append(entry)
    }

    var rows = groups.map { key, group in
      let sorted = group.sorted { placeOrder($0.place) < placeOrder($1.place) }
      return Row(
        id: key,
        name: sorted[0].name,
        kind: sorted[0].kind,
        entries: sorted,
        isDuplicate: sorted[0].kind == .server && isDuplicate(sorted),
        hasNameConflict: false
      )
    }

    for index in conflictingRows(rows) {
      rows[index].hasNameConflict = true
    }

    return rows.map { (key: ($0.kind.sortIndex, $0.name.lowercased(), $0.id), row: $0) }
      .sorted { $0.key < $1.key }
      .map(\.row)
  }

  // ponytail: servers that differ only in `env` values share a target and group as duplicates,
  // because values are never read.
  private static func groupKey(of entry: Entry) -> String {
    switch (entry.kind, entry.target) {
    case (.server, let target?): "server|\(target.mode)|\(target.key)"
    case (.server, nil): "server|none|\(entry.place)|\(entry.origin)|\(entry.name)"
    case (.plugin, _): "plugin|\(entry.name)@\(entry.typeLabel)"
    case (.skill, _): "skill|\(entry.name)"
    }
  }

  /// Rows that share an entry name with another row of the same kind, where both could load
  /// together: they share a place, or one of them is in Desktop or at Claude Code user level.
  private static func conflictingRows(_ rows: [Row]) -> Set<Int> {
    var byName: [String: [(row: Int, place: Place)]] = [:]
    for (index, row) in rows.enumerated() where row.kind != .skill {
      for entry in row.entries {
        byName["\(row.kind.rawValue)|\(entry.name)", default: []].append((index, entry.place))
      }
    }
    var conflicting: Set<Int> = []
    for uses in byName.values where Set(uses.map(\.row)).count > 1 {
      for first in uses {
        for second in uses where second.row != first.row {
          if first.place == second.place || !first.place.isProject || !second.place.isProject {
            conflicting.formUnion([first.row, second.row])
          }
        }
      }
    }
    return conflicting
  }

  /// True when the same target would load twice in one place, or is configured in both apps.
  /// The same project-level server in several unrelated projects is not a duplicate.
  private static func isDuplicate(_ entries: [Entry]) -> Bool {
    var desktop = 0
    var claudeCode = 0
    var perProject: [String: Int] = [:]
    for entry in entries {
      switch entry.place {
      case .desktop: desktop += 1
      case .claudeCode: claudeCode += 1
      case .project(let path): perProject[path, default: 0] += 1
      }
    }
    let inClaudeCode = claudeCode > 0 || !perProject.isEmpty
    return desktop > 1
      || (desktop > 0 && inClaudeCode)
      || claudeCode > 1
      || (claudeCode > 0 && !perProject.isEmpty)
      || perProject.values.contains { $0 > 1 }
  }

  private static func placeOrder(_ place: Place) -> Int {
    switch place {
    case .desktop: 0
    case .claudeCode: 1
    case .project: 2
    }
  }
}

extension Kind {
  fileprivate var sortIndex: Int {
    Kind.allCases.firstIndex(of: self) ?? 0
  }
}

extension Place {
  fileprivate var isProject: Bool {
    if case .project = self { true } else { false }
  }
}
