import AppKit
import SwiftUI

/// A soft ring of light behind the owner donut, in the section's colours. It breathes over 6
/// seconds and drifts a little. It is decoration: hidden from assistive technologies, still when
/// Reduce motion is on, and still while the window is not on screen.
///
/// The ring is drawn once with SwiftUI shapes and gradients. Core Animation moves it in the
/// system's render server, so the app does no work for each frame.
struct DonutGlow: View {
  let isAnimated: Bool
  @Environment(\.sectionTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GlowLayer(
      theme: theme, colorScheme: colorScheme, isMoving: isAnimated && !reduceMotion,
      opacity: colorScheme == .dark ? 0.62 : 0.38
    )
    .frame(width: GlowRing.canvas, height: GlowRing.canvas)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// The ring itself, with room around it for the blur.
private struct GlowRing: View {
  static let canvas = 280.0
  let theme: SectionTheme

  var body: some View {
    Circle()
      .strokeBorder(
        AngularGradient(
          colors: [theme.tint, theme.accent, theme.tint.opacity(0.35), theme.tint],
          center: .center),
        lineWidth: 22
      )
      .frame(width: 198, height: 198)
      .blur(radius: 18)
      .frame(width: Self.canvas, height: Self.canvas)
  }
}

private struct GlowLayer: NSViewRepresentable {
  let theme: SectionTheme
  let colorScheme: ColorScheme
  let isMoving: Bool
  let opacity: Double

  func makeNSView(context: Context) -> GlowView {
    GlowView()
  }

  func updateNSView(_ view: GlowView, context: Context) {
    let key = "\(theme.id)-\(colorScheme)"
    if view.imageKey != key {
      view.imageKey = key
      view.effectiveAppearance.performAsCurrentDrawingAppearance {
        let renderer = ImageRenderer(content: GlowRing(theme: theme))
        renderer.scale = view.window?.backingScaleFactor ?? 2
        view.glow.contents = renderer.cgImage
      }
    }
    view.update(opacity: opacity, isMoving: isMoving)
  }
}

private final class GlowView: NSView {
  let glow = CALayer()
  var imageKey = ""

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    glow.contentsGravity = .resizeAspect
    layer?.addSublayer(glow)
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    glow.bounds = bounds
    glow.position = CGPoint(x: bounds.midX, y: bounds.midY)
    CATransaction.commit()
  }

  /// Lets clicks through.
  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  func update(opacity: Double, isMoving: Bool) {
    glow.opacity = Float(opacity)
    let isRunning = glow.animation(forKey: "breath") != nil
    if isMoving, !isRunning {
      glow.add(Self.wave("transform.scale", 0.965, 1.035, 3), forKey: "breath")
      glow.add(Self.wave("opacity", opacity - 0.12, opacity + 0.12, 3), forKey: "glow")
      glow.add(Self.wave("transform.rotation.z", -0.35, 0.35, 11.5), forKey: "turn")
      glow.add(Self.wave("transform.translation.x", -3, 3, 11.5), forKey: "drift x")
      glow.add(Self.wave("transform.translation.y", -3, 3, 8.5), forKey: "drift y")
    } else if !isMoving, isRunning {
      glow.removeAllAnimations()
    }
  }

  /// From `from` to `to` over `seconds`, and back, for ever.
  private static func wave(_ keyPath: String, _ from: Double, _ to: Double, _ seconds: Double)
    -> CABasicAnimation
  {
    let animation = CABasicAnimation(keyPath: keyPath)
    animation.fromValue = from
    animation.toValue = to
    animation.duration = seconds
    animation.autoreverses = true
    animation.repeatCount = .infinity
    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    return animation
  }
}
