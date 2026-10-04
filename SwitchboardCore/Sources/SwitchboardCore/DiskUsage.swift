import Foundation

/// Space on disk taken by plugins, old plugin versions, Desktop extensions, and user skills.
public struct DiskReport: Sendable {
  public enum Category: CaseIterable, Sendable {
    /// The folders installed plugins point to.
    case plugins
    /// Folders in the plugin cache that no installed plugin points to.
    case oldPluginVersions
    case extensions
    /// User skills. A linked skill counts as zero bytes.
    case skills
  }

  /// Allocated bytes per category.
  public var sizes: [Category: UInt64]
  /// User skills that are symbolic links, which are not followed.
  public var linkedSkills: Int
  public var issues: [SourceIssue]

  /// Measures the four categories under `home`. Slow on large folders: call it off the main
  /// thread, and never from the memory sampling path.
  public static func scan(home: URL) -> DiskReport {
    var files = SourceFiles(home: home)
    var unreadable = 0
    let pluginsRoot = files.url(".claude/plugins").resolvingSymlinksInPath().path
    var installPaths: Set<String> = []
    var outside = 0
    for path in ClaudeCodeReader.installPaths(&files) {
      let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
      if resolved.hasPrefix(pluginsRoot + "/") {
        installPaths.insert(resolved)
      } else {
        outside += 1
      }
    }

    var sizes: [Category: UInt64] = [:]
    sizes[.plugins] = installPaths.sorted().reduce(0) {
      $0 + allocatedSize(of: URL(fileURLWithPath: $1), unreadable: &unreadable)
    }

    let cache = files.url(".claude/plugins/cache")
    var oldVersions: UInt64 = 0
    for marketplace in files.children(of: cache) {
      let marketplaceURL = cache.appending(path: marketplace)
      for plugin in files.children(of: marketplaceURL) {
        let pluginURL = marketplaceURL.appending(path: plugin)
        for version in files.children(of: pluginURL) {
          let path = pluginURL.appending(path: version).resolvingSymlinksInPath().path
          let isInstalled = installPaths.contains { $0 == path || $0.hasPrefix(path + "/") }
          if !isInstalled {
            oldVersions += allocatedSize(of: URL(fileURLWithPath: path), unreadable: &unreadable)
          }
        }
      }
    }
    sizes[.oldPluginVersions] = oldVersions

    sizes[.extensions] = allocatedSize(
      of: files.url("Library/Application Support/Claude/Claude Extensions"), unreadable: &unreadable
    )

    let skills = files.url(".claude/skills")
    sizes[.skills] = allocatedSize(of: skills, unreadable: &unreadable)
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: skills.path)) ?? []
    let linkedSkills = entries.filter { isSymbolicLink(skills.appending(path: $0)) }.count

    var issues = files.issues
    if outside > 0 {
      issues.append(
        SourceIssue(
          source: "Disk usage",
          message: "\(outside) plugin folders outside the plugins folder were skipped"))
    }
    if unreadable > 0 {
      issues.append(
        SourceIssue(
          source: "Disk usage",
          message: "\(unreadable) items could not be measured and are left out"))
    }
    return DiskReport(sizes: sizes, linkedSkills: linkedSkills, issues: issues)
  }

  private static func isSymbolicLink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
  }

  /// The allocated size of the regular files under `folder`. Symbolic links are not followed,
  /// so a linked folder counts as zero bytes.
  static func allocatedSize(of folder: URL, unreadable: inout Int) -> UInt64 {
    guard !isSymbolicLink(folder), FileManager.default.fileExists(atPath: folder.path) else {
      return 0
    }
    let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
    var failures = 0
    let enumerator = FileManager.default.enumerator(
      at: folder, includingPropertiesForKeys: keys, options: []
    ) { _, _ in
      failures += 1
      return true
    }
    var total: UInt64 = 0
    while let item = enumerator?.nextObject() as? URL {
      guard let values = try? item.resourceValues(forKeys: Set(keys)) else {
        failures += 1
        continue
      }
      if values.isRegularFile == true {
        total += UInt64(values.totalFileAllocatedSize ?? 0)
      }
    }
    unreadable += failures
    return total
  }
}
