import SwiftUI
import SwitchboardCore

enum SidebarItem: Hashable {
  case overview
  case rows(RowSection)
  case cloudHistory
  case removed

  var title: String {
    switch self {
    case .overview: "Overview"
    case .rows(.servers): "Servers"
    case .rows(.plugins): "Plugins"
    case .rows(.skills): "Skills"
    case .rows(.duplicates): "Duplicates"
    case .cloudHistory: "Cloud history"
    case .removed: "Removed"
    }
  }

  var systemImage: String {
    switch self {
    case .overview: "chart.bar"
    case .rows(.servers): "server.rack"
    case .rows(.plugins): "puzzlepiece.extension"
    case .rows(.skills): "book.closed"
    case .rows(.duplicates): "square.on.square"
    case .cloudHistory: "clock.arrow.circlepath"
    case .removed: "trash"
    }
  }

  var theme: SectionTheme {
    switch self {
    case .overview: .overview
    case .rows(.servers): .servers
    case .rows(.plugins): .plugins
    case .rows(.skills): .skills
    case .rows(.duplicates): .duplicates
    case .cloudHistory: .cloudHistory
    case .removed: .removed
    }
  }
}

/// The section switcher, always visible: one tile per section with its count as a badge. The
/// section's name is the tooltip and the accessibility label. Command-1 and onward select them.
struct SectionRail: View {
  let items: [(item: SidebarItem, count: Int?)]
  @Binding var selection: SidebarItem?

  var body: some View {
    VStack(spacing: 12) {
      ForEach(Array(items.enumerated()), id: \.element.item) { index, entry in
        RailTile(
          item: entry.item, count: entry.count, isSelected: selection == entry.item,
          shortcut: KeyEquivalent(Character(String(index + 1)))
        ) { selection = entry.item }
      }
      Spacer(minLength: 0)
    }
    .padding(.top, 10)
    .frame(width: 76)
    .frame(maxHeight: .infinity)
  }
}

private struct RailTile: View {
  let item: SidebarItem
  let count: Int?
  let isSelected: Bool
  let shortcut: KeyEquivalent
  let select: () -> Void
  @State private var isHovering = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
    Button(action: select) {
      Image(systemName: item.systemImage)
        .font(.system(size: 18, weight: .medium))
        .frame(width: 46, height: 46)
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background(fill, in: shape)
        .overlay(shape.strokeBorder(.white.opacity(isSelected ? 0.25 : 0)))
        .overlay(alignment: .topTrailing) {
          if let count {
            badge(count)
          }
        }
        .contentShape(shape)
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help(item.title)
    .accessibilityLabel(item.title)
    .accessibilityValue(count.map(String.init) ?? "")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .keyboardShortcut(shortcut, modifiers: .command)
  }

  private var fill: Color {
    if isSelected { return item.theme.accent }
    return .primary.opacity(isHovering ? 0.1 : 0.04)
  }

  /// The count in the section's own colour, or white on the selected tile.
  private func badge(_ count: Int) -> some View {
    Text("\(count)")
      .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
      .padding(.horizontal, 5)
      .frame(minWidth: 18, minHeight: 16)
      .foregroundStyle(isSelected ? item.theme.accent : .white)
      .background(isSelected ? Color.white : item.theme.accent, in: Capsule())
      .offset(x: 8, y: -6)
      .accessibilityHidden(true)
  }
}
