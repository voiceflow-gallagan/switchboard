import SwiftUI
import SwitchboardCore

struct MemoryFigures {
  var running: [Row.ID: ServerTotal]
  var measured: [Row.ID: ServerMeasurement]
}

struct RowTable: View {
  let rows: [Row]
  let projectPath: String?
  let memory: MemoryFigures?
  /// Nil when switches are not offered, so every cell is a mark.
  let switches: SwitchStore?
  /// Nil when rows offer no actions.
  var actions: RowActions?
  /// Short project names by path, as the project picker shows them.
  var projectLabels: [String: String] = [:]
  @State private var selection = Set<Row.ID>()

  var body: some View {
    Group {
      if let memory {
        Table(rows, selection: $selection) {
          placeColumns
          TableColumn("Memory") { row in
            if row.kind == .server {
              MemoryCell(row: row, figures: memory)
            }
          }
          .width(min: 90, ideal: 120)
          typeColumn
        }
      } else {
        Table(rows, selection: $selection) {
          placeColumns
          typeColumn
        }
      }
    }
    .scrollContentBackground(.hidden)
    .alternatingRowBackgrounds(.disabled)
    .contextMenu(forSelectionType: Row.ID.self) { ids in
      if let actions, ids.count == 1, let row = rows.first(where: { ids.contains($0.id) }) {
        actions.menuItems(for: row)
      }
    }
    .overlay {
      if rows.isEmpty {
        ContentUnavailableView("No items", systemImage: "tray")
      }
    }
  }

  @TableColumnBuilder<Row, Never> private var placeColumns: some TableColumnContent<Row, Never> {
    TableColumn("Name") { row in
      NameCell(row: row, actions: actions, isSelected: selection.contains(row.id))
    }
    .width(min: 180, ideal: 280)
    TableColumn("Desktop") { row in
      PlaceCell(row: row, place: .desktop, switches: switches)
    }
    .width(min: 70, ideal: 80)
    TableColumn("Claude Code") { row in
      PlaceCell(row: row, place: .claudeCode, switches: switches)
    }
    .width(min: 80, ideal: 95)
    TableColumn("Project") { row in
      if let projectPath {
        PlaceCell(row: row, place: .project(path: projectPath), switches: switches)
      }
    }
    .width(min: 70, ideal: 80)
  }

  private var typeColumn: some TableColumnContent<Row, Never> {
    TableColumn("Type") { row in
      let type = row.typeDescription(projectLabels: projectLabels)
      Text(type.text)
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(Theme.secondaryText)
        .help(type.help ?? "")
    }
    .width(min: 80, ideal: 180)
  }
}

private struct NameCell: View {
  let row: Row
  let actions: RowActions?
  let isSelected: Bool
  @State private var isHovering = false
  @Environment(\.sectionTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    HStack(spacing: 6) {
      details
      Spacer(minLength: 0)
      if let actions {
        RowActionButton(row: row, actions: actions)
          .opacity(isHovering || isSelected ? 1 : 0)
          .accessibilityHidden(false)
      }
    }
    .contentShape(Rectangle())
    .background(
      RowHighlight(
        isSelected: isSelected,
        color: colorScheme == .dark
          ? NSColor(theme.accent).withAlphaComponent(0.32)
          : NSColor(theme.tint).withAlphaComponent(0.14))
    )
    .onHover { isHovering = $0 }
    .accessibilityActions {
      actions?.menuItems(for: row)
    }
  }

  private var details: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Text(row.name)
        if row.isDuplicate {
          Text("\(row.entries.count)×")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.tint.opacity(0.15), in: Capsule())
            .foregroundStyle(.primary)
            .help("Configured \(row.entries.count) times")
            .accessibilityLabel("Duplicate, configured \(row.entries.count) times")
        }
        if row.hasNameConflict {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .help("The same name points at a different target elsewhere")
            .accessibilityLabel(
              "Name conflict: the same name points at a different target elsewhere")
        }
      }
      if row.isDuplicate || row.hasNameConflict {
        let locations = row.entries.map(Self.location)
        Text(locations.joined(separator: "  ·  "))
          .font(.caption)
          .foregroundStyle(Theme.secondaryText)
          .help(locations.joined(separator: "\n"))
      }
    }
  }

  private static func location(of entry: Entry) -> String {
    let place =
      switch entry.place {
      case .desktop: "Desktop"
      case .claudeCode: "Claude Code"
      case .project(let path): URL(filePath: path).lastPathComponent
      }
    return "\(entry.name) (\(place), \(entry.origin))"
  }
}

private struct MemoryCell: View {
  let row: Row
  let figures: MemoryFigures

  private static func runningHelp(_ running: ServerTotal) -> String {
    let base = running.copies > 1 ? "\(running.copies) copies running" : "Running"
    guard running.offButRunningCopies > 0 else { return base }
    let off =
      running.offButRunningCopies == running.copies
      ? "Switched off, but still running"
      : "\(running.offButRunningCopies) of \(running.copies) copies switched off, but still running"
    return
      "\(off) until the app or session that started it restarts. A restart frees \(Format.memory(running.offButRunningFootprint))."
  }

  var body: some View {
    if let running = figures.running[row.id] {
      HStack(spacing: 4) {
        Text(
          Format.memory(running.footprint)
            + (running.copies > 1 ? " ×\(running.copies)" : "")
        )
        .monospacedDigit()
        if running.offButRunningCopies > 0 {
          Image(systemName: "power.circle")
            .foregroundStyle(Theme.secondaryText)
            .accessibilityLabel("Switched off, still running")
        }
      }
      .help(Self.runningHelp(running))
    } else if let measured = figures.measured[row.id] {
      Text(
        "\(Format.memory(measured.bytes)), \(measured.date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))"
      )
      .monospacedDigit()
      .foregroundStyle(Theme.secondaryText)
      .help(
        "Not running. Last measured \(measured.date.formatted(date: .abbreviated, time: .shortened))"
      )
    } else if row.entries.allSatisfy({ $0.typeLabel == "extension" }) {
      Text("In extensions")
        .foregroundStyle(Theme.secondaryText)
        .help(
          "Desktop extensions share their processes, so their memory is in the Desktop extensions group"
        )
    } else if row.entries.allSatisfy({ $0.target?.mode == .remote }) {
      Text("Remote")
        .foregroundStyle(Theme.secondaryText)
        .help("Remote server, no local process")
    } else {
      Text("–")
        .foregroundStyle(Theme.tertiaryText)
        .accessibilityLabel("Never measured")
    }
  }
}

/// A switch when the cell offers one, otherwise the state as a mark.
private struct PlaceCell: View {
  let row: Row
  let place: Place
  let switches: SwitchStore?

  var body: some View {
    if let switches, let offer = Switches.offered(for: row, in: place) {
      let name = row.entries.first { $0.state(in: place) != .absent }?.name ?? row.name
      let label = offer.placeLabel(name: name)
      Toggle(
        isOn: Binding(
          get: { !offer.turnsOn },
          set: { _ in switches.apply(offer, name: name) })
      ) {
        Text(label)
      }
      .toggleStyle(.switch)
      .controlSize(.mini)
      .labelsHidden()
      .disabled(switches.isApplying)
      .help(offer.actionLabel(name: name))
      .accessibilityLabel(label)
    } else {
      StateCell(state: row.state(in: place))
    }
  }
}

private struct StateCell: View {
  let state: Presence

  var body: some View {
    switch state {
    case .on:
      Label {
        Text("On")
      } icon: {
        Image(systemName: "checkmark.circle.fill")
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(.green)
      }
    case .off:
      Label {
        Text("Off")
          .foregroundStyle(Theme.secondaryText)
      } icon: {
        Image(systemName: "minus.circle.fill")
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(Theme.secondaryText)
      }
    case .absent:
      Text("–")
        .foregroundStyle(Theme.tertiaryText)
        .accessibilityLabel("Not configured")
    }
  }
}
