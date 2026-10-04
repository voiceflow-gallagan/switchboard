import Foundation

/// Invented processes and disk sizes, for demos and screenshots. Nothing here is read from this
/// Mac, and nothing the app measures goes through it.
public enum InventedData: Sendable {
  /// A process that does not exist.
  public static func process(
    id: Int32, parent: Int32, footprint: UInt64, programPath: String, target: Target? = nil,
    workingFolder: String? = nil
  ) -> RunningProcess {
    RunningProcess(
      id: id, parent: parent, footprint: footprint, programPath: programPath, target: target,
      workingFolder: workingFolder)
  }

  /// Disk sizes that were not measured.
  public static func diskReport(sizes: [DiskReport.Category: UInt64], linkedSkills: Int)
    -> DiskReport
  {
    DiskReport(sizes: sizes, linkedSkills: linkedSkills, issues: [])
  }
}
