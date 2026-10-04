import Foundation
import SwitchboardCore

/// Where running processes and disk sizes come from: this Mac, or in demo mode invented figures
/// for screenshots, so no name from this Mac appears on screen.
enum MeasurementSource {
  static func processes(inventory: Inventory, isDemo: Bool) -> (
    processes: [RunningProcess], issues: [SourceIssue]
  ) {
    guard isDemo else {
      let snapshot = ProcessSnapshot.take(inventory: inventory)
      return (snapshot.processes, snapshot.issues)
    }
    return (DemoScene.processes(inventory: inventory, at: .now), [])
  }

  static func disk(home: URL, isDemo: Bool) -> DiskReport {
    isDemo ? DemoScene.disk : DiskReport.scan(home: home)
  }
}

/// Invented figures that look lived in: Claude Desktop runs several of the inventory's Desktop
/// servers, most of them twice, and its extension hosts. Two sessions run in the projects alpha
/// and beta. In alpha one server is off but still running, and in beta a few unmatched programs
/// run. Every size moves a little with time, so the live chart shows movement.
private enum DemoScene {
  private static let megabyte = 1_048_576.0
  private static let desktopApp = "/Applications/Claude.app/Contents/MacOS/Claude"
  private static let extensionHost =
    "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Plugin).app/Contents/MacOS/Claude Helper (Plugin)"
  private static let sessionProgram = "/opt/claude/versions/2.0.0/claude"
  private static let node = "/opt/homebrew/bin/node"

  static var disk: DiskReport {
    InventedData.diskReport(
      sizes: [
        .plugins: UInt64(1_240 * megabyte), .oldPluginVersions: UInt64(356 * megabyte),
        .extensions: UInt64(612 * megabyte), .skills: UInt64(88 * megabyte),
      ],
      linkedSkills: 3)
  }

  static func processes(inventory: Inventory, at date: Date) -> [RunningProcess] {
    var scene = Scene(time: date.timeIntervalSinceReferenceDate)
    let servers = inventory.rows.filter { $0.kind == .server }.flatMap(\.entries)
      .filter { $0.target != nil }

    let desktop = scene.add(parent: 1, desktopApp, 1)
    for megabytes in [210.0, 160, 120] {
      scene.add(parent: desktop, extensionHost, megabytes)
    }
    let onDesktop = servers.filter { $0.place == .desktop && $0.state == .on }
    for (index, entry) in onDesktop.prefix(4).enumerated() {
      let megabytes = [380.0, 240, 150, 95][index]
      scene.add(parent: desktop, node, megabytes, target: entry.target)
      if index < 3 {
        scene.add(parent: desktop, node, megabytes * 0.9, target: entry.target)
      }
    }

    for (name, sizes) in [("alpha", [180.0, 130, 90]), ("beta", [260.0, 110, 70])] {
      guard
        let project = inventory.projects.first(where: {
          URL(filePath: $0).lastPathComponent == name
        })
      else { continue }
      let session = scene.add(parent: 1, sessionProgram, 1, folder: project)
      let place = Place.project(path: project)
      let running = servers.filter { $0.place != .desktop && $0.state(in: place) == .on }
      for (entry, megabytes) in zip(running, sizes) {
        scene.add(parent: session, node, megabytes, target: entry.target)
      }
      if name == "alpha",
        let off = servers.first(where: { $0.place != .desktop && $0.state(in: place) == .off })
      {
        scene.add(parent: session, node, 140, target: off.target)
      }
      if name == "beta" {
        for (program, megabytes) in [("deno", 120.0), ("ruby", 75), ("bun", 60)] {
          scene.add(parent: session, "/opt/homebrew/bin/\(program)", megabytes)
        }
      }
    }
    return scene.processes
  }

  private struct Scene {
    let time: TimeInterval
    var processes: [RunningProcess] = []
    var nextID: Int32 = 4100

    /// Adds a process whose size moves by up to 6% over a cycle of 45 to 99 seconds.
    @discardableResult
    mutating func add(
      parent: Int32, _ path: String, _ megabytes: Double, target: Target? = nil,
      folder: String? = nil
    ) -> Int32 {
      let id = nextID
      nextID += 1
      let period = 45 + Double(id % 7) * 9
      let wave = 1 + 0.06 * sin(time * 2 * .pi / period + Double(id))
      processes.append(
        InventedData.process(
          id: id, parent: parent, footprint: UInt64(megabytes * wave * DemoScene.megabyte),
          programPath: path, target: target, workingFolder: folder))
      return id
    }
  }
}
