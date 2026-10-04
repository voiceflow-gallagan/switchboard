import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct MeasurementStoreTests {
  private let now = Date(timeIntervalSince1970: 1_700_000_100)

  private func temporaryFolder() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "switchboard-\(UUID().uuidString)")
  }

  private func usage(_ rowID: String?, _ bytes: UInt64, root: Int32) -> ServerUsage {
    ServerUsage(
      id: "desktop|\(root)", owner: .desktop, label: "x", rowID: rowID,
      matchedBy: rowID == nil ? nil : .target, footprint: bytes, processCount: 1)
  }

  private func report(_ usages: ServerUsage...) -> MemoryReport {
    MemoryReport(usages: usages, issues: [])
  }

  private func inventory(rowIDs: [String]) -> Inventory {
    let rows = rowIDs.map {
      Row(id: $0, name: $0, kind: .server, entries: [], isDuplicate: false, hasNameConflict: false)
    }
    return Inventory(rows: rows, issues: [], projects: [], cloudHistory: [])
  }

  @Test func missingFolderLoadsEmptyWithoutIssue() {
    let loaded = MeasurementStore.load(folder: temporaryFolder(), now: now)
    #expect(loaded.store.savedKeys.isEmpty)
    #expect(loaded.issues.isEmpty)
  }

  @Test func roundTripLooksUpByRowIdentifier() throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    var store = MeasurementStore.load(folder: folder, now: now).store
    store.record(
      report(usage("server|a", 10, root: 1), usage("server|a", 5, root: 2), usage(nil, 7, root: 3)),
      at: now)
    #expect(store.saveIfDue(at: now).isEmpty)

    let reloaded = MeasurementStore.load(folder: folder, now: now)
    #expect(reloaded.issues.isEmpty)
    #expect(reloaded.store.measurement(for: "server|a") == ServerMeasurement(bytes: 15, date: now))
    #expect(reloaded.store.measurements(for: ["server|a", "server|b"]).count == 1)
    let text = String(
      decoding: try Data(contentsOf: folder.appending(path: MeasurementStore.fileName)),
      as: UTF8.self)
    #expect(!text.contains("server|a"))
  }

  @Test func folderAndFileAreOwnerOnly() throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    var store = MeasurementStore.load(folder: folder, now: now).store
    store.record(report(usage("server|a", 1, root: 1)), at: now)
    for _ in 1...2 {
      #expect(store.save().isEmpty)
      let file = folder.appending(path: MeasurementStore.fileName).path
      let folderMode = try FileManager.default.attributesOfItem(atPath: folder.path)[
        .posixPermissions]
      let fileMode = try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions]
      #expect(folderMode as? Int == 0o700)
      #expect(fileMode as? Int == 0o600)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
      try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file)
    }
  }

  @Test func twoInstallsWriteDifferentKeysForTheSameRow() {
    var first = MeasurementStore.load(folder: temporaryFolder(), now: now).store
    var second = MeasurementStore.load(folder: temporaryFolder(), now: now).store
    first.record(report(usage("server|a", 1, root: 1)), at: now)
    second.record(report(usage("server|a", 1, root: 1)), at: now)
    #expect(first.savedKeys.count == 1)
    #expect(first.savedKeys.isDisjoint(with: second.savedKeys))
  }

  @Test func earlierFormatIsDiscardedSilently() throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let earlier = #"{"measurements": {"server|a": {"bytes": 1, "date": 720000000}}}"#
    try Data(earlier.utf8).write(to: folder.appending(path: MeasurementStore.fileName))
    let loaded = MeasurementStore.load(folder: folder, now: now)
    #expect(loaded.issues.isEmpty)
    #expect(loaded.store.savedKeys.isEmpty)
  }

  @Test func savesAtMostOncePerInterval() throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    var store = MeasurementStore.load(folder: folder, now: now).store
    store.record(report(usage("server|a", 1, root: 1)), at: now)
    #expect(store.saveIfDue(at: now).isEmpty)
    store.record(report(usage("server|a", 2, root: 1)), at: now + 30)
    #expect(store.saveIfDue(at: now + 30).isEmpty)
    #expect(
      MeasurementStore.load(folder: folder, now: now).store.measurement(for: "server|a")?.bytes == 1
    )
    #expect(store.saveIfDue(at: now + 61).isEmpty)
    #expect(
      MeasurementStore.load(folder: folder, now: now).store.measurement(for: "server|a")?.bytes == 2
    )
  }

  @Test func damagedFileLoadsEmptyWithOneIssue() throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("{ broken".utf8).write(to: folder.appending(path: MeasurementStore.fileName))
    let loaded = MeasurementStore.load(folder: folder, now: now)
    #expect(loaded.store.savedKeys.isEmpty)
    #expect(loaded.issues.map(\.source) == ["Saved measurements"])
  }

  @Test func entriesOlderThanNinetyDaysAreDropped() throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let old = now - MeasurementStore.retention - 1
    var store = MeasurementStore.load(folder: folder, now: now).store
    store.record(report(usage("server|old", 1, root: 1)), at: old)
    store.record(report(usage("server|new", 2, root: 2)), at: now)
    #expect(store.measurement(for: "server|old") == nil)
    #expect(store.measurement(for: "server|new") != nil)

    var kept = MeasurementStore.load(folder: folder, now: old).store
    kept.record(report(usage("server|old", 1, root: 1)), at: old)
    #expect(kept.save().isEmpty)
    #expect(MeasurementStore.load(folder: folder, now: old).store.savedKeys.count == 1)
    #expect(MeasurementStore.load(folder: folder, now: now).store.savedKeys.isEmpty)
  }

  @Test func pruneDropsRowsMissingFromACompleteInventoryOnly() {
    var store = MeasurementStore.load(folder: temporaryFolder(), now: now).store
    store.record(report(usage("server|a", 1, root: 1), usage("server|gone", 2, root: 2)), at: now)

    store.prune(now: now, inventory: inventory(rowIDs: ["server|a"]), inventoryIsComplete: false)
    #expect(store.measurement(for: "server|gone") != nil)

    store.prune(now: now, inventory: inventory(rowIDs: ["server|a"]), inventoryIsComplete: true)
    #expect(store.measurement(for: "server|gone") == nil)
    #expect(store.measurement(for: "server|a") != nil)

    store.prune(
      now: now + MeasurementStore.retention + 1, inventory: inventory(rowIDs: ["server|a"]),
      inventoryIsComplete: false)
    #expect(store.savedKeys.isEmpty)
  }

  @Test func clockMovedBackwardsStillSaves() throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    var store = MeasurementStore.load(folder: folder, now: now).store
    store.record(report(usage("server|a", 1, root: 1)), at: now)
    #expect(store.saveIfDue(at: now).isEmpty)
    store.record(report(usage("server|a", 2, root: 1)), at: now - 3_600)
    #expect(store.saveIfDue(at: now - 3_600).isEmpty)
    #expect(
      MeasurementStore.load(folder: folder, now: now).store.measurement(for: "server|a")?.bytes == 2
    )
  }

  @Test func failedSaveRetriesOncePerIntervalAndSaveWritesAtOnce() throws {
    let blocker = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: blocker) }
    try Data().write(to: blocker)
    var store = MeasurementStore.load(folder: blocker.appending(path: "inside"), now: now).store
    #expect(store.saveIfDue(at: now).count == 1)
    #expect(store.saveIfDue(at: now + 5).isEmpty)
    #expect(store.saveIfDue(at: now + 61).count == 1)

    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    var writable = MeasurementStore.load(folder: folder, now: now).store
    writable.record(report(usage("server|a", 1, root: 1)), at: now)
    #expect(writable.saveIfDue(at: now).isEmpty)
    writable.record(report(usage("server|a", 3, root: 1)), at: now + 1)
    #expect(writable.save().isEmpty)
    #expect(
      MeasurementStore.load(folder: folder, now: now).store.measurement(for: "server|a")?.bytes == 3
    )
  }
}
