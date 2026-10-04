import Foundation

/// Reads Claude Code's servers, plugins, and skills at user, project, and plugin level.
enum ClaudeCodeReader {
  struct Result {
    var entries: [Entry]
    var projects: [String]
    var projectAliases: [String: String] = [:]
    var cloudHistory: [String]
  }

  private struct Config: Decodable {
    var mcpServers: [String: Lenient<ServerConfig>]?
    var projects: [String: Lenient<ProjectConfig>]?
    var claudeAiMcpEverConnected: Lenient<[String]>?
  }

  private struct ProjectConfig: Decodable {
    var mcpServers: [String: Lenient<ServerConfig>]?
    var disabledMcpServers: [String]?
    var enabledMcpjsonServers: [String]?
    var disabledMcpjsonServers: [String]?
  }

  private struct Settings: Decodable {
    var enabledPlugins: [String: Lenient<Bool>]?
    var enableAllProjectMcpServers: Bool?
    var enabledMcpjsonServers: [String]?
    var disabledMcpjsonServers: [String]?
  }

  private struct InstalledPlugins: Decodable {
    struct Install: Decodable {
      var scope: String?
      var installPath: String
      var projectPath: String?
    }

    var plugins: [String: Lenient<[Install]>]?
  }

  private struct PluginManifest: Decodable {
    var mcpServers: ServerSource?
    var skills: Paths?
  }

  private struct KnownMarketplace: Decodable {
    var installLocation: String?
  }

  private struct Marketplace: Decodable {
    struct Plugin: Decodable {
      var name: String
      var skills: Paths?
    }

    var plugins: [Lenient<Plugin>]?
  }

  /// Either `{"mcpServers": {...}}` or the server map itself.
  private struct ServerFile: Decodable {
    private struct Wrapped: Decodable {
      var mcpServers: [String: Lenient<ServerConfig>]?
    }

    var servers: [String: Lenient<ServerConfig>]

    init(from decoder: any Decoder) throws {
      if let wrapped = try Wrapped(from: decoder).mcpServers {
        servers = wrapped
      } else {
        servers = try [String: Lenient<ServerConfig>](from: decoder)
      }
    }
  }

  /// A plugin manifest's `mcpServers`: inline servers or a path to a server file.
  private enum ServerSource: Decodable {
    case servers([String: Lenient<ServerConfig>])
    case path(String)

    init(from decoder: any Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let path = try? container.decode(String.self) {
        self = .path(path)
      } else {
        self = .servers(try container.decode([String: Lenient<ServerConfig>].self))
      }
    }
  }

  /// One path or a list of paths.
  private struct Paths: Decodable {
    var values: [String]

    init(from decoder: any Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let single = try? container.decode(String.self) {
        values = [single]
      } else {
        values = try container.decode([String].self)
      }
    }
  }

  /// The settings that decide state inside one project, merged from all files that set them.
  private struct ProjectRules {
    var disabledServers: Set<String> = []
    var enabledPlugins: [String: Bool] = [:]
    var enableAllMcpjson = false
    var enabledMcpjson: Set<String> = []
    var disabledMcpjson: Set<String> = []
  }

  /// Where a plugin is on, shared by the plugin and everything it ships.
  private struct Placement {
    var place: Place
    var state: Presence
    var projectOverrides: [String: Presence]
  }

  static func read(_ files: inout SourceFiles, includingProjects: Bool = true) -> Result {
    let configURL = files.url(".claude.json")
    let config = files.decode(Config.self, at: configURL, required: true)
    let userSettingsURL = files.url(".claude/settings.json")
    let userSettings = files.decode(Settings.self, at: userSettingsURL, required: true)
    let userPlugins = enabledPlugins(userSettings, at: userSettingsURL, files: &files)
    files.projects = Array((config?.projects ?? [:]).keys)
    let projectConfigs = Dictionary(
      uniqueKeysWithValues: files.valid(config?.projects, in: configURL, as: "project"))
    let projects =
      includingProjects
      ? projectConfigs.keys.filter { files.isDirectory(URL(fileURLWithPath: $0)) }.sorted()
      : projectConfigs.keys.sorted()
    var readable: Set<String> = []
    if includingProjects {
      for path in projects {
        if files.isReadable(URL(fileURLWithPath: path)) {
          readable.insert(path)
        } else {
          files.report(URL(fileURLWithPath: path), "Project folder could not be read")
        }
      }
    }

    var rules: [String: ProjectRules] = [:]
    for path in projects {
      rules[path] = projectRules(
        path, config: projectConfigs[path], user: userSettings,
        readingFiles: readable.contains(path), files: &files)
    }

    if !includingProjects {
      files.skippedFolders = projects.filter { $0 != "/" && $0 != files.home.path }
    }
    var entries = userServers(
      files.valid(config?.mcpServers, in: configURL, as: "server"), rules: rules, files: files)
    for path in projects {
      entries += projectServers(
        path, config: projectConfigs[path], configURL: configURL,
        rules: rules[path] ?? ProjectRules(), readingFiles: readable.contains(path), files: &files)
      if path != files.home.path, readable.contains(path) {
        entries += skills(
          in: URL(fileURLWithPath: path).appending(path: ".claude/skills"), files: &files
        ).map {
          Entry(
            name: $0.name,
            kind: .skill,
            place: .project(path: path),
            origin: "project",
            state: .on,
            typeLabel: "project",
            description: $0.description
          )
        }
      }
    }
    entries += plugins(
      userSettings: userSettings, userPlugins: userPlugins, rules: rules,
      projectConfigs: projectConfigs, includingProjects: includingProjects, files: &files)
    entries += skills(in: files.url(".claude/skills"), files: &files).map {
      Entry(
        name: $0.name,
        kind: .skill,
        place: .claudeCode,
        origin: "user",
        state: .on,
        typeLabel: "user",
        description: $0.description
      )
    }

    var connectors: [String] = []
    switch config?.claudeAiMcpEverConnected {
    case .valid(let names):
      connectors = names
    case .invalid(let reason):
      files.report(configURL, "Skipped cloud connector history: \(reason)")
    case nil:
      break
    }
    let prefix = "claude.ai "
    let cloudHistory = Set(
      connectors.map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 }
    ).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    var aliases: [String: String] = [:]
    for path in readable {
      let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
      if resolved != path {
        aliases[resolved] = path
      }
    }
    return Result(
      entries: entries, projects: projects, projectAliases: aliases, cloudHistory: cloudHistory)
  }

  private static func projectRules(
    _ path: String,
    config: ProjectConfig?,
    user: Settings?,
    readingFiles: Bool,
    files: inout SourceFiles
  ) -> ProjectRules {
    let folder = URL(fileURLWithPath: path).appending(path: ".claude")
    let shared =
      readingFiles ? files.decode(Settings.self, at: folder.appending(path: "settings.json")) : nil
    let local =
      readingFiles
      ? files.decode(Settings.self, at: folder.appending(path: "settings.local.json")) : nil
    var rules = ProjectRules()
    rules.disabledServers = Set(config?.disabledMcpServers ?? [])
    rules.enabledPlugins = enabledPlugins(
      shared, at: folder.appending(path: "settings.json"), files: &files
    ).merging(
      enabledPlugins(local, at: folder.appending(path: "settings.local.json"), files: &files)
    ) { $1 }
    rules.enableAllMcpjson =
      local?.enableAllProjectMcpServers ?? shared?.enableAllProjectMcpServers ?? user?
      .enableAllProjectMcpServers
      ?? false
    for source in [
      config?.enabledMcpjsonServers, shared?.enabledMcpjsonServers, local?.enabledMcpjsonServers,
    ] {
      rules.enabledMcpjson.formUnion(source ?? [])
    }
    for source in [
      config?.disabledMcpjsonServers, shared?.disabledMcpjsonServers, local?.disabledMcpjsonServers,
    ] {
      rules.disabledMcpjson.formUnion(source ?? [])
    }
    return rules
  }

  private static func enabledPlugins(
    _ settings: Settings?, at url: URL, files: inout SourceFiles
  ) -> [String: Bool] {
    Dictionary(
      uniqueKeysWithValues: files.valid(settings?.enabledPlugins, in: url, as: "plugin setting"))
  }

  private static func userServers(
    _ servers: [(name: String, value: ServerConfig)], rules: [String: ProjectRules],
    files: SourceFiles
  ) -> [Entry] {
    servers.map { name, server in
      let launch = Duplicates.launch(of: server, isProgramFile: files.isProgramFile)
      var overrides: [String: Presence] = [:]
      for (path, rule) in rules where rule.disabledServers.contains(name) {
        overrides[path] = .off
      }
      return Entry(
        name: name,
        kind: .server,
        place: .claudeCode,
        origin: "user",
        state: .on,
        target: launch.target,
        secretNames: launch.secretNames,
        typeLabel: launch.typeLabel,
        projectOverrides: overrides,
        switchName: name,
        listedOffIn: Set(overrides.keys)
      )
    }
  }

  private static func projectServers(
    _ path: String,
    config: ProjectConfig?,
    configURL: URL,
    rules: ProjectRules,
    readingFiles: Bool,
    files: inout SourceFiles
  ) -> [Entry] {
    var entries: [Entry] = []
    for (name, server) in files.valid(config?.mcpServers, in: configURL, as: "server") {
      let isListed = rules.disabledServers.contains(name)
      entries.append(
        serverEntry(
          name,
          server,
          origin: "project",
          place: .project(path: path),
          state: isListed ? .off : .on,
          listedOffIn: isListed ? [path] : [],
          files: files
        )
      )
    }

    let fileURL = URL(fileURLWithPath: path).appending(path: ".mcp.json")
    let file = readingFiles ? files.decode(ServerFile.self, at: fileURL) : nil
    for (name, server) in files.valid(file?.servers, in: fileURL, as: "server") {
      let isListed = rules.disabledServers.contains(name)
      let isOffInFile = rules.disabledMcpjson.contains(name)
      let isApproved = rules.enableAllMcpjson || rules.enabledMcpjson.contains(name)
      entries.append(
        serverEntry(
          name,
          server,
          origin: ".mcp.json",
          place: .project(path: path),
          state: !isListed && !isOffInFile && isApproved ? .on : .off,
          listedOffIn: isListed && !isOffInFile && isApproved ? [path] : [],
          files: files
        )
      )
    }
    return entries
  }

  private static func serverEntry(
    _ name: String,
    _ server: ServerConfig,
    origin: String,
    place: Place,
    state: Presence,
    typeLabel: String? = nil,
    projectOverrides: [String: Presence] = [:],
    switchName: String? = nil,
    listedOffIn: Set<String> = [],
    files: SourceFiles
  ) -> Entry {
    let launch = Duplicates.launch(of: server, isProgramFile: files.isProgramFile)
    return Entry(
      name: name,
      kind: .server,
      place: place,
      origin: origin,
      state: state,
      target: launch.target,
      secretNames: launch.secretNames,
      typeLabel: typeLabel ?? launch.typeLabel,
      projectOverrides: projectOverrides,
      switchName: switchName ?? name,
      listedOffIn: listedOffIn
    )
  }

  private static func plugins(
    userSettings: Settings?,
    userPlugins: [String: Bool],
    rules: [String: ProjectRules],
    projectConfigs: [String: ProjectConfig],
    includingProjects: Bool,
    files: inout SourceFiles
  ) -> [Entry] {
    let pluginsFolder = files.url(".claude/plugins")
    let installedURL = pluginsFolder.appending(path: "installed_plugins.json")
    let installed = files.decode(InstalledPlugins.self, at: installedURL, required: true)
    let marketplaces =
      files.decode(
        [String: KnownMarketplace].self,
        at: pluginsFolder.appending(path: "known_marketplaces.json"))
      ?? [:]
    var marketplaceSkills: [String: [String: [String]]] = [:]

    var entries: [Entry] = []
    for (id, installs) in files.valid(installed?.plugins, in: installedURL, as: "plugin") {
      let name = String(id.prefix { $0 != "@" })
      let marketplace = String(id.drop { $0 != "@" }.dropFirst())
      if marketplaceSkills[marketplace] == nil {
        marketplaceSkills[marketplace] = declaredSkills(
          in: marketplaces[marketplace], files: &files)
      }

      for install in installs {
        let placement: Placement
        if let projectPath = install.projectPath, install.scope != "user" {
          let rule =
            rules[projectPath]
            ?? projectRules(
              projectPath, config: projectConfigs[projectPath], user: userSettings,
              readingFiles: includingProjects
                && files.isReadable(URL(fileURLWithPath: projectPath)),
              files: &files)
          placement = Placement(
            place: .project(path: projectPath),
            state: rule.enabledPlugins[id] == true ? .on : .off,
            projectOverrides: [:]
          )
        } else {
          let state: Presence = userPlugins[id] == true ? .on : .off
          var overrides: [String: Presence] = [:]
          for (path, rule) in rules {
            if let enabled = rule.enabledPlugins[id], (enabled ? Presence.on : .off) != state {
              overrides[path] = enabled ? .on : .off
            }
          }
          placement = Placement(place: .claudeCode, state: state, projectOverrides: overrides)
        }

        entries.append(
          Entry(
            name: name,
            kind: .plugin,
            place: placement.place,
            origin: install.scope ?? "user",
            state: placement.state,
            typeLabel: marketplace,
            projectOverrides: placement.projectOverrides,
            switchName: id
          )
        )

        let root = URL(fileURLWithPath: install.installPath)
        let manifest = files.decode(
          PluginManifest.self, at: root.appending(path: ".claude-plugin/plugin.json"))
        entries += pluginServers(
          name, root: root, manifest: manifest, placement: placement, rules: rules, files: &files)

        let manifestURL = root.appending(path: ".claude-plugin/plugin.json")
        let declaredPaths =
          (manifest?.skills?.values ?? []).map { ($0, manifestURL) }
          + (marketplaceSkills[marketplace]?[name] ?? []).map {
            ($0, marketplaceURL(marketplaces[marketplace]) ?? manifestURL)
          }
        let skillFolders =
          [root.appending(path: "skills")]
          + declaredPaths.compactMap { files.path($0, inside: root, declaredIn: $1) }
        var seenFolders: Set<String> = []
        var seen: Set<String> = []
        for folder in skillFolders
        where seenFolders.insert(folder.standardizedFileURL.path).inserted {
          for skill in skills(in: folder, files: &files)
          where seen.insert(skill.folder.standardizedFileURL.path).inserted {
            entries.append(
              Entry(
                name: "\(name):\(skill.name)",
                kind: .skill,
                place: placement.place,
                origin: "plugin \(name)",
                state: placement.state,
                typeLabel: "plugin \(name)",
                description: skill.description,
                projectOverrides: placement.projectOverrides
              )
            )
          }
        }
      }
    }
    return entries
  }

  /// The folders installed plugins point to, from `installed_plugins.json`.
  static func installPaths(_ files: inout SourceFiles) -> [String] {
    let url = files.url(".claude/plugins/installed_plugins.json")
    let installed = files.decode(InstalledPlugins.self, at: url, required: true)
    return files.valid(installed?.plugins, in: url, as: "plugin").flatMap {
      $0.value.map(\.installPath)
    }
  }

  /// Skill paths a marketplace declares for its plugins, keyed by plugin name.
  private static func declaredSkills(in marketplace: KnownMarketplace?, files: inout SourceFiles)
    -> [String: [String]]
  {
    guard let url = marketplaceURL(marketplace) else { return [:] }
    var declared: [String: [String]] = [:]
    for (index, plugin) in (files.decode(Marketplace.self, at: url)?.plugins ?? []).enumerated() {
      switch plugin {
      case .valid(let plugin):
        declared[plugin.name] = declared[plugin.name] ?? plugin.skills?.values ?? []
      case .invalid(let reason):
        files.report(url, "Skipped marketplace plugin \(index): \(reason)")
      }
    }
    return declared
  }

  private static func marketplaceURL(_ marketplace: KnownMarketplace?) -> URL? {
    marketplace?.installLocation.map {
      URL(fileURLWithPath: $0).appending(path: ".claude-plugin/marketplace.json")
    }
  }

  /// Claude Code replaces `${CLAUDE_PLUGIN_ROOT}` with the plugin's folder before it starts a
  /// server, so the target is built from the same text.
  private static func expandingPluginRoot(_ server: ServerConfig, root: URL) -> ServerConfig {
    var expanded = server
    let replace = { (text: String) in
      text.replacingOccurrences(of: "${CLAUDE_PLUGIN_ROOT}", with: root.path)
    }
    expanded.command = server.command.map(replace)
    expanded.args = server.args?.map(replace)
    return expanded
  }

  private static func pluginServers(
    _ plugin: String,
    root: URL,
    manifest: PluginManifest?,
    placement: Placement,
    rules: [String: ProjectRules],
    files: inout SourceFiles
  ) -> [Entry] {
    let fileURL = root.appending(path: ".mcp.json")
    var servers: [String: ServerConfig] = [:]
    for (name, server) in files.valid(
      files.decode(ServerFile.self, at: fileURL)?.servers, in: fileURL, as: "server")
    {
      servers[name] = server
    }
    let manifestURL = root.appending(path: ".claude-plugin/plugin.json")
    let declared: [(name: String, value: ServerConfig)]
    switch manifest?.mcpServers {
    case .servers(let inline):
      declared = files.valid(inline, in: manifestURL, as: "server")
    case .path(let path):
      if let url = files.path(path, inside: root, declaredIn: manifestURL) {
        declared = files.valid(
          files.decode(ServerFile.self, at: url, required: true)?.servers, in: url, as: "server")
      } else {
        declared = []
      }
    case nil:
      declared = []
    }
    for (name, server) in declared {
      servers[name] = server
    }

    return servers.sorted { $0.key < $1.key }.map { name, configured in
      let server = expandingPluginRoot(configured, root: root)
      let key = "plugin:\(plugin):\(name)"
      var state = placement.state
      var overrides = placement.projectOverrides
      var listedOffIn: Set<String> = []
      switch placement.place {
      case .project(let path):
        if rules[path]?.disabledServers.contains(key) == true {
          if state == .on {
            listedOffIn.insert(path)
          }
          state = .off
        }
      default:
        for (path, rule) in rules where rule.disabledServers.contains(key) {
          if (overrides[path] ?? state) == .on {
            listedOffIn.insert(path)
          }
          overrides[path] = .off
        }
      }
      return serverEntry(
        name,
        server,
        origin: "plugin \(plugin)",
        place: placement.place,
        state: state,
        typeLabel: "plugin \(plugin)",
        projectOverrides: overrides,
        switchName: key,
        listedOffIn: listedOffIn,
        files: files
      )
    }
  }

  private struct Skill {
    var folder: URL
    var name: String
    var description: String?
  }

  /// `folder` itself when it holds a `SKILL.md`, otherwise each child folder that does.
  private static func skills(in folder: URL, files: inout SourceFiles) -> [Skill] {
    if files.fileExists(folder.appending(path: "SKILL.md")) {
      return [skill(at: folder, files: &files)]
    }
    var found: [Skill] = []
    for child in files.children(of: folder) {
      let childFolder = folder.appending(path: child)
      if files.fileExists(childFolder.appending(path: "SKILL.md")) {
        found.append(skill(at: childFolder, files: &files))
      }
    }
    return found
  }

  private static func skill(at folder: URL, files: inout SourceFiles) -> Skill {
    let data = files.read(folder.appending(path: "SKILL.md")) ?? Data()
    let text = String(decoding: data, as: UTF8.self)
    let frontMatter = parseFrontMatter(text)
    return Skill(
      folder: folder,
      name: frontMatter["name"] ?? folder.lastPathComponent,
      description: frontMatter["description"]
    )
  }

  // ponytail: reads only `name` and `description` as plain, quoted, or indented block scalars.
  // Other YAML forms such as flow mappings or escapes inside quotes come through as raw text.
  static func parseFrontMatter(_ text: String) -> [String: String] {
    var lines: [String] = []
    text.enumerateLines { line, stop in
      lines.append(line)
      let isMarker = line.trimmingCharacters(in: .whitespaces) == "---"
      stop = lines.count == 1 ? !isMarker : isMarker
    }
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }

    var values: [String: String] = [:]
    var index = 1
    while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) != "---" {
      let line = lines[index]
      index += 1
      guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else {
        continue
      }
      let key = String(line[..<colon])
      guard key == "name" || key == "description" else { continue }

      var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      if value.isEmpty || value.hasPrefix("|") || value.hasPrefix(">") {
        var block: [String] = []
        while index < lines.count,
          lines[index].hasPrefix(" ") || lines[index].hasPrefix("\t") || lines[index].isEmpty
        {
          let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
          if !trimmed.isEmpty {
            block.append(trimmed)
          }
          index += 1
        }
        value = block.joined(separator: " ")
      } else if value.count >= 2, let first = value.first, first == "\"" || first == "'",
        value.last == first
      {
        value = String(value.dropFirst().dropLast())
      }
      values[key] = value
    }
    return values
  }
}
