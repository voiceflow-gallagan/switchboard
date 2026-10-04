import SwiftUI

/// One server entry in the "Most expensive servers" list.
struct ServerBar: Identifiable {
  var id: String
  var label: String
  /// Quiet text that tells apart two entries with the same label.
  var detail: String?
  var bytes: UInt64
  var badge: String?
  var isQuiet = false
  /// Set when some copies are switched off but still run until their app or session restarts.
  var offButRunning: OffButRunning?

  struct OffButRunning {
    /// True when every copy is off.
    var isAll: Bool
    var bytes: UInt64
  }
}

struct ServerBars: View {
  let bars: [ServerBar]
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let largest = max(bars.map(\.bytes).max() ?? 1, 1)
    VStack(alignment: .leading, spacing: 12) {
      ForEach(bars) { bar in
        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 6) {
            Text(bar.label)
              .lineLimit(1)
              .truncationMode(.middle)
              .foregroundStyle(
                bar.isQuiet || bar.offButRunning?.isAll == true ? Theme.secondaryText : .primary)
            if let detail = bar.detail {
              Text(detail)
                .lineLimit(1)
                .foregroundStyle(Theme.secondaryText)
            }
            if let badge = bar.badge {
              Text(badge)
                .font(.caption2.weight(.medium).monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.tint.opacity(0.15), in: Capsule())
                .foregroundStyle(.primary)
            }
            if let off = bar.offButRunning {
              Text(off.isAll ? "Off, still running" : "Some off, still running")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
                .foregroundStyle(Theme.secondaryText)
                .help(
                  "Switched off, but its processes run until the app or session that started them restarts. A restart frees \(Format.memory(off.bytes))."
                )
            }
            Spacer(minLength: 8)
            Text(Format.memory(bar.bytes))
              .monospacedDigit()
              .foregroundStyle(Theme.secondaryText)
          }
          .font(.callout)
          GeometryReader { geometry in
            ZStack(alignment: .leading) {
              Capsule().fill(.quaternary.opacity(0.5))
              Capsule()
                .fill(
                  LinearGradient(
                    colors: bar.isQuiet || bar.offButRunning?.isAll == true
                      ? [.gray.opacity(0.35), .gray.opacity(0.6)]
                      : [.accentColor.opacity(0.45), .accentColor],
                    startPoint: .leading, endPoint: .trailing)
                )
                .frame(width: max(geometry.size.width * Double(bar.bytes) / Double(largest), 6))
            }
          }
          .frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bar.label)
        .accessibilityValue(
          [
            Format.memory(bar.bytes), bar.badge,
            bar.offButRunning.map {
              "switched off but still running, a restart frees \(Format.memory($0.bytes))"
            },
          ].compactMap { $0 }.joined(separator: ", "))
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: bars.map(\.bytes))
  }
}
