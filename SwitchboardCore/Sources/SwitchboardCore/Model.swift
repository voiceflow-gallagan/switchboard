import CryptoKit
import Foundation

public enum Kind: String, CaseIterable, Sendable {
  case server, plugin, skill
}

public enum Place: Hashable, Sendable {
  case desktop
  case claudeCode
  case project(path: String)
}

/// `absent` means the item is not configured in that place.
public enum Presence: Sendable {
  case on, off, absent
}

/// What a server launches or reaches. Two servers with an equal target are duplicates.
public struct Target: Hashable, Sendable {
  public enum Mode: Hashable, Sendable {
    case remote, local
  }

  public let mode: Mode
  /// Safe to display: the host and port of an address, or a program and package name.
  public let label: String
  /// SHA-256 hex digest of the full identity, which may hold credentials. Never shown.
  public let key: String

  init(mode: Mode, label: String, identity: [String]) {
    self.mode = mode
    self.label = label
    let digest = SHA256.hash(
      data: Data(([String(describing: mode)] + identity).joined(separator: "\u{0}").utf8))
    key = digest.map { String(format: "%02x", $0) }.joined()
  }

  public static func == (lhs: Target, rhs: Target) -> Bool {
    lhs.mode == rhs.mode && lhs.key == rhs.key
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(mode)
    hasher.combine(key)
  }
}

/// One configured thing in one place, as found on disk.
public struct Entry: Sendable {
  public var name: String
  public var kind: Kind
  public var place: Place
  /// `config`, `extension`, `user`, `project`, `.mcp.json`, `plugin <name>`, or `kept` for a
  /// server Switchboard took out of a configuration and keeps, which is always off.
  public var origin: String
  public var state: Presence
  /// Servers only.
  public var target: Target?
  /// Names of environment variables and headers. Never their values.
  public var secretNames: [String]
  public var typeLabel: String
  /// Skills only, from the `SKILL.md` front matter.
  public var description: String?
  /// For entries placed in Claude Code: the state in a project where it differs from `state`.
  public var projectOverrides: [String: Presence]
  /// The name a switch uses for this entry: the server name, the name in a project's off list,
  /// the plugin identifier, or the extension folder. Nil when the entry cannot be switched.
  public var switchName: String?
  /// Projects where only the project's off list keeps this entry off. Removing the name from
  /// that list turns the entry on there.
  public var listedOffIn: Set<String>

  public init(
    name: String,
    kind: Kind,
    place: Place,
    origin: String,
    state: Presence,
    target: Target? = nil,
    secretNames: [String] = [],
    typeLabel: String,
    description: String? = nil,
    projectOverrides: [String: Presence] = [:],
    switchName: String? = nil,
    listedOffIn: Set<String> = []
  ) {
    self.name = name
    self.kind = kind
    self.place = place
    self.origin = origin
    self.state = state
    self.target = target
    self.secretNames = secretNames
    self.typeLabel = typeLabel
    self.description = description
    self.projectOverrides = projectOverrides
    self.switchName = switchName
    self.listedOffIn = listedOffIn
  }

  /// The state this entry contributes to `place`.
  public func state(in place: Place) -> Presence {
    switch (self.place, place) {
    case (.claudeCode, .project(let path)):
      return projectOverrides[path] ?? state
    default:
      return self.place == place ? state : .absent
    }
  }
}

/// One table row. Servers are grouped by target, plugins by identifier, skills by name.
public struct Row: Identifiable, Sendable {
  public var id: String
  public var name: String
  public var kind: Kind
  public var entries: [Entry]
  /// The same target is configured where it would load twice, or in both apps.
  public var isDuplicate: Bool
  /// Another row of the same kind uses this name for a different target.
  public var hasNameConflict: Bool

  public var typeLabel: String {
    var labels: [String] = []
    for entry in entries where !labels.contains(entry.typeLabel) {
      labels.append(entry.typeLabel)
    }
    return labels.joined(separator: ", ")
  }

  public func state(in place: Place) -> Presence {
    let states = entries.map { $0.state(in: place) }
    if states.contains(.on) { return .on }
    if states.contains(.off) { return .off }
    return .absent
  }
}

public struct SourceIssue: Sendable {
  /// The file or folder, written relative to the home folder.
  public var source: String
  public var message: String

  public init(source: String, message: String) {
    self.source = source
    self.message = message
  }
}
