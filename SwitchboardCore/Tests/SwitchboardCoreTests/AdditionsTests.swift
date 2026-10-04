import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct AdditionsTests {
  private static let envSecret = "SWB-FAKE-SECRET-added-env"
  private static let headerSecret = "SWB-FAKE-SECRET-added-header"
  private static let address = "https://added.example.test/mcp"
  private static let apps: [Place] = [.desktop, .claudeCode]
  private static let targetChoices: [Set<Place>] = [
    [.desktop], [.claudeCode], [.desktop, .claudeCode],
  ]

  private func file(_ app: Place) -> String {
    app == .desktop ? Switches.desktopFile : Switches.claudeCodeFile
  }

  private func local(_ targets: Set<Place>, name: String = "added") -> NewServer {
    NewServer(
      name: name,
      launch: .local(
        command: "npx", arguments: ["-y", "@acme/added-server"],
        environment: [("ADDED_TOKEN", Self.envSecret)]),
      targets: targets)
  }

  private func remote(
    _ targets: Set<Place>, name: String = "added", transport: NewServer.Transport = .http,
    usesInstalledBridge: Bool = false
  ) -> NewServer {
    NewServer(
      name: name,
      launch: .remote(
        address: Self.address, headers: [("Authorization", "Bearer " + Self.headerSecret)]),
      targets: targets, transport: transport, usesInstalledBridge: usesInstalledBridge)
  }

  private func add(_ server: NewServer, _ home: FixtureHome) -> AdditionOutcome {
    Additions.add(server, home: home.url, supportFolder: home.support)
  }

  private func undo(_ outcome: AdditionOutcome, _ home: FixtureHome) throws -> AdditionOutcome {
    Additions.undo(try #require(outcome.added), home: home.url, supportFolder: home.support)
  }

  private func copy(
    _ name: String, to app: Place, usesInstalledBridge: Bool = false, _ home: FixtureHome
  ) throws -> AdditionOutcome {
    Additions.copy(
      try load(home).row(name), to: app, usesInstalledBridge: usesInstalledBridge,
      home: home.url, supportFolder: home.support)
  }

  private func load(_ home: FixtureHome) -> Inventory {
    Inventory.load(home: home.url, supportFolder: home.support)
  }

  private func originals(_ home: FixtureHome) throws -> [Data] {
    try Self.apps.map { try home.data(file($0)) }
  }

  /// The server's definition in `app`'s file, decoded.
  private func definition(_ name: String, in app: Place, _ home: FixtureHome) throws
    -> NSDictionary
  {
    let config = try #require(
      try JSONSerialization.jsonObject(with: home.data(file(app))) as? [String: Any])
    let servers = try #require(config["mcpServers"] as? [String: Any])
    return try #require(servers[name] as? NSDictionary)
  }

  private func insert(_ raw: String, named name: String, in app: Place, _ home: FixtureHome)
    throws
  {
    let text = try home.text(file(app))
    try home.write(
      try #require(JSONText.insertMember(raw, named: name, at: ["mcpServers"], in: text)),
      to: file(app))
  }

  // MARK: Adding

  @Test(arguments: targetChoices)
  func aLocalServerHasTheTableShapeAndUndoIsExact(targets: Set<Place>) throws {
    let home = try FixtureHome()
    let before = try originals(home)
    let outcome = add(local(targets), home)
    #expect(outcome.applied)
    #expect(outcome.issues.isEmpty)
    #expect(outcome.backups.count == targets.count)
    #expect(outcome.added?.places == targets)
    for (index, app) in Self.apps.enumerated() {
      guard targets.contains(app) else {
        #expect(try home.data(file(app)) == before[index])
        continue
      }
      let shared: [String: Any] = [
        "command": "npx", "args": ["-y", "@acme/added-server"],
        "env": ["ADDED_TOKEN": Self.envSecret],
      ]
      let expected = app == .desktop ? shared : shared.merging(["type": "stdio"]) { $1 }
      #expect(try definition("added", in: app, home) == expected as NSDictionary)
      #expect(try load(home).row("added").state(in: app) == .on)
    }

    #expect(try undo(outcome, home).applied)
    #expect(try originals(home) == before)
  }

  @Test(arguments: targetChoices)
  func aRemoteServerHasTheTableShapeAndUndoIsExact(targets: Set<Place>) throws {
    let home = try FixtureHome()
    let before = try originals(home)
    let outcome = add(remote(targets), home)
    #expect(outcome.applied)
    #expect(outcome.added?.places == targets)
    let header = "Bearer " + Self.headerSecret
    if targets.contains(.desktop) {
      #expect(
        try definition("added", in: .desktop, home)
          == [
            "command": "npx",
            "args": ["-y", "mcp-remote", Self.address, "--header", "Authorization: " + header],
          ])
    }
    if targets.contains(.claudeCode) {
      #expect(
        try definition("added", in: .claudeCode, home)
          == ["type": "http", "url": Self.address, "headers": ["Authorization": header]])
    }
    #expect(try load(home).row("added").entries.count == targets.count)

    #expect(try undo(outcome, home).applied)
    #expect(try originals(home) == before)
  }

  @Test func theInstalledBridgeAndSSEAreChosenByTheirFlags() throws {
    let home = try FixtureHome()
    let outcome = add(
      remote([.desktop, .claudeCode], transport: .sse, usesInstalledBridge: true), home)
    #expect(outcome.applied)
    let header = "Authorization: Bearer " + Self.headerSecret
    #expect(
      try definition("added", in: .desktop, home)
        == ["command": "mcp-remote", "args": [Self.address, "--header", header]])
    #expect(try definition("added", in: .claudeCode, home)["type"] as? String == "sse")
  }

  @Test func emptyArgumentsEnvironmentAndHeadersAreLeftOut() throws {
    let home = try FixtureHome()
    let bare = NewServer(
      name: "bare", launch: .local(command: "bare-server", arguments: [], environment: []),
      targets: [.desktop, .claudeCode])
    let plain = NewServer(
      name: "plain", launch: .remote(address: Self.address, headers: []),
      targets: [.desktop, .claudeCode])
    #expect(add(bare, home).applied)
    #expect(add(plain, home).applied)
    #expect(try definition("bare", in: .desktop, home) == ["command": "bare-server"])
    #expect(
      try definition("bare", in: .claudeCode, home) == ["type": "stdio", "command": "bare-server"])
    #expect(
      try definition("plain", in: .desktop, home)
        == ["command": "npx", "args": ["-y", "mcp-remote", Self.address]])
    #expect(
      try definition("plain", in: .claudeCode, home) == ["type": "http", "url": Self.address])
  }

  @Test func bridgeOptionsFollowTheHeadersInDesktopOnly() throws {
    let home = try FixtureHome()
    let metadata = #"{"scope":"SWB-FAKE-SECRET-added-scope"}"#
    var server = remote([.desktop, .claudeCode])
    server.bridgeOptions = ["--static-oauth-client-metadata", metadata]
    let outcome = add(server, home)
    #expect(outcome.applied)
    let header = "Bearer " + Self.headerSecret
    #expect(
      try definition("added", in: .desktop, home)
        == [
          "command": "npx",
          "args": [
            "-y", "mcp-remote", Self.address, "--header", "Authorization: " + header,
            "--static-oauth-client-metadata", metadata,
          ],
        ])
    #expect(
      try definition("added", in: .claudeCode, home)
        == ["type": "http", "url": Self.address, "headers": ["Authorization": header]])
    #expect(try undo(outcome, home).applied)

    let desktop = Additions.preview(server, for: .desktop)
    #expect(desktop.contains("\"--static-oauth-client-metadata\",\n    \"••••••\"\n  ]"))
    #expect(!desktop.contains("scope"))
    #expect(!desktop.contains(FixtureHome.secret))
    #expect(desktop.hasSuffix("}\n\n" + Additions.argumentsNote))
    let code = Additions.preview(server, for: .claudeCode)
    #expect(!code.contains("static-oauth"))
    #expect(!code.contains(Additions.argumentsNote))
  }

  @Test func theNewMemberFollowsEachFilesIndentation() throws {
    let home = try FixtureHome()
    #expect(add(local([.desktop, .claudeCode]), home).applied)
    let body = [
      "\"command\": \"npx\",", "\"args\": [", "  \"-y\",", "  \"@acme/added-server\"", "],",
      "\"env\": {", "  \"ADDED_TOKEN\": \"\(Self.envSecret)\"", "}",
    ]
    func member(_ lines: [String]) -> String {
      "\n    \"added\": {\n" + lines.map { "      " + $0 + "\n" }.joined() + "    }\n  }"
    }
    #expect(try home.text(Switches.desktopFile).contains(member(body) + "\n}"))
    #expect(
      try home.text(Switches.claudeCodeFile).contains(
        member(["\"type\": \"stdio\","] + body) + ",\n  \"projects\""))
  }

  @Test func aFileOnOneLineGetsTheMemberOnOneLine() throws {
    let home = try FixtureHome()
    let original = #"{"mcpServers":{"one":{"command":"x"}}}"#
    try home.write(original, to: Switches.desktopFile)
    let outcome = add(local([.desktop]), home)
    #expect(outcome.applied)
    #expect(
      try home.text(Switches.desktopFile)
        == #"{"mcpServers":{"one":{"command":"x"},"added":{"command":"npx","args":["-y","@acme/added-server"],"env":{"ADDED_TOKEN":"\#(Self.envSecret)"}}}}"#
    )
    #expect(try undo(outcome, home).applied)
    #expect(try home.text(Switches.desktopFile) == original)
  }

  @Test func aMissingServerListIsCreatedAndTakenOutByUndo() throws {
    let home = try FixtureHome()
    let original = "{\n  \"preferences\": {\n    \"theme\": \"dark\"\n  }\n}\n"
    try home.write(original, to: Switches.desktopFile)
    let outcome = add(
      NewServer(
        name: "added", launch: .remote(address: Self.address, headers: []), targets: [.desktop]),
      home)
    #expect(outcome.applied)
    #expect(
      try home.text(Switches.desktopFile)
        == """
        {
          "preferences": {
            "theme": "dark"
          },
          "mcpServers": {
            "added": {
              "command": "npx",
              "args": [
                "-y",
                "mcp-remote",
                "https://added.example.test/mcp"
              ]
            }
          }
        }

        """)
    #expect(try undo(outcome, home).applied)
    #expect(try home.text(Switches.desktopFile) == original)
  }

  @Test func whenTheSecondWriteFailsTheFirstIsTakenOutAgain() throws {
    let home = try FixtureHome()
    let desktop = try home.data(Switches.desktopFile)
    let outcome = Additions.add(
      local([.desktop, .claudeCode]), home: home.url, supportFolder: home.support,
      beforeWriting: { app in
        if app == .claudeCode {
          try? home.write("{ damaged", to: Switches.claudeCodeFile)
        }
      })
    #expect(!outcome.applied)
    #expect(outcome.added == nil)
    #expect(try home.data(Switches.desktopFile) == desktop)
    #expect(
      outcome.issues.map(\.message) == [
        "Not valid JSON. Nothing was changed.",
        "The server was taken out again, because the other app could not be changed.",
      ])
    #expect(outcome.issues.map(\.source) == ["~/.claude.json", "Claude Desktop"])
    #expect(outcome.backups.count == 2)
  }

  @Test func whenTheFirstCannotBeTakenOutAgainItsUndoIsKept() throws {
    let home = try FixtureHome()
    let outcome = Additions.add(
      local([.desktop, .claudeCode]), home: home.url, supportFolder: home.support,
      beforeWriting: { app in
        if app == .claudeCode {
          try? home.write("{ damaged", to: Switches.claudeCodeFile)
          try? home.write("{ damaged", to: Switches.desktopFile)
        }
      })
    #expect(!outcome.applied)
    #expect(outcome.added?.places == [.desktop])
    #expect(outcome.issues.count == 2)
  }

  @Test func undoLeavesAnEntryChangedSinceAndAcceptsOneAlreadyGone() throws {
    let home = try FixtureHome()
    let added = try #require(add(local([.desktop, .claudeCode]), home).added)
    let code = try home.text(Switches.claudeCodeFile)
    let removed = try #require(JSONText.removeMember(at: ["mcpServers", "added"], in: code))
    let changed = try #require(
      JSONText.insertMember(
        #"{"command": "other"}"#, named: "added", at: ["mcpServers"], in: removed.text))
    try home.write(changed, to: Switches.claudeCodeFile)
    let desktop = try home.text(Switches.desktopFile)
    try home.write(
      try #require(JSONText.removeMember(at: ["mcpServers", "added"], in: desktop)).text,
      to: Switches.desktopFile)

    let undone = Additions.undo(added, home: home.url, supportFolder: home.support)
    #expect(!undone.applied)
    #expect(
      undone.issues.map(\.message)
        == ["This server has changed since it was added. It was not taken out."])
    #expect(try home.text(Switches.claudeCodeFile) == changed)
  }

  @Test func anAdditionIsCheckedOnDisk() throws {
    let home = try FixtureHome()
    let added = try #require(add(local([.desktop, .claudeCode]), home).added)
    #expect(Additions.isInEffect(added, home: home.url) == true)
    let code = try home.text(Switches.claudeCodeFile)
    try home.write(
      try #require(JSONText.removeMember(at: ["mcpServers", "added"], in: code)).text,
      to: Switches.claudeCodeFile)
    #expect(Additions.isInEffect(added, home: home.url) == false)
    try home.write("{ damaged", to: Switches.claudeCodeFile)
    #expect(Additions.isInEffect(added, home: home.url) == nil)
  }

  @Test func restartNeedsAreThoseOfSwitchingTheServerOn() throws {
    let home = try FixtureHome()
    let processes = [
      RunningProcess(
        id: 10, parent: 1, footprint: 0,
        programPath: "/Applications/Claude.app/Contents/MacOS/Claude", target: nil,
        workingFolder: nil),
      RunningProcess(
        id: 20, parent: 1, footprint: 0, programPath: "/opt/homebrew/bin/claude", target: nil,
        workingFolder: "/work/alpha"),
      RunningProcess(
        id: 21, parent: 1, footprint: 0, programPath: "/opt/homebrew/bin/claude", target: nil,
        workingFolder: nil),
    ]
    let inventory = Inventory(rows: [], issues: [], projects: ["/work/alpha"], cloudHistory: [])
    func ids(_ targets: Set<Place>, _ name: String) throws -> [Int32] {
      let added = try #require(add(local(targets, name: name), home).added)
      return RestartNeeds.needs(for: added, processes: processes, inventory: inventory).map(\.id)
    }
    #expect(try ids([.desktop], "one") == [10])
    #expect(try ids([.claudeCode], "two") == [20, 21])
    #expect(try ids([.desktop, .claudeCode], "three") == [10, 20, 21])
  }

  // MARK: Refusals

  @Test func aNameTheTargetAppUsesIsRefusedWithWhatToDoInstead() throws {
    let home = try FixtureHome()
    #expect(
      Switches.apply(
        .claudeCodeServer(name: "positional", on: false), home: home.url,
        supportFolder: home.support
      ).applied)
    #expect(
      Removals.remove(
        .server(name: "browser", place: .desktop), home: home.url, supportFolder: home.support,
        claude: nil
      ).applied)
    let before = try originals(home)
    let backups = home.backups.count
    let inventory = load(home)
    let cases: [(name: String, app: Place, source: String, message: String)] = [
      (
        "notes", .claudeCode, "Claude Code",
        "Already has a server with this name. Choose another name."
      ),
      (
        "positional", .claudeCode, "Claude Code",
        "Has a switched-off server with this name. Switch it on instead."
      ),
      (
        "browser", .desktop, "Claude Desktop",
        "Has a removed server with this name. Restore it from the Removed list instead."
      ),
    ]
    for item in cases {
      let server = local([item.app], name: item.name)
      let issues = Additions.validate(server, inventory: inventory)
      #expect(issues.map(\.message) == [item.message])
      #expect(issues.map(\.source) == [item.source])
      let outcome = add(server, home)
      #expect(!outcome.applied)
      #expect(outcome.issues.map(\.message) == [item.message])
    }
    #expect(try originals(home) == before)
    #expect(home.backups.count == backups)

    #expect(Additions.validate(local([.desktop], name: "notes"), inventory: inventory).isEmpty)
    #expect(Additions.validate(local([.desktop], name: "positional"), inventory: inventory).isEmpty)
    #expect(Additions.validate(local([.claudeCode], name: "browser"), inventory: inventory).isEmpty)
    #expect(add(local([.claudeCode], name: "browser"), home).applied)
  }

  @Test func badInputIsRefusedWithoutWriting() throws {
    let home = try FixtureHome()
    let before = try originals(home)
    let inventory = load(home)
    let command = NewServer.Launch.local(command: "server", arguments: [], environment: [])
    func named(_ name: String) -> NewServer {
      NewServer(name: name, launch: command, targets: [.desktop])
    }
    func launching(_ launch: NewServer.Launch) -> NewServer {
      NewServer(name: "added", launch: launch, targets: [.desktop])
    }
    func withEnvironment(_ environment: [(name: String, value: String)]) -> NewServer {
      launching(.local(command: "server", arguments: [], environment: environment))
    }
    func reaching(_ address: String, _ headers: [(name: String, value: String)] = []) -> NewServer {
      launching(.remote(address: address, headers: headers))
    }
    let address =
      "The address must start with http:// or https://, name a host, and hold no control character."
    let cases: [(server: NewServer, message: String)] = [
      (named(" "), "The name is empty."),
      (named("a/b"), "The name cannot contain a slash."),
      (named("a\nb"), "The name cannot contain a line break or another control character."),
      (
        NewServer(name: "added", launch: command, targets: []),
        "Choose Claude Desktop, Claude Code, or both."
      ),
      (
        NewServer(name: "added", launch: command, targets: [.project(path: "/work/alpha")]),
        "A server can be added only to Claude Desktop or to Claude Code."
      ),
      (
        launching(.local(command: "  ", arguments: [], environment: [])),
        "The command is empty."
      ),
      (withEnvironment([("", "value")]), "Every environment variable needs a name."),
      (
        withEnvironment([("A=B", "value")]),
        "An environment variable name cannot contain = or a control character."
      ),
      (
        withEnvironment([("A", "1"), ("A", "2")]),
        "Each environment variable needs a different name."
      ),
      (reaching("ftp://files.example.test/mcp"), address),
      (reaching("files.example.test/mcp"), address),
      (reaching("not an address"), address),
      (reaching("https://"), address),
      (reaching("https://added.example.test/m\ncp"), address),
      (reaching("https://added.example.test/mcp\u{7}"), address),
      (
        NewServer(
          name: "added", launch: .remote(address: Self.address, headers: []), targets: [.desktop],
          bridgeOptions: ["--debug", ""]),
        "A bridge option cannot be empty or contain a line break or another control character."
      ),
      (
        NewServer(
          name: "added", launch: .remote(address: Self.address, headers: []), targets: [.desktop],
          bridgeOptions: ["--debug\n"]),
        "A bridge option cannot be empty or contain a line break or another control character."
      ),
      (
        reaching(Self.address, [("Bad Name", Self.headerSecret)]),
        "A header name can hold only letters, digits, and the characters ! # $ % & ' * + - . ^ _ ` | ~."
      ),
      (
        reaching(Self.address, [("X-Key", "1"), ("x-key", "2")]),
        "Each header needs a different name."
      ),
      (
        reaching(Self.address, [("X-Key", "a\r\nInjected: \(Self.headerSecret)")]),
        "A header value cannot contain a line break or another control character."
      ),
    ]
    for item in cases {
      #expect(
        Additions.validate(item.server, inventory: inventory).map(\.message) == [item.message])
      #expect(add(item.server, home).issues.map(\.message) == [item.message])
    }
    #expect(try originals(home) == before)
    #expect(home.backups.isEmpty)
  }

  // MARK: Copying

  @Test func onlyAServerOneAppAloneHasIsOfferedACopy() throws {
    let home = try FixtureHome()
    #expect(
      Switches.apply(
        .desktopServer(name: "tracker", on: false), home: home.url, supportFolder: home.support
      ).applied)
    let inventory = load(home)
    #expect(Additions.offeredCopy(for: try inventory.row("browser")) == .claudeCode)
    #expect(Additions.offeredCopy(for: try inventory.row("positional")) == .desktop)
    for name in ["files", "Weather", "local-db", "helper-api", "approved"] {
      #expect(Additions.offeredCopy(for: try inventory.row(name)) == nil)
    }
    let kept = try #require(
      inventory.rows.first { $0.entries.contains { $0.name == "tracker" && $0.origin == "kept" } })
    #expect(Additions.offeredCopy(for: kept) == nil)
    #expect(Additions.offeredCopy(for: try inventory.row("writing", .skill)) == nil)

    let refused = Additions.copy(
      try inventory.row("files"), to: .desktop, home: home.url, supportFolder: home.support)
    #expect(!refused.applied)
    #expect(
      refused.issues.map(\.message)
        == ["Only a server that one app alone has can be copied. Nothing was changed."])
  }

  @Test func desktopBridgesAreCopiedToClaudeCodeAsAddresses() throws {
    let home = try FixtureHome()
    let secret = Self.headerSecret
    try insert(
      #"{"command": "npx", "args": ["-y", "mcp-remote", "https://bridge.example.test/mcp", "--header", "Authorization: Bearer \#(secret)", "--header=X-Team: blue"]}"#,
      named: "bridged", in: .desktop, home)
    try insert(
      #"{"command": "/usr/local/bin/mcp-remote", "args": ["--header=Authorization:Bearer \#(secret)", "https://installed.example.test/mcp"]}"#,
      named: "installed", in: .desktop, home)
    let before = try home.data(Switches.claudeCodeFile)
    let inventory = load(home)
    let bridged = try inventory.row("bridged")
    #expect(Additions.offeredCopy(for: bridged) == .claudeCode)

    let preview = Additions.preview(
      copying: bridged, to: .claudeCode, home: home.url, inventory: inventory)
    #expect(preview.issues.isEmpty)
    #expect(
      preview.text == """
        "bridged": {
          "type": "http",
          "url": "https://bridge.example.test/mcp",
          "headers": {
            "Authorization": "••••••",
            "X-Team": "••••••"
          }
        }
        """)

    let first = try copy("bridged", to: .claudeCode, home)
    #expect(first.applied)
    #expect(
      try definition("bridged", in: .claudeCode, home)
        == [
          "type": "http", "url": "https://bridge.example.test/mcp",
          "headers": ["Authorization": "Bearer " + secret, "X-Team": "blue"],
        ])
    let second = try copy("installed", to: .claudeCode, home)
    #expect(second.applied)
    #expect(
      try definition("installed", in: .claudeCode, home)
        == [
          "type": "http", "url": "https://installed.example.test/mcp",
          "headers": ["Authorization": "Bearer " + secret],
        ])
    #expect(try load(home).row("bridged").entries.map(\.place) == [.desktop, .claudeCode])

    #expect(try undo(second, home).applied)
    #expect(try undo(first, home).applied)
    #expect(try home.data(Switches.claudeCodeFile) == before)
  }

  @Test func claudeCodeServersAreCopiedToDesktopInBothBridgeForms() throws {
    let home = try FixtureHome()
    let secret = Self.headerSecret
    try insert(
      #"{"type": "http", "url": "https://code.example.test/mcp", "headers": {"Authorization": "Bearer \#(secret)"}}"#,
      named: "code-remote", in: .claudeCode, home)
    try insert(
      #"{"type": "stdio", "command": "uvx", "args": ["acme-mcp", "--verbose"], "env": {"ACME_KEY": "\#(Self.envSecret)", "MODE": "fast"}}"#,
      named: "code-local", in: .claudeCode, home)
    let before = try home.data(Switches.desktopFile)
    let header = "Authorization: Bearer " + secret

    let bridged = try copy("code-remote", to: .desktop, home)
    #expect(bridged.applied)
    #expect(
      try definition("code-remote", in: .desktop, home)
        == [
          "command": "npx",
          "args": ["-y", "mcp-remote", "https://code.example.test/mcp", "--header", header],
        ])
    let copiedLocal = try copy("code-local", to: .desktop, home)
    #expect(copiedLocal.applied)
    #expect(
      try definition("code-local", in: .desktop, home)
        == [
          "command": "uvx", "args": ["acme-mcp", "--verbose"],
          "env": ["ACME_KEY": Self.envSecret, "MODE": "fast"],
        ])
    #expect(
      try home.text(Switches.desktopFile).contains(
        "\"ACME_KEY\": \"\(Self.envSecret)\",\n        \"MODE\""))
    #expect(try undo(copiedLocal, home).applied)
    #expect(try undo(bridged, home).applied)
    #expect(try home.data(Switches.desktopFile) == before)

    let installed = try copy("code-remote", to: .desktop, usesInstalledBridge: true, home)
    #expect(installed.applied)
    #expect(
      try definition("code-remote", in: .desktop, home)
        == [
          "command": "mcp-remote", "args": ["https://code.example.test/mcp", "--header", header],
        ])
  }

  @Test func whatTheTranslationCannotExpressIsRefused() throws {
    let home = try FixtureHome()
    let cases: [(name: String, app: Place, raw: String, message: String)] = [
      (
        "odd-flag", .desktop,
        #"{"command": "npx", "args": ["-y", "mcp-remote", "https://flag.example.test/mcp", "--allow-http"]}"#,
        "Its mcp-remote line has an argument the copy cannot carry over. Nothing was changed."
      ),
      (
        "odd-port", .desktop,
        #"{"command": "mcp-remote", "args": ["https://port.example.test/mcp", "9696"]}"#,
        "Its mcp-remote line has an argument the copy cannot carry over. Nothing was changed."
      ),
      (
        "odd-runner", .desktop,
        #"{"command": "npx", "args": ["--package", "x", "mcp-remote", "https://runner.example.test/mcp"]}"#,
        "Its mcp-remote line has an argument the copy cannot carry over. Nothing was changed."
      ),
      (
        "odd-env", .desktop,
        #"{"command": "npx", "args": ["mcp-remote", "https://env.example.test/mcp"], "env": {"AUTH": "x"}}"#,
        "Its mcp-remote line uses environment variables, which the copy cannot carry over. Nothing was changed."
      ),
      (
        "odd-setting", .claudeCode,
        #"{"type": "http", "url": "https://setting.example.test/mcp", "timeout": 30}"#,
        "Has a setting the copy cannot carry over. Nothing was changed."
      ),
      (
        "odd-type", .claudeCode, #"{"type": "ws", "url": "wss://type.example.test/mcp"}"#,
        "Has a setting the copy cannot carry over. Nothing was changed."
      ),
      (
        "odd-value", .claudeCode, #"{"command": "server", "env": {"PORT": 8080}}"#,
        "Has a value that is not text, which the copy cannot carry over. Nothing was changed."
      ),
      (
        "odd-pinned", .desktop,
        #"{"command": "npx", "args": ["-y", "mcp-remote@0.1.29", "https://pinned.example.test/mcp"]}"#,
        "Its mcp-remote line pins a version, which the copy cannot carry over. Add the server through the form instead. Nothing was changed."
      ),
      (
        "odd-twice", .claudeCode,
        #"{"type": "http", "url": "https://first.example.test/mcp", "url": "https://second.example.test/mcp"}"#,
        "Has the same setting more than once, so the copy cannot tell which one counts. Nothing was changed."
      ),
    ]
    for item in cases {
      try insert(item.raw, named: item.name, in: item.app, home)
    }
    let before = try originals(home)
    let inventory = load(home)
    for item in cases {
      let row = try inventory.row(item.name)
      let target: Place = item.app == .desktop ? .claudeCode : .desktop
      let preview = Additions.preview(
        copying: row, to: target, home: home.url, inventory: inventory)
      #expect(preview.text == nil)
      #expect(preview.issues.map(\.message) == [item.message])
      #expect(preview.issues.map(\.source) == ["~/" + file(item.app)])
      let outcome = Additions.copy(row, to: target, home: home.url, supportFolder: home.support)
      #expect(!outcome.applied)
      #expect(outcome.issues.map(\.message) == [item.message])
    }
    #expect(try originals(home) == before)
    #expect(home.backups.isEmpty)
  }

  @Test func aCopyIsRefusedWhenTheOtherAppUsesTheName() throws {
    let home = try FixtureHome()
    let before = try originals(home)
    let inventory = load(home)
    let tracker = try #require(
      inventory.rows.first {
        $0.entries.contains { $0.name == "tracker" && $0.place == .claudeCode }
      })
    let message = "Already has a server with this name. Choose another name."
    let preview = Additions.preview(
      copying: tracker, to: .desktop, home: home.url, inventory: inventory)
    #expect(preview.text != nil)
    #expect(preview.issues.map(\.message) == [message])
    let outcome = Additions.copy(tracker, to: .desktop, home: home.url, supportFolder: home.support)
    #expect(outcome.issues.map(\.message) == [message])
    #expect(try originals(home) == before)
  }

  // MARK: Previews and credentials

  @Test func thePreviewMasksValues() {
    #expect(
      Additions.preview(local([.claudeCode]), for: .claudeCode) == """
        "added": {
          "type": "stdio",
          "command": "npx",
          "args": [
            "-y",
            "@acme/added-server"
          ],
          "env": {
            "ADDED_TOKEN": "••••••"
          }
        }
        """ + "\n\n" + Additions.argumentsNote)
    #expect(
      Additions.preview(remote([.desktop]), for: .desktop) == """
        "added": {
          "command": "npx",
          "args": [
            "-y",
            "mcp-remote",
            "https://added.example.test/mcp",
            "--header",
            "Authorization: ••••••"
          ]
        }
        """)
    #expect(
      Additions.maskedAddress(
        "https://user:pw@Host.example.test:8443/mcp/?token=abc&flag&empty=#part")
        == "https://••••••@Host.example.test:8443/mcp/?token=••••••&••••••&empty=••••••#••••••")
    #expect(
      Additions.maskedAddress("https://host.example.test/mcp") == "https://host.example.test/mcp")
    #expect(Additions.maskedAddress("host.example.test/mcp?key=abc") == Additions.mask)
    #expect(
      Additions.maskedAddress("https://host.example.test/mcp/SWB-FAKE-SECRET-path/sse?x=1")
        == "https://host.example.test/mcp/••••••?x=••••••")
    #expect(
      Additions.maskedAddress("https://host.example.test/mcp/") == "https://host.example.test/mcp/")
    #expect(
      Additions.maskedAddress("postgres://reader:SWB-FAKE-SECRET-hash#x@db.example.test/main")
        == "postgres://••••••@db.example.test/main")
  }

  @Test func argumentsAreShownAsFlagNamesOnly() throws {
    let secret = "SWB-FAKE-SECRET-added-argument"
    let mask = Additions.mask
    #expect(
      Additions.maskedWords([
        "/opt/tools/server", "--api-key", secret, "-e", "TOKEN=\(secret)", "--password=\(secret)",
        "-p\(secret)", "-\(secret)", "-y", "--", "--{\(secret)}", secret,
      ]) == [
        "/opt/tools/server", "--api-key", mask, "-e", mask, "--password=" + mask, "-p" + mask,
        "-S" + mask, "-y", "--", mask, mask,
      ])
    #expect(
      Additions.maskedWords(["npx", "-y", "@acme/server@1.2.0", secret])
        == ["npx", "-y", "@acme/server@1.2.0", mask])
    #expect(
      Additions.maskedWords(["uvx", "--from", secret, "tool"]) == ["uvx", "--from", mask, mask])
    #expect(Additions.maskedWords(["API_KEY=\(secret)", "node"]) == [mask, mask])

    let typed = NewServer(
      name: "added",
      launch: .local(
        command: "node server.js --token \(secret)", arguments: ["--name=\(secret)"],
        environment: []),
      targets: [.claudeCode])
    let preview = Additions.preview(typed, for: .claudeCode)
    #expect(!preview.contains(secret))
    #expect(preview.contains("\"command\": \"node •••••• --token ••••••\""))
    #expect(preview.contains("\"--name=••••••\""))
    #expect(preview.hasSuffix("}\n\n" + Additions.argumentsNote))
    let bare = NewServer(
      name: "bare", launch: .local(command: "bare-server", arguments: [], environment: []),
      targets: [.desktop])
    #expect(!Additions.preview(bare, for: .desktop).contains(Additions.argumentsNote))
    #expect(!Additions.preview(remote([.desktop]), for: .desktop).contains(Additions.argumentsNote))
  }

  @Test func aCopyPreviewShowsNoValueOfTheBrowserServer() throws {
    let home = try FixtureHome()
    let inventory = load(home)
    let text = try #require(
      Additions.preview(
        copying: try inventory.row("browser"), to: .claudeCode, home: home.url,
        inventory: inventory
      ).text)
    #expect(
      text == """
        "browser": {
          "type": "stdio",
          "command": "/opt/tools/browser-mcp",
          "args": [
            "--wsEndpoint=••••••",
            "--wsHeaders=••••••",
            "--extraHeader=••••••"
          ]
        }
        """ + "\n\n" + Additions.argumentsNote)
    for part in [
      FixtureHome.secret, "wss:", "agent", "browser.example.test", "run?", "Authorization",
      "Bearer", "X-Session",
    ] {
      #expect(!text.contains(part))
    }
  }

  @Test func noCopyPreviewOfAFixtureServerShowsACredential() throws {
    let home = try FixtureHome()
    let inventory = load(home)
    var previews: [String] = []
    for row in inventory.rows {
      guard let app = Additions.offeredCopy(for: row) else { continue }
      let preview = Additions.preview(copying: row, to: app, home: home.url, inventory: inventory)
      previews += [preview.text ?? ""] + preview.issues.map(\.message)
    }
    #expect(previews.count > 20)
    #expect(!previews.contains { $0.contains(FixtureHome.secret) })
  }

  @Test func thePreviewMatchesWhatIsWritten() throws {
    let home = try FixtureHome()
    for server in [local([.desktop, .claudeCode]), remote([.desktop, .claudeCode])] {
      let secret: String
      if case .local = server.launch {
        secret = Self.envSecret
      } else {
        secret = "Bearer " + Self.headerSecret
      }
      let outcome = add(server, home)
      #expect(outcome.applied)
      for app in Self.apps {
        let shown = Additions.preview(server, for: app)
          .replacingOccurrences(of: "\n\n" + Additions.argumentsNote, with: "")
          .replacingOccurrences(of: Additions.mask, with: secret)
        let parsed = try #require(
          try JSONSerialization.jsonObject(with: Data(("{" + shown + "}").utf8)) as? NSDictionary)
        #expect(try definition("added", in: app, home) == parsed["added"] as? NSDictionary)
      }
      #expect(try undo(outcome, home).applied)
    }
  }

  @Test func noAddedCredentialIsReachable() throws {
    let home = try FixtureHome()
    let query = "SWB-FAKE-SECRET-added-query"
    let argument = "SWB-FAKE-SECRET-added-argument"
    let localServer = NewServer(
      name: "added-local",
      launch: .local(
        command: "server", arguments: ["--api-key", argument, "TOKEN=\(argument)"],
        environment: [("ADDED_TOKEN", Self.envSecret)]),
      targets: [.desktop, .claudeCode])
    let remoteServer = NewServer(
      name: "added-remote",
      launch: .remote(
        address: "https://reader:\(query)@remote.example.test/mcp/\(query)/sse?key=\(query)",
        headers: [("Authorization", "Bearer " + Self.headerSecret)]),
      targets: [.desktop, .claudeCode])
    try insert(
      #"{"type": "http", "url": "https://code.example.test/mcp?key=\#(query)", "headers": {"X-Key": "\#(Self.headerSecret)"}}"#,
      named: "code-remote", in: .claudeCode, home)
    let before = load(home)

    let added = [add(localServer, home), add(remoteServer, home)]
    let row = try load(home).row("code-remote")
    let copyPreview = Additions.preview(
      copying: row, to: .desktop, home: home.url, inventory: before)
    let copied = Additions.copy(row, to: .desktop, home: home.url, supportFolder: home.support)
    let clash = add(localServer, home)
    let refused = add(
      NewServer(
        name: "bad\n\(Self.envSecret)",
        launch: .remote(
          address: "ftp://\(query)@x.example.test", headers: [("Bad \(Self.headerSecret)", query)]),
        targets: [.desktop]), home)
    let validation = Additions.validate(localServer, inventory: load(home))
    let previews = Self.apps.flatMap {
      [Additions.preview(localServer, for: $0), Additions.preview(remoteServer, for: $0)]
    }
    for app in Self.apps {
      let text = try home.text(file(app))
      for secret in [Self.envSecret, Self.headerSecret, query, argument] {
        #expect(text.contains(secret))
      }
    }
    #expect(added.allSatisfy { $0.applied })
    #expect(copied.applied)
    #expect(!clash.applied)
    #expect(!refused.applied)
    let after = load(home)
    let undone = try (added + [copied]).map { try undo($0, home) }
    #expect(undone.allSatisfy { $0.applied })

    let reachable: [Any] = [
      before, after, added, copyPreview.text ?? "", copyPreview.issues, copied, clash, refused,
      validation, previews, undone,
    ]
    let strings = reachable.flatMap { reachableStrings(in: $0) }
    #expect(!strings.isEmpty)
    #expect(!strings.contains { $0.contains(FixtureHome.secret) })
  }

  /// Leading whitespace in a header value has no meaning in HTTP, so the copy drops it, and a
  /// round trip through Claude Code changes the text of the bridge line.
  @Test func aCopiedHeaderValueLosesItsLeadingSpaces() throws {
    let home = try FixtureHome()
    try insert(
      #"{"command": "npx", "args": ["-y", "mcp-remote", "https://spaced.example.test/mcp", "--header", "X-Key: \t  spaced value "]}"#,
      named: "spaced", in: .desktop, home)
    #expect(try copy("spaced", to: .claudeCode, home).applied)
    #expect(
      try definition("spaced", in: .claudeCode, home)["headers"] as? [String: String]
        == ["X-Key": "spaced value "])
  }

  // MARK: Command lines

  @Test func aCommandLineIsSplitByWhitespaceAndQuotes() {
    #expect(
      Additions.splitCommandLine("npx -y @acme/server  /srv/share")
        == ["npx", "-y", "@acme/server", "/srv/share"])
    #expect(
      Additions.splitCommandLine(#"node "my server.js" --name='a b' "#)
        == ["node", "my server.js", "--name=a b"])
    #expect(
      Additions.splitCommandLine(#"say "a \"quoted\" word" "back\\slash" "keep\n""#)
        == ["say", "a \"quoted\" word", "back\\slash", "keep\\n"])
    #expect(
      Additions.splitCommandLine(#"path\ with 'single \' x"#) == [
        "path\\", "with", "single \\", "x",
      ])
    #expect(Additions.splitCommandLine("a '' \"\" b") == ["a", "", "", "b"])
    #expect(Additions.splitCommandLine(" \t\n") == [])
    #expect(Additions.splitCommandLine("node 'unclosed") == nil)
    #expect(Additions.splitCommandLine(#"node "unclosed \""#) == nil)
  }
}
