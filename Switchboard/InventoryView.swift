import AppKit
import SwiftUI
import SwitchboardCore

struct InventoryView: View {
  let model: AppModel
  @State private var isShowingBackups = false
  @State private var folderToAdd: URL?
  @State private var isAddingServer = false
  @State private var serverToCopy: PendingCopy?
  @State private var pluginToUninstall: PendingUninstall?
  @State private var selection: SidebarItem? = .overview
  @State private var projectPath: String?
  @State private var search = ""

  private var store: InventoryStore { model.store }
  private var usage: UsageStore { model.usage }
  private var switches: SwitchStore { model.switches }
  private var paths: AppPaths { model.paths }

  var body: some View {
    let theme = (selection ?? .overview).theme
    HStack(spacing: 0) {
      SectionRail(items: railItems, selection: $selection)
      detail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .themed(theme)
    .navigationTitle(paths.isTestHome && !paths.isDemo ? "Switchboard (TEST HOME)" : "Switchboard")
    .sectionBackground(theme)
    .toolbarBackground(.hidden, for: .windowToolbar)
    .toolbar {
      if paths.offersSwitches {
        ToolbarItem {
          Button("Add server", systemImage: "plus") { isAddingServer = true }
            .help("Add an MCP server to Claude Desktop or Claude Code")
            .disabled(store.inventory == nil || switches.isApplying)
        }
        ToolbarItem {
          Button("Add project", systemImage: "folder.badge.plus", action: chooseFolderToAdd)
            .help("Add a folder as a Claude Code project")
            .disabled(!store.includesProjects || switches.isApplying)
        }
        ToolbarItem {
          Button("Backups", systemImage: "archivebox") { isShowingBackups = true }
            .help("Copies taken before each change, with Restore")
        }
      }
      ToolbarItem {
        Button("Reload", systemImage: "arrow.clockwise", action: reload)
          .help("Read the configuration again")
          .disabled(store.isLoading)
      }
    }
    .frame(minWidth: 820, minHeight: 440)
    .sheet(item: $pluginToUninstall) { plugin in
      UninstallView(plugin: plugin, switches: switches)
        .themed(theme, tintsControls: false)
    }
    .sheet(isPresented: $isShowingBackups) {
      BackupsView(switches: switches)
        .themed(theme, tintsControls: false)
    }
    .sheet(isPresented: $isAddingServer) {
      AddServerView(switches: switches, inventory: store.inventory) { selection = .rows(.servers) }
        .themed(theme, tintsControls: false)
    }
    .sheet(item: $serverToCopy) { pending in
      CopyServerView(pending: pending, switches: switches, inventory: store.inventory)
        .themed(theme, tintsControls: false)
    }
    .sheet(
      isPresented: Binding(get: { folderToAdd != nil }, set: { if !$0 { folderToAdd = nil } })
    ) {
      if let folder = folderToAdd {
        AddProjectView(folder: folder, projects: store.inventory?.projects ?? []) { source in
          Task {
            if let path = await switches.addProject(folder, copyingFrom: source) {
              projectPath = path
            }
          }
        }
        .themed(theme, tintsControls: false)
      }
    }
    .onChange(of: usage.sampledAt) {
      switches.refreshRestartNeeds(processes: usage.processes)
    }
    .onAppear {
      if store.inventory != nil {
        store.reload()
      }
      reportVisibility()
    }
    .onDisappear {
      model.windowVisibilityChanged(false)
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    {
      _ in
      if store.inventory != nil {
        store.reload()
      }
    }
    .onChange(of: store.includesProjects) {
      model.sample()
    }
    .onReceive(
      NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)
    ) {
      _ in
      reportVisibility()
    }
  }

  /// The window counts as visible while any window that can be the main one is on screen, which
  /// leaves out the menu bar item's own window.
  private func reportVisibility() {
    model.windowVisibilityChanged(
      NSApp.windows.contains {
        $0.isVisible && $0.canBecomeMain && $0.occlusionState.contains(.visible)
      })
  }

  private func chooseFolderToAdd() {
    Task {
      folderToAdd = await FolderPicker.chooseProjectFolder()
    }
  }

  private func reload() {
    store.reload()
    model.sample()
    usage.scanDisk()
  }

  private var railItems: [(item: SidebarItem, count: Int?)] {
    let inventory = store.inventory
    return [(.overview, nil)]
      + RowSection.allCases.map { (.rows($0), count(of: $0)) }
      + [(.cloudHistory, inventory?.cloudHistory.count ?? 0)]
      + (paths.offersSwitches ? [(.removed, inventory?.removed.count ?? 0)] : [])
  }

  @ViewBuilder private var detail: some View {
    if let inventory = store.inventory {
      VStack(spacing: 0) {
        banners(issues: switches.issues + inventory.issues + usage.issues)
          .zIndex(1)
        section(inventory)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .clipped()
      }
      .overlay(alignment: .bottom) {
        if let progress = switches.progress {
          ProgressNotice(message: progress)
        } else if let notice = switches.notice {
          ChangeNotice(
            notice: notice, canUndo: !switches.isApplying, undo: switches.undo,
            dismiss: switches.dismissNotice)
        }
      }
      .animation(.snappy, value: switches.notice?.id)
    } else {
      ProgressView("Reading configuration")
    }
  }

  /// Banners sit above the section and push it down. The section is clipped to the space left,
  /// so a scrolled card never draws over them.
  @ViewBuilder private func banners(issues: [SourceIssue]) -> some View {
    VStack(spacing: 8) {
      if !issues.isEmpty {
        IssueBanner(issues: issues)
      }
      if !switches.restartNeeds.isEmpty {
        RestartBanner(needs: switches.restartNeeds, dismiss: switches.dismissRestartNeeds)
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, issues.isEmpty && switches.restartNeeds.isEmpty ? 0 : 8)
  }

  @ViewBuilder private func section(_ inventory: Inventory) -> some View {
    switch selection {
    case .overview:
      OverviewView(usage: usage, isGlowAnimated: model.isWindowVisible)
    case .rows(let section):
      let rows = section.rows(from: inventory.rows, matching: search)
      let showsMemory = section == .servers || section == .duplicates
      ContentPanel(title: SidebarItem.rows(section).title) {
        rowControls
      } content: {
        RowTable(
          rows: rows, projectPath: projectPath,
          memory: showsMemory ? memoryFigures(for: rows) : nil,
          switches: paths.offersSwitches ? switches : nil,
          actions: paths.offersSwitches ? rowActions : nil,
          projectLabels: ProjectPicker.shortLabels(for: inventory.projects)
        )
      }
      .padding(16)
    case .cloudHistory:
      ContentPanel(title: SidebarItem.cloudHistory.title) {
      } content: {
        CloudHistoryList(names: inventory.cloudHistory)
      }
      .padding(16)
    case .removed:
      ContentPanel(title: SidebarItem.removed.title) {
      } content: {
        RemovedView(removed: inventory.removed, switches: switches)
      }
      .padding(16)
    case nil:
      ContentUnavailableView("Choose a section", systemImage: "sidebar.left")
    }
  }

  /// The project picker and the search field, in a list's header bar.
  private var rowControls: some View {
    HStack(spacing: 10) {
      if !store.includesProjects {
        Text("Reading project folders")
          .font(.caption)
          .foregroundStyle(Theme.secondaryText)
      }
      ProjectPicker(
        projects: store.includesProjects ? store.inventory?.projects ?? [] : [],
        selection: $projectPath
      )
      .labelsHidden()
      .fixedSize()
      .disabled(!store.includesProjects)
      SearchField(text: $search)
    }
  }

  private var rowActions: RowActions {
    RowActions(
      copy: { row, app in serverToCopy = PendingCopy(row: row, app: app) },
      remove: switches.remove,
      uninstall: { id, name in pluginToUninstall = PendingUninstall(id: id, name: name) },
      programProblem: paths.claudeProgram == nil
        ? paths.claudeProblem ?? RemovedServer.programNotFound : nil,
      isBusy: switches.isApplying)
  }

  private func memoryFigures(for rows: [Row]) -> MemoryFigures {
    MemoryFigures(
      running: Dictionary(
        (usage.report?.serverTotals ?? []).compactMap { total in total.rowID.map { ($0, total) } },
        uniquingKeysWith: { first, _ in first }),
      measured: usage.measurements(for: rows.filter { $0.kind == .server }.map(\.id))
    )
  }

  private func count(of section: RowSection) -> Int {
    guard let rows = store.inventory?.rows else { return 0 }
    return section.count(in: rows)
  }
}
