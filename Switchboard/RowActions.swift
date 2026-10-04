import SwiftUI
import SwitchboardCore

/// What a row can do beyond its switches: copy a server to the other app, remove a server, or
/// uninstall a plugin.
@MainActor
struct RowActions {
  let copy: (Row, _ app: Place) -> Void
  let remove: (Removal, _ name: String) -> Void
  let uninstall: (_ pluginID: String, _ name: String) -> Void
  /// Why Claude Code's program cannot be run, when it cannot. Uninstall is then disabled.
  let programProblem: String?
  let isBusy: Bool

  /// One item for the copy and one per removal the row offers, for a menu.
  @ViewBuilder func menuItems(for row: Row) -> some View {
    if let app = Additions.offeredCopy(for: row) {
      Button(app.copyTitle, systemImage: Self.copyImage) { copy(row, app) }
        .disabled(isBusy)
    }
    let removals = Removals.offered(for: row)
    ForEach(removals, id: \.self) { removal in
      item(removal, row: row, namesServer: removals.count > 1)
    }
  }

  @ViewBuilder private func item(_ removal: Removal, row: Row, namesServer: Bool) -> some View {
    switch removal {
    case .server(let name, let place):
      Button(
        namesServer ? "Remove \(name) from \(place.spokenName)" : removal.actionTitle,
        systemImage: "trash"
      ) { remove(removal, name) }
      .disabled(isBusy)
    case .plugin(let id):
      Button(removal.actionTitle, systemImage: "trash") { uninstall(id, row.name) }
        .disabled(isBusy || programProblem != nil)
        .help(programProblem ?? "")
    }
  }

  static let copyImage = "plus.square.on.square"
}

/// Small quiet buttons with the row's actions, shown while the row is hovered or selected.
struct RowActionButton: View {
  let row: Row
  let actions: RowActions

  var body: some View {
    HStack(spacing: 8) {
      if let app = Additions.offeredCopy(for: row) {
        Button(app.copyTitle, systemImage: RowActions.copyImage) { actions.copy(row, app) }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .foregroundStyle(Theme.secondaryText)
          .disabled(actions.isBusy)
          .help("Copy \(row.name) to \(app.spokenName)")
          .accessibilityLabel("\(app.copyTitle), \(row.name)")
      }
      removal
    }
  }

  @ViewBuilder private var removal: some View {
    let removals = Removals.offered(for: row)
    if removals.count == 1, let removal = removals.first {
      Button(removal.actionTitle, systemImage: "trash") {
        switch removal {
        case .server(let name, _): actions.remove(removal, name)
        case .plugin(let id): actions.uninstall(id, row.name)
        }
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .foregroundStyle(Theme.secondaryText)
      .disabled(actions.isBusy || (removal.isPlugin && actions.programProblem != nil))
      .help(
        (removal.isPlugin ? actions.programProblem : nil)
          ?? "\(removal.actionTitle): \(row.name)"
      )
      .accessibilityLabel("\(removal.actionTitle), \(row.name)")
    } else if !removals.isEmpty {
      Menu {
        actions.menuItems(for: row)
      } label: {
        Image(systemName: "trash")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .foregroundStyle(Theme.secondaryText)
      .help("Remove \(row.name)")
      .accessibilityLabel("Remove \(row.name)")
    }
  }
}

extension Removal {
  var isPlugin: Bool {
    if case .plugin = self { true } else { false }
  }
}
