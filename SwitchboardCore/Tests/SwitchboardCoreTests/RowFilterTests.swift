import Testing

@testable import SwitchboardCore

@Suite struct RowFilterTests {
  /// In `Inventory.rows` order: by kind, then by name ignoring case.
  private let rows = [
    Self.row("Alpha", .server, entryNames: ["Alpha", "alpha-remote"], isDuplicate: true),
    Self.row("beta", .server),
    Self.row("zeta", .server),
    Self.row("Notes", .plugin),
    Self.row("tracker", .plugin, hasNameConflict: true),
    Self.row("draw", .skill, isDuplicate: true),
  ]

  private static func row(
    _ name: String,
    _ kind: Kind,
    entryNames: [String]? = nil,
    isDuplicate: Bool = false,
    hasNameConflict: Bool = false
  ) -> Row {
    let entries = (entryNames ?? [name]).map {
      Entry(name: $0, kind: kind, place: .claudeCode, origin: "user", state: .on, typeLabel: "npx")
    }
    return Row(
      id: "\(kind.rawValue)|\(name)", name: name, kind: kind, entries: entries,
      isDuplicate: isDuplicate, hasNameConflict: hasNameConflict)
  }

  @Test func sectionKeepsItsKindInInventoryOrder() {
    #expect(
      RowSection.servers.rows(from: rows, matching: "").map(\.name) == ["Alpha", "beta", "zeta"])
    #expect(RowSection.plugins.rows(from: rows, matching: "").map(\.name) == ["Notes", "tracker"])
    #expect(RowSection.skills.rows(from: rows, matching: "").map(\.name) == ["draw"])
  }

  @Test func duplicatesKeepsDuplicateAndConflictRowsOfEveryKindSortedByName() {
    #expect(
      RowSection.duplicates.rows(from: rows, matching: "").map(\.name)
        == ["Alpha", "draw", "tracker"])
  }

  @Test func countMatchesTheUnsearchedSection() {
    for section in RowSection.allCases {
      #expect(section.count(in: rows) == section.rows(from: rows, matching: "").count)
    }
  }

  @Test func searchIgnoresCaseAndSurroundingSpace() {
    #expect(RowSection.servers.rows(from: rows, matching: "  ALP ").map(\.name) == ["Alpha"])
    #expect(RowSection.plugins.rows(from: rows, matching: "note").map(\.name) == ["Notes"])
    #expect(RowSection.servers.rows(from: rows, matching: "nothing").isEmpty)
  }

  @Test func searchMatchesTheNameOfAnyEntry() {
    #expect(RowSection.servers.rows(from: rows, matching: "Remote").map(\.name) == ["Alpha"])
  }
}
