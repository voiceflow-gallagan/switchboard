import Foundation
import SwitchboardCore

@MainActor @Observable
final class UsageStore {
  private(set) var report: MemoryReport?
  /// The processes of the latest sample.
  private(set) var processes: [RunningProcess] = []
  private(set) var sampledAt: Date?
  private(set) var isClaudeRunning = false
  private(set) var history = MemoryHistory()
  private(set) var serverChart: ServerChart?
  private(set) var serverBars: [ServerBar] = []
  private(set) var disk: DiskReport?
  private(set) var isScanning = false
  private var loadIssues: [SourceIssue] = []
  private var saveIssues: [SourceIssue] = []
  private var store: MeasurementStore?
  private var didStartLoadingStore = false
  private var isSampling = false
  private var queuedSample: (inventory: Inventory, isComplete: Bool)?
  private var isScanQueued = false
  private let paths: AppPaths

  init(paths: AppPaths) {
    self.paths = paths
  }

  var issues: [SourceIssue] {
    loadIssues + saveIssues + (report?.issues ?? []) + (disk?.issues ?? [])
  }

  func measurements(for rowIDs: [Row.ID]) -> [Row.ID: ServerMeasurement] {
    store?.measurements(for: rowIDs) ?? [:]
  }

  func loadStore() async {
    guard !didStartLoadingStore else { return }
    didStartLoadingStore = true
    guard let folder = paths.supportFolder else {
      loadIssues = [
        SourceIssue(source: "Saved measurements", message: "No Application Support folder")
      ]
      return
    }
    let loaded = await Task.detached { MeasurementStore.load(folder: folder) }.value
    store = loaded.store
    loadIssues = loaded.issues
  }

  /// Takes a snapshot, then records and prunes the saved measurements against `inventory`.
  /// `isComplete` is false for an inventory loaded without project folders.
  func sample(inventory: Inventory, isComplete: Bool) {
    guard !isSampling else {
      queuedSample = (inventory, isComplete)
      return
    }
    isSampling = true
    let previous = store
    let isDemo = paths.isDemo
    Task {
      let result = await Task.detached {
        let snapshot = MeasurementSource.processes(inventory: inventory, isDemo: isDemo)
        let report = MemoryReport.build(
          processes: snapshot.processes, inventory: inventory, issues: snapshot.issues)
        let now = Date()
        var store = previous
        store?.prune(now: now, inventory: inventory, inventoryIsComplete: isComplete)
        store?.record(report, at: now)
        let saveIssues = store?.saveIfDue(at: now) ?? []
        let chart = report.serverChart()
        return (
          report: report, processes: snapshot.processes, chart: chart,
          bars: Self.serverBars(chart, rows: inventory.rows),
          isRunning: !snapshot.processes.isEmpty, store: store,
          saveIssues: saveIssues, date: now
        )
      }.value
      report = result.report
      processes = result.processes
      serverChart = result.chart
      serverBars = result.bars
      history.append(result.report, at: result.date)
      isClaudeRunning = result.isRunning
      if let updated = result.store {
        store = updated
        saveIssues = result.saveIssues
      }
      sampledAt = result.date
      isSampling = false
      if let queued = queuedSample {
        queuedSample = nil
        sample(inventory: queued.inventory, isComplete: queued.isComplete)
      }
    }
  }

  /// Matched servers carry their configured row name. Only the extension hosts group and the
  /// unmatched fold keep a launch label. Names that still collide show the launch label quietly.
  nonisolated static func serverBars(_ chart: ServerChart, rows: [Row]) -> [ServerBar] {
    let rowIDs = Set(chart.top.compactMap(\.rowID))
    let names = Dictionary(
      rows.filter { rowIDs.contains($0.id) }.map { ($0.id, $0.name) },
      uniquingKeysWith: { first, _ in first })
    let titles = chart.top.map { total in total.rowID.flatMap { names[$0] } ?? total.label }
    let titleCounts = Dictionary(grouping: titles, by: { $0 }).mapValues(\.count)
    let top = zip(chart.top, titles).map { total, title in
      ServerBar(
        id: total.id, label: title,
        detail: titleCounts[title, default: 0] > 1 ? total.label : nil, bytes: total.footprint,
        badge: total.copies > 1 ? "\(total.copies) copies" : nil,
        offButRunning: total.offButRunningCopies > 0
          ? ServerBar.OffButRunning(
            isAll: total.offButRunningCopies == total.copies, bytes: total.offButRunningFootprint)
          : nil)
    }
    guard let unmatched = chart.unmatched else { return top }
    return top + [
      ServerBar(
        id: "unmatched", label: "Unmatched", bytes: unmatched.footprint,
        badge: "\(unmatched.groups) groups", isQuiet: true)
    ]
  }

  /// Writes the saved measurements off the main thread, for when the app stops being active.
  func saveInBackground() {
    guard let store else { return }
    Task {
      saveIssues = await Task.detached { store.save() }.value
    }
  }

  /// Writes the saved measurements before the app quits, when no later task would run.
  func saveNow() {
    saveIssues = store?.save() ?? []
  }

  /// Scans only when there is no result and no scan running. Reload uses `scanDisk` instead.
  func scanDiskIfNeeded() {
    if disk == nil && !isScanning {
      scanDisk()
    }
  }

  func scanDisk() {
    guard !isScanning else {
      isScanQueued = true
      return
    }
    isScanning = true
    let home = paths.home
    let isDemo = paths.isDemo
    Task {
      disk = await Task.detached { MeasurementSource.disk(home: home, isDemo: isDemo) }.value
      isScanning = false
      if isScanQueued {
        isScanQueued = false
        scanDisk()
      }
    }
  }
}
