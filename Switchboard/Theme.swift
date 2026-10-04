import AppKit
import SwiftUI

/// The look of one section: its colour, the tint of its controls, and the window gradient.
///
/// The colours were chosen so that white text on `accent`, and primary and secondary text on
/// every gradient stop and on a panel over it, reach a contrast of at least 4.5 to 1.
struct SectionTheme: Equatable, Sendable {
  let id: String
  /// Pills, the selected rail tile, and count badges. White text on it reaches 4.5 to 1.
  let accent: Color
  /// Switches and tinted badges: the accent in light mode and a brighter shade in dark mode, so
  /// a switch that is on stands out on a deep panel.
  let tint: Color
  /// The window background, from the top leading corner to the bottom trailing one.
  let gradient: [Color]

  init(
    _ id: String, accent: UInt32, bright: UInt32, dark: (UInt32, UInt32),
    light: (UInt32, UInt32)
  ) {
    self.id = id
    self.accent = Color(hex: accent)
    tint = Color(light: accent, dark: bright)
    gradient = [Color(light: light.0, dark: dark.0), Color(light: light.1, dark: dark.1)]
  }

  static func == (lhs: SectionTheme, rhs: SectionTheme) -> Bool {
    lhs.id == rhs.id
  }

  static let overview = SectionTheme(
    "overview", accent: 0x5A3FD1, bright: 0x9A85FF, dark: (0x1A1240, 0x2A1350),
    light: (0xEEEAFF, 0xF7EFFF))
  static let servers = SectionTheme(
    "servers", accent: 0x1F5FCC, bright: 0x5C9BFF, dark: (0x08163A, 0x0C2452),
    light: (0xE8F0FF, 0xF0F6FF))
  static let plugins = SectionTheme(
    "plugins", accent: 0x0A6B75, bright: 0x3CC8C8, dark: (0x04232A, 0x063138),
    light: (0xE3F6F4, 0xEEF9F7))
  static let skills = SectionTheme(
    "skills", accent: 0x2B6B34, bright: 0x5ED17A, dark: (0x082011, 0x0D2F1B),
    light: (0xE7F6E9, 0xF1F9F0))
  static let duplicates = SectionTheme(
    "duplicates", accent: 0x8F4F00, bright: 0xF2B04A, dark: (0x281803, 0x3B2507),
    light: (0xFFF2DA, 0xFFF8EA))
  static let removed = SectionTheme(
    "removed", accent: 0x4A4F57, bright: 0xAEB4BE, dark: (0x151619, 0x25272C),
    light: (0xEDEEF0, 0xF5F5F7))
  static let cloudHistory = SectionTheme(
    "cloudHistory", accent: 0x465E78, bright: 0x8FB1D6, dark: (0x111821, 0x1B2735),
    light: (0xE9EEF4, 0xF2F5F9))
}

/// Colours that do not belong to one section.
enum Theme {
  /// Text for memory that went down, and for memory that went up. Both reach 4.5 to 1 on a panel.
  static let decrease = Color(light: 0x1E7B34, dark: 0x5BD27A)
  static let increase = Color(light: 0xC0261C, dark: 0xFF8A80)
  /// The fill of a pill that deletes or uninstalls. White text on it reaches 4.5 to 1.
  static let destructive = Color(hex: 0xC42B1C)
  /// Secondary text. The system's half-transparent grey reaches only 3.9 to 1 on a white
  /// panel, so this one is darker in light mode and reaches 4.5 to 1 on every panel and gradient.
  static let secondaryText = Color(light: 0x5E5E66, dark: 0xBEBEC8)
  /// Placeholders such as the dash in an empty cell.
  static let tertiaryText = Color(light: 0x8A8A92, dark: 0x7C7C86)
}

extension EnvironmentValues {
  /// The theme of the section on screen, for pills and toasts, also inside sheets.
  @Entry var sectionTheme: SectionTheme = .overview
}

extension Color {
  /// An sRGB colour written as 0xRRGGBB.
  init(hex: UInt32) {
    self.init(
      .sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255)
  }

  /// `light` in a light appearance and `dark` in a dark one.
  init(light: UInt32, dark: UInt32) {
    self.init(
      nsColor: NSColor(name: nil) { appearance in
        let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        return NSColor(
          srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
          blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
      })
  }
}

enum PanelLevel {
  /// A card on the Overview.
  case card
  /// The lighter panel that holds a list.
  case content
}

extension View {
  /// A translucent white panel over the gradient, with a soft border.
  func panel(_ level: PanelLevel = .card, cornerRadius: CGFloat = 22) -> some View {
    modifier(PanelBackground(level: level, cornerRadius: cornerRadius))
  }

  /// Gives pills, toasts, and controls the colours of `theme`. Sheets do not inherit it, so
  /// they apply it again without tinting controls, which keeps Cancel neutral.
  func themed(_ theme: SectionTheme, tintsControls: Bool = true) -> some View {
    environment(\.sectionTheme, theme).tint(tintsControls ? theme.tint : nil)
  }

  /// A rounded floating notice, tinted with the section's colour.
  func toast() -> some View {
    modifier(ToastBackground())
  }
}

private struct PanelBackground: ViewModifier {
  let level: PanelLevel
  let cornerRadius: CGFloat
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    let isDark = colorScheme == .dark
    content
      .background(fill(isDark: isDark), in: shape)
      .overlay(shape.strokeBorder(isDark ? .white.opacity(0.12) : .black.opacity(0.07)))
      .shadow(color: .black.opacity(isDark ? 0 : 0.06), radius: 10, y: 3)
  }

  /// Opaque when Reduce transparency is on.
  private func fill(isDark: Bool) -> Color {
    switch (isDark, reduceTransparency) {
    case (true, false): .white.opacity(level == .card ? 0.07 : 0.09)
    case (true, true): Color(white: level == .card ? 0.13 : 0.15)
    case (false, false): .white.opacity(level == .card ? 0.72 : 0.94)
    case (false, true): .white
    }
  }
}

/// A material in dark mode. In light mode a white fill, because a material over the light
/// gradient turns grey. Opaque when Reduce transparency is on.
private struct ToastBackground: ViewModifier {
  @Environment(\.sectionTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
    content
      .background {
        if colorScheme == .dark {
          shape.fill(.regularMaterial)
        } else {
          shape.fill(.white.opacity(reduceTransparency ? 1 : 0.9))
        }
        shape.fill(theme.tint.opacity(colorScheme == .dark ? 0.16 : 0.08))
      }
      .overlay(
        shape.strokeBorder(colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.08))
      )
      .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
  }
}

/// A primary action: a rounded pill in the section's colour, or red for one that deletes.
struct PillButtonStyle: ButtonStyle {
  var isDestructive = false

  func makeBody(configuration: Configuration) -> some View {
    PillLabel(configuration: configuration, isDestructive: isDestructive)
  }
}

private struct PillLabel: View {
  let configuration: ButtonStyleConfiguration
  let isDestructive: Bool
  @Environment(\.sectionTheme) private var theme
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.controlSize) private var controlSize

  var body: some View {
    let isSmall = controlSize == .small || controlSize == .mini
    configuration.label
      .font(isSmall ? .callout.weight(.semibold) : .body.weight(.semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, isSmall ? 11 : 16)
      .padding(.vertical, isSmall ? 3 : 6)
      .background(
        (isDestructive ? Theme.destructive : theme.accent)
          .opacity(configuration.isPressed ? 0.8 : 1), in: Capsule()
      )
      .opacity(isEnabled ? 1 : 0.45)
      .contentShape(Capsule())
  }
}

/// The lighter panel that holds a list, with a header bar: the title on the left and
/// `accessory`, such as a search field, on the right.
struct ContentPanel<Accessory: View, Content: View>: View {
  let title: String
  @ViewBuilder let accessory: Accessory
  @ViewBuilder let content: Content

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Text(title)
          .font(.title3.weight(.bold))
          .fontDesign(.rounded)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 12)
        accessory
      }
      .padding(.horizontal, 16)
      .frame(minHeight: 48)
      Divider()
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .panel(.content, cornerRadius: 18)
  }
}

/// A rounded search field for a panel's header bar. Command-F focuses it.
struct SearchField: View {
  @Binding var text: String
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(Theme.secondaryText)
        .accessibilityHidden(true)
      TextField("Filter by name", text: $text)
        .textFieldStyle(.plain)
        .frame(width: 150)
        .focused($isFocused)
      Button("Clear the filter", systemImage: "xmark.circle.fill") { text = "" }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.secondaryText)
        .opacity(text.isEmpty ? 0 : 1)
        .disabled(text.isEmpty)
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 5)
    .background(.primary.opacity(0.06), in: Capsule())
    .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
    .background {
      Button("Find") { isFocused = true }
        .keyboardShortcut("f")
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }
}
