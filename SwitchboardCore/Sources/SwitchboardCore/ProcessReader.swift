import Darwin
import Foundation

/// One running process. It never holds launch arguments.
public struct RunningProcess: Sendable {
  public var id: Int32
  public var parent: Int32
  /// Bytes, the measure Activity Monitor shows as Memory.
  public var footprint: UInt64
  public var programPath: String
  /// Built from the launch arguments, which are then dropped.
  public var target: Target?
  public var workingFolder: String?
}

/// The Claude processes running at one moment, with an issue for those that could not be read.
public struct ProcessSnapshot: Sendable {
  public var processes: [RunningProcess]
  public var issues: [SourceIssue]

  /// Reads Claude Desktop, every Claude Code session, and every process they started.
  /// With an inventory, servers left running by an owner that exited are read too: direct
  /// children of process 1 whose target equals a configured server's target.
  public static func take(inventory: Inventory? = nil) -> ProcessSnapshot {
    let targets = Set(
      inventory?.rows.filter { $0.kind == .server }.flatMap(\.entries).compactMap(\.target) ?? [])
    return ProcessReader.snapshot(orphanTargets: targets)
  }
}

/// Reads the current user's running processes from macOS. The only code that touches the system.
enum ProcessReader {
  private static let launchd: pid_t = 1

  static func snapshot(orphanTargets: Set<Target> = []) -> ProcessSnapshot {
    let user = getuid()
    var parents: [pid_t: pid_t] = [:]
    var children: [pid_t: [pid_t]] = [:]
    var paths: [pid_t: String] = [:]
    for id in allProcessIDs() {
      guard let info = bsdInfo(id), info.pbi_uid == user else { continue }
      let parent = pid_t(info.pbi_ppid)
      parents[id] = parent
      children[parent, default: []].append(id)
      paths[id] = programPath(id)
    }
    let owners = paths.filter { MemoryReport.ownerKind(programPath: $0.value) != nil }

    var targets: [pid_t: Target] = [:]
    if !orphanTargets.isEmpty {
      for id in children[launchd] ?? [] where owners[id] == nil {
        guard let path = paths[id], mayBeServer(path),
          let found = withArguments(id, { Duplicates.target(launchArguments: $0) }) ?? nil,
          orphanTargets.contains(found)
        else { continue }
        targets[id] = found
      }
    }

    var relevant = Set(owners.keys).union(targets.keys)
    var pending = Array(relevant)
    while let id = pending.popLast() {
      for child in children[id] ?? [] where !relevant.contains(child) {
        relevant.insert(child)
        pending.append(child)
      }
    }

    var processes: [RunningProcess] = []
    var unreadable = 0
    for id in relevant.sorted() {
      let isOwner = owners[id] != nil
      let target: Target??
      if isOwner {
        target = .some(nil)
      } else if let known = targets[id] {
        target = known
      } else {
        target = withArguments(id) { Duplicates.target(launchArguments: $0) }
      }
      guard let parent = parents[id], let footprint = footprint(id), let path = paths[id],
        let target
      else {
        if bsdInfo(id) != nil {
          unreadable += 1
        }
        continue
      }
      processes.append(
        RunningProcess(
          id: id,
          parent: parent,
          footprint: footprint,
          programPath: path,
          target: target,
          workingFolder: isOwner ? workingFolder(id) : nil
        )
      )
    }
    let issues =
      unreadable == 0
      ? []
      : [
        SourceIssue(
          source: "Running processes",
          message: "\(unreadable) processes could not be read and are left out")
      ]
    return ProcessSnapshot(processes: processes, issues: issues)
  }

  /// App main programs and system services are never MCP servers, so their arguments are
  /// not read when looking for servers left running.
  private static func mayBeServer(_ path: String) -> Bool {
    !path.contains(".app/Contents/MacOS/") && !path.hasPrefix("/System/")
      && !path.hasPrefix("/usr/libexec/") && !path.hasPrefix("/usr/sbin/")
  }

  static func allProcessIDs() -> [pid_t] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var ids = [pid_t](repeating: 0, count: Int(count) + 64)
    let filled = ids.withUnsafeMutableBytes {
      proc_listallpids($0.baseAddress, Int32($0.count))
    }
    return Array(ids.prefix(Int(max(filled, 0)))).filter { $0 > 0 }
  }

  static func bsdInfo(_ id: pid_t) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    return proc_pidinfo(id, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
  }

  /// The physical footprint in bytes, the measure Activity Monitor shows as Memory.
  static func footprint(_ id: pid_t) -> UInt64? {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(id, RUSAGE_INFO_V4, $0)
      }
    }
    return result == 0 ? usage.ri_phys_footprint : nil
  }

  static func programPath(_ id: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let length = proc_pidpath(id, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  static func workingFolder(_ id: pid_t) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(id, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes in
      String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
    return path.isEmpty ? nil : path
  }

  /// Calls `body` with the launch arguments, `argv[0]` first, and returns its result.
  /// The arguments exist only during the call. The environment that follows them is never read.
  static func withArguments<Result>(_ id: pid_t, _ body: ([String]) -> Result) -> Result? {
    var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, id]
    var size = 0
    guard sysctl(&name, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
      return nil
    }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
      return nil
    }
    let count = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
    var index = MemoryLayout<Int32>.size
    while index < size, buffer[index] != 0 { index += 1 }
    while index < size, buffer[index] == 0 { index += 1 }

    var arguments: [String] = []
    while arguments.count < count, index < size {
      let start = index
      while index < size, buffer[index] != 0 { index += 1 }
      arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
      index += 1
    }
    return body(arguments)
  }
}
