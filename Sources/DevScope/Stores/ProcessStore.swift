import DevScopeCore
import Foundation

struct ProcessActionFeedback: Identifiable, Equatable {
  enum Kind: Equatable {
    case success
    case warning
    case error
    case info
  }

  let id = UUID()
  let title: String
  let detail: String
  let symbolName: String
  let kind: Kind
}

private enum SignalVerificationContext {
  case complete
  case partial(failedTarget: ProcessIdentity, reason: String)
}

private struct PendingSignalVerification {
  let targets: [ProcessIdentity]
  let signalName: String
  let context: SignalVerificationContext
}

@MainActor
final class ProcessStore: ObservableObject {
  @Published private(set) var liveSnapshot = ProcessStoreLiveSnapshot()
  @Published private(set) var enhancedNames: [ProcessCacheIdentity: String] = [:]
  @Published private(set) var workflowNotes: [String: WorkflowAINote] = [:]
  @Published private(set) var isRefreshing = false
  @Published private(set) var isEnhancingNames = false
  @Published private(set) var isEnhancingWorkflows = false
  @Published private(set) var actionFeedback: ProcessActionFeedback?
  @Published private(set) var automationEvents: [AutomationEvent] = []

  var processes: [DevProcess] { liveSnapshot.processes }
  var classifiedProcesses: [ClassifiedDevProcess] { liveSnapshot.classifiedProcesses }
  var workflows: [DevWorkflow] { liveSnapshot.workflows }
  var dashboardMetricHistory: [DevProcessMetricSample] { liveSnapshot.dashboardMetricHistory }
  var liveProcessIDs: Set<Int32> { liveSnapshot.liveProcessIDs }
  var statusMessage: String {
    get { liveSnapshot.statusMessage }
    set { liveSnapshot.statusMessage = newValue }
  }
  var lastRefresh: Date? { liveSnapshot.lastRefresh }

  private let scanner: ProcessProviding
  private let gpuMetricProvider: GPUMetricProviding
  private let killer: ProcessKiller
  private let nameEnhancer = ProcessNameEnhancer()
  private let workflowEnhancer = WorkflowIntelligenceEnhancer()
  private let snapshotWorker = ProcessSnapshotWorker()
  private var processMetricHistory = ProcessMetricHistoryStore(limit: 120)
  private var automaticRefreshTask: Task<Void, Never>?
  private var feedbackDismissalTask: Task<Void, Never>?
  private var pendingSignalVerifications: [PendingSignalVerification] = []
  private var automationContext = AutomationPresentationContext(
    inventory: ProcessStoreLiveSnapshot.emptyAutomationInventory,
    longRunningThreshold: AutomationPresentationContext.defaultLongRunningThreshold
  )
  private var automationContextVersion: UInt64 = 0
  private var automationEventDetector = AutomationEventDetector()
  private var previousAutomationPresentation: AutomationPresentationSnapshot?
  private var resetAutomationEventBaselineOnNextScan = false
  private var isScanInFlight = false
  private var manualRefreshPending = false
  private var lastCurrentDirectoryRefresh = Date.distantPast
  private var lastNameEnhancement = Date.distantPast
  private var lastWorkflowEnhancement = Date.distantPast
  private var lastGPUMetricRefresh = Date.distantPast
  private var cachedGPUMetric: DevGPUMetric?
  private let currentDirectoryRefreshInterval: TimeInterval = 120
  private let gpuMetricRefreshInterval: TimeInterval = 10
  private let automaticRefreshInterval: Duration = .seconds(2)
  private let nameEnhancementInterval: TimeInterval = 300
  private let workflowEnhancementInterval: TimeInterval = 300
  private let missingProcessGraceInterval: TimeInterval = 2.5
  private let maxDashboardMetricSamples = 180
  var usesAppleNaming = true

  init(
    scanner: ProcessProviding = SystemProcessScanner(),
    gpuMetricProvider: GPUMetricProviding = SystemGPUMetricProvider(),
    killer: ProcessKiller = ProcessKiller()
  ) {
    self.scanner = scanner
    self.gpuMetricProvider = gpuMetricProvider
    self.killer = killer
  }

  deinit {
    automaticRefreshTask?.cancel()
    feedbackDismissalTask?.cancel()
  }

  func startRealtimeUpdates() {
    guard automaticRefreshTask == nil else {
      return
    }

    automaticRefreshTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled else {
        return
      }
      self?.refresh()

      while !Task.isCancelled {
        try? await Task.sleep(for: self?.automaticRefreshInterval ?? .seconds(2))
        guard !Task.isCancelled else {
          return
        }
        self?.refresh(isAutomatic: true)
      }
    }
  }

  func stopRealtimeUpdates() {
    automaticRefreshTask?.cancel()
    automaticRefreshTask = nil
  }

  func updateAutomationContext(
    inventory: AutomationInventorySnapshot,
    longRunningThreshold: TimeInterval
  ) {
    let nextContext = AutomationPresentationContext(
      inventory: inventory,
      longRunningThreshold: longRunningThreshold
    )
    guard nextContext != automationContext else { return }
    if nextContext.longRunningThreshold != automationContext.longRunningThreshold {
      resetAutomationEventBaselineOnNextScan = true
    }
    automationContext = nextContext
    automationContextVersion &+= 1

    let projection = nextContext.build(
      processes: liveSnapshot.processes,
      now: liveSnapshot.lastRefresh ?? Date()
    )
    liveSnapshot = liveSnapshot.replacingAutomationProjection(projection)
  }

  func refresh(isAutomatic: Bool = false) {
    guard !isScanInFlight else {
      if !isAutomatic {
        manualRefreshPending = true
        isRefreshing = true
      }
      return
    }

    let scanner = scanner
    let gpuMetricProvider = gpuMetricProvider
    let existingProcesses = processes
    let capturedAutomationContext = automationContext
    let capturedAutomationContextVersion = automationContextVersion
    let includeCurrentDirectories = shouldRefreshCurrentDirectories(isAutomatic: isAutomatic)
    let includeGPUMetric = shouldRefreshGPUMetric(isAutomatic: isAutomatic)
    isScanInFlight = true
    if !isAutomatic {
      isRefreshing = true
    }

    Task { @MainActor in
      do {
        if includeCurrentDirectories {
          await snapshotWorker.invalidateWorkspaceFacts()
        }
        let scanResult = try await Task.detached(priority: .userInitiated) {
          let processes = try scanner.snapshot(includeCurrentDirectories: includeCurrentDirectories)
          let gpuMetric = includeGPUMetric ? try? gpuMetricProvider.snapshot() : nil
          return (processes: processes, gpuMetric: gpuMetric)
        }.value
        if includeGPUMetric {
          cachedGPUMetric = scanResult.gpuMetric
          lastGPUMetricRefresh = Date()
        }
        let effectiveGPUMetric = includeGPUMetric ? scanResult.gpuMetric : cachedGPUMetric
        let mergedSnapshot = mergeCurrentDirectories(
          into: scanResult.processes,
          from: existingProcesses,
          includeCurrentDirectories: includeCurrentDirectories
        )
        let timestamp = Date()
        let presentationSnapshot = await snapshotWorker.build(
          processes: mergedSnapshot,
          now: timestamp,
          graceInterval: missingProcessGraceInterval
        )
        processMetricHistory.record(
          processes: mergedSnapshot,
          gpuMetric: effectiveGPUMetric,
          timestamp: timestamp
        )
        let nextDashboardHistory = updatedDashboardMetricHistory(
          current: liveSnapshot.dashboardMetricHistory,
          processes: mergedSnapshot,
          gpuMetric: effectiveGPUMetric,
          timestamp: timestamp
        )
        let newestAutomationContext = capturedAutomationContextVersion == automationContextVersion
          ? capturedAutomationContext
          : automationContext
        let automationPresentation = newestAutomationContext.build(
          processes: presentationSnapshot.processes,
          now: timestamp
        )
        automationEvents = automationEventDetector.events(
          previous: resetAutomationEventBaselineOnNextScan
            ? nil : previousAutomationPresentation,
          current: automationPresentation,
          now: timestamp
        )
        previousAutomationPresentation = automationPresentation
        resetAutomationEventBaselineOnNextScan = false
        liveSnapshot = ProcessStoreLiveSnapshot(
          processes: presentationSnapshot.processes,
          classifiedProcesses: presentationSnapshot.classified,
          workflows: presentationSnapshot.workflows,
          dashboardMetricHistory: nextDashboardHistory,
          liveProcessIDs: presentationSnapshot.liveProcessIDs,
          automationInventory: automationPresentation.inventory,
          automationLinksByProcessID: automationPresentation.linksByProcessID,
          allAutomationLinksByProcessID: automationPresentation.allLinksByProcessID,
          longRunningProcessIDs: automationPresentation.longRunningProcessIDs,
          statusMessage: "\(presentationSnapshot.liveProcessIDs.count) running items found",
          lastRefresh: timestamp
        )
        let enhanceableIdentities = Set(
          presentationSnapshot.classified
            .filter(isEnhanceableForNaming)
            .map { ProcessCacheIdentity(process: $0.process) }
        )
        enhancedNames = enhancedNames.filter { enhanceableIdentities.contains($0.key) }
        workflowNotes = workflowNotes.filter { entry in
          presentationSnapshot.workflows.contains { $0.id == entry.key }
        }
        if includeCurrentDirectories {
          lastCurrentDirectoryRefresh = timestamp
        }
        if usesAppleNaming && shouldEnhanceNames(isAutomatic: isAutomatic) {
          let liveItems = presentationSnapshot.classified.filter {
            presentationSnapshot.liveProcessIDs.contains($0.process.pid)
          }
          enhanceVisibleNamesIfAvailable(items: liveItems)
        }
        if usesAppleNaming && shouldEnhanceWorkflows(isAutomatic: isAutomatic) {
          enhanceWorkflowNotesIfAvailable(
            workflows: presentationSnapshot.workflows,
            items: presentationSnapshot.classified
          )
        }
        resolvePendingSignalVerifications()
      } catch {
        statusMessage = error.localizedDescription
      }
      isScanInFlight = false
      if manualRefreshPending {
        manualRefreshPending = false
        refresh()
      } else if !isAutomatic {
        isRefreshing = false
      }
    }
  }

  func displayName(for item: ClassifiedDevProcess) -> String {
    guard usesAppleNaming,
          let enhancedName = enhancedNames[ProcessCacheIdentity(process: item.process)],
          ProcessNameEnhancer.isSafeDisplayName(enhancedName, fallback: item.classification.displayName) else {
      return item.classification.displayName
    }

    return enhancedName
  }

  func metricHistory(for processID: Int32) -> [DevProcessMetricSample] {
    processMetricHistory.history(for: processID)
  }

  func familySummary(for process: DevProcess) -> ProcessFamilySummary {
    ProcessPresentation.familySummary(for: process, in: processes)
  }

  func isProcessLive(pid: Int32) -> Bool {
    liveProcessIDs.contains(pid)
  }

  private func enhanceVisibleNamesIfAvailable(items classifiedItems: [ClassifiedDevProcess]) {
    guard !isEnhancingNames else {
      return
    }

    let items = Array(classifiedItems.filter(isEnhanceableForNaming).prefix(8))
    guard !items.isEmpty else {
      return
    }

    let enhancer = nameEnhancer
    isEnhancingNames = true

    Task { @MainActor in
      lastNameEnhancement = Date()
      guard await enhancer.isAvailable() else {
        isEnhancingNames = false
        return
      }

      await enhancer.retainOnly(
        identities: Set(items.map { ProcessCacheIdentity(process: $0.process) })
      )
      var names: [ProcessCacheIdentity: String] = [:]

      for item in items {
        if let enhancedName = await enhancer.enhancedName(for: item) {
          names[ProcessCacheIdentity(process: item.process)] = enhancedName
        }
      }

      enhancedNames.merge(names) { _, new in new }
      isEnhancingNames = false
    }
  }

  private func enhanceWorkflowNotesIfAvailable(workflows: [DevWorkflow], items: [ClassifiedDevProcess]) {
    guard !isEnhancingWorkflows, !workflows.isEmpty else {
      return
    }

    let enhancer = workflowEnhancer
    isEnhancingWorkflows = true

    Task { @MainActor in
      lastWorkflowEnhancement = Date()
      let notes = await enhancer.notes(for: workflows, items: items)
      if !notes.isEmpty {
        workflowNotes.merge(notes) { _, new in new }
      }
      isEnhancingWorkflows = false
    }
  }

  func actionDecision(for item: ClassifiedDevProcess) -> ProcessActionDecision {
    ProcessActionPolicy.decision(
      for: item,
      currentProcessID: Int32(ProcessInfo.processInfo.processIdentifier)
    )
  }

  private func allowSignal(_ item: ClassifiedDevProcess) -> Bool {
    let decision = actionDecision(for: item)
    guard let reason = decision.reason else { return true }
    statusMessage = reason
    presentFeedback(
      title: "Process protected",
      detail: reason,
      symbolName: "lock.shield.fill",
      kind: .warning
    )
    return false
  }

  func terminate(_ item: ClassifiedDevProcess) {
    guard allowSignal(item) else { return }
    let process = item.process
    do {
      let targets = try killer.terminate(
        item,
        currentProcessID: Int32(ProcessInfo.processInfo.processIdentifier)
      )
      statusMessage = "Sent TERM to PID \(process.pid)"
      presentFeedback(
        title: "TERM sent",
        detail: "\(process.executable) · PID \(process.pid)",
        symbolName: "xmark.circle",
        kind: .info
      )
      scheduleSignalVerification(targets: targets, signalName: "TERM")
    } catch {
      handleSignalExecutionError(error, signalName: "TERM")
    }
  }

  func forceTerminate(_ item: ClassifiedDevProcess) {
    guard allowSignal(item) else { return }
    let process = item.process
    do {
      let targets = try killer.forceTerminate(
        item,
        currentProcessID: Int32(ProcessInfo.processInfo.processIdentifier)
      )
      statusMessage = "Sent KILL to PID \(process.pid)"
      presentFeedback(
        title: "KILL sent",
        detail: "\(process.executable) · PID \(process.pid)",
        symbolName: "bolt.fill",
        kind: .warning
      )
      scheduleSignalVerification(targets: targets, signalName: "KILL")
    } catch {
      handleSignalExecutionError(error, signalName: "KILL")
    }
  }

  func terminateTree(root item: ClassifiedDevProcess) {
    guard allowSignal(item) else { return }
    do {
      let targets = try killer.terminateTree(
        root: item,
        processes: processes,
        classifiedProcesses: classifiedProcesses,
        currentProcessID: Int32(ProcessInfo.processInfo.processIdentifier)
      )
      statusMessage = "Sent TERM to \(targets.count) processes"
      presentFeedback(
        title: "TERM tree sent",
        detail: "\(targets.count) process\(targets.count == 1 ? "" : "es") signaled",
        symbolName: "point.3.connected.trianglepath.dotted",
        kind: .info
      )
      scheduleSignalVerification(targets: targets, signalName: "TERM")
    } catch {
      handleSignalExecutionError(error, signalName: "TERM")
    }
  }

  func forceTerminateTree(root item: ClassifiedDevProcess) {
    guard allowSignal(item) else { return }
    do {
      let targets = try killer.forceTerminateTree(
        root: item,
        processes: processes,
        classifiedProcesses: classifiedProcesses,
        currentProcessID: Int32(ProcessInfo.processInfo.processIdentifier)
      )
      statusMessage = "Sent KILL to \(targets.count) processes"
      presentFeedback(
        title: "KILL tree sent",
        detail: "\(targets.count) process\(targets.count == 1 ? "" : "es") signaled",
        symbolName: "bolt.horizontal.fill",
        kind: .warning
      )
      scheduleSignalVerification(targets: targets, signalName: "KILL")
    } catch {
      handleSignalExecutionError(error, signalName: "KILL")
    }
  }

  func presentFeedback(
    title: String,
    detail: String,
    symbolName: String,
    kind: ProcessActionFeedback.Kind = .info
  ) {
    actionFeedback = ProcessActionFeedback(
      title: title,
      detail: detail,
      symbolName: symbolName,
      kind: kind
    )

    feedbackDismissalTask?.cancel()
    feedbackDismissalTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled else {
        return
      }
      await MainActor.run {
        self?.actionFeedback = nil
      }
    }
  }

  private func scheduleSignalVerification(
    targets: [ProcessIdentity],
    signalName: String,
    context: SignalVerificationContext = .complete
  ) {
    var seenPIDs = Set<Int32>()
    let targets = targets.filter { seenPIDs.insert($0.pid).inserted }
    guard !targets.isEmpty else { return }

    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(700))
      guard !Task.isCancelled, let self else { return }
      pendingSignalVerifications.append(
        PendingSignalVerification(
          targets: targets,
          signalName: signalName,
          context: context
        )
      )
      refresh()
    }
  }

  private func resolvePendingSignalVerifications() {
    guard !pendingSignalVerifications.isEmpty else { return }
    let verifications = pendingSignalVerifications
    pendingSignalVerifications.removeAll()
    let currentProcesses = processes.filter { liveProcessIDs.contains($0.pid) }

    for verification in verifications {
      let observation = ProcessSignalObservation.observe(
        targets: verification.targets,
        in: currentProcesses
      )
      switch verification.context {
      case .complete:
        presentCompleteSignalVerification(
          observation,
          signalName: verification.signalName
        )
      case let .partial(failedTarget, reason):
        let presentation = ProcessPartialSignalVerificationPresentation.make(
          signalName: verification.signalName,
          observation: observation,
          failedTarget: failedTarget,
          reason: reason
        )
        statusMessage = presentation.statusMessage
        presentFeedback(
          title: presentation.title,
          detail: presentation.detail,
          symbolName: presentation.symbolName,
          kind: .warning
        )
      }
    }
  }

  private func presentCompleteSignalVerification(
    _ observation: ProcessSignalObservationSummary,
    signalName: String
  ) {
    let targetPIDs = observation.observations.map(\.target.pid)
    if !observation.unverifiable.isEmpty {
      let unverifiablePIDs = observation.unverifiable.map(\.pid).sorted()
      let stillRunningPIDs = observation.stillRunning.map(\.pid).sorted()
      var details = [
        "Could not verify birth identity for: \(unverifiablePIDs.map(String.init).joined(separator: ", "))"
      ]
      if !stillRunningPIDs.isEmpty {
        details.append("Still running: \(stillRunningPIDs.map(String.init).joined(separator: ", "))")
      }
      statusMessage = "\(signalName) result could not be verified"
      presentFeedback(
        title: "Signal result not verified",
        detail: details.joined(separator: ". "),
        symbolName: "questionmark.circle.fill",
        kind: .warning
      )
    } else if observation.verifiesAllTargetsStopped {
      let detail = targetPIDs.count == 1
        ? "PID \(targetPIDs[0]) exited"
        : "\(targetPIDs.count) processes exited"
      statusMessage = "\(signalName) completed"
      presentFeedback(
        title: "Process stopped",
        detail: detail,
        symbolName: "checkmark.circle.fill",
        kind: .success
      )
    } else {
      let stillRunning = observation.stillRunning
      statusMessage = "\(stillRunning.count) process\(stillRunning.count == 1 ? "" : "es") still running"
      presentFeedback(
        title: "\(signalName) still pending",
        detail: "Still running: \(stillRunning.map(\.pid).sorted().map(String.init).joined(separator: ", "))",
        symbolName: "exclamationmark.triangle.fill",
        kind: .warning
      )
    }
  }

  private func presentSignalError(_ error: Error) {
    presentFeedback(
      title: "Signal failed",
      detail: error.localizedDescription,
      symbolName: "xmark.octagon.fill",
      kind: .error
    )
  }

  private func handleSignalExecutionError(_ error: Error, signalName: String) {
    guard let failure = error as? ProcessSignalExecutionFailure,
          !failure.signaledIdentities.isEmpty else {
      let underlyingError = (error as? ProcessSignalExecutionFailure)?.underlyingError ?? error
      statusMessage = underlyingError.localizedDescription
      presentSignalError(underlyingError)
      return
    }

    let signaledCount = failure.signaledIdentities.count
    scheduleSignalVerification(
      targets: failure.signaledIdentities,
      signalName: signalName,
      context: .partial(
        failedTarget: failure.failedTarget,
        reason: failure.underlyingError.localizedDescription
      )
    )
    statusMessage = "\(signalName) partially completed: \(signaledCount) signaled; PID \(failure.failedTarget.pid) failed"
    presentFeedback(
      title: "\(signalName) partially completed",
      detail: "\(failure.localizedDescription). Earlier signals remain in effect.",
      symbolName: "exclamationmark.triangle.fill",
      kind: .warning
    )
  }

  private func shouldRefreshCurrentDirectories(isAutomatic: Bool) -> Bool {
    !isAutomatic || lastRefresh == nil || Date().timeIntervalSince(lastCurrentDirectoryRefresh) >= currentDirectoryRefreshInterval
  }

  private func shouldRefreshGPUMetric(isAutomatic: Bool) -> Bool {
    !isAutomatic || lastRefresh == nil || Date().timeIntervalSince(lastGPUMetricRefresh) >= gpuMetricRefreshInterval
  }

  private func shouldEnhanceNames(isAutomatic: Bool) -> Bool {
    !isAutomatic || Date().timeIntervalSince(lastNameEnhancement) >= nameEnhancementInterval
  }

  private func shouldEnhanceWorkflows(isAutomatic: Bool) -> Bool {
    !isAutomatic || Date().timeIntervalSince(lastWorkflowEnhancement) >= workflowEnhancementInterval
  }

  private func isEnhanceableForNaming(_ item: ClassifiedDevProcess) -> Bool {
    item.classification.kind != .ai && item.classification.kind != .other && item.classification.kind != .shell
  }

  private func updatedDashboardMetricHistory(
    current: [DevProcessMetricSample],
    processes: [DevProcess],
    gpuMetric: DevGPUMetric?,
    timestamp: Date
  ) -> [DevProcessMetricSample] {
    var updated = current
    let usage = processes.compactMap(\.resourceUsage)
    let totalCPU = usage.reduce(0) { $0 + $1.cpuPercent }
    let totalMemory = usage.reduce(Int64(0)) { $0 + $1.residentMemoryBytes }

    updated.append(
      DevProcessMetricSample(
        timestamp: timestamp,
        cpuPercent: totalCPU,
        residentMemoryBytes: totalMemory,
        gpuPercent: gpuMetric?.utilizationPercent
      )
    )

    if updated.count > maxDashboardMetricSamples {
      updated.removeFirst(updated.count - maxDashboardMetricSamples)
    }

    return updated
  }

  private func mergeCurrentDirectories(
    into snapshot: [DevProcess],
    from existingProcesses: [DevProcess],
    includeCurrentDirectories: Bool
  ) -> [DevProcess] {
    guard !includeCurrentDirectories else {
      return snapshot
    }

    let existingByPID = Dictionary(uniqueKeysWithValues: existingProcesses.map { ($0.pid, $0) })
    return snapshot.map { process in
      guard process.currentDirectory == nil,
            let previous = existingByPID[process.pid],
            let currentDirectory = ProcessScanner.carriedCurrentDirectory(
              from: previous,
              to: process
            ) else {
        return process
      }

      return DevProcess(
        pid: process.pid,
        parentPID: process.parentPID,
        executable: process.executable,
        command: process.command,
        argumentVector: process.argumentVector,
        currentDirectory: currentDirectory,
        resourceUsage: process.resourceUsage,
        birthToken: process.birthToken,
        bundleIdentifier: process.bundleIdentifier,
        launchLabel: process.launchLabel
      )
    }
  }

}
