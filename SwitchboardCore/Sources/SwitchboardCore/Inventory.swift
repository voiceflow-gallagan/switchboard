import Foundation

public struct Inventory: Sendable {
  public var rows: [Row]
  public var issues: [SourceIssue]
  /// Claude Code projects, sorted. A full load keeps only folders that still exist. A load
  /// without projects keeps every path from Claude Code's file, because checking whether a
  /// folder exists would touch it.
  public var projects: [String]
  /// Names of claude.ai connectors Claude Code has connected to at some point. Not current state.
  public var cloudHistory: [String]
  /// Servers the user removed, newest first. They are not rows. Filled when a support folder is
  /// given.
  public var removed: [RemovedServer] = []
  /// Project folders reached through a symbolic link: the resolved path, then the project path.
  /// Filled only by a full load.
  var projectAliases: [String: String] = [:]

  /// Reads every source under `home`. A missing or malformed source becomes an issue
  /// and the other sources still load.
  ///
  /// With `includingProjects` false, nothing inside or about a project folder is touched on
  /// disk, so a folder macOS protects cannot make the load wait for a permission prompt.
  /// Project servers and off lists still come from Claude Code's own file. Each project's
  /// settings files, `.mcp.json`, and skills are left out.
  ///
  /// With a `supportFolder`, servers Switchboard keeps aside are added as entries that are off.
  public static func load(home: URL, includingProjects: Bool = true, supportFolder: URL? = nil)
    -> Inventory
  {
    var files = SourceFiles(home: home)
    return load(&files, includingProjects: includingProjects, supportFolder: supportFolder)
  }

  static func load(_ files: inout SourceFiles, includingProjects: Bool, supportFolder: URL? = nil)
    -> Inventory
  {
    let desktopEntries = DesktopReader.read(&files)
    let claudeCode = ClaudeCodeReader.read(&files, includingProjects: includingProjects)
    let kept = supportFolder.map { ParkedServers.read(supportFolder: $0, files: &files) }
    return Inventory(
      rows: Duplicates.rows(from: desktopEntries + claudeCode.entries + (kept?.entries ?? [])),
      issues: files.issues,
      projects: claudeCode.projects,
      cloudHistory: claudeCode.cloudHistory,
      removed: kept?.removed ?? [],
      projectAliases: claudeCode.projectAliases
    )
  }
}

/// Decodes files and records an issue for each one that cannot be read.
struct SourceFiles {
  static let sizeLimit = 64 * 1_048_576

  let home: URL
  var issues: [SourceIssue] = []
  /// When set, every path asked about is recorded, so tests can prove what was touched.
  var accessLog: AccessLog?
  /// Folders whose files must not be touched, such as project folders during a quick load.
  var skippedFolders: [String] = []
  /// Known project folders. An issue about a project, or a file inside one, names the project
  /// instead of showing its path.
  var projects: [String] = []

  /// `path` relative to the home folder, or as is when it is absolute.
  func url(_ path: String) -> URL {
    path.hasPrefix("/") ? URL(fileURLWithPath: path) : home.appending(path: path)
  }

  func isDirectory(_ url: URL) -> Bool {
    accessLog?.paths.append(url.path)
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  /// Folder names inside `url`, sorted. Symbolic links are included.
  func children(of url: URL) -> [String] {
    accessLog?.paths.append(url.path)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    return names.filter { !$0.hasPrefix(".") && isDirectory(url.appending(path: $0)) }.sorted()
  }

  /// Returns nil when the file is missing or malformed. A missing file is an issue only when `required`.
  func fileExists(_ url: URL) -> Bool {
    accessLog?.paths.append(url.path)
    return FileManager.default.fileExists(atPath: url.path)
  }

  /// Whether `path` is an absolute path to an existing file outside `skippedFolders`.
  func isProgramFile(_ path: String) -> Bool {
    guard path.hasPrefix("/"),
      !skippedFolders.contains(where: { path == $0 || path.hasPrefix($0 + "/") })
    else { return false }
    accessLog?.paths.append(path)
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      && !isDirectory.boolValue
  }

  /// False when the folder exists but cannot be read, for example when permission is denied.
  func isReadable(_ url: URL) -> Bool {
    accessLog?.paths.append(url.path)
    return FileManager.default.isReadableFile(atPath: url.path)
  }

  mutating func decode<T: Decodable>(_ type: T.Type, at url: URL, required: Bool = false) -> T? {
    guard fileExists(url) else {
      if required {
        report(url, "File not found")
      }
      return nil
    }
    guard let data = read(url) else { return nil }
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      report(url, Self.message(for: error))
      return nil
    }
  }

  /// The contents of a regular file of at most `sizeLimit` bytes, after following symbolic links.
  /// Anything else, such as a pipe or a device, is refused with an issue and never opened.
  mutating func read(_ url: URL) -> Data? {
    accessLog?.paths.append(url.path)
    let resolved = url.resolvingSymlinksInPath()
    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
    } catch {
      report(url, "Could not be read")
      return nil
    }
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      report(url, "Not a regular file")
      return nil
    }
    guard let size = attributes[.size] as? Int, size <= Self.sizeLimit else {
      report(url, "Larger than \(Self.sizeLimit / 1_048_576) MB")
      return nil
    }
    do {
      return try Data(contentsOf: resolved)
    } catch {
      report(url, "Could not be read")
      return nil
    }
  }

  /// `relativePath` joined to `root`, or nil with an issue when the result leaves `root`.
  mutating func path(_ relativePath: String, inside root: URL, declaredIn source: URL) -> URL? {
    let base = root.standardizedFileURL.path
    let joined = root.appending(path: relativePath).standardizedFileURL
    guard joined.path == base || joined.path.hasPrefix(base + "/") else {
      report(source, "Skipped a path that leaves the plugin folder")
      return nil
    }
    return joined
  }

  /// The entries that decoded, sorted by name. Each entry that did not adds one issue.
  mutating func valid<Value>(
    _ items: [String: Lenient<Value>]?,
    in url: URL,
    as itemKind: String
  ) -> [(name: String, value: Value)] {
    var valid: [(name: String, value: Value)] = []
    let names = Array((items ?? [:]).keys)
    for (name, item) in (items ?? [:]).sorted(by: { $0.key < $1.key }) {
      switch item {
      case .valid(let value):
        valid.append((name, value))
      case .invalid(let reason):
        let shown = name.hasPrefix("/") ? Self.projectName(name, among: names) : name
        report(url, "Skipped \(itemKind) \"\(shown)\": \(reason)")
      }
    }
    return valid
  }

  mutating func report(_ url: URL, _ message: String) {
    issues.append(SourceIssue(source: displayPath(url), message: message))
  }

  private func displayPath(_ url: URL) -> String {
    let homePath = home.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    let project = projects.filter { $0 != "/" && $0 != homePath }
      .filter { path == $0 || path.hasPrefix($0 + "/") }
      .max { $0.count < $1.count }
    if let project {
      let name = Self.projectName(project, among: projects)
      return path == project ? name : "\(url.lastPathComponent) in \(name)"
    }
    guard path.hasPrefix(homePath + "/") else { return path }
    return "~" + path.dropFirst(homePath.count)
  }

  /// A project named by its folder, never by its full path. When another known project has a
  /// folder of the same name, the parent folder's name is added.
  static func projectName(_ path: String, among projects: [String]) -> String {
    let url = URL(fileURLWithPath: path)
    let name = url.lastPathComponent
    let isShared = projects.contains {
      $0 != path && URL(fileURLWithPath: $0).lastPathComponent == name
    }
    return isShared ? "\(name) (\(url.deletingLastPathComponent().lastPathComponent))" : name
  }

  static func message(for error: any Error) -> String {
    guard let decodingError = error as? DecodingError else { return "Could not be read" }
    let context: DecodingError.Context
    switch decodingError {
    case .typeMismatch(_, let found), .valueNotFound(_, let found), .keyNotFound(_, let found),
      .dataCorrupted(let found):
      context = found
    @unknown default:
      return "Could not be decoded"
    }
    let path = context.codingPath.map(\.stringValue).joined(separator: ".")
    return path.isEmpty ? "Not valid JSON" : "Unexpected value at \(path)"
  }
}

/// Decodes one entry without failing the file around it.
/// The reason holds fixed wording and a key path, never a decoded value.
enum Lenient<Value: Decodable>: Decodable {
  case valid(Value)
  case invalid(reason: String)

  init(from decoder: any Decoder) throws {
    do {
      self = .valid(try Value(from: decoder))
    } catch {
      self = .invalid(reason: SourceFiles.message(for: error))
    }
  }
}

final class AccessLog {
  var paths: [String] = []
}
