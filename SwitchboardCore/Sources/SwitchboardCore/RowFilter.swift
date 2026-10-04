import Foundation

/// A sidebar section that lists rows.
public enum RowSection: CaseIterable, Hashable, Sendable {
  case servers, plugins, skills, duplicates

  /// The rows of this section whose name or entry names contain `search`, ignoring letter case.
  /// A blank search matches every row. `rows` must be in `Inventory.rows` order, which sorts by
  /// kind and then by name. The duplicates section mixes kinds, so it is sorted by name again.
  public func rows(from rows: [Row], matching search: String) -> [Row] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    let matching = rows.filter { contains($0) && (query.isEmpty || Self.row($0, matches: query)) }
    guard self == .duplicates else { return matching }
    return matching.map { (key: ($0.name.lowercased(), $0.id), row: $0) }
      .sorted { $0.key < $1.key }
      .map(\.row)
  }

  /// The number of rows in this section, without searching or sorting.
  public func count(in rows: [Row]) -> Int {
    rows.reduce(0) { contains($1) ? $0 + 1 : $0 }
  }

  private func contains(_ row: Row) -> Bool {
    switch self {
    case .servers: row.kind == .server
    case .plugins: row.kind == .plugin
    case .skills: row.kind == .skill
    case .duplicates: row.isDuplicate || row.hasNameConflict
    }
  }

  private static func row(_ row: Row, matches query: String) -> Bool {
    row.name.localizedCaseInsensitiveContains(query)
      || row.entries.contains { $0.name.localizedCaseInsensitiveContains(query) }
  }
}
