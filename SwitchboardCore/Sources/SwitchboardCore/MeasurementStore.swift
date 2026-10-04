import CryptoKit
import Foundation

/// The last memory value measured for one server.
public struct ServerMeasurement: Codable, Equatable, Sendable {
  public var bytes: UInt64
  public var date: Date
}

/// Remembers the last measured memory of each server, so a stopped server can still show a figure.
///
/// The saved file holds keyed digests of row identifiers, byte counts, dates, and the
/// per-install key. Its folder is readable by the owner only. Row identifiers never appear in it,
/// so a launch line cannot be guessed back from the file without the key.
public struct MeasurementStore: Sendable {
  public static let fileName = "measurements.json"
  public static let saveInterval: TimeInterval = 60
  /// Measurements older than this are dropped.
  public static let retention: TimeInterval = 90 * 86_400

  private struct File: Codable {
    var version: Int
    var key: Data
    var measurements: [String: ServerMeasurement]
  }

  /// Any earlier format has no `key`. It is discarded without an issue.
  private struct Header: Decodable {
    var version: Int?
    var key: Data?
  }

  public let folder: URL
  private let key: SymmetricKey
  private var saved: [String: ServerMeasurement]
  private var lastAttempt: Date?

  /// A missing file loads as empty. A damaged or unreadable one loads as empty, with one issue.
  /// Measurements older than `retention` before `now` are dropped.
  public static func load(folder: URL, now: Date = Date()) -> (
    store: MeasurementStore, issues: [SourceIssue]
  ) {
    var files = SourceFiles(home: folder)
    let url = folder.appending(path: fileName)
    var store = MeasurementStore(folder: folder)
    if let header = files.decode(Header.self, at: url), header.version == 2, header.key != nil,
      let file = files.decode(File.self, at: url)
    {
      store = MeasurementStore(
        folder: folder, key: SymmetricKey(data: file.key), saved: file.measurements)
    }
    store.dropExpired(before: now)
    let issues = files.issues.map { SourceIssue(source: "Saved measurements", message: $0.message) }
    return (store, issues)
  }

  init(
    folder: URL, key: SymmetricKey = SymmetricKey(size: .bits256),
    saved: [String: ServerMeasurement] = [:]
  ) {
    self.folder = folder
    self.key = key
    self.saved = saved
  }

  public func measurement(for rowID: Row.ID) -> ServerMeasurement? {
    saved[digest(rowID)]
  }

  public func measurements(for rowIDs: some Sequence<Row.ID>) -> [Row.ID: ServerMeasurement] {
    var found: [Row.ID: ServerMeasurement] = [:]
    for rowID in rowIDs {
      found[rowID] = measurement(for: rowID)
    }
    return found
  }

  /// The keyed digests written to the file, for tests.
  var savedKeys: Set<String> {
    Set(saved.keys)
  }

  private func digest(_ rowID: Row.ID) -> String {
    HMAC<SHA256>.authenticationCode(for: Data(rowID.utf8), using: key)
      .map { String(format: "%02x", $0) }.joined()
  }

  /// Keeps the total of every matched server in `report`, across all its copies, and drops
  /// measurements older than `retention`.
  public mutating func record(_ report: MemoryReport, at date: Date) {
    var totals: [Row.ID: UInt64] = [:]
    for usage in report.usages {
      if let rowID = usage.rowID {
        totals[rowID, default: 0] += usage.footprint
      }
    }
    for (rowID, bytes) in totals {
      saved[digest(rowID)] = ServerMeasurement(bytes: bytes, date: date)
    }
    dropExpired(before: date)
  }

  /// Drops measurements older than `retention`. When `inventoryIsComplete` is true, also drops
  /// measurements of servers that no row of `inventory` has. Pass false after a load without
  /// projects, which has no project rows.
  public mutating func prune(now: Date, inventory: Inventory, inventoryIsComplete: Bool) {
    dropExpired(before: now)
    guard inventoryIsComplete else { return }
    let current = Set(inventory.rows.filter { $0.kind == .server }.map { digest($0.id) })
    saved = saved.filter { current.contains($0.key) }
  }

  private mutating func dropExpired(before now: Date) {
    saved = saved.filter { now.timeIntervalSince($0.value.date) <= Self.retention }
  }

  /// Writes the file atomically, at most once per `saveInterval` whether the last attempt
  /// succeeded or failed. A clock that moved backwards makes a save due at once.
  /// Returns an issue on failure.
  public mutating func saveIfDue(at date: Date) -> [SourceIssue] {
    if let lastAttempt {
      let elapsed = date.timeIntervalSince(lastAttempt)
      if elapsed >= 0, elapsed < Self.saveInterval {
        return []
      }
    }
    lastAttempt = date
    return save()
  }

  /// Writes the file atomically now, for example when the app is about to quit. The folder is
  /// kept at mode 0700 and the file at 0600. Returns an issue on failure.
  public func save() -> [SourceIssue] {
    let fileManager = FileManager.default
    let url = folder.appending(path: Self.fileName)
    do {
      try fileManager.createDirectory(
        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
      let keyData = key.withUnsafeBytes { Data($0) }
      let encoder = JSONEncoder()
      encoder.outputFormatting = .sortedKeys
      let data = try encoder.encode(File(version: 2, key: keyData, measurements: saved))
      try data.write(to: url, options: .atomic)
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      return []
    } catch {
      return [SourceIssue(source: "Saved measurements", message: "Could not be saved")]
    }
  }
}
