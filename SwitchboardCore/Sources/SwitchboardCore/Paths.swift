import Darwin

/// Paths on this Mac.
public enum Paths: Sendable {
  /// The canonical absolute path of an existing item, with every symbolic link, `.` and `..`
  /// resolved, as Claude Code keys its projects. Nil for a relative path or a missing item.
  public static func realPath(_ path: String) -> String? {
    guard path.hasPrefix("/"), let resolved = Darwin.realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }
}
