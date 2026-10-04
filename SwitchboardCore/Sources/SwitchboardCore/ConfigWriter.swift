import Darwin
import Foundation

/// Changes one configuration file so that a failure never leaves it damaged or lost.
///
/// The file is read and edited in memory. When the edit changes it, the original is backed up
/// and the new text is written and flushed to a temporary file beside the target. Only then is
/// the target read again, and when nothing else wrote it meanwhile, the temporary file replaces
/// it in one step. The result is read back.
///
/// Claude Code takes no lock on its files, so there is none to take. Between the last read and
/// the replacement there remains a window of one read and one rename in which another
/// program's write can be overwritten. The read back and the delayed check report such a loss.
enum ConfigWriter {
  static let attempts = 3

  struct Result {
    /// Nil when nothing was written.
    var backup: URL?
    var issues: [SourceIssue]
  }

  /// Applies `edit` to the file at `file`, a path relative to `home`. `edit` returns nil when the
  /// text does not have the expected shape, and the text unchanged when the change is already
  /// in place. In both cases nothing is written and no backup is made.
  ///
  /// Issues name a file inside one of `projects` by its project, never by its path.
  /// `isSafeTarget`, when given, runs right before the rename, after `beforeCompare`. When it
  /// returns false, nothing is replaced and no backup is left. Project files use it to refuse a
  /// symbolic link swapped in after the first check. Home files follow links.
  /// When the file read back differs from what was written, `isInEffect` says whether the
  /// change is still there. By default, the change is there when `edit` changes nothing.
  /// `beforeCompare` and `afterReplace` let tests act between the steps.
  static func change(
    _ file: String,
    home: URL,
    supportFolder: URL,
    projects: [String] = [],
    edit: (String) -> String?,
    isInEffect: ((String) -> Bool)? = nil,
    isSafeTarget: (() -> Bool)? = nil,
    beforeCompare: () -> Void = {},
    afterReplace: () -> Void = {}
  ) -> Result {
    var files = SourceFiles(home: home)
    files.projects = projects
    let url = files.url(file)
    removeStaleTemporaryFiles(of: url)
    for _ in 0..<attempts {
      guard let original = readJSON(url, files: &files) else {
        return Result(issues: files.issues)
      }
      guard let changed = edit(original.text) else {
        files.report(url, "Does not have the expected shape. Nothing was changed.")
        return Result(issues: files.issues)
      }
      guard changed != original.text else { return Result(issues: []) }

      let backup: URL
      do {
        backup = try Backups.save(original.data, of: file, supportFolder: supportFolder)
      } catch {
        files.report(url, "Could not be backed up. Nothing was changed.")
        return Result(issues: files.issues)
      }
      let new = Data(changed.utf8)
      var isUnsafe = false
      let replaced: Bool
      do {
        replaced = try replace(url, with: new) {
          beforeCompare()
          if let isSafeTarget, !isSafeTarget() {
            isUnsafe = true
            return false
          }
          return contents(of: url, home: home) == original.data
        }
      } catch {
        try? FileManager.default.removeItem(at: backup)
        files.report(url, "Could not be written. Nothing was changed.")
        return Result(issues: files.issues)
      }
      guard replaced else {
        try? FileManager.default.removeItem(at: backup)
        if isUnsafe {
          files.report(url, "Is a symbolic link or leaves the project. Nothing was changed.")
          return Result(issues: files.issues)
        }
        continue
      }
      afterReplace()

      let readBack = contents(of: url, home: home)
      if readBack == new {
        return Result(backup: backup, issues: [])
      }
      if let readBack, let text = String(data: readBack, encoding: .utf8), JSONText.isValid(text) {
        if isInEffect?(text) ?? (edit(text) == text) {
          return Result(backup: backup, issues: [])
        }
        files.report(url, "Another program rewrote the file while saving. The change did not stay.")
        return Result(backup: backup, issues: files.issues)
      }
      do {
        try replace(url, with: original.data)
        files.report(url, "Could not be verified after saving. The backup was restored.")
      } catch {
        files.report(
          url, "Could not be verified after saving, and the backup could not be restored.")
      }
      return Result(backup: backup, issues: files.issues)
    }
    files.report(url, "Kept changing while saving. Nothing was changed.")
    return Result(issues: files.issues)
  }

  /// The file's bytes and text, or nil with an issue when it is missing, unreadable, or not JSON.
  static func readJSON(_ url: URL, files: inout SourceFiles) -> (data: Data, text: String)? {
    guard files.fileExists(url) else {
      files.report(url, "File not found")
      return nil
    }
    guard let data = files.read(url) else { return nil }
    guard let text = String(data: data, encoding: .utf8), JSONText.isValid(text) else {
      files.report(url, "Not valid JSON. Nothing was changed.")
      return nil
    }
    return (data, text)
  }

  static func contents(of url: URL, home: URL) -> Data? {
    var files = SourceFiles(home: home)
    return files.fileExists(url) ? files.read(url) : nil
  }

  static let temporaryMarker = ".switchboard-"
  static let staleAge: TimeInterval = 60

  /// Replaces the file at `url` in one step, keeping its permissions. When `url` is a symbolic
  /// link, the file it points to is replaced and the link stays. The new content is written and
  /// flushed first. `shouldReplace` runs last, right before the rename, and when it returns false
  /// nothing is replaced and the result is false.
  // ponytail: keeps the mode bits only. Extended attributes and access control lists on the
  // replaced file are lost.
  @discardableResult
  static func replace(
    _ url: URL, with data: Data, if shouldReplace: () -> Bool = { true }
  ) throws -> Bool {
    let target = url.resolvingSymlinksInPath()
    let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
    let mode = attributes?[.posixPermissions] as? Int ?? 0o600
    let temporary = target.deletingLastPathComponent().appending(
      path: ".\(target.lastPathComponent)\(temporaryMarker)\(UUID().uuidString)")
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    var isRenamed = false
    defer {
      if !isRenamed {
        unlink(temporary.path)
      }
    }
    let isWritten = data.withUnsafeBytes { buffer in
      guard let base = buffer.baseAddress else { return true }
      var offset = 0
      while offset < buffer.count {
        let count = write(descriptor, base + offset, buffer.count - offset)
        if count < 0 {
          guard errno == EINTR else { return false }
          continue
        }
        offset += count
      }
      return true
    }
    let isSynced = fsync(descriptor) == 0
    let isModeSet = fchmod(descriptor, mode_t(mode)) == 0
    close(descriptor)
    guard isWritten, isSynced, isModeSet else { throw CocoaError(.fileWriteUnknown) }
    guard shouldReplace() else { return false }
    guard rename(temporary.path, target.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    isRenamed = true
    return true
  }

  /// Removes temporary files of `replace` for the file at `url` that are older than
  /// `staleAge`. They are left when a replace is killed before its rename, and hold a full copy
  /// of the file. Only regular files in the target's own folder are removed.
  static func removeStaleTemporaryFiles(of url: URL, now: Date = Date()) {
    let target = url.resolvingSymlinksInPath()
    let folder = target.deletingLastPathComponent()
    let prefix = ".\(target.lastPathComponent)\(temporaryMarker)"
    let fileManager = FileManager.default
    for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] {
      guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
      else { continue }
      let path = folder.appending(path: name).path
      guard let attributes = try? fileManager.attributesOfItem(atPath: path),
        attributes[.type] as? FileAttributeType == .typeRegular,
        let modified = attributes[.modificationDate] as? Date,
        now.timeIntervalSince(modified) > staleAge
      else { continue }
      unlink(path)
    }
  }

  /// Writes a file of Switchboard's own, readable only by its owner. Each of `folders` is created
  /// when missing and kept at mode 0700, and the file is kept at 0600.
  static func writePrivately(_ data: Data, to url: URL, folders: [URL]) throws {
    let fileManager = FileManager.default
    for folder in folders {
      try fileManager.createDirectory(
        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }
    try data.write(to: url, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
