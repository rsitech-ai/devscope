import AppKit
import DevScopeCore
import SwiftUI

struct ContentView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ObservedObject private var store: ProcessStore
  @ObservedObject private var automationStore: AutomationStore
  private let automationNotifier: AutomationNotifier
  @State private var searchText = ""
  @State private var automationSearchText = ""
  @State private var automationSourceFilter = AutomationSourceFilter.all
  @State private var automationStateFilter: AutomationState?
  @State private var automationOwnershipFilter = AutomationOwnershipFilter.all
  @State private var activityTypeFilter = AutomationActivityTypeFilter.all
  @State private var selectedProcessID: Int32?
  @State private var retainedSelectedProcess: ClassifiedDevProcess?
  @State private var pendingKillAction: KillAction?
  @State private var isSponsorPresented = false
  @State private var processSort = ProcessTableSortState()
  @State private var lastCopiedPayload: PersistedCopyPayload?
  @State private var expandedApplicationFamilyIDs: Set<String> = []
  @AppStorage(DevScopeSettingsKey.useAppleNaming) private var useAppleNaming = true
  @AppStorage(DevScopeSettingsKey.showProcessGraphs) private var showProcessGraphs = true
  @AppStorage(DevScopeSettingsKey.showLiveNotch) private var showLiveNotch = true
  @AppStorage(DevScopeSettingsKey.selectedCategoryID) private var selectedCategoryID =
    ProcessPresentation.allCategoryID
  @AppStorage(DevScopeSettingsKey.activityScope) private var activityScopeRawValue =
    ProcessActivityScope.applications.rawValue
  @AppStorage(DevScopeSettingsKey.isRailCollapsed) private var isRailCollapsed = false
  @AppStorage(DevScopeSettingsKey.isLiveActivityExpanded) private var isLiveActivityExpanded = false
  @AppStorage(DevScopeSettingsKey.liveActivityPreferredHeight)
  private var liveActivityPreferredHeight = LiveActivityLayoutPolicy.defaultHeight
  @AppStorage(DevScopeSettingsKey.selectedWorkspaceMode) private var workspaceModeRaw =
    DevScopeWorkspaceMode.processes.rawValue
  @AppStorage(DevScopeSettingsKey.includeAppleSystemServices) private var includeAppleSystemServices = false
  @AppStorage("favoriteProcessKeys") private var favoriteProcessKeysRaw = ""
  @AppStorage("watchedProcessKeys") private var watchedProcessKeysRaw = ""
  private let persistentCopyStore = PersistentCopyStore()
  private let automationDocumentPanel = AutomationDocumentPanel()

  init(
    store: ProcessStore,
    automationStore: AutomationStore,
    automationNotifier: AutomationNotifier
  ) {
    self.store = store
    self.automationStore = automationStore
    self.automationNotifier = automationNotifier
  }

  private var allProcesses: [ClassifiedDevProcess] {
    store.classifiedProcesses
  }

  private var activityScope: ProcessActivityScope {
    ProcessActivityScope(rawValue: activityScopeRawValue) ?? .applications
  }

  private var activityScopeBinding: Binding<ProcessActivityScope> {
    Binding(
      get: { activityScope },
      set: { activityScopeRawValue = $0.rawValue }
    )
  }

  private var activityFilteredProcesses: [ClassifiedDevProcess] {
    allProcesses.filter(matchesActivityType)
  }

  private var filteredProcesses: [ClassifiedDevProcess] {
    let filtered: [ClassifiedDevProcess]
    if let selectedWorkflow {
      let processIDs = Set(selectedWorkflow.processIDs)
      filtered = ProcessPresentation.filtered(
        allProcesses.filter { processIDs.contains($0.process.pid) },
        categoryID: ProcessPresentation.allCategoryID,
        searchText: searchText,
        favoriteKeys: favoriteProcessKeys,
        watchedKeys: watchedProcessKeys
      )
    } else {
      filtered = ProcessPresentation.filtered(
        allProcesses,
        categoryID: selectedCategoryID,
        searchText: searchText,
        favoriteKeys: favoriteProcessKeys,
        watchedKeys: watchedProcessKeys
      )
    }
    return filtered.filter(matchesActivityType)
  }

  private var intelligenceWorkflows: [DevWorkflow] {
    store.workflows
  }

  private var processRows: [ProcessTableRow] {
    filteredProcesses
      .enumerated()
      .map { offset, item in
        return ProcessTableRow(
          item: item,
          title: store.displayName(for: item),
          isFavorite: ProcessPresentation.isSaved(item, in: favoriteProcessKeys),
          isWatched: ProcessPresentation.isSaved(item, in: watchedProcessKeys),
          automationBadges: AutomationPresentation.badges(
            isAutomated: store.liveSnapshot.automationLinksByProcessID[item.process.pid] != nil,
            isLongRunning: store.liveSnapshot.longRunningProcessIDs.contains(item.process.pid),
            elapsed: item.process.resourceUsage?.elapsedTime ?? "-"
          ),
          snapshotOrder: offset
        )
      }
      .sorted(using: stableSortOrder)
  }

  private var applicationFamilies: [ProcessApplicationFamily] {
    ProcessScopePresentation.applicationFamilies(
      for: activityFilteredProcesses,
      searchText: searchText
    )
  }

  private var hierarchyNodes: [ProcessHierarchyNode] {
    ProcessScopePresentation.hierarchy(
      for: activityFilteredProcesses,
      searchText: searchText
    )
  }

  private var activeVisibleProcesses: [ClassifiedDevProcess] {
    switch activityScope {
    case .applications:
      processes(withIDs: applicationFamilies.flatMap(\.processIDs))
    case .processes, .workflows:
      filteredProcesses
    case .hierarchy:
      processes(withIDs: ProcessScopePresentation.flattened(hierarchyNodes).map(\.id))
    }
  }

  private var stableSortOrder: [KeyPathComparator<ProcessTableRow>] {
    processSort.comparators + [
      KeyPathComparator(\ProcessTableRow.stableOrderKey, order: .forward)
    ]
  }

  private var categories: [DevProcessCategory] {
    ProcessPresentation.categories(
      for: allProcesses,
      favoriteKeys: favoriteProcessKeys,
      watchedKeys: watchedProcessKeys
    )
  }

  private var selectedCategoryTitle: String {
    if let selectedWorkflow {
      return selectedWorkflow.title
    }

    return categories.first { $0.id == selectedCategoryID }?.title ?? "All"
  }

  private var activeScopeTitle: String {
    switch activityScope {
    case .applications, .hierarchy:
      activityScope.title
    case .processes, .workflows:
      selectedCategoryTitle
    }
  }

  private var selectedWorkflow: DevWorkflow? {
    intelligenceWorkflows.first { $0.id == selectedCategoryID }
  }

  private var processEmptyTitle: String {
    if store.statusMessage.localizedCaseInsensitiveContains("operation not permitted")
      || store.statusMessage.localizedCaseInsensitiveContains("blocked by macOS")
      || store.statusMessage.localizedCaseInsensitiveContains("native process")
    {
      return "Process scanning blocked"
    }

    return "No matching running items"
  }

  private var processEmptyDescription: String {
    if processEmptyTitle == "Process scanning blocked" {
      return
        "This sandboxed build cannot inspect local process metadata. Open Settings > Access for permissions, diagnostics, and distribution guidance."
    }

    return
      "Refresh after opening an app, starting a service, running a script, or launching a build watcher."
  }

  private var selectedProcess: ClassifiedDevProcess? {
    guard let selectedProcessID else {
      return nil
    }

    return allProcesses.first { $0.process.pid == selectedProcessID }
  }

  private var selectedProcessExistsInSnapshot: Bool {
    guard let selectedProcessID else {
      return false
    }

    return allProcesses.contains { $0.process.pid == selectedProcessID }
  }

  private var selectedProcessForDetail: ClassifiedDevProcess? {
    if let selectedProcess {
      return selectedProcess
    }

    return selectedProcessExistsInSnapshot ? nil : retainedSelectedProcess
  }

  private var selectedProcessIsEnded: Bool {
    guard let selectedProcessID else {
      return false
    }

    return !store.isProcessLive(pid: selectedProcessID)
  }

  private var selectedProcessIsFavorite: Bool {
    guard let selectedProcessForDetail else {
      return false
    }
    return ProcessPresentation.isSaved(selectedProcessForDetail, in: favoriteProcessKeys)
  }

  private var selectedProcessIsWatched: Bool {
    guard let selectedProcessForDetail else {
      return false
    }
    return ProcessPresentation.isSaved(selectedProcessForDetail, in: watchedProcessKeys)
  }

  private var selectedProcessMetricHistory: [DevProcessMetricSample] {
    guard let selectedProcess = selectedProcessForDetail else {
      return []
    }

    return store.metricHistory(for: selectedProcess.process.pid)
  }

  private var selectedProcessFamilySummary: ProcessFamilySummary? {
    guard let selectedProcess = selectedProcessForDetail else {
      return nil
    }

    return store.familySummary(for: selectedProcess.process)
  }

  private var selectedProcessWorkflow: DevWorkflow? {
    guard let selectedProcessForDetail else {
      return nil
    }

    return ProcessIntelligence.workflow(
      containing: selectedProcessForDetail, in: intelligenceWorkflows)
  }

  private var selectedProcessActionDecision: ProcessActionDecision? {
    selectedProcessForDetail.map(store.actionDecision(for:))
  }

  private var selectedProcessInsight: DevProcessInsight? {
    guard let selectedProcessForDetail else {
      return nil
    }

    return ProcessIntelligence.insight(
      for: selectedProcessForDetail,
      workflow: selectedProcessWorkflow,
      familySummary: selectedProcessFamilySummary,
      metricHistory: selectedProcessMetricHistory,
      actionDecision: selectedProcessActionDecision ?? .allowed
    )
  }

  private var selectedWorkflowNote: String? {
    guard let selectedProcessWorkflow else {
      return nil
    }

    return store.workflowNotes[selectedProcessWorkflow.id]?.text
  }

  private var dashboardStats: ProcessDashboardStats {
    ProcessPresentation.dashboardStats(
      visibleItems: activeVisibleProcesses,
      totalItems: allProcesses,
      dashboardMetricHistory: store.dashboardMetricHistory
    )
  }

  var body: some View {
    DevScopeGlassContainer {
      ZStack(alignment: .top) {
        mainWorkspace
        if showLiveNotch {
          LiveNotchPanelPresenter(
            stats: dashboardStats,
            metricHistory: store.dashboardMetricHistory,
            selectedScope: activeScopeTitle,
            isRefreshing: store.isRefreshing,
            lastRefresh: store.lastRefresh,
            refreshAction: { store.refresh() },
            displayName: store.displayName(for:)
          )
          .frame(width: 0, height: 0)
          .zIndex(3)
        }
      }
      .padding(12)
    }
    .background(DevScopeBackground())
    .overlay(alignment: .topTrailing) {
      if let feedback = store.actionFeedback {
        ActionFeedbackBanner(feedback: feedback)
          .padding(.top, 12)
          .padding(.trailing, 14)
          .transition(feedbackTransition)
      }
    }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        if workspaceMode == .processes {
          Button(action: exportVisibleProcesses) { Image(systemName: "tablecells") }
            .accessibilityLabel("Copy visible rows")
            .accessibilityHint("Copies the currently visible running items as redacted TSV.")
            .help("Copy visible rows as redacted TSV")

          Button(action: restoreLastCopiedPayload) { Image(systemName: "clipboard") }
            .disabled(lastCopiedPayload == nil)
            .accessibilityLabel("Restore last copy")
            .accessibilityHint("Restores the last command or export saved by DevScope to the clipboard.")
            .help(lastCopiedPayload.map { "Restore last copy: \($0.label)" } ?? "No saved copy")

          Button(action: { store.refresh() }) { Image(systemName: "arrow.clockwise") }
            .accessibilityLabel("Refresh running items")
            .accessibilityHint("Scans local apps, services, agents, and processes now.")
            .help("Refresh running items")
            .keyboardShortcut("r", modifiers: [.command])
        } else {
          Button(action: { automationStore.refresh() }) { Image(systemName: "arrow.clockwise") }
            .disabled(automationStore.isRefreshing)
            .accessibilityLabel("Refresh automations")
            .accessibilityHint("Refreshes configured automation sources without changing them.")
            .help("Refresh automation inventory")
            .keyboardShortcut("r", modifiers: [.command])
        }
      }
    }
    .onChange(of: categories) { _, categories in
      if !categories.contains(where: { $0.id == selectedCategoryID })
        && !intelligenceWorkflows.contains(where: { $0.id == selectedCategoryID })
      {
        selectedCategoryID = ProcessPresentation.allCategoryID
      }
    }
    .onChange(of: intelligenceWorkflows) { _, workflows in
      if !categories.contains(where: { $0.id == selectedCategoryID })
        && !workflows.contains(where: { $0.id == selectedCategoryID })
      {
        selectedCategoryID = ProcessPresentation.allCategoryID
      }
    }
    .onChange(of: activityScopeRawValue) { _, _ in
      alignSelectionWithActivityScope()
    }
    .onChange(of: selectedProcessID) { _, _ in
      scheduleRememberSelectedProcess()
    }
    .onChange(of: allProcesses) { _, _ in
      if selectedProcessID != nil {
        scheduleRememberSelectedProcess()
      }
    }
    .onChange(of: useAppleNaming) { _, value in
      store.usesAppleNaming = value
    }
    .onChange(of: store.actionFeedback) { _, feedback in
      guard let feedback else {
        return
      }
      announceFeedback(feedback)
    }
    .task {
      store.usesAppleNaming = useAppleNaming
      migrateLegacySavedIdentityKeys()
      loadLastCopiedPayload()
      store.startRealtimeUpdates()
    }
    .onDisappear {
      store.stopRealtimeUpdates()
    }
    .onReceive(NotificationCenter.default.publisher(for: .devScopeRefreshRequested)) { _ in
      if workspaceMode == .processes {
        store.refresh()
      } else {
        automationStore.refresh()
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .devScopeRestoreLastCopyRequested)) { _ in
      restoreLastCopiedPayload()
    }
    .sheet(isPresented: $isSponsorPresented) {
      SponsorSheetView()
    }
    .confirmationDialog(
      pendingKillAction?.title ?? "Terminate process?",
      isPresented: pendingKillBinding,
      titleVisibility: .visible
    ) {
      if let action = pendingKillAction {
        Button(action.buttonTitle, role: .destructive) {
          switch action {
          case .single(let process):
            store.terminate(process)
          case .tree(let process):
            store.terminateTree(root: process)
          case .forceSingle(let process):
            store.forceTerminate(process)
          case .forceTree(let process):
            store.forceTerminateTree(root: process)
          }
          pendingKillAction = nil
        }
      }

      Button("Cancel", role: .cancel) {
        pendingKillAction = nil
      }
    } message: {
      if let action = pendingKillAction {
        let descendants = store.familySummary(for: action.process.process).descendantCount
        Text(action.consequence(descendantCount: descendants))
      }
    }
    .modifier(AutomationIntegrationModifier(
      processStore: store,
      automationStore: automationStore,
      automationNotifier: automationNotifier
    ))
  }

  private var mainWorkspace: some View {
    VStack(spacing: 10) {
      Picker("Workspace", selection: workspaceModeBinding) {
        Text("Processes").tag(DevScopeWorkspaceMode.processes)
        Text("Automations").tag(DevScopeWorkspaceMode.automations)
      }
      .pickerStyle(.segmented)
      .frame(maxWidth: 320)
      .accessibilityHint("Switches between live running processes and configured automations without clearing either selection.")

      ZStack {
        if workspaceMode == .processes {
          processModeWorkspace
        }

        AutomationWorkspaceView(
          store: automationStore,
          inventory: store.liveSnapshot.automationInventory,
          processes: store.classifiedProcesses,
          linksByProcessID: store.liveSnapshot.allAutomationLinksByProcessID,
          searchText: $automationSearchText,
          sourceFilter: $automationSourceFilter,
          stateFilter: $automationStateFilter,
          ownershipFilter: $automationOwnershipFilter,
          includeAppleSystemServices: includeAppleSystemServices,
          documentPanel: automationDocumentPanel
        )
        .workspaceLayer(isActive: workspaceMode == .automations)
      }
    }
  }

  private var processModeWorkspace: some View {
    HSplitView {
      CategoryRail(
        selectedCategoryID: $selectedCategoryID,
        activityScope: activityScopeBinding,
        workflows: intelligenceWorkflows,
        categories: categories,
        isCollapsed: $isRailCollapsed,
        isEnhancingWorkflows: store.isEnhancingWorkflows,
        sponsorAction: { isSponsorPresented = true }
      )
      .frame(
        minWidth: isRailCollapsed ? 58 : 190,
        idealWidth: isRailCollapsed ? 64 : 225,
        maxWidth: isRailCollapsed ? 74 : 320
      )

      VStack(spacing: 12) {
        ControlStrip(
          searchText: $searchText,
          activityScope: activityScopeBinding,
          selectedCategoryTitle: activeScopeTitle,
          visibleProcessCount: activeVisibleProcesses.count,
          totalProcessCount: allProcesses.count,
          applicationCount: applicationFamilies.count,
          activityTypeFilter: $activityTypeFilter
        )
        selectedProcessCommandBar
        monitoringWorkspace
      }
      .frame(minWidth: 620)
    }
  }

  @ViewBuilder private var selectedProcessCommandBar: some View {
    if let selectedProcessForDetail {
      ProcessCommandBar(
        process: selectedProcessForDetail,
        displayName: store.displayName(for: selectedProcessForDetail),
        isEnded: selectedProcessIsEnded,
        actionDecision: selectedProcessActionDecision ?? .allowed,
        isFavorite: selectedProcessIsFavorite,
        isWatched: selectedProcessIsWatched,
        favoriteAction: toggleSelectedFavorite,
        watchAction: toggleSelectedWatch,
        exportAction: exportSelectedProcess,
        copyCommandAction: copySelectedCommand,
        openFolderAction: openSelectedFolder,
        killAction: { pendingKillAction = .single(selectedProcessForDetail) },
        killTreeAction: { pendingKillAction = .tree(selectedProcessForDetail) },
        forceKillAction: { pendingKillAction = .forceSingle(selectedProcessForDetail) },
        forceKillTreeAction: { pendingKillAction = .forceTree(selectedProcessForDetail) }
      )
    }
  }

  @ViewBuilder
  private var monitoringWorkspace: some View {
    if isLiveActivityExpanded {
      GeometryReader { proxy in
        let resolvedHeight = LiveActivityLayoutPolicy.resolvedHeight(
          preferredHeight: liveActivityPreferredHeight,
          workspaceHeight: proxy.size.height
        )

        VSplitView {
          processWorkspace

          liveActivityDock
            .frame(
              minHeight: LiveActivityLayoutPolicy.minimumHeight,
              idealHeight: resolvedHeight,
              maxHeight: LiveActivityLayoutPolicy.maximumHeight
            )
            .background {
              GeometryReader { dockProxy in
                Color.clear.preference(
                  key: LiveActivityHeightPreferenceKey.self,
                  value: dockProxy.size.height
                )
              }
            }
        }
        .onPreferenceChange(LiveActivityHeightPreferenceKey.self) { measuredHeight in
          let updatedHeight = LiveActivityLayoutPolicy.updatedPreferredHeight(
            currentPreferredHeight: liveActivityPreferredHeight,
            measuredHeight: measuredHeight,
            workspaceHeight: proxy.size.height
          )
          guard updatedHeight != liveActivityPreferredHeight else { return }
          liveActivityPreferredHeight = updatedHeight
        }
      }
    } else {
      VStack(spacing: 12) {
        processWorkspace
          .layoutPriority(1)

        liveActivityDock
          .frame(height: 60)
      }
    }
  }

  private var processWorkspace: some View {
    HSplitView {
      activityBrowser
      .frame(minWidth: 460)
      .transaction { transaction in
        transaction.animation = nil
      }

      ProcessDetailView(
        process: selectedProcessForDetail,
        displayName: selectedProcessForDetail.map(store.displayName(for:)),
        metricHistory: selectedProcessMetricHistory,
        familySummary: selectedProcessFamilySummary,
        showsMetricHistory: showProcessGraphs,
        isEnded: selectedProcessIsEnded,
        isFavorite: selectedProcessIsFavorite,
        isWatched: selectedProcessIsWatched,
        workflow: selectedProcessWorkflow,
        processInsight: selectedProcessInsight,
        workflowNote: selectedWorkflowNote,
        automationLink: selectedProcessForDetail.flatMap { store.liveSnapshot.automationLinksByProcessID[$0.process.pid] },
        automationRecord: selectedProcessForDetail
          .flatMap { store.liveSnapshot.automationLinksByProcessID[$0.process.pid] }
          .flatMap { link in store.liveSnapshot.automationInventory.records.first { $0.id == link.recordID } },
        showInAutomations: { recordID in
          automationStore.selectedRecordID = recordID
          workspaceModeRaw = DevScopeWorkspaceMode.automations.rawValue
        }
      )
      .frame(minWidth: 300, idealWidth: 360)
    }
    .softPanel(cornerRadius: 18)
    .frame(minHeight: 360)
  }

  @ViewBuilder
  private var activityBrowser: some View {
    switch activityScope {
    case .applications:
      ApplicationFamilyListView(
        families: applicationFamilies,
        selection: $selectedProcessID,
        expandedFamilyIDs: $expandedApplicationFamilyIDs,
        displayName: store.displayName(for:)
      )
    case .processes, .workflows:
      ProcessTableView(
        rows: processRows,
        emptyTitle: processEmptyTitle,
        emptyDescription: processEmptyDescription,
        selection: $selectedProcessID,
        sort: $processSort,
        copyCommand: copyCommand
      )
    case .hierarchy:
      ProcessHierarchyView(
        nodes: hierarchyNodes,
        selection: $selectedProcessID,
        displayName: store.displayName(for:)
      )
    }
  }

  private var liveActivityDock: some View {
    LiveActivitiesDockView(
      stats: dashboardStats,
      metricHistory: store.dashboardMetricHistory,
      isRefreshing: store.isRefreshing,
      lastRefresh: store.lastRefresh,
      isExpanded: $isLiveActivityExpanded
    )
  }

  private var favoriteProcessKeys: Set<String> {
    decodeKeys(favoriteProcessKeysRaw)
  }

  private var watchedProcessKeys: Set<String> {
    decodeKeys(watchedProcessKeysRaw)
  }

  private func rememberSelectedProcess() {
    let resolution = ProcessSelectionPolicy.reconcile(
      selectedProcessID: selectedProcessID,
      retainedProcess: retainedSelectedProcess,
      currentProcesses: allProcesses
    )
    if selectedProcessID != resolution.selectedProcessID {
      selectedProcessID = resolution.selectedProcessID
    }
    if retainedSelectedProcess != resolution.retainedProcess {
      retainedSelectedProcess = resolution.retainedProcess
    }
  }

  private func scheduleRememberSelectedProcess() {
    DispatchQueue.main.async {
      rememberSelectedProcess()
    }
  }

  private func toggleSelectedFavorite() {
    guard let selectedProcessForDetail else {
      return
    }

    let willRemove = ProcessPresentation.isSaved(selectedProcessForDetail, in: favoriteProcessKeys)
    favoriteProcessKeysRaw = toggledKeys(for: selectedProcessForDetail, in: favoriteProcessKeys)
    store.presentFeedback(
      title: willRemove ? "Favorite removed" : "Favorite added",
      detail: store.displayName(for: selectedProcessForDetail),
      symbolName: willRemove ? "star.slash" : "star.fill",
      kind: .success
    )
  }

  private func toggleSelectedWatch() {
    guard let selectedProcessForDetail else {
      return
    }

    let willRemove = ProcessPresentation.isSaved(selectedProcessForDetail, in: watchedProcessKeys)
    watchedProcessKeysRaw = toggledKeys(for: selectedProcessForDetail, in: watchedProcessKeys)
    store.presentFeedback(
      title: willRemove ? "Watch removed" : "Watch added",
      detail: store.displayName(for: selectedProcessForDetail),
      symbolName: willRemove ? "eye.slash" : "eye.fill",
      kind: .success
    )
  }

  private func exportSelectedProcess() {
    guard let selectedProcessForDetail else {
      return
    }

    copyToPasteboard(
      ProcessPresentation.exportRows([selectedProcessForDetail]), label: "Process export")
    store.statusMessage = "Copied process export"
    store.presentFeedback(
      title: "Process export copied",
      detail: store.displayName(for: selectedProcessForDetail),
      symbolName: "square.and.arrow.up",
      kind: .success
    )
  }

  private func exportVisibleProcesses() {
    copyToPasteboard(
      ProcessPresentation.exportRows(activeVisibleProcesses), label: "Visible rows export")
    store.statusMessage = "Copied \(activeVisibleProcesses.count) OS processes"
    store.presentFeedback(
      title: "Visible rows copied",
      detail:
        "\(activeVisibleProcesses.count) redacted OS process row\(activeVisibleProcesses.count == 1 ? "" : "s")",
      symbolName: "square.and.arrow.up",
      kind: .success
    )
  }

  private func matchesActivityType(_ item: ClassifiedDevProcess) -> Bool {
    activityTypeFilter.matches(
      isAutomated: store.liveSnapshot.automationLinksByProcessID[item.process.pid] != nil,
      isLongRunning: store.liveSnapshot.longRunningProcessIDs.contains(item.process.pid)
    )
  }

  private func processes(withIDs processIDs: [Int32]) -> [ClassifiedDevProcess] {
    let visibleIDs = Set(processIDs)
    return activityFilteredProcesses.filter { visibleIDs.contains($0.process.pid) }
  }

  private func alignSelectionWithActivityScope() {
    switch activityScope {
    case .workflows:
      if selectedWorkflow == nil {
        selectedCategoryID = intelligenceWorkflows.first?.id ?? ProcessPresentation.allCategoryID
      }
    case .processes:
      if selectedWorkflow != nil {
        selectedCategoryID = ProcessPresentation.allCategoryID
      }
    case .applications, .hierarchy:
      break
    }
  }

  private func copySelectedCommand() {
    guard let selectedProcessForDetail else {
      return
    }

    copyCommand(selectedProcessForDetail)
  }

  private func copyCommand(_ item: ClassifiedDevProcess) {
    copyToPasteboard(
      item.process.command,
      label: "Process command",
      recoveryText: ProcessPresentation.redactedCommand(item.process.command)
    )
    store.presentFeedback(
      title: "Command copied",
      detail: store.displayName(for: item),
      symbolName: "doc.on.doc.fill",
      kind: .success
    )
  }

  private func openSelectedFolder() {
    guard let selectedProcessForDetail,
      let currentDirectory = selectedProcessForDetail.process.currentDirectory
    else {
      return
    }

    let didOpen = NSWorkspace.shared.open(
      URL(fileURLWithPath: currentDirectory, isDirectory: true)
    )
    store.presentFeedback(
      title: didOpen ? "Folder opened" : "Folder unavailable",
      detail: didOpen ? currentDirectory : "macOS could not open this process folder.",
      symbolName: didOpen ? "folder.fill" : "folder.badge.questionmark",
      kind: didOpen ? .info : .warning
    )
  }

  private func toggledKeys(for item: ClassifiedDevProcess, in keys: Set<String>) -> String {
    var updated = keys
    let aliases = ProcessPresentation.identityKeys(for: item)
    if !updated.isDisjoint(with: aliases) {
      updated.subtract(aliases)
    } else {
      updated.insert(ProcessPresentation.identityKey(for: item))
    }
    return encodeKeys(updated)
  }

  private func decodeKeys(_ rawValue: String) -> Set<String> {
    Set(rawValue.split(separator: "\n").map(String.init))
  }

  private func encodeKeys(_ keys: Set<String>) -> String {
    keys.sorted().joined(separator: "\n")
  }

  private func migrateLegacySavedIdentityKeys() {
    favoriteProcessKeysRaw = encodeKeys(
      ProcessPresentation.sanitizedSavedIdentityKeys(decodeKeys(favoriteProcessKeysRaw))
    )
    watchedProcessKeysRaw = encodeKeys(
      ProcessPresentation.sanitizedSavedIdentityKeys(decodeKeys(watchedProcessKeysRaw))
    )
  }

  private func announceFeedback(_ feedback: ProcessActionFeedback) {
    let announcement = "\(feedback.title). \(feedback.detail)"
    let userInfo: [NSAccessibility.NotificationUserInfoKey: Any] = [
      .announcement: announcement,
      .priority: NSAccessibilityPriorityLevel.high.rawValue,
    ]
    NSAccessibility.post(
      element: NSApp as Any,
      notification: .announcementRequested,
      userInfo: userInfo
    )
  }

  private func copyToPasteboard(_ value: String, label: String, recoveryText: String? = nil) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
    do {
      lastCopiedPayload = try persistentCopyStore.save(text: recoveryText ?? value, label: label)
    } catch {
      store.presentFeedback(
        title: "Copy recovery failed",
        detail: error.localizedDescription,
        symbolName: "externaldrive.badge.exclamationmark",
        kind: .warning
      )
    }
  }

  private func loadLastCopiedPayload() {
    do {
      lastCopiedPayload = try persistentCopyStore.load()
    } catch {
      lastCopiedPayload = nil
      store.presentFeedback(
        title: "Copy recovery unavailable",
        detail: error.localizedDescription,
        symbolName: "externaldrive.badge.exclamationmark",
        kind: .warning
      )
    }
  }

  private func restoreLastCopiedPayload() {
    do {
      guard let payload = try persistentCopyStore.load() else {
        lastCopiedPayload = nil
        store.presentFeedback(
          title: "No saved copy",
          detail: "Copy or export a process first.",
          symbolName: "clipboard",
          kind: .info
        )
        return
      }

      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(payload.text, forType: .string)
      lastCopiedPayload = payload
      store.presentFeedback(
        title: "Redacted recovery copy restored",
        detail: payload.isTruncated
          ? "\(payload.label) · recovery cache was truncated" : payload.label,
        symbolName: "clipboard.fill",
        kind: payload.isTruncated ? .warning : .success
      )
    } catch {
      lastCopiedPayload = nil
      store.presentFeedback(
        title: "Restore failed",
        detail: error.localizedDescription,
        symbolName: "clipboard",
        kind: .error
      )
    }
  }

  private var feedbackTransition: AnyTransition {
    reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity)
  }

  private var workspaceMode: DevScopeWorkspaceMode {
    DevScopeWorkspaceMode(rawValue: workspaceModeRaw) ?? .processes
  }

  private var workspaceModeBinding: Binding<DevScopeWorkspaceMode> {
    Binding(
      get: { workspaceMode },
      set: { workspaceModeRaw = $0.rawValue }
    )
  }

  private var pendingKillBinding: Binding<Bool> {
    Binding(
      get: { pendingKillAction != nil },
      set: { presented in
        if !presented { pendingKillAction = nil }
      }
    )
  }
}

private extension View {
  func workspaceLayer(isActive: Bool) -> some View {
    opacity(isActive ? 1 : 0)
      .disabled(!isActive)
      .allowsHitTesting(isActive)
      .accessibilityHidden(!isActive)
  }
}

private struct AutomationIntegrationModifier: ViewModifier {
  @ObservedObject var processStore: ProcessStore
  @ObservedObject var automationStore: AutomationStore
  let automationNotifier: AutomationNotifier
  @AppStorage(DevScopeSettingsKey.longRunningThresholdSeconds) private var longRunningThresholdSeconds = 14_400.0
  @AppStorage(DevScopeSettingsKey.notifyLongRunningAutomation) private var notifyLongRunningAutomation = false
  @AppStorage(DevScopeSettingsKey.notifyUnexpectedAutomationExit) private var notifyUnexpectedAutomationExit = false
  @AppStorage(DevScopeSettingsKey.notifyRepeatedAutomationFailure) private var notifyRepeatedAutomationFailure = false

  func body(content: Content) -> some View {
    content
      .onChange(of: automationStore.snapshot) { _, snapshot in
        processStore.updateAutomationContext(
          inventory: snapshot,
          longRunningThreshold: AutomationPresentationSettings.normalizedThreshold(longRunningThresholdSeconds)
        )
      }
      .onChange(of: longRunningThresholdSeconds) { _, threshold in
        processStore.updateAutomationContext(
          inventory: automationStore.snapshot,
          longRunningThreshold: AutomationPresentationSettings.normalizedThreshold(threshold)
        )
      }
      .onChange(of: processStore.automationEvents) { _, events in
        guard !events.isEmpty else { return }
        Task {
          await automationNotifier.consume(events)
        }
      }
      .task {
        processStore.updateAutomationContext(
          inventory: automationStore.snapshot,
          longRunningThreshold: AutomationPresentationSettings.normalizedThreshold(longRunningThresholdSeconds)
        )
        await automationNotifier.synchronize(AutomationNotificationPreferences(
          crossedLongRunningThreshold: notifyLongRunningAutomation,
          unexpectedExit: notifyUnexpectedAutomationExit,
          repeatedFailure: notifyRepeatedAutomationFailure
        ))
        automationStore.start()
      }
      .onDisappear {
        automationStore.stop()
      }
  }
}

private struct ActionFeedbackBanner: View {
  let feedback: ProcessActionFeedback

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: feedback.symbolName)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 18, height: 18)

      VStack(alignment: .leading, spacing: 2) {
        Text(feedback.title)
          .font(.callout.weight(.semibold))
          .lineLimit(1)
        Text(feedback.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .truncationMode(.middle)
      }
      .frame(maxWidth: 300, alignment: .leading)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(tint.opacity(0.28), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
  }

  private var tint: Color {
    switch feedback.kind {
    case .success:
      .green
    case .warning:
      .orange
    case .error:
      .red
    case .info:
      DevScopePalette.accent
    }
  }
}

private struct CategoryRail: View {
  @Environment(\.openSettings) private var openSettings
  @Binding var selectedCategoryID: String
  @Binding var activityScope: ProcessActivityScope
  let workflows: [DevWorkflow]
  let categories: [DevProcessCategory]
  @Binding var isCollapsed: Bool
  let isEnhancingWorkflows: Bool
  let sponsorAction: () -> Void
  @State private var showsAllWorkflows = false
  @State private var showsRuntimeFilters = true

  var body: some View {
    VStack(spacing: 10) {
      RailHeader(isCollapsed: $isCollapsed)

      ScrollView {
        VStack(alignment: .leading, spacing: isCollapsed ? 6 : 8) {
          if !savedCategories.isEmpty {
            if !isCollapsed {
              RailSectionTitle(title: "Saved", detail: nil)
            }

            VStack(spacing: 3) {
              ForEach(savedCategories) { category in
                Button {
                  selectedCategoryID = category.id
                  activityScope = .processes
                } label: {
                  CategoryRailItem(
                    category: category,
                    isSelected: selectedCategoryID == category.id,
                    isCollapsed: isCollapsed
                  )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(category.title)
                .accessibilityValue("\(category.count) item\(category.count == 1 ? "" : "s")")
                .accessibilityHint("Filters the running activity list to \(category.title).")
                .accessibilityAddTraits(selectedCategoryID == category.id ? .isSelected : [])
                .help("Filter running activity by \(category.title)")
              }
            }
            .padding(.bottom, isCollapsed ? 0 : 2)
          }

          if !activityCategories.isEmpty {
            if !isCollapsed {
              RuntimeFiltersDisclosure(
                categories: activityCategories,
                selectedCategoryID: selectedCategoryID,
                isExpanded: $showsRuntimeFilters
              )
            }

            if isCollapsed || showsRuntimeFilters
              || activityCategories.contains(where: { $0.id == selectedCategoryID })
            {
              VStack(spacing: 2) {
                ForEach(activityCategories) { category in
                  Button {
                    selectedCategoryID = category.id
                    activityScope = .processes
                  } label: {
                    RuntimeRailItem(
                      category: category,
                      isSelected: selectedCategoryID == category.id,
                      isCollapsed: isCollapsed
                    )
                  }
                  .buttonStyle(.plain)
                  .accessibilityLabel(category.title)
                  .accessibilityValue("\(category.count) item\(category.count == 1 ? "" : "s")")
                  .accessibilityHint("Filters the running activity list to \(category.title).")
                  .accessibilityAddTraits(selectedCategoryID == category.id ? .isSelected : [])
                  .help("Filter running activity by \(category.title)")
                }
              }
              .padding(.leading, isCollapsed ? 0 : 12)
              .padding(.bottom, isCollapsed ? 0 : 4)
            }
          }

          if !workflows.isEmpty {
            if !isCollapsed {
              RailSectionTitle(
                title: "Focus",
                detail: isEnhancingWorkflows ? "Apple AI" : "\(workflows.count)"
              )
            }

            VStack(spacing: 4) {
              ForEach(visibleWorkflows) { workflow in
                Button {
                  selectedCategoryID = workflow.id
                  activityScope = .workflows
                } label: {
                  WorkflowRailItem(
                    workflow: workflow,
                    isSelected: selectedCategoryID == workflow.id,
                    isCollapsed: isCollapsed
                  )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(workflow.title)
                .accessibilityValue(workflow.subtitle)
                .accessibilityHint(workflow.summary)
                .accessibilityAddTraits(selectedCategoryID == workflow.id ? .isSelected : [])
                .help(workflow.summary)
              }

              if !isCollapsed && workflows.count > visibleWorkflows.count {
                RailDisclosureButton(
                  title: showsAllWorkflows
                    ? "Show fewer" : "Show \(workflows.count - visibleWorkflows.count) more",
                  systemImage: showsAllWorkflows ? "chevron.up" : "chevron.down",
                  tint: DevScopePalette.accent
                ) {
                  showsAllWorkflows.toggle()
                }
              }
            }
          }
        }
      }

      Divider()

      VStack(spacing: 3) {
        RailActionButton(
          title: "Support", symbolName: "cup.and.saucer.fill", tint: .pink,
          isCollapsed: isCollapsed, action: sponsorAction)
        RailActionButton(
          title: "Settings", symbolName: "gearshape", tint: .secondary, isCollapsed: isCollapsed
        ) {
          openSettings()
        }
      }
    }
    .padding(6)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(.white.opacity(0.08), lineWidth: 1)
    }
  }

  private var savedCategories: [DevProcessCategory] {
    categories.filter { category in
      category.id == ProcessPresentation.favoritesCategoryID
        || category.id == ProcessPresentation.watchedCategoryID
    }
  }

  private var activityCategories: [DevProcessCategory] {
    categories.filter { category in
      category.id != ProcessPresentation.favoritesCategoryID
        && category.id != ProcessPresentation.watchedCategoryID
    }
  }

  private var visibleWorkflows: [DevWorkflow] {
    guard !isCollapsed else {
      return workflows
    }

    return InterfacePresentation.visibleFocusWorkflows(
      workflows,
      selectedID: selectedCategoryID,
      showsAll: showsAllWorkflows
    )
  }
}

private func disclosureAnimation(reduceMotion: Bool) -> Animation? {
  reduceMotion ? nil : .snappy(duration: 0.18)
}

private struct RailHeader: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Binding var isCollapsed: Bool

  var body: some View {
    HStack {
      if !isCollapsed {
        Text("Control")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .textCase(.uppercase)
        Spacer()
      }

      Button {
        withAnimation(disclosureAnimation(reduceMotion: reduceMotion)) {
          isCollapsed.toggle()
        }
      } label: {
        Image(systemName: isCollapsed ? "sidebar.left" : "sidebar.leading")
          .accessibilityHidden(true)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(isCollapsed ? "Expand control panel" : "Collapse control panel")
      .accessibilityHint(isCollapsed ? "Shows the control panel." : "Hides the control panel.")
      .help(isCollapsed ? "Expand panel" : "Collapse panel")
    }
    .padding(.horizontal, isCollapsed ? 2 : 8)
  }
}

private struct RuntimeFiltersDisclosure: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let categories: [DevProcessCategory]
  let selectedCategoryID: String
  @Binding var isExpanded: Bool

  var body: some View {
    Button {
      withAnimation(disclosureAnimation(reduceMotion: reduceMotion)) {
        isExpanded.toggle()
      }
    } label: {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Label("Activity types", systemImage: "square.grid.2x2")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)

          Spacer()

          Text("\(runtimeOnlyCategories.count)")
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(.tertiary)

          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }

        RuntimeMixBar(runtimeCounts: runtimeCounts, height: 7)

        HStack(spacing: 7) {
          ForEach(topRuntimeCategories.prefix(3)) { category in
            HStack(spacing: 4) {
              Circle()
                .fill(color(for: category))
                .frame(width: 6, height: 6)
              Text(category.title)
                .lineLimit(1)
              Text("\(category.count)")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            }
            .font(.caption2)
            .foregroundStyle(selectedCategoryID == category.id ? .primary : .secondary)
          }
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 8)
      .background(
        .quaternary.opacity(0.20), in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(.white.opacity(0.08), lineWidth: 1)
      }
      .accessibilityHidden(true)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(isExpanded ? "Collapse activity types" : "Expand activity types")
    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    .accessibilityHint("Shows or hides dynamic activity filters.")
    .help(isExpanded ? "Hide activity filters" : "Show activity filters")
  }

  private var runtimeOnlyCategories: [DevProcessCategory] {
    categories.filter { category in
      DevRuntimeKind(rawValue: category.title) != nil
    }
  }

  private var runtimeCounts: [DevRuntimeKind: Int] {
    Dictionary(
      uniqueKeysWithValues: runtimeOnlyCategories.compactMap { category in
        guard let kind = DevRuntimeKind(rawValue: category.title) else {
          return nil
        }
        return (kind, category.count)
      }
    )
  }

  private var topRuntimeCategories: [DevProcessCategory] {
    runtimeOnlyCategories.sorted { lhs, rhs in
      if lhs.count != rhs.count {
        return lhs.count > rhs.count
      }
      return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
  }

  private func color(for category: DevProcessCategory) -> Color {
    if category.id == ProcessPresentation.allCategoryID {
      return DevScopePalette.accent
    }
    guard let kind = DevRuntimeKind(rawValue: category.title) else {
      return .secondary
    }
    return DevScopePalette.color(for: kind)
  }
}

private struct RuntimeRailItem: View {
  let category: DevProcessCategory
  let isSelected: Bool
  let isCollapsed: Bool

  var body: some View {
    HStack(spacing: isCollapsed ? 0 : 7) {
      if !isCollapsed {
        Capsule()
          .fill(color.opacity(0.45))
          .frame(width: 2, height: 20)
      }

      Image(systemName: category.symbolName)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(color)
        .frame(width: isCollapsed ? 30 : 16, height: 22)

      if !isCollapsed {
        Text(category.title)
          .font(.caption.weight(isSelected ? .semibold : .regular))
          .foregroundStyle(isSelected ? .primary : .secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.72)

        Spacer(minLength: 4)

        Text("\(category.count)")
          .font(.caption2.monospacedDigit().weight(.semibold))
          .foregroundStyle(isSelected ? .primary : .tertiary)
          .contentTransition(.numericText())
          .frame(width: 22, alignment: .trailing)
      }
    }
    .padding(.horizontal, isCollapsed ? 5 : 7)
    .padding(.vertical, 4)
    .background {
      if isSelected {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(color.opacity(0.14))
      }
    }
    .overlay {
      if isSelected {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .stroke(color.opacity(0.28), lineWidth: 1)
      }
    }
    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    .accessibilityHidden(true)
  }

  private var color: Color {
    if category.id == ProcessPresentation.allCategoryID {
      return DevScopePalette.accent
    }
    guard let kind = DevRuntimeKind(rawValue: category.title) else {
      return .secondary
    }
    return DevScopePalette.color(for: kind)
  }
}

private struct RailDisclosureButton: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let title: String
  let systemImage: String
  let tint: Color
  let action: () -> Void

  var body: some View {
    Button {
      withAnimation(disclosureAnimation(reduceMotion: reduceMotion)) {
        action()
      }
    } label: {
      Label(title, systemImage: systemImage)
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityHidden(true)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityHint(title)
    .help(title)
  }
}

private struct RailSectionTitle: View {
  let title: String
  let detail: String?

  var body: some View {
    HStack {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      Spacer()
      if let detail {
        Text(detail)
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 7)
    .padding(.top, 3)
  }
}

private struct WorkflowRailItem: View {
  let workflow: DevWorkflow
  let isSelected: Bool
  let isCollapsed: Bool

  var body: some View {
    HStack(spacing: isCollapsed ? 0 : 8) {
      Image(systemName: workflow.kind.symbolName)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(workflowColor)
        .frame(width: isCollapsed ? 30 : 34, height: 24)

      if !isCollapsed {
        VStack(alignment: .leading, spacing: 2) {
          Text(workflow.title)
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .lineLimit(1)

          Text(workflow.subtitle)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        .layoutPriority(1)

        Spacer(minLength: 4)

        Text(riskLabel)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(riskColor)
          .lineLimit(1)
          .frame(width: 38, alignment: .trailing)
      }
    }
    .padding(.horizontal, isCollapsed ? 5 : 8)
    .padding(.vertical, 5)
    .frame(minHeight: isCollapsed ? 34 : 38, alignment: .center)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      if isSelected {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(workflowColor.opacity(0.16))
      }
    }
    .overlay {
      if isSelected {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .stroke(workflowColor.opacity(0.34), lineWidth: 1)
      }
    }
    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    .accessibilityHidden(true)
  }

  private var workflowColor: Color {
    switch workflow.kind {
    case .aiMLLab, .localLLMStack:
      .pink
    case .notebookSession, .dataApp:
      .cyan
    case .trainingRun:
      .orange
    case .apiService, .webWorkspace:
      .indigo
    case .vectorDatabase:
      .purple
    case .buildWorkspace:
      .blue
    case .projectWorkspace, .runtimeGroup:
      DevScopePalette.accent
    }
  }

  private var riskLabel: String {
    switch workflow.risk {
    case .normal:
      ""
    case .busy:
      "Busy"
    case .heavy:
      "Heavy"
    }
  }

  private var riskColor: Color {
    switch workflow.risk {
    case .normal:
      .secondary
    case .busy:
      .orange
    case .heavy:
      .red
    }
  }
}

private struct CategoryRailItem: View {
  let category: DevProcessCategory
  let isSelected: Bool
  let isCollapsed: Bool

  var body: some View {
    HStack(spacing: isCollapsed ? 0 : 8) {
      Image(systemName: category.symbolName)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(iconColor)
        .frame(width: isCollapsed ? 30 : 18, height: 24)

      if !isCollapsed {
        Text(category.title)
          .font(.subheadline.weight(isSelected ? .semibold : .regular))
          .foregroundStyle(isSelected ? .primary : .secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.72)
          .layoutPriority(1)

        Spacer()

        Text("\(category.count)")
          .font(.caption.monospacedDigit().weight(.semibold))
          .foregroundStyle(isSelected ? .primary : .tertiary)
          .contentTransition(.numericText())
          .lineLimit(1)
          .minimumScaleFactor(0.75)
          .frame(width: 26, alignment: .trailing)
      }
    }
    .padding(.horizontal, isCollapsed ? 5 : 8)
    .padding(.vertical, 6)
    .background {
      if isSelected {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(DevScopePalette.accent.opacity(0.16))
      }
    }
    .overlay {
      if isSelected {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .stroke(DevScopePalette.accent.opacity(0.36), lineWidth: 1)
      }
    }
    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    .accessibilityHidden(true)
  }

  private var iconColor: Color {
    if category.id == ProcessPresentation.allCategoryID {
      DevScopePalette.accent
    } else if category.id == ProcessPresentation.favoritesCategoryID {
      .yellow
    } else if category.id == ProcessPresentation.watchedCategoryID {
      .cyan
    } else if let kind = DevRuntimeKind(rawValue: category.title) {
      DevScopePalette.color(for: kind)
    } else {
      .secondary
    }
  }
}

private struct RailActionButton: View {
  let title: String
  let symbolName: String
  let tint: Color
  let isCollapsed: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: isCollapsed ? 0 : 8) {
        Image(systemName: symbolName)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(tint)
          .frame(width: isCollapsed ? 30 : 18, height: 24)
        if !isCollapsed {
          Text(title)
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Spacer()
        }
      }
      .padding(.horizontal, isCollapsed ? 5 : 8)
      .padding(.vertical, 6)
      .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
      .accessibilityHidden(true)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityHint("Opens \(title).")
    .help(title)
  }
}

private struct ControlStrip: View {
  @Binding var searchText: String
  @Binding var activityScope: ProcessActivityScope
  let selectedCategoryTitle: String
  let visibleProcessCount: Int
  let totalProcessCount: Int
  let applicationCount: Int
  @Binding var activityTypeFilter: AutomationActivityTypeFilter

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        ProcessScopePicker(selection: $activityScope)

        Spacer(minLength: 12)

        Text(resultText)
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      HStack(spacing: 12) {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(.tertiary)

          TextField("Search application, project, command, PID, folder", text: $searchText)
            .textFieldStyle(.plain)

          if !searchText.isEmpty {
            Button {
              searchText = ""
            } label: {
              Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .accessibilityLabel("Clear search")
            .help("Clear search")
            .transition(.scale.combined(with: .opacity))
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .softPanel(cornerRadius: 10)
        .frame(maxWidth: 520)

        Spacer()

        Picker("Activity Type", selection: $activityTypeFilter) {
          ForEach(AutomationActivityTypeFilter.allCases, id: \.self) { filter in
            Text(filter.displayTitle).tag(filter)
          }
        }
        .frame(width: 170)
        .accessibilityHint("Filters Automated and Long Running signals independently or together.")
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(.bar, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(.white.opacity(0.08), lineWidth: 1)
    }
  }

  private var resultText: String {
    switch activityScope {
    case .applications:
      return "\(applicationCount) applications · \(visibleProcessCount) OS processes"
    case .processes, .hierarchy, .workflows:
      if selectedCategoryTitle == "All"
        && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && activityTypeFilter == .all
      {
        return "\(totalProcessCount) OS processes"
      }
      return
        "\(visibleProcessCount) of \(totalProcessCount) OS processes · \(selectedCategoryTitle)"
    }
  }
}

private extension AutomationActivityTypeFilter {
  var displayTitle: String {
    switch self {
    case .all: "All Activity"
    case .automated: "Automated"
    case .longRunning: "Long Running"
    case .both: "Both"
    }
  }
}

struct DevScopeBackground: View {
  var body: some View {
    ZStack {
      LinearGradient(
        colors: [
          DevScopePalette.backgroundTop,
          DevScopePalette.backgroundBottom,
          Color(nsColor: .controlBackgroundColor),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )

      RadialGradient(
        colors: [
          DevScopePalette.accent.opacity(0.18),
          .clear,
        ],
        center: .topLeading,
        startRadius: 40,
        endRadius: 520
      )
      .opacity(0.65)
    }
    .ignoresSafeArea()
  }
}

private struct LiveActivityHeightPreferenceKey: PreferenceKey {
  static let defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = nextValue()
  }
}

private enum KillAction: Identifiable {
  case single(ClassifiedDevProcess)
  case tree(ClassifiedDevProcess)
  case forceSingle(ClassifiedDevProcess)
  case forceTree(ClassifiedDevProcess)

  var process: ClassifiedDevProcess {
    switch self {
    case .single(let process), .tree(let process),
      .forceSingle(let process), .forceTree(let process):
      return process
    }
  }

  var id: String {
    switch self {
    case .single(let process):
      "single-\(process.process.pid)"
    case .tree(let process):
      "tree-\(process.process.pid)"
    case .forceSingle(let process):
      "force-single-\(process.process.pid)"
    case .forceTree(let process):
      "force-tree-\(process.process.pid)"
    }
  }

  var title: String {
    switch self {
    case .single(let process):
      "Terminate \(process.classification.displayName)?"
    case .tree(let process):
      "Terminate \(process.classification.displayName) and children?"
    case .forceSingle(let process):
      "Force kill \(process.classification.displayName)?"
    case .forceTree(let process):
      "Force kill \(process.classification.displayName) and children?"
    }
  }

  var buttonTitle: String {
    switch self {
    case .single:
      "Send TERM"
    case .tree:
      "Send TERM to Tree"
    case .forceSingle:
      "Send KILL"
    case .forceTree:
      "Send KILL to Tree"
    }
  }

  private var terminationAction: ProcessTerminationAction {
    switch self {
    case .single:
      .single
    case .tree:
      .tree
    case .forceSingle:
      .forceSingle
    case .forceTree:
      .forceTree
    }
  }

  func consequence(descendantCount: Int) -> String {
    terminationAction.consequence(
      pid: process.process.pid,
      descendantCount: descendantCount
    )
  }
}
