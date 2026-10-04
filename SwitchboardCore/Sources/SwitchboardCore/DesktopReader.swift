import Foundation

/// Reads Claude Desktop's configured servers and installed extensions.
enum DesktopReader {
  private struct Config: Decodable {
    var mcpServers: [String: Lenient<ServerConfig>]?
  }

  private struct ExtensionManifest: Decodable {
    struct Server: Decodable {
      var mcpConfig: ServerConfig?

      enum CodingKeys: String, CodingKey {
        case mcpConfig = "mcp_config"
      }
    }

    var name: String
    var displayName: String?
    var server: Server?

    enum CodingKeys: String, CodingKey {
      case name, server
      case displayName = "display_name"
    }
  }

  private struct ExtensionSettings: Decodable {
    var isEnabled: Bool?
  }

  static func read(_ files: inout SourceFiles) -> [Entry] {
    let root = files.url("Library/Application Support/Claude")
    var entries: [Entry] = []

    let configURL = root.appending(path: "claude_desktop_config.json")
    let config = files.decode(Config.self, at: configURL, required: true)
    for (name, server) in files.valid(config?.mcpServers, in: configURL, as: "server") {
      let launch = Duplicates.launch(of: server, isProgramFile: files.isProgramFile)
      entries.append(
        Entry(
          name: name,
          kind: .server,
          place: .desktop,
          origin: "config",
          state: .on,
          target: launch.target,
          secretNames: launch.secretNames,
          typeLabel: launch.typeLabel,
          switchName: name
        )
      )
    }

    let extensions = root.appending(path: "Claude Extensions")
    for folder in files.children(of: extensions) {
      let manifestURL = extensions.appending(path: folder).appending(path: "manifest.json")
      guard let manifest = files.decode(ExtensionManifest.self, at: manifestURL, required: true)
      else { continue }
      let settings = files.decode(
        ExtensionSettings.self,
        at: root.appending(path: "Claude Extensions Settings").appending(path: "\(folder).json")
      )
      entries.append(
        Entry(
          name: manifest.displayName ?? manifest.name,
          kind: .server,
          place: .desktop,
          origin: "extension",
          state: settings?.isEnabled == false ? .off : .on,
          target: Target(
            mode: .local, label: manifest.name, identity: ["extension", folder]),
          secretNames: Array((manifest.server?.mcpConfig?.env ?? [:]).keys).sorted(),
          typeLabel: "extension",
          // ponytail: an extension without a settings file cannot be switched, because
          // Switchboard never creates a file in Claude Desktop's folders.
          switchName: settings == nil ? nil : folder
        )
      )
    }
    return entries
  }
}
