import AppKit
import SwiftUI

/// Tints the table row it sits in while that row is selected, in place of the system highlight,
/// which turns grey on the section gradients. It hides the system highlight of its table and
/// leaves text colours as they are, so text stays readable on the tint.
struct RowHighlight: NSViewRepresentable {
  let isSelected: Bool
  let color: NSColor

  func makeNSView(context: Context) -> HighlightView {
    HighlightView()
  }

  func updateNSView(_ view: HighlightView, context: Context) {
    view.isSelected = isSelected
    view.color = color
    view.apply()
  }
}

final class HighlightView: NSView {
  var isSelected = false
  var color = NSColor.clear

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    apply()
  }

  /// Lets clicks through to the row.
  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  func apply() {
    guard let row = enclosing(NSTableRowView.self) else { return }
    if let table = enclosing(NSTableView.self), table.selectionHighlightStyle != .none {
      table.selectionHighlightStyle = .none
    }
    row.backgroundColor = isSelected ? color : .clear
  }

  private func enclosing<Enclosing: NSView>(_ type: Enclosing.Type) -> Enclosing? {
    var view = superview
    while let current = view {
      if let match = current as? Enclosing { return match }
      view = current.superview
    }
    return nil
  }
}
