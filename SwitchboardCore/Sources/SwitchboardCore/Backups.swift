import Foundation

/// A copy of a configuration file, taken before Switchboard changed it. It holds the file's
/// credentials and is readable only by its owner.
///
/// Only `Backups.list` makes one. A restore never trusts `file`: it derives the target again
/// from the backup's own location.
public struct Backup: Identifiable, Hashable, Sendable {
  public var id: URL { url }
  public let url: URL
  /// The file it is a copy of, relative to the home folder, or the absolute path of a project's
  /// personal settings file. Not for display.
  public let file: String
  /// The file for display, such as `~/.claude.json` or `settings.local.json in alpha`. Never a
  /// project's full path.
  public let label: String
  public let date: Date
}

/// The backups in Switchboard's support folder: one folder per configuration file, holding at
/// most `limit` copies named by the time they were taken.
public enum Backups: Sendable {
  public static let folderName = "Backups"
  public static let limit = 20
  private static let source = "Backups"

  /// Every backup, newest first. Nothing inside a backup is read.
  public static func list(supportFolder: URL) -> [Backup] {
    let root = supportFolder.appending(path: folderName)
    let fileManager = FileManager.default
    var found: [(url: URL, file: String, date: Date)] = []
    for folder in (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [] {
      let folderURL = root.appending(path: folder)
      for name in (try? fileManager.contentsOfDirectory(atPath: folderURL.path)) ?? [] {
        let url = folderURL.appending(path: name)
        if let location = located(url, supportFolder: supportFolder) {
          found.append((url, location.file, location.date))
        }
      }
    }
    let projects = Set(found.map(\.file).filter { $0.hasPrefix("/") }.map(projectOf))
    let backups = found.map {
      Backup(
        url: $0.url, file: $0.file, label: label(of: $0.file, among: Array(projects)),
        date: $0.date)
    }
    return backups.sorted { ($0.date, $0.url.path) > ($1.date, $1.url.path) }
  }

  /// Puts `backup` in place of the file it is a copy of. The current file is backed up first,
  /// even when it does not parse, and the outcome holds that new backup. When the file already
  /// has the backup's bytes, nothing is written and `wrote` is false. A missing file is created,
  /// with no new backup and `wrote` true. A project's personal settings file is refused, before
  /// anything is read and again right before the rename, when it or its `.claude` folder is a
  /// symbolic link or leaves the project, as for every other write to a project.
  public static func restore(_ backup: Backup, home: URL, supportFolder: URL) -> SwitchOutcome {
    guard let found = located(backup.url, supportFolder: supportFolder) else {
      return failure("Not a backup of a configuration file. Nothing was changed.")
    }
    let file = found.file
    var files = SourceFiles(home: supportFolder)
    guard let data = files.read(found.resolved), let text = String(data: data, encoding: .utf8),
      JSONText.isValid(text)
    else {
      return failure("The backup could not be read. Nothing was changed.")
    }
    let url = SourceFiles(home: home).url(file)
    let isSafe: () -> Bool = {
      !file.hasPrefix("/") || Switches.safeSettingsURL(projectOf(file)) != nil
    }
    guard isSafe() else {
      return SwitchOutcome(
        applied: false, issues: [linkIssue(file, home: home)], undo: nil, backup: nil)
    }
    ConfigWriter.removeStaleTemporaryFiles(of: url)
    let current = ConfigWriter.contents(of: url, home: home)
    if current == data {
      return SwitchOutcome(applied: true, issues: [], undo: nil, backup: nil, wrote: false)
    }
    var newBackup: URL?
    if let current {
      do {
        newBackup = try save(current, of: file, supportFolder: supportFolder)
      } catch {
        return failure("The current file could not be backed up. Nothing was changed.")
      }
    }
    do {
      guard try ConfigWriter.replace(url, with: data, if: isSafe) else {
        if let newBackup {
          try? FileManager.default.removeItem(at: newBackup)
        }
        return SwitchOutcome(
          applied: false, issues: [linkIssue(file, home: home)], undo: nil, backup: nil)
      }
    } catch {
      return failure("The backup could not be written. Nothing was changed.")
    }
    guard ConfigWriter.contents(of: url, home: home) == data else {
      return SwitchOutcome(
        applied: false,
        issues: [
          SourceIssue(
            source: label(of: file, among: Switches.knownProjects(home: home) + [projectOf(file)]),
            message: "Could not be verified after restoring.")
        ],
        undo: nil, backup: newBackup, wrote: true)
    }
    return SwitchOutcome(applied: true, issues: [], undo: nil, backup: newBackup, wrote: true)
  }

  /// Whether the file `backup` was restored to still has exactly the backup's bytes. A running
  /// Claude Code session may rewrite it, so check again a few seconds after a restore. Nil when
  /// the backup cannot be read.
  public static func isRestored(_ backup: Backup, home: URL, supportFolder: URL) -> Bool? {
    guard let found = located(backup.url, supportFolder: supportFolder) else { return nil }
    var files = SourceFiles(home: supportFolder)
    guard let data = files.read(found.resolved) else { return nil }
    return ConfigWriter.contents(of: SourceFiles(home: home).url(found.file), home: home) == data
  }

  /// Where a backup at `url` belongs. It must be a regular file, not a symbolic link, named like
  /// a backup, whose resolved location is directly inside the backups folder of a
  /// configuration file.
  static func located(_ url: URL, supportFolder: URL) -> (
    file: String, date: Date, resolved: URL
  )? {
    let root = supportFolder.appending(path: folderName).resolvingSymlinksInPath()
    let resolved = url.resolvingSymlinksInPath()
    let folder = resolved.deletingLastPathComponent()
    guard
      (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        == .typeRegular,
      folder.deletingLastPathComponent().path == root.path,
      let date = date(fromName: resolved.lastPathComponent),
      let file = folder.lastPathComponent.removingPercentEncoding, isConfigurationFile(file)
    else { return nil }
    return (file, date, resolved)
  }

  /// Saves `data` as the newest backup of `file` and prunes that file's backups.
  static func save(_ data: Data, of file: String, supportFolder: URL, date: Date = Date()) throws
    -> URL
  {
    guard isConfigurationFile(file),
      let folderName = file.addingPercentEncoding(withAllowedCharacters: folderNameCharacters)
    else { throw CocoaError(.fileWriteInvalidFileName) }
    let root = supportFolder.appending(path: Self.folderName)
    let folder = root.appending(path: folderName)
    let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    let suffix = UUID().uuidString.prefix(8).lowercased()
    let url = folder.appending(path: String(format: "%013lld", milliseconds) + "-\(suffix).json")
    try ConfigWriter.writePrivately(data, to: url, folders: [supportFolder, root, folder])
    prune(folder, keeping: url.lastPathComponent)
    return url
  }

  /// Keeps `newest`, which was just written, and the newest others up to `limit` in all, even
  /// when the clock is behind the names already there.
  private static func prune(_ folder: URL, keeping newest: String) {
    let fileManager = FileManager.default
    let names = ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [])
      .filter { $0 != newest && date(fromName: $0) != nil }
      .sorted(by: >)
    for name in names.dropFirst(limit - 1) {
      try? fileManager.removeItem(at: folder.appending(path: name))
    }
  }

  // ponytail: a file's backups folder is named by its percent-encoded path. A project path long
  // enough to pass the 255-byte name limit cannot be backed up, so its change is refused.
  private static let folderNameCharacters = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")

  /// The date in a name of the form `<milliseconds>-<8 hex digits>.json`.
  private static func date(fromName name: String) -> Date? {
    guard let match = name.wholeMatch(of: /([0-9]{13})-[0-9a-f]{8}\.json/),
      let milliseconds = Double(match.1)
    else { return nil }
    return Date(timeIntervalSince1970: milliseconds / 1000)
  }

  /// Whether `file` is one of the configuration files a switch changes: a path relative to the
  /// home folder, or the absolute path of a project's personal settings file.
  static func isConfigurationFile(_ file: String) -> Bool {
    if [Switches.claudeCodeFile, Switches.settingsFile, Switches.desktopFile].contains(file) {
      return true
    }
    let components = file.split(separator: "/", omittingEmptySubsequences: false)
    if file.hasPrefix("/") {
      return file.hasSuffix("/" + Switches.projectSettingsFile)
        && !components.dropFirst().contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
    let prefix = Switches.extensionSettingsFolder + "/"
    guard file.hasPrefix(prefix) else { return false }
    let name = String(file.dropFirst(prefix.count))
    return name.hasSuffix(".json") && Switches.isFolderName(String(name.dropLast(5)))
  }

  /// `~/` and the relative path, or for a project's personal settings file its name and the
  /// project's name.
  static func label(of file: String, among projects: [String]) -> String {
    guard file.hasPrefix("/") else { return "~/" + file }
    let name = SourceFiles.projectName(projectOf(file), among: projects)
    return "\(URL(fileURLWithPath: file).lastPathComponent) in \(name)"
  }

  private static func linkIssue(_ file: String, home: URL) -> SourceIssue {
    Switches.linkIssue(
      projectOf(file), among: Switches.knownProjects(home: home) + [projectOf(file)])
  }

  /// The project folder of a project's personal settings file.
  private static func projectOf(_ file: String) -> String {
    URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().path
  }

  private static func failure(_ message: String) -> SwitchOutcome {
    SwitchOutcome(
      applied: false, issues: [SourceIssue(source: source, message: message)], undo: nil,
      backup: nil)
  }
}
