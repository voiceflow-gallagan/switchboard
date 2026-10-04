import Darwin
import Foundation

/// A project added by `Switches.addProject`, with what it created, so it can be removed exactly.
public struct AddedProject: Hashable, Sendable {
  /// The project's real path, the key Claude Code uses.
  public let path: String
  /// The exact text of the entry that was inserted.
  let entry: String
  /// Plugin keys inserted into the project's personal settings file.
  let plugins: [String]
  let created: Created
  /// The addition created Claude Code's `projects` object, which Undo takes out when empty.
  var createdProjectList = false
}

public struct ProjectOutcome: Sendable {
  public var applied: Bool
  public var issues: [SourceIssue]
  /// What was added, for Undo. Nil when nothing was added.
  public var added: AddedProject?
  /// The copy of Claude Code's file taken before the change.
  public var backup: URL?
}

extension Switches {
  static let emptyProjectSettings = "{\n  \"enabledPlugins\": {}\n}"

  /// Gives a folder that Claude Code has no entry for an entry in its file, keyed by the
  /// folder's real path. With `source`, the entry gets that project's off list, and that
  /// project's plugin settings from its personal settings file are copied. A folder that already
  /// has an entry is refused.
  public static func addProject(
    folder: URL, copyingFrom source: String?, home: URL, supportFolder: URL
  ) -> ProjectOutcome {
    addProject(
      folder: folder, copyingFrom: source, home: home, supportFolder: supportFolder,
      beforeReadingBack: {})
  }

  /// `beforeReadingBack` lets tests change the file between the write and the read back.
  static func addProject(
    folder: URL, copyingFrom source: String?, home: URL, supportFolder: URL,
    beforeReadingBack: () -> Void
  ) -> ProjectOutcome {
    guard let path = Paths.realPath(folder.path), isDirectory(path) else {
      return projectFailure(
        projectLabel(folder.path, home: home), "Folder not found. Nothing was changed.")
    }
    guard let current = text(of: claudeCodeFile, home: home) else {
      return projectFailure("~/" + claudeCodeFile, "Could not be read. Nothing was changed.")
    }
    let known = JSONText.members(at: ["projects"], in: current)?.map(\.name) ?? []
    let projects = known + [path]
    if JSONText.hasMember(at: ["projects"], in: current) != false {
      for candidate in [path, folder.path] {
        switch JSONText.hasMember(at: ["projects", candidate], in: current) {
        case false?:
          continue
        case true?:
          return projectFailure(
            SourceFiles.projectName(candidate, among: known + [candidate]),
            "Claude Code already has this project. Nothing was changed.")
        case nil:
          return projectFailure(
            "~/" + claudeCodeFile, "Does not have the expected shape. Nothing was changed.")
        }
      }
    }
    var offList: [String] = []
    var plugins: [(id: String, on: Bool)] = []
    if let source {
      guard JSONText.hasMember(at: ["projects", source], in: current) == true else {
        return projectFailure(
          SourceFiles.projectName(source, among: known + [source]),
          "The project to copy from was not found. Nothing was changed.")
      }
      offList = JSONText.strings(at: ["projects", source, "disabledMcpServers"], in: current) ?? []
      plugins = projectPlugins(source, home: home)
    }

    var createdProjectList = false
    let result = ConfigWriter.change(
      claudeCodeFile, home: home, supportFolder: supportFolder,
      edit: { text in
        var edited = text
        createdProjectList = JSONText.hasMember(at: ["projects"], in: text) == false
        if createdProjectList {
          guard let withProjects = JSONText.insertMember("{}", named: "projects", at: [], in: text)
          else { return nil }
          edited = withProjects
        }
        guard JSONText.hasMember(at: ["projects", path], in: edited) == false,
          let withEntry = JSONText.insertMember("{}", named: path, at: ["projects"], in: edited),
          let withList = JSONText.insertMember(
            "[]", named: "disabledMcpServers", at: ["projects", path], in: withEntry)
        else { return nil }
        edited = withList
        for name in offList {
          guard
            let added = JSONText.addString(
              name, toArrayAt: ["projects", path, "disabledMcpServers"], in: edited)
          else { return nil }
          edited = added
        }
        return edited
      },
      isInEffect: { JSONText.hasMember(at: ["projects", path], in: $0) == true })
    guard result.issues.isEmpty else {
      return ProjectOutcome(
        applied: false, issues: result.issues, added: nil, backup: result.backup)
    }
    beforeReadingBack()
    guard
      let entry = text(of: claudeCodeFile, home: home).flatMap({
        JSONText.removeMember(at: ["projects", path], in: $0)?.removed
      })
    else {
      let issue = SourceIssue(
        source: SourceFiles.projectName(path, among: projects),
        message:
          "Was added, but could not be read back. A running Claude Code session may have removed it."
      )
      return ProjectOutcome(applied: false, issues: [issue], added: nil, backup: result.backup)
    }

    var added = AddedProject(
      path: path, entry: entry, plugins: [], created: [], createdProjectList: createdProjectList)
    if !plugins.isEmpty {
      let set = setPlugins(
        plugins, project: path, projects: projects, home: home, support: supportFolder)
      guard set.result.issues.isEmpty else {
        let removed = removeProject(added, home: home, supportFolder: supportFolder)
        return ProjectOutcome(
          applied: false, issues: set.result.issues + removed.issues, added: nil,
          backup: result.backup)
      }
      added = AddedProject(
        path: path, entry: entry, plugins: set.inserted, created: set.created,
        createdProjectList: createdProjectList)
    }
    return ProjectOutcome(applied: true, issues: [], added: added, backup: result.backup)
  }

  /// Undoes `addProject`: removes the entry, then the plugin keys and anything it created in
  /// the project's personal settings. Nothing is removed when Claude Code has changed the entry
  /// since.
  public static func removeProject(_ added: AddedProject, home: URL, supportFolder: URL)
    -> ProjectOutcome
  {
    let path = ["projects", added.path]
    guard let current = text(of: claudeCodeFile, home: home) else {
      return projectFailure("~/" + claudeCodeFile, "Could not be read. Nothing was changed.")
    }
    let projects =
      (JSONText.members(at: ["projects"], in: current)?.map(\.name) ?? []) + [added.path]
    switch JSONText.removeMember(at: path, in: current)?.removed {
    case nil:
      let isGone =
        JSONText.hasMember(at: ["projects"], in: current) == false
        || JSONText.hasMember(at: path, in: current) == false
      guard isGone else {
        return projectFailure(
          "~/" + claudeCodeFile, "Does not have the expected shape. The project was not removed.")
      }
      return ProjectOutcome(applied: true, issues: [], added: nil, backup: nil)
    case let entry? where !entry.isIdentical(to: added.entry):
      return projectFailure(
        SourceFiles.projectName(added.path, among: projects),
        "Claude Code has changed this project since it was added. It was not removed.")
    default:
      break
    }
    let result = ConfigWriter.change(
      claudeCodeFile, home: home, supportFolder: supportFolder,
      edit: { text in
        guard let removal = JSONText.removeMember(at: path, in: text),
          removal.removed.isIdentical(to: added.entry)
        else { return nil }
        if added.createdProjectList,
          JSONText.members(at: ["projects"], in: removal.text)?.isEmpty == true,
          let withoutProjects = JSONText.removeMember(at: ["projects"], in: removal.text)
        {
          return withoutProjects.text
        }
        return removal.text
      },
      isInEffect: { JSONText.hasMember(at: path, in: $0) != true })
    guard result.issues.isEmpty else {
      return ProjectOutcome(
        applied: false, issues: result.issues, added: nil, backup: result.backup)
    }
    let settings = removePlugins(
      added.plugins, created: added.created, project: added.path, projects: projects, home: home,
      supportFolder: supportFolder)
    return ProjectOutcome(
      applied: settings.issues.isEmpty, issues: settings.issues, added: nil,
      backup: result.backup)
  }

  /// `beforeCompare` lets tests act right before the file is replaced.
  static func pluginInProject(
    _ id: String, project: String, on: Bool, removing: Created, home: URL, support: URL,
    beforeCompare: () -> Void = {}
  ) -> SwitchOutcome {
    let projects = knownProjects(home: home) + [project]
    guard project.hasPrefix("/"), isDirectory(project) else {
      return failure(
        SourceFiles.projectName(project, among: projects),
        "Project folder not found. Nothing was changed.")
    }
    if removing.contains(.key) {
      let result = removePlugins(
        [id], created: removing, project: project, projects: projects, home: home,
        supportFolder: support)
      return SwitchOutcome(
        applied: result.issues.isEmpty, issues: result.issues,
        undo: result.backup == nil ? nil : .pluginInProject(id: id, project: project, on: !on),
        backup: result.backup, wrote: result.backup != nil)
    }
    let set = setPlugins(
      [(id, on)], project: project, projects: projects, home: home, support: support,
      beforeCompare: beforeCompare)
    let wrote = set.result.backup != nil
    return SwitchOutcome(
      applied: set.result.issues.isEmpty, issues: set.result.issues,
      undo: wrote
        ? .pluginInProject(id: id, project: project, on: !on, removing: set.created) : nil,
      backup: set.result.backup, wrote: wrote, created: set.created)
  }

  static func isPluginInProjectInEffect(_ id: String, project: String, on: Bool, removing: Created)
    -> Bool?
  {
    guard let url = safeSettingsURL(project) else { return nil }
    guard FileManager.default.fileExists(atPath: url.path) else {
      return removing.contains(.key) ? true : false
    }
    guard let text = text(of: url.path, home: URL(fileURLWithPath: project)) else { return nil }
    if removing.contains(.key) {
      return JSONText.hasMember(at: ["enabledPlugins", id], in: text).map { !$0 }
    }
    return JSONText.setBool(on, at: ["enabledPlugins", id], in: text).map { $0 == text }
  }

  /// Sets each plugin in the project's personal settings file, creating the `.claude` folder,
  /// the file, and its `enabledPlugins` object when they are missing. When writing fails, what
  /// was created is removed again. `projects` are the known projects, with `project`, for
  /// naming it in issues.
  private static func setPlugins(
    _ values: [(id: String, on: Bool)], project: String, projects: [String], home: URL,
    support: URL, beforeCompare: () -> Void = {}
  ) -> (result: ConfigWriter.Result, created: Created, inserted: [String]) {
    guard let url = safeSettingsURL(project) else {
      return (ConfigWriter.Result(issues: [linkIssue(project, among: projects)]), [], [])
    }
    let folder = url.deletingLastPathComponent()
    var created: Created = []
    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: url.path) {
      do {
        if !isDirectory(folder.path) {
          try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
          created.insert(.folder)
        }
        guard safeSettingsURL(project) != nil else {
          removeCreated(created, file: url)
          return (ConfigWriter.Result(issues: [linkIssue(project, among: projects)]), [], [])
        }
        try Data(emptyProjectSettings.utf8).write(to: url, options: .withoutOverwriting)
        created.insert(.file)
      } catch {
        removeCreated(created, file: url)
        return (
          ConfigWriter.Result(issues: [
            SourceIssue(
              source:
                "\(url.lastPathComponent) in \(SourceFiles.projectName(project, among: projects))",
              message: "Could not be created. Nothing was changed.")
          ]), [], []
        )
      }
    }
    var files = SourceFiles(home: home)
    files.projects = projects
    guard let current = ConfigWriter.readJSON(url, files: &files) else {
      removeCreated(created, file: url)
      return (ConfigWriter.Result(issues: files.issues), [], [])
    }
    if JSONText.hasMember(at: ["enabledPlugins"], in: current.text) == false {
      created.insert(.object)
    }
    let inserted = values.map(\.id).filter {
      JSONText.hasMember(at: ["enabledPlugins", $0], in: current.text) != true
    }
    if !inserted.isEmpty {
      created.insert(.key)
    }
    let result = ConfigWriter.change(
      url.path, home: home, supportFolder: support, projects: projects,
      edit: { text in
        var edited = text
        if JSONText.hasMember(at: ["enabledPlugins"], in: edited) == false {
          guard
            let withObject = JSONText.insertMember(
              "{}", named: "enabledPlugins", at: [], in: edited)
          else { return nil }
          edited = withObject
        }
        for value in values {
          guard let set = JSONText.setBool(value.on, at: ["enabledPlugins", value.id], in: edited)
          else { return nil }
          edited = set
        }
        return edited
      },
      isSafeTarget: { safeSettingsURL(project) != nil },
      beforeCompare: beforeCompare)
    guard result.issues.isEmpty else {
      removeCreated(created, file: url)
      return (result, [], [])
    }
    return (result, result.backup == nil ? [] : created, result.backup == nil ? [] : inserted)
  }

  /// Removes `keys` from the project's personal settings file, then the `enabledPlugins` object,
  /// the file, and the `.claude` folder when `created` says a change created them and they hold
  /// nothing else. The file is backed up before it is changed or removed.
  private static func removePlugins(
    _ keys: [String], created: Created, project: String, projects: [String], home: URL,
    supportFolder: URL
  ) -> ConfigWriter.Result {
    guard let url = safeSettingsURL(project) else {
      return ConfigWriter.Result(issues: [linkIssue(project, among: projects)])
    }
    guard FileManager.default.fileExists(atPath: url.path) else {
      return ConfigWriter.Result(issues: [])
    }
    let edit: (String) -> String? = { text in
      var edited = text
      for key in keys where JSONText.hasMember(at: ["enabledPlugins", key], in: edited) == true {
        guard let removal = JSONText.removeMember(at: ["enabledPlugins", key], in: edited) else {
          return nil
        }
        edited = removal.text
      }
      if created.contains(.object),
        JSONText.members(at: ["enabledPlugins"], in: edited)?.isEmpty == true,
        let removal = JSONText.removeMember(at: ["enabledPlugins"], in: edited)
      {
        edited = removal.text
      }
      return edited
    }
    var files = SourceFiles(home: home)
    files.projects = projects
    guard let current = ConfigWriter.readJSON(url, files: &files) else {
      return ConfigWriter.Result(issues: files.issues)
    }
    guard let final = edit(current.text) else {
      files.report(url, "Does not have the expected shape. Nothing was changed.")
      return ConfigWriter.Result(issues: files.issues)
    }
    guard created.contains(.file), holdsNothingElse(final) else {
      return ConfigWriter.change(
        url.path, home: home, supportFolder: supportFolder, projects: projects, edit: edit,
        isSafeTarget: { safeSettingsURL(project) != nil })
    }
    let backup: URL
    do {
      backup = try Backups.save(current.data, of: url.path, supportFolder: supportFolder)
    } catch {
      files.report(url, "Could not be backed up. Nothing was changed.")
      return ConfigWriter.Result(issues: files.issues)
    }
    // ponytail: `created` is trusted as recorded. A file the user recreated since, holding only
    // the same single key, is removed as if Switchboard had created it.
    guard ConfigWriter.contents(of: url, home: home) == current.data, unlink(url.path) == 0 else {
      try? FileManager.default.removeItem(at: backup)
      files.report(url, "Changed while removing it. Nothing was changed.")
      return ConfigWriter.Result(issues: files.issues)
    }
    if created.contains(.folder) {
      rmdir(url.deletingLastPathComponent().path)
    }
    return ConfigWriter.Result(backup: backup, issues: [])
  }

  /// Whether settings text holds nothing but an empty `enabledPlugins`, or nothing at all.
  private static func holdsNothingElse(_ text: String) -> Bool {
    guard let members = JSONText.members(at: [], in: text) else { return false }
    return members.allSatisfy { $0.name.isIdentical(to: "enabledPlugins") }
      && JSONText.members(at: ["enabledPlugins"], in: text)?.isEmpty != false
  }

  /// Removes a file and folder that were just created, when the file still holds only what
  /// Switchboard wrote and the folder is empty.
  private static func removeCreated(_ created: Created, file: URL) {
    if created.contains(.file),
      ConfigWriter.contents(of: file, home: file) == Data(emptyProjectSettings.utf8)
    {
      unlink(file.path)
    }
    if created.contains(.folder) {
      rmdir(file.deletingLastPathComponent().path)
    }
  }

  /// The plugin settings in a project's personal settings file, as literal booleans only.
  private static func projectPlugins(_ project: String, home: URL) -> [(id: String, on: Bool)] {
    guard let url = safeSettingsURL(project),
      let data = ConfigWriter.contents(of: url, home: home),
      let text = String(data: data, encoding: .utf8)
    else { return [] }
    return (JSONText.members(at: ["enabledPlugins"], in: text) ?? []).compactMap { member in
      switch member.value {
      case "true": (member.name, true)
      case "false": (member.name, false)
      default: nil
      }
    }
  }

  /// The project paths Claude Code's file has entries for.
  static func knownProjects(home: URL) -> [String] {
    text(of: claudeCodeFile, home: home).flatMap {
      JSONText.members(at: ["projects"], in: $0)?.map(\.name)
    } ?? []
  }

  /// A project named for an issue: its folder name, never its path.
  static func projectLabel(_ path: String, home: URL) -> String {
    SourceFiles.projectName(path, among: knownProjects(home: home) + [path])
  }

  /// The project's personal settings file, or nil when the `.claude` folder or the file is a
  /// symbolic link, or the file would lie outside the project's real folder. A cloned
  /// repository could otherwise point either at any JSON file the user can write.
  static func safeSettingsURL(_ project: String) -> URL? {
    let url = settingsURL(project)
    let folder = url.deletingLastPathComponent()
    guard let root = Paths.realPath(project) else { return nil }
    for item in [folder, url] {
      let type = (try? FileManager.default.attributesOfItem(atPath: item.path))?[.type]
      if type as? FileAttributeType == .typeSymbolicLink { return nil }
      if let resolved = Paths.realPath(item.path), !resolved.hasPrefix(root + "/") { return nil }
    }
    return url
  }

  static func linkIssue(_ project: String, among projects: [String]) -> SourceIssue {
    SourceIssue(
      source: "settings.local.json in \(SourceFiles.projectName(project, among: projects))",
      message: "Is a symbolic link or leaves the project. Nothing was changed.")
  }

  static func settingsURL(_ project: String) -> URL {
    URL(fileURLWithPath: project).appending(path: projectSettingsFile)
  }

  private static func isDirectory(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  private static func projectFailure(_ source: String, _ message: String) -> ProjectOutcome {
    ProjectOutcome(
      applied: false, issues: [SourceIssue(source: source, message: message)], added: nil,
      backup: nil)
  }
}
