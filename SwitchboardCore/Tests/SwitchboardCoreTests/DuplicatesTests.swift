import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct DuplicatesTests {
  private func launch(_ json: String) throws -> Launch {
    Duplicates.launch(of: try JSONDecoder().decode(ServerConfig.self, from: Data(json.utf8)))
  }

  private func target(_ json: String) throws -> Target {
    try #require(try launch(json).target)
  }

  private func server(_ name: String, _ place: Place, _ target: Target) -> Entry {
    Entry(
      name: name, kind: .server, place: place, origin: "test", state: .on, target: target,
      typeLabel: "local")
  }

  private func local(_ identity: String) -> Target {
    Target(mode: .local, label: identity, identity: [identity])
  }

  @Test func addressBecomesRemoteTargetLabelledByHostAndPort() throws {
    let result = try launch(
      #"{"type": "http", "url": "HTTPS://API.Example.test:8443/v1/?x=1#part"}"#)
    let plain = try target(#"{"url": "https://api.example.test:8443/v1"}"#)
    #expect(result.target?.mode == .remote)
    #expect(result.target?.label == "api.example.test:8443")
    #expect(result.target == plain)
    #expect(result.typeLabel == "http")
  }

  @Test func addressPathTakesPartInIdentity() throws {
    let first = try target(#"{"url": "https://hub.test/mcp/one"}"#)
    let second = try target(#"{"url": "https://hub.test/mcp/two"}"#)
    #expect(first != second)
    #expect(first.label == second.label)
  }

  @Test func credentialsInAddressNeverChangeIdentity() throws {
    let plain = try target(#"{"url": "postgres://db.test/main"}"#)
    let withHash = try target(#"{"url": "postgres://user:pa#rt?x@db.test/main"}"#)
    #expect(withHash == plain)
    #expect(withHash.label == "db.test")
  }

  @Test func addressWithoutSchemeIsParsedOrDigested() throws {
    #expect(try target(#"{"url": "host.test:5432/db?password=v"}"#).label == "host.test:5432")
    #expect(try target(#"{"url": "user:pw@host.test/db"}"#).label == "host.test")
    let unreadable = try target(#"{"url": "user:p/w@host.test/db"}"#)
    #expect(unreadable.label == "remote")
    #expect(unreadable.mode == .remote)
  }

  @Test func mcpRemoteBecomesRemoteTargetOfFirstAddress() throws {
    let asCommand = try target(
      #"{"command": "/usr/local/bin/mcp-remote", "args": ["https://a.test/mcp"]}"#)
    let throughNpx = try launch(
      #"{"command": "npx", "args": ["-y", "mcp-remote@0.1", "https://A.test/mcp/", "--header", "X-Key: v"]}"#
    )
    let direct = try target(#"{"type": "http", "url": "https://a.test/mcp"}"#)
    #expect(throughNpx.target == asCommand)
    #expect(direct == asCommand)
    #expect(throughNpx.typeLabel == "mcp-remote")
    #expect(throughNpx.secretNames == ["X-Key"])
  }

  @Test func npxBecomesPackageWithoutRunnerFlagsOrVersion() throws {
    let pinned = try launch(
      #"{"command": "/opt/homebrew/bin/npx", "args": ["-y", "@scope/pkg@1.2.3", "--port", "3000"]}"#
    )
    let latest = try target(#"{"command": "npx", "args": ["@scope/pkg@latest", "--port", "3000"]}"#)
    let otherPort = try target(#"{"command": "npx", "args": ["@scope/pkg", "--port", "4000"]}"#)
    #expect(pinned.target?.label == "npx @scope/pkg")
    #expect(latest == pinned.target)
    #expect(otherPort != latest)
    #expect(pinned.typeLabel == "npx")
  }

  @Test func otherCommandBecomesProgramNameWithEveryArgumentHashed() throws {
    let result = try launch(#"{"command": "/usr/bin/python3", "args": ["server.py", "--verbose"]}"#)
    let other = try target(#"{"command": "python3", "args": ["server.py", "--quiet"]}"#)
    #expect(result.target?.label == "python3")
    #expect(result.target != other)
    #expect(result.typeLabel == "local")
  }

  @Test func serverWithoutAddressOrCommandHasNoTarget() throws {
    #expect(try launch(#"{"type": "stdio"}"#).target == nil)
  }

  @Test func secretNamesComeFromHeaderAndEnvironmentFlags() throws {
    let result = try launch(
      #"{"command": "x", "args": ["-H", "X-Api-Key: v", "--header=Authorization: Basic v", "-e", "NAME=v", "--header", "v"], "env": {"TOKEN": "v"}}"#
    )
    #expect(result.secretNames == ["Authorization", "NAME", "TOKEN", "X-Api-Key"])
  }

  @Test func sameTargetInBothAppsIsOneDuplicateRow() {
    let target = Target(mode: .remote, label: "a.test", identity: ["a.test/mcp"])
    let rows = Duplicates.rows(from: [
      server("a", .desktop, target), server("b", .claudeCode, target),
    ])
    #expect(rows.count == 1)
    #expect(rows[0].isDuplicate)
    #expect(rows[0].name == "a")
  }

  @Test func userAndProjectServerWithSameTargetIsDuplicate() {
    let rows = Duplicates.rows(from: [
      server("tool", .claudeCode, local("tool")),
      server("tool", .project(path: "/p"), local("tool")),
    ])
    #expect(rows.count == 1)
    #expect(rows[0].isDuplicate)
  }

  @Test func sameServerInUnrelatedProjectsIsNotDuplicate() {
    let rows = Duplicates.rows(from: [
      server("tool", .project(path: "/a"), local("tool")),
      server("tool", .project(path: "/b"), local("tool")),
    ])
    #expect(rows.count == 1)
    #expect(!rows[0].isDuplicate)
  }

  @Test func sameNameWithDifferentTargetIsConflictNotDuplicate() {
    let rows = Duplicates.rows(from: [
      server("github", .desktop, local("mcp-server-github")),
      server("github", .claudeCode, Target(mode: .remote, label: "h", identity: ["h/mcp"])),
    ])
    #expect(rows.count == 2)
    #expect(rows.allSatisfy { $0.hasNameConflict && !$0.isDuplicate })
  }

  @Test func sameNameInTwoProjectsIsNotConflict() {
    let rows = Duplicates.rows(from: [
      server("db", .project(path: "/a"), local("db-a")),
      server("db", .project(path: "/b"), local("db-b")),
    ])
    #expect(rows.count == 2)
    #expect(rows.allSatisfy { !$0.hasNameConflict })
  }

  @Test func spacedCommandLabelUsesOnlyAProgramName() throws {
    #expect(
      try target(#"{"command": "node server.js https://host.test/TOKEN123"}"#).label == "node")
    #expect(try target(#"{"command": "env TOKEN=ab/SECRETB node"}"#).label == "env")
    #expect(try target(#"{"command": "API_KEY=SECRETA node"}"#).label == "local")
    #expect(try target(#"{"command": "/opt/user:pass@host"}"#).label == "local")
  }

  @Test func realProgramPathWithSpaceKeepsItsFileName() throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "switchboard-\(UUID().uuidString)/Application Support/acme-ls")
    defer {
      try? FileManager.default.removeItem(
        at: folder.deletingLastPathComponent().deletingLastPathComponent())
    }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let program = folder.appending(path: "acme-mcp")
    try Data().write(to: program)
    let files = SourceFiles(home: folder)
    let config = ServerConfig(command: program.path, args: ["mcp"])
    let configured = Duplicates.launch(of: config, isProgramFile: files.isProgramFile)
    #expect(configured.target?.label == "acme-mcp")
    #expect(configured.target == Duplicates.target(launchArguments: [program.path, "mcp"]))
    #expect(Duplicates.launch(of: config).target?.label == "Application")
  }

  @Test func packageRunnerSkipsOnlyFlagsWithoutValue() throws {
    #expect(
      try target(#"{"command": "npx", "args": ["-y", "--quiet", "pkg@1"]}"#).label == "npx pkg")
    let withValue = try target(#"{"command": "npx", "args": ["-y", "--token", "VALUE", "pkg"]}"#)
    #expect(withValue.label == "npx")
    let process = try #require(
      Duplicates.target(launchArguments: ["uvx", "--from", "VALUE", "tool"]))
    #expect(process.label == "uvx")
    #expect(process != (try target(#"{"command": "uvx", "args": ["--from", "OTHER", "tool"]}"#)))
  }
}
