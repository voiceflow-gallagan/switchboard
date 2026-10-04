import Darwin
import Foundation
import SwitchboardCore

/// The folders Switchboard reads and writes, decided once at launch.
///
/// In a debug build, the environment variable `SWITCHBOARD_HOME` can name a test home inside
/// the system temporary folder. That folder then replaces the home folder for everything
/// Switchboard reads and writes, and Switchboard's own files go inside it. Only the list of
/// running processes and the disk sizes still come from this Mac, unless `SWITCHBOARD_DEMO` is
/// set too, which replaces them with invented figures for screenshots. Any other value is
/// ignored.
struct AppPaths: Sendable {
  /// Whether switches and backups are offered against the real home folder. Turned on after two
  /// independent reviews of the write path on 2026-10-02. Set it to false to make the app
  /// read-only again. A test home always offers them.
  static let offersSwitchesOnRealHome = true

  static let testHomeVariable = "SWITCHBOARD_HOME"
  /// In a debug build with a test home, names the program to run in place of Claude Code.
  static let testClaudeVariable = "SWITCHBOARD_CLAUDE"
  /// In a debug build with a test home, shows invented memory and disk figures.
  static let demoVariable = "SWITCHBOARD_DEMO"
  static let current = resolve(environment: ProcessInfo.processInfo.environment)

  let home: URL
  /// Saved measurements, backups, and kept servers. Nil when macOS names no such folder.
  let supportFolder: URL?
  let isTestHome: Bool
  /// Memory and disk figures are invented. Only ever true with a test home in a debug build.
  let isDemo: Bool
  /// Claude Code's program, run to uninstall and reinstall plugins. Nil when not found. A test
  /// home never uses the real one.
  let claudeProgram: URL?
  /// Why Claude Code's program cannot be run, when it cannot.
  let claudeProblem: String?

  var offersSwitches: Bool {
    supportFolder != nil && (isTestHome || Self.offersSwitchesOnRealHome)
  }

  static func resolve(environment: [String: String]) -> AppPaths {
    if let home = testHome(environment: environment) {
      let program = testClaude(environment: environment)
      return AppPaths(
        home: home,
        supportFolder: home.appending(path: "Library/Application Support/Switchboard"),
        isTestHome: true,
        isDemo: isDemo(environment: environment),
        claudeProgram: program,
        claudeProblem: program == nil
          ? ClaudeCommand.problem(home: home, searchPath: "")?.message : nil)
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    return AppPaths(
      home: home,
      supportFolder: FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      )
      .first?.appending(path: "Switchboard"),
      isTestHome: false,
      isDemo: false,
      claudeProgram: ClaudeCommand.locate(home: home),
      claudeProblem: ClaudeCommand.problem(home: home)?.message)
  }

  private static func isDemo(environment: [String: String]) -> Bool {
    #if DEBUG
      environment[demoVariable] != nil
    #else
      false
    #endif
  }

  /// The fake program named by the environment. The library still refuses it unless it is a file
  /// the user owns inside the test home.
  private static func testClaude(environment: [String: String]) -> URL? {
    #if DEBUG
      environment[testClaudeVariable].flatMap(Paths.realPath).map { URL(filePath: $0) }
    #else
      nil
    #endif
  }

  /// The test home named by the environment, or nil unless this is a debug build and the folder,
  /// with every symbolic link and `..` resolved, lies inside the system temporary folder.
  private static func testHome(environment: [String: String]) -> URL? {
    #if DEBUG
      guard let value = environment[testHomeVariable], let path = Paths.realPath(value) else {
        return nil
      }
      let roots = [systemTemporaryFolder(), "/private/tmp"].compactMap {
        $0.flatMap(Paths.realPath)
      }
      guard roots.contains(where: { path.hasPrefix($0 + "/") }) else { return nil }
      return URL(filePath: path, directoryHint: .isDirectory)
    #else
      return nil
    #endif
  }

  /// The per-user temporary folder from the system, not from the `TMPDIR` variable, which the
  /// launching process controls.
  private static func systemTemporaryFolder() -> String? {
    let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
    guard length > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: length)
    guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) > 0 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
}
