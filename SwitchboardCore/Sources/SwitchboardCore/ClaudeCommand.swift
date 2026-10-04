import Darwin
import Foundation

/// Runs Claude Code's own plugin commands, and nothing else.
///
/// The program must resolve to a regular executable file that the current user owns, that no one
/// else can write, and that lies in Claude Code's own versions folder,
/// `~/.local/share/claude/versions/`. A `claude` installed any other way, for example by a package
/// manager, is not run. The arguments are fixed. The environment holds `PATH`, `HOME`, and only
/// those of `passedThrough` that are set. Standard input is closed and a time limit applies.
/// Only exit codes and the single JSON line of `plugin uninstall --json` and `plugin install --json` are read. Raw output
/// never leaves this type: it is in no value, issue, or log.
///
/// Running a command blocks the calling thread for up to `timeLimit`. Call it from a dispatch
/// queue, never from Swift's cooperative thread pool. `Removals` offers async versions that do so.
public enum ClaudeCommand: Sendable {
  public static let timeLimit: TimeInterval = 90
  static let outputLimit = 1_048_576
  /// How long to wait for the end of the output after the program exits, since a child it
  /// started may hold the pipe open.
  static let grace: TimeInterval = 2
  static let source = "Claude Code"
  static let versionsFolder = ".local/share/claude/versions"
  /// Variables passed on when set: SSH agent, temporary folder, and proxies, which a reinstall
  /// from a private marketplace may need.
  static let passedThrough: Set<String> = [
    "SSH_AUTH_SOCK", "TMPDIR", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY",
    "http_proxy", "https_proxy", "no_proxy", "all_proxy",
  ]

  /// The Claude Code program: `claude` in the first absolute folder of `searchPath` whose
  /// `claude` resolves into Claude Code's versions folder, otherwise `~/.local/bin/claude` when
  /// it does. Nil when none is found.
  public static func locate(
    home: URL, searchPath: String? = ProcessInfo.processInfo.environment["PATH"]
  ) -> URL? {
    let folders = (searchPath ?? "").split(separator: ":").map(String.init)
      .filter { $0.hasPrefix("/") }
      .map { URL(fileURLWithPath: $0) }
    let candidates =
      folders.map { $0.appending(path: "claude") } + [home.appending(path: ".local/bin/claude")]
    return candidates.first { verified($0, home: home) != nil }
  }

  /// Nil when `locate` finds the program, otherwise why it does not, in the wording a failed
  /// command uses.
  public static func problem(
    home: URL, searchPath: String? = ProcessInfo.processInfo.environment["PATH"]
  ) -> SourceIssue? {
    guard locate(home: home, searchPath: searchPath) == nil else { return nil }
    let folders = (searchPath ?? "").split(separator: ":").map(String.init)
      .filter { $0.hasPrefix("/") }
    let candidates =
      folders.map { URL(fileURLWithPath: $0).appending(path: "claude").path }
      + [home.appending(path: ".local/bin/claude").path]
    let exists = candidates.contains { FileManager.default.fileExists(atPath: $0) }
    return exists ? issues(for: .refused)[0] : notFound
  }

  static var notFound: SourceIssue {
    issue("The Claude Code program was not found. Nothing was changed.")
  }

  struct Result {
    var issues: [SourceIssue]
    /// The command finished, but whether it did its work is not known.
    var isUnconfirmed = false
  }

  /// Runs `claude plugin uninstall --json -- <id>`. Success needs exit code 0 and an answer that
  /// says `"outcome": "ok"`.
  static func uninstall(
    pluginID: String, program: URL, home: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    timeLimit: TimeInterval = timeLimit
  ) -> Result {
    guard isPluginIdentifier(pluginID) else { return Result(issues: [invalidIdentifier]) }
    let run = run(
      ["plugin", "uninstall", "--json", "--", pluginID], program: program, home: home,
      environment: environment, timeLimit: timeLimit)
    return result(of: run, verb: "uninstall")
  }

  /// Runs `claude plugin install --json -- <id>`. Success needs exit code 0 and an answer that
  /// says `"outcome": "ok"`.
  static func install(
    pluginID: String, program: URL, home: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    timeLimit: TimeInterval = timeLimit
  ) -> Result {
    guard isPluginIdentifier(pluginID) else { return Result(issues: [invalidIdentifier]) }
    let run = run(
      ["plugin", "install", "--json", "--", pluginID], program: program, home: home,
      environment: environment, timeLimit: timeLimit)
    return result(of: run, verb: "install")
  }

  private static func result(of run: Run, verb: String) -> Result {
    guard case .finished(let code, let output) = run else {
      return Result(issues: issues(for: run))
    }
    let answer = answer(from: output)
    guard code == 0 else {
      if case .failed(let failure) = answer, let wording = wording(for: failure, verb: verb) {
        return Result(issues: [issue(wording)])
      }
      return Result(issues: [issue("Claude Code could not \(verb) the plugin. Exit code \(code).")])
    }
    switch answer {
    case .ok:
      return Result(issues: [])
    case .failed(let failure):
      return Result(issues: [
        issue(
          wording(for: failure, verb: verb)
            ?? "Claude Code reported that the plugin was not \(verb)ed.")
      ])
    case .unreadable:
      return Result(
        issues: [
          issue("Claude Code finished, but its answer could not be read. Check the plugin list.")
        ],
        isUnconfirmed: true)
    }
  }

  /// Fixed wording for the failure codes known to matter. The answer's own text is never used.
  /// Nil for any other code, which gets the generic wording.
  // ponytail: the failure code for "Claude Code wanted a marketplace command accepted" is not
  // known, so that case gets generic wording until it is observed.
  private static func wording(for failureCode: String?, verb: String) -> String? {
    switch failureCode {
    case "not_installed": "Claude Code reported that the plugin is not installed."
    default: nil
    }
  }

  static func isPluginIdentifier(_ id: String) -> Bool {
    !id.hasPrefix("-") && id.wholeMatch(of: /[A-Za-z0-9._\-]+@[A-Za-z0-9._\-]+/) != nil
  }

  enum Run {
    case refused
    case notStarted
    case timedOut(TimeInterval)
    /// `output` is nil when it was longer than `outputLimit`.
    case finished(code: Int32, output: Data?)
  }

  /// The real file `program` resolves to, when it is a regular executable file owned by the
  /// current user, writable by no one else, and inside Claude Code's versions folder.
  static func verified(_ program: URL, home: URL) -> URL? {
    guard let real = Paths.realPath(program.path),
      let versions = Paths.realPath(home.appending(path: versionsFolder).path),
      real.hasPrefix(versions + "/")
    else { return nil }
    var info = stat()
    guard lstat(real, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
      info.st_mode & (S_IWGRP | S_IWOTH) == 0, access(real, X_OK) == 0
    else { return nil }
    return URL(fileURLWithPath: real)
  }

  /// `PATH` and `HOME`, and those of `passedThrough` that `inherited` sets.
  static func environment(home: URL, inherited: [String: String]) -> [String: String] {
    var result = inherited.filter { passedThrough.contains($0.key) }
    result["PATH"] = inherited["PATH"] ?? "/usr/bin:/bin"
    result["HOME"] = home.path
    return result
  }

  static func run(
    _ arguments: [String], program: URL, home: URL, environment: [String: String],
    timeLimit: TimeInterval
  ) -> Run {
    guard let executable = verified(program, home: home) else { return .refused }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = self.environment(home: home, inherited: environment)
    process.currentDirectoryURL = home
    process.standardInput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let pipe = Pipe()
    for handle in [pipe.fileHandleForReading, pipe.fileHandleForWriting] {
      _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC)
    }
    process.standardOutput = pipe
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    do {
      try process.run()
    } catch {
      return .notStarted
    }
    try? pipe.fileHandleForWriting.close()
    let output = Output(pipe.fileHandleForReading)
    defer { try? pipe.fileHandleForReading.close() }

    if finished.wait(timeout: .now() + timeLimit) == .timedOut {
      let family = [process.processIdentifier] + descendants(of: process.processIdentifier)
      for id in family {
        kill(id, SIGTERM)
      }
      if finished.wait(timeout: .now() + 5) == .timedOut {
        for id in family {
          kill(id, SIGKILL)
        }
        _ = finished.wait(timeout: .now() + 5)
      }
      _ = output.data(waiting: 0)
      return .timedOut(timeLimit)
    }
    return .finished(code: process.terminationStatus, output: output.data(waiting: grace))
  }

  /// Every process started by `id`, its children's children included.
  static func descendants(of id: pid_t) -> [pid_t] {
    var found: [pid_t] = []
    var pending = [id]
    while let parent = pending.popLast() {
      var children = [pid_t](repeating: 0, count: 256)
      let bytes = children.withUnsafeMutableBytes {
        proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), $0.baseAddress, Int32($0.count))
      }
      let count = max(0, Int(bytes) / MemoryLayout<pid_t>.size)
      for child in children.prefix(count) where child > 0 && !found.contains(child) {
        found.append(child)
        pending.append(child)
      }
    }
    return found
  }

  private enum Answer {
    case ok
    case failed(code: String?)
    case unreadable
  }

  /// `ok` for `"outcome": "ok"` and `failed` for `"outcome": "failed"`, with its `failureCode`
  /// when it is a string. Unreadable unless the output is exactly one non-empty line holding a
  /// JSON object with one of those outcomes.
  private static func answer(from output: Data?) -> Answer {
    guard let output, let text = String(data: output, encoding: .utf8) else { return .unreadable }
    let lines = text.split(whereSeparator: \.isNewline).filter {
      !$0.trimmingCharacters(in: .whitespaces).isEmpty
    }
    guard lines.count == 1,
      let object = try? JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
    else { return .unreadable }
    switch object["outcome"] as? String {
    case "ok": return .ok
    case "failed": return .failed(code: object["failureCode"] as? String)
    default: return .unreadable
    }
  }

  private static func issues(for run: Run) -> [SourceIssue] {
    switch run {
    case .refused:
      [issue("Claude Code's program was not found in its standard location. Nothing was run.")]
    case .notStarted:
      [issue("Claude Code could not be started.")]
    case .timedOut(let limit):
      [issue("Claude Code did not finish within \(Int(limit)) seconds and was stopped.")]
    case .finished:
      []
    }
  }

  private static var invalidIdentifier: SourceIssue {
    issue("Not a valid plugin identifier. Nothing was run.")
  }

  static func issue(_ message: String) -> SourceIssue {
    SourceIssue(source: source, message: message)
  }
}

/// Reads a pipe on a thread of its own, so a busy shared pool cannot delay it, keeping at most
/// `ClaudeCommand.outputLimit` bytes. The thread always ends: at the end of the output, on an
/// error, or when `data(waiting:)` stops it. Every access to the stored values holds `lock`.
private final class Output: @unchecked Sendable {
  private let lock = NSLock()
  private let done = DispatchSemaphore(value: 0)
  private var collected = Data()
  private var isOverLimit = false
  private var isStopped = false

  init(_ handle: FileHandle) {
    let descriptor = handle.fileDescriptor
    Thread.detachNewThread { [self] in
      var buffer = [UInt8](repeating: 0, count: 65_536)
      while !lock.withLock({ isStopped }) {
        var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&request, 1, 50)
        if ready < 0, errno == EINTR { continue }
        if ready < 0 { break }
        if ready == 0 { continue }
        let count = read(descriptor, &buffer, buffer.count)
        if count < 0, errno == EINTR || errno == EAGAIN { continue }
        if count <= 0 { break }
        lock.withLock {
          if collected.count + count <= ClaudeCommand.outputLimit {
            collected.append(contentsOf: buffer[0..<count])
          } else {
            isOverLimit = true
          }
        }
      }
      done.signal()
    }
  }

  /// Waits up to `seconds` for the end of the output, then stops reading and returns what was
  /// read. Nil when the output was longer than the limit.
  func data(waiting seconds: Double) -> Data? {
    if done.wait(timeout: .now() + seconds) == .timedOut {
      lock.withLock { isStopped = true }
      done.wait()
    }
    return lock.withLock { isOverLimit ? nil : collected }
  }
}
