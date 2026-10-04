import SwiftUI

@main
struct SwitchboardApp: App {
  @NSApplicationDelegateAdaptor private var delegate: AppDelegate
  private let model = AppModel.shared

  init() {
    AppModel.shared.start()
  }

  var body: some Scene {
    Window("Switchboard", id: "main") {
      InventoryView(model: model)
    }
    MenuBarExtra {
      MenuBarMenu(usage: model.usage)
    } label: {
      MenuBarLabel(usage: model.usage)
    }
    .menuBarExtraStyle(.menu)
  }
}
