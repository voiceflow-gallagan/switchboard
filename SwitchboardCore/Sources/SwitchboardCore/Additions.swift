import CryptoKit
import Foundation

/// A server to add, as typed in a form. It holds credential values, so it is never stored,
/// logged, or kept after `Additions.add` returns.
public struct NewServer: Sendable {
  public enum Launch: Sendable {
    case local(
      command: String, arguments: [String], environment: [(name: String, value: String)])
    case remote(address: String, headers: [(name: String, value: String)])
  }

  /// How Claude Code reaches a remote server.
  public enum Transport: String, Sendable {
    case http, sse
  }

  public var name: String
  public var launch: Launch
  /// `.desktop`, `.claudeCode`, or both. A project is refused.
  public var targets: Set<Place>
  /// Claude Code's transport for a remote server.
  public var transport: Transport
  /// Claude Desktop starts a remote server with the globally installed `mcp-remote` command
  /// instead of `npx -y mcp-remote`.
  public var usesInstalledBridge: Bool
  /// Arguments added, as given, after the address and headers of Claude Desktop's bridge line
  /// for a remote server. Claude Code connects directly and does not use them.
  public var bridgeOptions: [String]

  public init(
    name: String, launch: Launch, targets: Set<Place>, transport: Transport = .http,
    usesInstalledBridge: Bool = false, bridgeOptions: [String] = []
  ) {
    self.name = name
    self.launch = launch
    self.targets = targets
    self.transport = transport
    self.usesInstalledBridge = usesInstalledBridge
    self.bridgeOptions = bridgeOptions
  }
}

/// A server added by `Additions.add` or `Additions.copy`, so that Undo takes out exactly that.
/// It holds no definition text, which carries credentials, only a digest of it per app.
public struct AddedServer: Hashable, Sendable {
  public let name: String
  /// SHA-256 hex digest of the exact text inserted in each app.
  let digests: [Place: String]
  /// Apps whose `mcpServers` object the addition created.
  let createdLists: Set<Place>

  /// The apps the server was added to.
  public var places: Set<Place> { Set(digests.keys) }
}

public struct AdditionOutcome: Sendable {
  public var applied: Bool
  public var issues: [SourceIssue]
  /// What was added and is still there, for Undo. Nil when nothing stayed.
  public var added: AddedServer?
  /// The copies of the configuration files taken before each write, in order.
  public var backups: [URL]
}

/// Adds servers to Claude Desktop and Claude Code, copies a server from one app to the other,
/// and takes an addition out again.
///
/// Credential values go from a `NewServer`, or from the definition being copied, into the file
/// text and nowhere else. Issues hold fixed wording, previews hold `mask`, and an addition's Undo
/// holds only a digest of the text it inserted.
public enum Additions: Sendable {
  /// What replaces each environment value, header value, and credential part of an address in a
  /// preview.
  public static let mask = "••••••"

  /// Follows a preview of a local server that has arguments.
  public static let argumentsNote =
    "Arguments are shown as flag names only. Their values are hidden."

  // MARK: Checking

  /// Everything that stops `server` from being added: its name, command, address, environment
  /// variable and header names, and a name that a target app already uses, switched off, or in
  /// the Removed list. A name used only in the other app is allowed. Load `inventory` with a
  /// support folder, or switched-off and removed servers are not seen.
  public static func validate(_ server: NewServer, inventory: Inventory) -> [SourceIssue] {
    var issues = inputIssues(server)
    let entries = inventory.rows.flatMap(\.entries).filter {
      $0.kind == .server && $0.name.isIdentical(to: server.name)
    }
    for app in apps(in: server.targets) {
      let message: String?
      if entries.contains(where: { $0.place == app && $0.origin == configOrigin(app) }) {
        message = existsMessage
      } else if inventory.removed.contains(where: {
        $0.place == app && $0.name.isIdentical(to: server.name)
      }) {
        message = removedMessage
      } else if entries.contains(where: { $0.place == app && $0.origin == "kept" }) {
        message = keptMessage
      } else {
        message = nil
      }
      if let message {
        issues.append(SourceIssue(source: appName(app), message: message))
      }
    }
    return issues
  }

  /// The member that `add` writes into `app`'s `mcpServers`, laid out on several lines, with
  /// every environment value, header value, credential part of the address, and argument value
  /// replaced by `mask`, as `maskedWords` shows a launch line. A local server with arguments is
  /// followed by a blank line and `argumentsNote`, and so is Claude Desktop's bridge line when it
  /// has `bridgeOptions`. Claude Code's shape for any place but Claude Desktop.
  public static func preview(_ server: NewServer, for app: Place) -> String {
    let raw = definition(server, for: app, isMasked: true)
    let member = JSONText.encoded(server.name) + ": " + (JSONText.formatted(raw) ?? raw)
    let hasArguments =
      switch server.launch {
      case .local(let command, let arguments, _): words(of: command).count + arguments.count > 1
      case .remote: app == .desktop && !server.bridgeOptions.isEmpty
      }
    return hasArguments ? member + "\n\n" + argumentsNote : member
  }

  // MARK: Adding

  /// Writes `server` into the `mcpServers` object of each target app's file, creating the object
  /// when it is missing, in the file's own style. Claude Desktop is written first. When the
  /// second write fails, the first is taken out again. Refused, with nothing written, when
  /// `validate` would refuse it.
  public static func add(_ server: NewServer, home: URL, supportFolder: URL) -> AdditionOutcome {
    add(server, home: home, supportFolder: supportFolder, beforeWriting: { _ in })
  }

  /// `beforeWriting` lets tests act right before each app's file is written.
  static func add(
    _ server: NewServer, home: URL, supportFolder: URL, beforeWriting: (Place) -> Void
  ) -> AdditionOutcome {
    let inputIssues = inputIssues(server)
    guard inputIssues.isEmpty else { return refusal(inputIssues) }
    let loaded = ParkedServers.load(supportFolder: supportFolder)
    guard let kept = loaded.servers else { return refusal(loaded.issues) }
    var issues: [SourceIssue] = []
    for app in apps(in: server.targets) {
      var files = SourceFiles(home: home)
      guard let current = ConfigWriter.readJSON(files.url(file(of: app)), files: &files) else {
        issues += files.issues
        continue
      }
      if let message = clash(server.name, in: app, text: current.text, kept: kept) {
        issues.append(SourceIssue(source: appName(app), message: message))
      }
    }
    guard issues.isEmpty else { return refusal(issues) }

    var digests: [Place: String] = [:]
    var createdLists: Set<Place> = []
    var backups: [URL] = []
    for app in apps(in: server.targets) {
      beforeWriting(app)
      let written = write(server, to: app, home: home, supportFolder: supportFolder)
      backups += written.backup.map { [$0] } ?? []
      guard written.issues.isEmpty, let digest = written.digest else {
        guard !digests.isEmpty else {
          return AdditionOutcome(
            applied: false, issues: written.issues, added: nil, backups: backups)
        }
        let partial = AddedServer(name: server.name, digests: digests, createdLists: createdLists)
        let rollback = undo(partial, home: home, supportFolder: supportFolder)
        backups += rollback.backups
        guard rollback.applied else {
          return AdditionOutcome(
            applied: false, issues: written.issues + rollback.issues, added: partial,
            backups: backups)
        }
        let undone = apps(in: partial.places).map {
          SourceIssue(
            source: appName($0),
            message: "The server was taken out again, because the other app could not be changed.")
        }
        return AdditionOutcome(
          applied: false, issues: written.issues + undone, added: nil, backups: backups)
      }
      digests[app] = digest
      if written.createdList {
        createdLists.insert(app)
      }
    }
    return AdditionOutcome(
      applied: true, issues: [],
      added: AddedServer(name: server.name, digests: digests, createdLists: createdLists),
      backups: backups)
  }

  /// Takes out what `add` or `copy` added, in every app, and the `mcpServers` object when the
  /// addition created it and it is empty again. Nothing is taken out of an app whose entry has
  /// changed since. An entry that is already gone counts as taken out.
  public static func undo(_ added: AddedServer, home: URL, supportFolder: URL) -> AdditionOutcome {
    var issues: [SourceIssue] = []
    var backups: [URL] = []
    for app in apps(in: added.places).reversed() {
      guard let digest = added.digests[app] else { continue }
      let result = takeOut(
        added.name, digest: digest, removingList: added.createdLists.contains(app), from: app,
        home: home, supportFolder: supportFolder)
      issues += result.issues
      backups += result.backup.map { [$0] } ?? []
    }
    return AdditionOutcome(applied: issues.isEmpty, issues: issues, added: nil, backups: backups)
  }

  /// Whether every app `added` names still has the server. Nil when a file cannot be read or
  /// lacks the expected shape. Check an addition to Claude Code again a few seconds later,
  /// because a running session may rewrite its file without the server.
  public static func isInEffect(_ added: AddedServer, home: URL) -> Bool? {
    for app in apps(in: added.places) {
      guard let text = Switches.text(of: file(of: app), home: home) else { return nil }
      switch JSONText.hasMember(at: ["mcpServers"], in: text) {
      case false?:
        return false
      case true?:
        guard let isPresent = JSONText.hasMember(at: ["mcpServers", added.name], in: text) else {
          return nil
        }
        if !isPresent { return false }
      case nil:
        return nil
      }
    }
    return true
  }

  // MARK: Copying

  /// The app that `row`'s server can be copied to: the other app, for a row whose only entry is
  /// a server the user configured in Claude Desktop or at Claude Code's user level. Nil for
  /// anything else, such as a row in both apps, a switched-off server, or a project's server.
  public static func offeredCopy(for row: Row) -> Place? {
    guard row.kind == .server, row.entries.count == 1, let entry = row.entries.first else {
      return nil
    }
    switch (entry.place, entry.origin) {
    case (.desktop, "config"): return .claudeCode
    case (.claudeCode, "user"): return .desktop
    default: return nil
    }
  }

  /// What `copy` would write into `app`, masked as by `preview(_:for:)`, and everything that
  /// stops it. The text is nil when the definition cannot be translated.
  public static func preview(
    copying row: Row, to app: Place, usesInstalledBridge: Bool = false, home: URL,
    inventory: Inventory
  ) -> (text: String?, issues: [SourceIssue]) {
    let translated = translation(
      of: row, to: app, usesInstalledBridge: usesInstalledBridge, home: home)
    guard let server = translated.server else { return (nil, translated.issues) }
    return (preview(server, for: app), validate(server, inventory: inventory))
  }

  /// Copies `row`'s server to `app` under the same name, as `add` would add it. A local server
  /// keeps its command, arguments, and environment. A remote server is translated between Claude
  /// Code's address and headers and Claude Desktop's `mcp-remote` line. A definition with
  /// anything the translation cannot express is refused, never shortened.
  // ponytail: the definition is read again here, so a change made to it after the preview is
  // copied as it is now, without a new preview.
  public static func copy(
    _ row: Row, to app: Place, usesInstalledBridge: Bool = false, home: URL, supportFolder: URL
  ) -> AdditionOutcome {
    let translated = translation(
      of: row, to: app, usesInstalledBridge: usesInstalledBridge, home: home)
    guard let server = translated.server else { return refusal(translated.issues) }
    return add(server, home: home, supportFolder: supportFolder)
  }

  // MARK: Command lines

  /// The words of a command line typed as one string. Whitespace separates words. Single and
  /// double quotes group, and quoted parts join the word around them. Inside double quotes, a
  /// backslash before a double quote or a backslash stands for that character. Every other
  /// backslash is kept. Nil when a quote is not closed.
  public static func splitCommandLine(_ line: String) -> [String]? {
    let characters = Array(line)
    var words: [String] = []
    var word = ""
    var isInWord = false
    var quote: Character?
    var index = 0
    while index < characters.count {
      let character = characters[index]
      index += 1
      switch quote {
      case "'"?:
        if character == "'" { quote = nil } else { word.append(character) }
      case "\""?:
        if character == "\"" {
          quote = nil
        } else if character == "\\", index < characters.count, "\"\\".contains(characters[index]) {
          word.append(characters[index])
          index += 1
        } else {
          word.append(character)
        }
      default:
        if character.isWhitespace {
          if isInWord {
            words.append(word)
            word = ""
            isInWord = false
          }
        } else {
          if character == "'" || character == "\"" {
            quote = character
          } else {
            word.append(character)
          }
          isInWord = true
        }
      }
    }
    guard quote == nil else { return nil }
    if isInWord {
      words.append(word)
    }
    return words
  }

  // MARK: Writing

  private static func write(_ server: NewServer, to app: Place, home: URL, supportFolder: URL)
    -> (issues: [SourceIssue], backup: URL?, digest: String?, createdList: Bool)
  {
    let raw = definition(server, for: app, isMasked: false)
    let path = ["mcpServers", server.name]
    var inserted: String?
    var createdList = false
    var exists = false
    let result = ConfigWriter.change(
      file(of: app), home: home, supportFolder: supportFolder,
      edit: { text in
        var edited = text
        createdList = JSONText.hasMember(at: ["mcpServers"], in: text) == false
        if createdList {
          guard let withList = JSONText.insertMember("{}", named: "mcpServers", at: [], in: text)
          else { return nil }
          edited = withList
        }
        switch JSONText.hasMember(at: path, in: edited) {
        case false?:
          break
        case true?:
          exists = true
          return nil
        case nil:
          return nil
        }
        guard let value = JSONText.formatted(raw, asMemberAt: ["mcpServers"], in: edited) else {
          return nil
        }
        inserted = value
        return JSONText.insertMember(value, named: server.name, at: ["mcpServers"], in: edited)
      },
      isInEffect: { JSONText.hasMember(at: path, in: $0) == true })
    if exists {
      return ([SourceIssue(source: appName(app), message: existsMessage)], nil, nil, false)
    }
    guard result.issues.isEmpty, result.backup != nil, let inserted else {
      return (result.issues, result.backup, nil, false)
    }
    let stored = Switches.text(of: file(of: app), home: home).flatMap {
      JSONText.removeMember(at: path, in: $0)?.removed
    }
    return ([], result.backup, digest(of: stored ?? inserted), createdList)
  }

  private static func takeOut(
    _ name: String, digest expected: String, removingList: Bool, from app: Place, home: URL,
    supportFolder: URL
  ) -> ConfigWriter.Result {
    let path = ["mcpServers", name]
    var files = SourceFiles(home: home)
    guard let current = ConfigWriter.readJSON(files.url(file(of: app)), files: &files) else {
      return ConfigWriter.Result(issues: files.issues)
    }
    let isPresent =
      JSONText.members(at: ["mcpServers"], in: current.text)?.contains {
        $0.name.isIdentical(to: name)
      } == true
    guard isPresent else { return ConfigWriter.Result(issues: []) }
    var isChanged = false
    let result = ConfigWriter.change(
      file(of: app), home: home, supportFolder: supportFolder,
      edit: { text in
        guard let removal = JSONText.removeMember(at: path, in: text) else { return nil }
        guard digest(of: removal.removed) == expected else {
          isChanged = true
          return nil
        }
        if removingList, JSONText.members(at: ["mcpServers"], in: removal.text)?.isEmpty == true,
          let withoutList = JSONText.removeMember(at: ["mcpServers"], in: removal.text)
        {
          return withoutList.text
        }
        return removal.text
      },
      isInEffect: { JSONText.hasMember(at: path, in: $0) != true })
    guard !isChanged else {
      return ConfigWriter.Result(issues: [
        SourceIssue(
          source: appName(app),
          message: "This server has changed since it was added. It was not taken out.")
      ])
    }
    return result
  }

  /// The compact JSON text of `server`'s definition in `app`, in the shapes of the plan's table.
  private static func definition(_ server: NewServer, for app: Place, isMasked: Bool) -> String {
    let secret: (String) -> String = { isMasked ? mask : $0 }
    let address: (String) -> String = { isMasked ? maskedAddress($0) : $0 }
    var members: [(name: String, raw: String)] = []
    switch (server.launch, app) {
    case (.local(let command, let arguments, let environment), _):
      if app != .desktop {
        members.append(("type", JSONText.encoded("stdio")))
      }
      let line =
        isMasked
        ? maskedLine(command: command, arguments: arguments)
        : (command: command, arguments: arguments)
      members.append(("command", JSONText.encoded(line.command)))
      if !line.arguments.isEmpty {
        members.append(("args", array(line.arguments)))
      }
      if !environment.isEmpty {
        members.append(
          ("env", object(environment.map { ($0.name, JSONText.encoded(secret($0.value))) })))
      }
    case (.remote(let url, let headers), .desktop):
      let bridge = server.usesInstalledBridge ? ["mcp-remote"] : ["npx", "-y", "mcp-remote"]
      let headerArguments = headers.flatMap { ["--header", "\($0.name): \(secret($0.value))"] }
      let options = isMasked ? server.bridgeOptions.map(maskedArgument) : server.bridgeOptions
      members.append(("command", JSONText.encoded(bridge[0])))
      members.append(
        ("args", array(bridge.dropFirst() + [address(url)] + headerArguments + options)))
    case (.remote(let url, let headers), _):
      members.append(("type", JSONText.encoded(server.transport.rawValue)))
      members.append(("url", JSONText.encoded(address(url))))
      if !headers.isEmpty {
        members.append(
          ("headers", object(headers.map { ($0.name, JSONText.encoded(secret($0.value))) })))
      }
    }
    return object(members)
  }

  private static func object(_ members: [(name: String, raw: String)]) -> String {
    "{" + members.map { JSONText.encoded($0.name) + ":" + $0.raw }.joined(separator: ",") + "}"
  }

  private static func array(_ strings: some Sequence<String>) -> String {
    "[" + strings.map(JSONText.encoded).joined(separator: ",") + "]"
  }

  /// What a long flag's name may hold to be shown.
  private static var flagName: Regex<Substring> { /[A-Za-z0-9][A-Za-z0-9._\-]{0,63}/ }

  /// `words` of a launch line as a preview shows them. Only an allowlist is shown: the program,
  /// unless it holds `=`, `:` or `@`; after a package runner, its value-free flags and the
  /// package name, as the inventory reads them; and each flag's name. Anything attached to a flag
  /// and every other word become `mask`. A single dash shows one letter, since `-pVALUE` is a
  /// flag with its value attached.
  static func maskedWords(_ words: [String]) -> [String] {
    guard let program = words.first else { return [] }
    var shown = [program.contains(where: { "=:@".contains($0) }) ? mask : program]
    var rest = words.dropFirst()
    let leadingFlags = rest.prefix { $0.hasPrefix("-") }
    if Duplicates.packageRunners.contains(Duplicates.programName(program)),
      leadingFlags.allSatisfy(Duplicates.runnerFlagsWithoutValue.contains),
      let package = rest.dropFirst(leadingFlags.count).first,
      package.wholeMatch(of: Duplicates.packageName) != nil
    {
      shown += leadingFlags + [package]
      rest = rest.dropFirst(leadingFlags.count + 1)
    }
    return shown + rest.map(maskedArgument)
  }

  private static func maskedArgument(_ word: String) -> String {
    if word == "-" || word == "--" { return word }
    if word.hasPrefix("--") {
      let name = word.prefix { $0 != "=" }
      guard name.dropFirst(2).wholeMatch(of: flagName) != nil else { return mask }
      return name.count == word.count ? word : String(name) + "=" + mask
    }
    if word.hasPrefix("-") {
      let flag = word.prefix(2)
      return flag.count == word.count ? word : String(flag) + mask
    }
    return mask
  }

  /// `command` and `arguments` masked as one line by `maskedWords`. A command holding whitespace
  /// takes part word by word, and comes back joined by single spaces when a word was masked.
  private static func maskedLine(command: String, arguments: [String]) -> (
    command: String, arguments: [String]
  ) {
    let commandWords = words(of: command)
    let masked = maskedWords(commandWords + arguments)
    let maskedCommand = Array(masked.prefix(commandWords.count))
    return (
      maskedCommand == commandWords ? command : maskedCommand.joined(separator: " "),
      Array(masked.dropFirst(commandWords.count))
    )
  }

  private static func words(of command: String) -> [String] {
    command.split(whereSeparator: \.isWhitespace).map(String.init)
  }

  /// `address` with the user part, the path after its first segment, every query value, and the
  /// fragment replaced by `mask`. The user part ends at the last `@` before the first `/`, as the
  /// inventory reads it, since a password may hold `?` or `#`. An address without a scheme is
  /// masked whole.
  // ponytail: a credential in the first path segment, such as `/<token>/mcp`, is shown.
  static func maskedAddress(_ address: String) -> String {
    guard let schemeEnd = address.range(of: "://") else { return mask }
    var result = String(address[..<schemeEnd.upperBound])
    var rest = address[schemeEnd.upperBound...]
    let firstSlash = rest.firstIndex(of: "/") ?? rest.endIndex
    if let at = rest[..<firstSlash].lastIndex(of: "@") {
      result += mask
      rest = rest[at...]
    }
    let authorityEnd = rest.firstIndex { "/?#".contains($0) } ?? rest.endIndex
    result += rest[..<authorityEnd]
    rest = rest[authorityEnd...]
    let fragmentStart = rest.firstIndex(of: "#") ?? rest.endIndex
    let queryStart = rest[..<fragmentStart].firstIndex(of: "?") ?? fragmentStart
    let path = rest[..<queryStart]
    if let secondSlash = path.dropFirst().firstIndex(of: "/"),
      path[path.index(after: secondSlash)...].contains(where: { $0 != "/" })
    {
      result += path[..<secondSlash] + "/" + mask
    } else {
      result += path
    }
    if queryStart < fragmentStart {
      let query = rest[rest.index(after: queryStart)..<fragmentStart]
      let items = query.split(separator: "&", omittingEmptySubsequences: false).map { item in
        guard let equals = item.firstIndex(of: "=") else { return item.isEmpty ? "" : mask }
        return String(item[...equals]) + mask
      }
      result += "?" + items.joined(separator: "&")
    }
    if fragmentStart < rest.endIndex {
      result += "#" + mask
    }
    return result
  }

  // MARK: Translating

  /// `row`'s server as a `NewServer` for `app`, or the issue that stops the copy.
  private static func translation(
    of row: Row, to app: Place, usesInstalledBridge: Bool, home: URL
  ) -> (server: NewServer?, issues: [SourceIssue]) {
    guard offeredCopy(for: row) == app, let entry = row.entries.first else {
      let message = "Only a server that one app alone has can be copied. Nothing was changed."
      return (nil, [SourceIssue(source: appName(app), message: message)])
    }
    let source = "~/" + file(of: entry.place)
    var files = SourceFiles(home: home)
    guard let current = ConfigWriter.readJSON(files.url(file(of: entry.place)), files: &files)
    else { return (nil, files.issues) }
    guard
      let definition = JSONText.removeMember(at: ["mcpServers", entry.name], in: current.text)?
        .removed
    else {
      let message = "No server with this name. Nothing was changed."
      return (nil, [SourceIssue(source: source, message: message)])
    }
    do throws(TranslationError) {
      let parsed = try launch(of: definition, isDesktop: entry.place == .desktop)
      let server = NewServer(
        name: entry.name, launch: parsed.launch, targets: [app], transport: parsed.transport,
        usesInstalledBridge: usesInstalledBridge)
      return (server, [])
    } catch {
      return (nil, [SourceIssue(source: source, message: error.rawValue)])
    }
  }

  private enum TranslationError: String, Error {
    case notAServer = "Is not a server definition the copy understands. Nothing was changed."
    case notText =
      "Has a value that is not text, which the copy cannot carry over. Nothing was changed."
    case unknownSetting = "Has a setting the copy cannot carry over. Nothing was changed."
    case bridgeArgument =
      "Its mcp-remote line has an argument the copy cannot carry over. Nothing was changed."
    case bridgeEnvironment =
      "Its mcp-remote line uses environment variables, which the copy cannot carry over. Nothing was changed."
    case pinnedBridge =
      "Its mcp-remote line pins a version, which the copy cannot carry over. Add the server through the form instead. Nothing was changed."
    case repeatedSetting =
      "Has the same setting more than once, so the copy cannot tell which one counts. Nothing was changed."
  }

  /// The launch a definition describes. In Claude Desktop, an `mcp-remote` line is read as the
  /// remote server it reaches.
  private static func launch(of definition: String, isDesktop: Bool) throws(TranslationError)
    -> (launch: NewServer.Launch, transport: NewServer.Transport)
  {
    guard let members = JSONText.members(at: [], in: definition) else { throw .notAServer }
    guard Set(members.map(\.name)).count == members.count else { throw .repeatedSetting }
    let fields = Dictionary(
      members.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
    let keys = Set(fields.keys)
    let type = try fields["type"].map(text)
    if let url = try fields["url"].map(text) {
      guard keys.isSubset(of: ["type", "url", "headers"]) else { throw .unknownSetting }
      let transport: NewServer.Transport
      switch type {
      case nil, "http"?: transport = .http
      case "sse"?: transport = .sse
      default: throw .unknownSetting
      }
      return (.remote(address: url, headers: try pairs(fields["headers"])), transport)
    }
    guard type == nil || type == "stdio", keys.isSubset(of: ["type", "command", "args", "env"])
    else { throw .unknownSetting }
    guard let command = try fields["command"].map(text) else { throw .notAServer }
    let arguments = try texts(fields["args"])
    let environment = try pairs(fields["env"])
    if isDesktop, let bridge = try bridge(command: command, arguments: arguments) {
      guard environment.isEmpty else { throw .bridgeEnvironment }
      // ponytail: a bridge always becomes `http`. A server that speaks only SSE, which
      // `mcp-remote` reaches by falling back, needs `sse` in Claude Code, and the copy cannot
      // tell.
      return (.remote(address: bridge.address, headers: bridge.headers), .http)
    }
    return (.local(command: command, arguments: arguments, environment: environment), .http)
  }

  /// The address and headers of an `mcp-remote` line, recognised as the inventory does: by
  /// `mcp-remote` in the program or an argument, and a web address. Nil for any other line.
  private static func bridge(command: String, arguments: [String]) throws(TranslationError)
    -> (address: String, headers: [(name: String, value: String)])?
  {
    let program = Duplicates.programName(command)
    let mentionsBridge =
      program.contains("mcp-remote")
      || arguments.contains {
        !$0.hasPrefix("-") && !$0.contains("://") && $0.contains("mcp-remote")
      }
    guard mentionsBridge,
      arguments.contains(where: { $0.hasPrefix("http://") || $0.hasPrefix("https://") })
    else { return nil }
    var rest = arguments[...]
    if program == "npx" {
      while let flag = rest.first, flag == "-y" || flag == "--yes" {
        rest = rest.dropFirst()
      }
      guard let package = rest.popFirst() else { throw .bridgeArgument }
      if package.hasPrefix("mcp-remote@") { throw .pinnedBridge }
      guard package == "mcp-remote" else { throw .bridgeArgument }
    } else if program != "mcp-remote" {
      throw .bridgeArgument
    }
    var headers: [(name: String, value: String)] = []
    var positional: [String] = []
    while let argument = rest.popFirst() {
      let header: String
      if argument == "--header" {
        guard let value = rest.popFirst() else { throw .bridgeArgument }
        header = value
      } else if argument.hasPrefix("--header=") {
        header = String(argument.dropFirst("--header=".count))
      } else if argument.hasPrefix("-") {
        throw .bridgeArgument
      } else {
        positional.append(argument)
        continue
      }
      guard let colon = header.firstIndex(of: ":") else { throw .bridgeArgument }
      let value = header[header.index(after: colon)...].drop { $0 == " " || $0 == "\t" }
      headers.append((String(header[..<colon]), String(value)))
    }
    guard positional.count == 1, let address = positional.first else { throw .bridgeArgument }
    return (address, headers)
  }

  private static func text(_ raw: String) throws(TranslationError) -> String {
    guard
      let string = try? JSONSerialization.jsonObject(
        with: Data(raw.utf8), options: .fragmentsAllowed) as? String
    else { throw .notText }
    return string
  }

  private static func texts(_ raw: String?) throws(TranslationError) -> [String] {
    guard let raw else { return [] }
    guard let strings = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String] else {
      throw .notText
    }
    return strings
  }

  private static func pairs(_ raw: String?) throws(TranslationError) -> [(
    name: String, value: String
  )] {
    guard let raw else { return [] }
    guard let members = JSONText.members(at: [], in: raw) else { throw .notText }
    var pairs: [(name: String, value: String)] = []
    for member in members {
      pairs.append((member.name, try text(member.value)))
    }
    return pairs
  }

  // MARK: Rules

  private static let existsMessage = "Already has a server with this name. Choose another name."
  private static let keptMessage =
    "Has a switched-off server with this name. Switch it on instead."
  private static let removedMessage =
    "Has a removed server with this name. Restore it from the Removed list instead."

  /// Characters a header name may hold, as HTTP defines a token.
  private static let headerNameCharacters = CharacterSet(
    charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

  /// Issues with the typed values themselves. Each names a field and never holds a value.
  private static func inputIssues(_ server: NewServer) -> [SourceIssue] {
    var issues: [SourceIssue] = []
    func refuse(_ field: String, _ message: String) {
      issues.append(SourceIssue(source: field, message: message))
    }
    if server.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      refuse("Name", "The name is empty.")
    } else if server.name.contains("/") {
      refuse("Name", "The name cannot contain a slash.")
    } else if server.name.unicodeScalars.contains(where: isControl) {
      refuse("Name", "The name cannot contain a line break or another control character.")
    }
    if server.targets.isEmpty {
      refuse("Apps", "Choose Claude Desktop, Claude Code, or both.")
    } else if !server.targets.isSubset(of: [.desktop, .claudeCode]) {
      refuse("Apps", "A server can be added only to Claude Desktop or to Claude Code.")
    }
    switch server.launch {
    case .local(let command, _, let environment):
      if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        refuse("Command", "The command is empty.")
      }
      let names = environment.map(\.name)
      if names.contains(where: \.isEmpty) {
        refuse("Environment", "Every environment variable needs a name.")
      } else if names.contains(where: {
        $0.contains("=") || $0.unicodeScalars.contains(where: isControl)
      }) {
        refuse(
          "Environment", "An environment variable name cannot contain = or a control character.")
      } else if Set(names).count < names.count {
        refuse("Environment", "Each environment variable needs a different name.")
      }
    case .remote(let address, let headers):
      if server.bridgeOptions.contains(where: {
        $0.isEmpty || $0.unicodeScalars.contains(where: isControl)
      }) {
        refuse(
          "Bridge options",
          "A bridge option cannot be empty or contain a line break or another control character.")
      }
      if !isWebAddress(address) {
        refuse(
          "Address",
          "The address must start with http:// or https://, name a host, and hold no control character."
        )
      }
      let names = headers.map(\.name)
      if names.contains(where: {
        $0.isEmpty || !$0.unicodeScalars.allSatisfy(headerNameCharacters.contains)
      }) {
        refuse(
          "Headers",
          "A header name can hold only letters, digits, and the characters ! # $ % & ' * + - . ^ _ ` | ~."
        )
      } else if Set(names.map { $0.lowercased() }).count < names.count {
        refuse("Headers", "Each header needs a different name.")
      }
      if headers.contains(where: {
        $0.value.unicodeScalars.contains { isControl($0) && $0 != "\t" }
      }) {
        refuse(
          "Headers", "A header value cannot contain a line break or another control character.")
      }
    }
    return issues
  }

  private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.generalCategory == .control
  }

  private static func isWebAddress(_ address: String) -> Bool {
    guard !address.unicodeScalars.contains(where: isControl),
      let components = URLComponents(string: address),
      let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = components.host, !host.isEmpty
    else { return false }
    return true
  }

  /// Why `name` cannot be added to `app`, from the app's file text and Switchboard's kept
  /// servers, or nil.
  private static func clash(
    _ name: String, in app: Place, text: String, kept: [ParkedServers.Server]
  ) -> String? {
    if JSONText.members(at: ["mcpServers"], in: text)?.contains(where: {
      $0.name.isIdentical(to: name)
    }) == true {
      return existsMessage
    }
    let parked = kept.filter {
      $0.app.place == app && $0.project == nil && $0.name.isIdentical(to: name)
    }
    if parked.contains(where: \.isRemoved) { return removedMessage }
    if !parked.isEmpty { return keptMessage }
    return nil
  }

  private static func digest(of text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private static func refusal(_ issues: [SourceIssue]) -> AdditionOutcome {
    AdditionOutcome(applied: false, issues: issues, added: nil, backups: [])
  }

  private static func refusal(_ issue: SourceIssue) -> AdditionOutcome {
    refusal([issue])
  }

  /// Claude Desktop and Claude Code among `places`, in the order they are written.
  private static func apps(in places: Set<Place>) -> [Place] {
    [.desktop, .claudeCode].filter(places.contains)
  }

  private static func file(of app: Place) -> String {
    app == .desktop ? Switches.desktopFile : Switches.claudeCodeFile
  }

  private static func appName(_ app: Place) -> String {
    app == .desktop ? "Claude Desktop" : "Claude Code"
  }

  private static func configOrigin(_ app: Place) -> String {
    app == .desktop ? "config" : "user"
  }
}
