import Darwin
import Foundation
import Testing

@testable import SwitchboardCore

/// A fake Claude Code program in a temporary home folder, placed where Claude Code keeps its
/// own versions, with `~/.local/bin/claude` linking to it. It records its arguments and
/// environment, then runs `body`. The real program is never run.
private final class FakeClaude {
  let home: URL
  let program: URL
  let link: URL

  static let ok =
    "{\"command\":\"x\",\"outcome\":\"ok\",\"plugin\":\"helper@market\",\"scope\":\"user\"}"
  static let failed =
    "{\"command\":\"x\",\"outcome\":\"failed\",\"plugin\":\"helper@market\",\"scope\":\"user\"}"

  init(output: String = FakeClaude.ok, code: Int32 = 0, body: String? = nil) throws {
    home = FileManager.default.temporaryDirectory.appending(
      path: "switchboard-claude-\(UUID().uuidString)")
    program = home.appending(path: ClaudeCommand.versionsFolder + "/9.9.9")
    link = home.appending(path: ".local/bin/claude")
    for folder in [program.deletingLastPathComponent(), link.deletingLastPathComponent()] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    try FakeClaude.write(
      """
      #!/bin/sh
      printf '%s\\n' "$@" > "$HOME/arguments"
      env > "$HOME/environment"
      \(body ?? "printf '%s' '\(output)'\nexit \(code)")
      """, to: program)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: program)
  }

  deinit {
    try? FileManager.default.removeItem(at: home)
  }

  static func write(_ script: String, to url: URL) throws {
    try Data(script.utf8).write(to: url)
    #expect(chmod(url.path, 0o700) == 0)
  }

  func recorded(_ name: String) -> String? {
    try? String(contentsOf: home.appending(path: name), encoding: .utf8)
  }

  func uninstall(
    _ id: String = "helper@market", timeLimit: TimeInterval = 10, program: URL? = nil,
    environment: [String: String] = ["PATH": "/usr/bin:/bin"]
  ) -> ClaudeCommand.Result {
    ClaudeCommand.uninstall(
      pluginID: id, program: program ?? link, home: home, environment: environment,
      timeLimit: timeLimit)
  }
}

@Suite struct ClaudeCommandTests {
  private static let unreadable =
    "Claude Code finished, but its answer could not be read. Check the plugin list."
  private static let notFound =
    "Claude Code's program was not found in its standard location. Nothing was run."

  @Test func aSuccessfulUninstallPassesTheFixedArguments() throws {
    let fake = try FakeClaude()
    let result = fake.uninstall()
    #expect(result.issues.isEmpty)
    #expect(!result.isUnconfirmed)
    #expect(fake.recorded("arguments") == "plugin\nuninstall\n--json\n--\nhelper@market\n")
  }

  @Test func installPassesTheFixedArgumentsAndReadsTheAnswer() throws {
    let fake = try FakeClaude()
    let result = ClaudeCommand.install(
      pluginID: "helper@market", program: fake.link, home: fake.home,
      environment: ["PATH": "/usr/bin:/bin"])
    #expect(result.issues.isEmpty)
    #expect(fake.recorded("arguments") == "plugin\ninstall\n--json\n--\nhelper@market\n")
  }

  @Test func aNonZeroExitIsAnIssueWithItsCodeOnly() throws {
    let fake = try FakeClaude(output: "{\"error\":\"SWB-FAKE-SECRET-output\"}", code: 3)
    let result = fake.uninstall()
    #expect(
      result.issues.map(\.message) == ["Claude Code could not uninstall the plugin. Exit code 3."])
    #expect(!reachableStrings(in: result.issues).contains { $0.contains("SWB-FAKE-SECRET") })
  }

  @Test(arguments: [
    "SWB-FAKE-SECRET-garbage", "\(FakeClaude.ok)\\n\(FakeClaude.ok)", "", "{}",
    "{\"outcome\":\"yes\"}", "{\"outcome\":true}", "{\"success\":true}",
    "[\"SWB-FAKE-SECRET\"]",
  ])
  func anAnswerWithoutOutcomeOkOrFailedIsUnconfirmed(output: String) throws {
    let fake = try FakeClaude(output: output)
    let result = fake.uninstall()
    #expect(result.isUnconfirmed)
    #expect(result.issues.map(\.message) == [Self.unreadable])
    #expect(!reachableStrings(in: result.issues).contains { $0.contains("SWB-FAKE-SECRET") })
  }

  @Test func theOldSuccessShapeIsUnreadable() throws {
    let fake = try FakeClaude(output: "{\"success\":true}")
    let result = fake.uninstall()
    #expect(result.isUnconfirmed)
    #expect(result.issues.map(\.message) == [Self.unreadable])
  }

  @Test func aFailedAnswerWithNotInstalledHasFixedWordingAndNoAnswerText() throws {
    let output =
      "{\"command\":\"uninstall\",\"outcome\":\"failed\",\"message\":\"SWB-FAKE-SECRET\",\"failureCode\":\"not_installed\"}"
    let fake = try FakeClaude(output: output, code: 1)
    let result = fake.uninstall()
    #expect(!result.isUnconfirmed)
    #expect(
      result.issues.map(\.message) == ["Claude Code reported that the plugin is not installed."])
    #expect(!reachableStrings(in: result.issues).contains { $0.contains("SWB-FAKE-SECRET") })
  }

  @Test func aFailedInstallIsAnIssueAndAnUnreadableOneIsUnconfirmed() throws {
    let failed = try FakeClaude(output: FakeClaude.failed, code: 1)
    let failedResult = ClaudeCommand.install(
      pluginID: "helper@market", program: failed.link, home: failed.home,
      environment: ["PATH": "/usr/bin:/bin"])
    #expect(!failedResult.isUnconfirmed)
    #expect(
      failedResult.issues.map(\.message) == [
        "Claude Code could not install the plugin. Exit code 1."
      ])

    let unreadable = try FakeClaude(output: "Done")
    let unreadableResult = ClaudeCommand.install(
      pluginID: "helper@market", program: unreadable.link, home: unreadable.home,
      environment: ["PATH": "/usr/bin:/bin"])
    #expect(unreadableResult.isUnconfirmed)
  }

  @Test func anAnswerThatReportsFailureIsAnIssue() throws {
    let fake = try FakeClaude(output: FakeClaude.failed)
    let result = fake.uninstall()
    #expect(!result.isUnconfirmed)
    #expect(
      result.issues.map(\.message) == ["Claude Code reported that the plugin was not uninstalled."])
  }

  @Test(arguments: ["-rf@x", "helper", "a b@c", "helper@market;x", "@market", "x@", "../x@y"])
  func anInvalidIdentifierRunsNothing(id: String) throws {
    let fake = try FakeClaude()
    #expect(
      fake.uninstall(id).issues.map(\.message)
        == ["Not a valid plugin identifier. Nothing was run."])
    #expect(fake.recorded("arguments") == nil)
  }

  /// The script records both process identifiers before it blocks, and the limit is generous,
  /// so a slow start under parallel load cannot fire the limit before they exist. Both
  /// processes are killed at the end whatever happens.
  @Test func aHangingProgramAndItsChildrenAreStopped() throws {
    let fake = try FakeClaude(
      body: """
        echo $$ > "$HOME/main.tmp" && mv "$HOME/main.tmp" "$HOME/main"
        sleep 120 &
        echo $! > "$HOME/child.tmp" && mv "$HOME/child.tmp" "$HOME/child"
        exec sleep 120
        """)
    func id(_ name: String) -> pid_t? {
      fake.recorded(name).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    defer {
      for name in ["main", "child"] {
        if let id = id(name) { kill(id, SIGKILL) }
      }
    }

    let result = fake.uninstall(timeLimit: 5)
    #expect(
      result.issues.map(\.message) == [
        "Claude Code did not finish within 5 seconds and was stopped."
      ])
    for name in ["main", "child"] {
      let process = try #require(id(name), "\(name) never started")
      let deadline = Date(timeIntervalSinceNow: 20)
      while kill(process, 0) == 0, Date() < deadline {
        usleep(50_000)
      }
      #expect(kill(process, 0) != 0, "\(name) still runs")
    }
  }

  @Test func aChildHoldingTheOutputOpenDoesNotHideTheAnswer() throws {
    let fake = try FakeClaude(
      body: """
        printf '%s\\n' '\(FakeClaude.ok)'
        sleep 30 &
        echo $! > "$HOME/child"
        exit 0
        """)
    let start = Date()
    let result = fake.uninstall(timeLimit: 20)
    #expect(result.issues.isEmpty)
    #expect(Date().timeIntervalSince(start) < 15)
    if let child = fake.recorded("child").flatMap({
      pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines))
    }) {
      kill(child, SIGKILL)
    }
  }

  @Test func outputLargerThanThePipeBufferIsReadToTheEnd() throws {
    let fake = try FakeClaude(
      body: """
        head -c 300000 /dev/zero | tr '\\0' ' '
        printf '\\n%s\\n' '\(FakeClaude.ok)'
        """)
    #expect(fake.uninstall().issues.isEmpty)
  }

  @Test func outputOverTheLimitIsNeverRead() throws {
    let fake = try FakeClaude(
      body: """
        head -c \(ClaudeCommand.outputLimit + 10) /dev/zero | tr '\\0' ' '
        printf '\\n%s\\n' '\(FakeClaude.ok)'
        """)
    let result = fake.uninstall()
    #expect(result.isUnconfirmed)
    #expect(result.issues.map(\.message) == [Self.unreadable])
  }

  @Test func aProgramThatIsNotExecutableOrWritableByOthersIsRefused() throws {
    for mode: mode_t in [0o600, 0o722] {
      let fake = try FakeClaude()
      #expect(chmod(fake.program.path, mode) == 0)
      #expect(fake.uninstall().issues.map(\.message) == [Self.notFound])
      #expect(fake.recorded("arguments") == nil)
    }
  }

  @Test func onlyAProgramInClaudeCodesVersionsFolderRuns() throws {
    let fake = try FakeClaude()
    let elsewhere = fake.home.appending(path: "bin/claude")
    try FileManager.default.createDirectory(
      at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FakeClaude.write("#!/bin/sh\nexit 0", to: elsewhere)
    #expect(fake.uninstall(program: elsewhere).issues.map(\.message) == [Self.notFound])

    let other = try FakeClaude()
    let leaving = fake.home.appending(path: "bin/leaving")
    try FileManager.default.createSymbolicLink(at: leaving, withDestinationURL: other.program)
    #expect(fake.uninstall(program: leaving).issues.map(\.message) == [Self.notFound])
    #expect(other.recorded("arguments") == nil)
    #expect(fake.uninstall(program: fake.program).issues.isEmpty)
  }

  @Test func theEnvironmentHoldsOnlyPathHomeAndThePassedThroughVariables() throws {
    let inherited = [
      "PATH": "/usr/bin:/bin", "SSH_AUTH_SOCK": "/tmp/agent", "https_proxy": "http://proxy:1",
      "TMPDIR": "/tmp/", "USER": "someone", "AWS_SECRET_ACCESS_KEY": "SWB-FAKE-SECRET",
      "DYLD_INSERT_LIBRARIES": "/x", "HOME": "/elsewhere",
    ]
    let home = URL(fileURLWithPath: "/h")
    #expect(
      ClaudeCommand.environment(home: home, inherited: inherited)
        == [
          "PATH": "/usr/bin:/bin", "HOME": "/h", "SSH_AUTH_SOCK": "/tmp/agent",
          "https_proxy": "http://proxy:1", "TMPDIR": "/tmp/",
        ])

    let fake = try FakeClaude()
    #expect(fake.uninstall(environment: inherited).issues.isEmpty)
    let names = Set(
      (fake.recorded("environment") ?? "").split(separator: "\n").map {
        String($0.prefix { $0 != "=" })
      })
    #expect(names.contains("SSH_AUTH_SOCK"))
    #expect(
      names.isSubset(of: ClaudeCommand.passedThrough.union(["PATH", "HOME", "PWD", "SHLVL", "_"])))
  }

  @Test func theProgramIsFoundOnlyInItsStandardLocation() throws {
    let fake = try FakeClaude()
    let onPath = fake.home.appending(path: "tools")
    try FileManager.default.createDirectory(at: onPath, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: onPath.appending(path: "claude"), withDestinationURL: fake.program)
    #expect(
      ClaudeCommand.locate(home: fake.home, searchPath: "/nowhere:\(onPath.path)")
        == onPath.appending(path: "claude"))
    #expect(ClaudeCommand.locate(home: fake.home, searchPath: "tools:/nowhere") == fake.link)

    try FileManager.default.removeItem(at: fake.link)
    #expect(ClaudeCommand.locate(home: fake.home, searchPath: "tools") == nil)
    let packaged = fake.home.appending(path: "packaged")
    try FileManager.default.createDirectory(at: packaged, withIntermediateDirectories: true)
    try FakeClaude.write("#!/bin/sh\nexit 0", to: packaged.appending(path: "claude"))
    #expect(ClaudeCommand.locate(home: fake.home, searchPath: packaged.path) == nil)
  }

  @Test func removingAndReinstallingAPluginUseTheProgram() async throws {
    let fake = try FakeClaude()
    let removed = await Removals.remove(
      .plugin(id: "helper@market"), home: fake.home, supportFolder: fake.home, claude: fake.link)
    #expect(removed.applied)
    #expect(removed.undo == .reinstall(pluginID: "helper@market"))
    let reinstalled = await Removals.undo(
      .reinstall(pluginID: "helper@market"), home: fake.home, supportFolder: fake.home,
      claude: fake.link)
    #expect(reinstalled.applied)
    #expect(fake.recorded("arguments") == "plugin\ninstall\n--json\n--\nhelper@market\n")
    let withoutProgram = await Removals.remove(
      .plugin(id: "helper@market"), home: fake.home, supportFolder: fake.home, claude: nil)
    #expect(!withoutProgram.applied)
  }

  @Test func anUnreadableUninstallIsUnconfirmedAndOffersNoReinstall() async throws {
    let fake = try FakeClaude(output: "{}")
    let removed = await Removals.remove(
      .plugin(id: "helper@market"), home: fake.home, supportFolder: fake.home, claude: fake.link)
    #expect(!removed.applied)
    #expect(removed.isUnconfirmed)
    #expect(removed.undo == nil)
  }

  @Test func aProblemExplainsWhyTheProgramIsNotFound() throws {
    let fake = try FakeClaude()
    #expect(ClaudeCommand.problem(home: fake.home, searchPath: nil) == nil)

    try FileManager.default.removeItem(at: fake.link)
    #expect(
      ClaudeCommand.problem(home: fake.home, searchPath: nil)?.message
        == "The Claude Code program was not found. Nothing was changed.")

    try FakeClaude.write("#!/bin/sh\nexit 0", to: fake.link)
    #expect(ClaudeCommand.problem(home: fake.home, searchPath: nil)?.message == Self.notFound)
  }
}
