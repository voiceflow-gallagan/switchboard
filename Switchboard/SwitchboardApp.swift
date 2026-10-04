import SwiftUI

@main
struct SwitchboardApp: App {
  @NSApplicationDelegateAdaptor private var delegate: AppDelegate
  @AppStorage(Appearance.key) private var appearance = Appearance.system
  private let model = AppModel.shared
  @State private var statusItem = StatusItemController(usage: AppModel.shared.usage)

  init() {
    AppModel.shared.start()
  }

  var body: some Scene {
    Window("Switchboard", id: "main") {
      MainWindow(model: model, statusItem: statusItem)
        .preferredColorScheme(appearance.colorScheme)
    }
    Settings {
      SettingsView()
    }
  }
}

/// The window's content, which also tells the menu bar item how to open windows. The environment
/// actions only resolve inside a view.
private struct MainWindow: View {
  let model: AppModel
  let statusItem: StatusItemController
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    InventoryView(model: model)
      .onAppear {
        statusItem.openWindow = { openWindow(id: "main") }
        statusItem.openSettings = { openSettings() }
      }
  }
}
