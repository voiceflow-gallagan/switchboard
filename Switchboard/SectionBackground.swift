import AppKit
import SwiftUI

extension View {
  /// Fills the whole window, title bar included, with `theme`'s gradient, and keeps the window
  /// opaque.
  func sectionBackground(_ theme: SectionTheme) -> some View {
    background {
      SectionBackground(theme: theme)
        .ignoresSafeArea()
        .background(OpaqueWindow())
    }
  }
}

/// The section's gradient over an opaque base. When the section changes, the new gradient is
/// drawn at once and fully opaque, and the old one fades out on top of it, so nothing behind the
/// window ever shows through. Without the fade when Reduce motion is on.
struct SectionBackground: View {
  static let fadeDuration = 0.3
  let theme: SectionTheme
  /// The previous section's gradient while it fades out.
  @State private var outgoing: SectionTheme?
  @State private var outgoingOpacity = 1.0
  /// Counts section changes, so a fade that ends after a newer change leaves that one alone.
  @State private var changes = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      Color(nsColor: .windowBackgroundColor)
      Self.gradient(theme)
      if let outgoing {
        Self.gradient(outgoing)
          .opacity(outgoingOpacity)
      }
    }
    .onChange(of: theme) { old, _ in
      changes += 1
      let change = changes
      outgoingOpacity = 1
      outgoing = reduceMotion ? nil : old
      guard !reduceMotion else { return }
      Task { @MainActor in
        withAnimation(.easeInOut(duration: Self.fadeDuration)) {
          outgoingOpacity = 0
        } completion: {
          if changes == change {
            outgoing = nil
          }
        }
      }
    }
  }

  private static func gradient(_ theme: SectionTheme) -> LinearGradient {
    LinearGradient(colors: theme.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
  }
}

/// Makes its window opaque, with an opaque background colour.
private struct OpaqueWindow: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    OpaqueWindowView()
  }

  func updateNSView(_ view: NSView, context: Context) {}
}

private final class OpaqueWindowView: NSView {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.isOpaque = true
    window?.backgroundColor = .windowBackgroundColor
  }

  /// Lets clicks through to the content.
  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}
