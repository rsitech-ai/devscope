import DevScopeCore
import Foundation

struct AutomationPendingOperation: Equatable, Sendable {
  let recordID: AutomationRecord.ID
  let operation: AutomationOperation
  let startedAt: Date
}

struct AutomationCapabilitySnapshot: Equatable, Sendable {
  static let empty = AutomationCapabilitySnapshot(
    inventoryGeneration: 0,
    decisionsByRecordID: [:]
  )

  let inventoryGeneration: UInt64
  let decisionsByRecordID: [AutomationRecord.ID: AutomationCapabilityDecision]
}

protocol AutomationCapabilityDecisionProviding: Sendable {
  func decisions(
    for records: [AutomationRecord]
  ) async -> [AutomationRecord.ID: AutomationCapabilityDecision]
}

protocol AutomationManagementDestinationProviding: Sendable {
  func duplicateDestination(for record: AutomationRecord, label: String) -> URL?
  func importDestination(for record: AutomationRecord, suggestedFilename: String) -> URL?
}

private struct UnavailableAutomationManagementDestinationProvider:
  AutomationManagementDestinationProviding
{
  func duplicateDestination(for record: AutomationRecord, label: String) -> URL? { nil }
  func importDestination(for record: AutomationRecord, suggestedFilename: String) -> URL? { nil }
}

private struct UnavailableAutomationCapabilityDecisionProvider:
  AutomationCapabilityDecisionProviding
{
  func decisions(
    for records: [AutomationRecord]
  ) async -> [AutomationRecord.ID: AutomationCapabilityDecision] {
    [:]
  }
}

protocol AutomationInventoryRefreshing: Sendable {
  func refresh(force: Bool) async -> AutomationInventorySnapshot
  func refreshAfterCurrent() async -> AutomationInventorySnapshot
}

extension AutomationInventoryService: AutomationInventoryRefreshing {}

protocol AutomationManaging: Sendable {
  func perform(
    _ operation: AutomationOperation,
    record: AutomationRecord,
    expectedChecksum: String?,
    linkedProcesses: [ClassifiedDevProcess]
  ) async -> AutomationOperationResult

  func restorationManifests() async -> [AutomationBackup]
}

extension AutomationManager: AutomationManaging {}

extension AutomationManaging {
  func restorationManifests() async -> [AutomationBackup] { [] }
}

@MainActor
final class AutomationStore: ObservableObject {
  typealias Sleep = @Sendable (Duration) async throws -> Void

  private enum RefreshMode: Int {
    case automatic
    case force
    case afterCurrent

    func merged(with other: RefreshMode) -> RefreshMode {
      rawValue >= other.rawValue ? self : other
    }
  }

  @Published private(set) var snapshot = ProcessStoreLiveSnapshot.emptyAutomationInventory
  @Published private(set) var isRefreshing = false
  @Published private(set) var pendingOperation: AutomationPendingOperation?
  @Published private(set) var operationResult: AutomationOperationResult?
  @Published private(set) var operationResultRecordID: AutomationRecord.ID?
  @Published private(set) var capabilitySnapshot = AutomationCapabilitySnapshot.empty
  @Published private(set) var backups: [AutomationBackup] = []
  @Published var selectedRecordID: AutomationRecord.ID?

  private let inventoryService: any AutomationInventoryRefreshing
  private let manager: any AutomationManaging
  private let capabilityDecisionProvider: any AutomationCapabilityDecisionProviding
  private let destinationProvider: any AutomationManagementDestinationProviding
  private let sleep: Sleep
  private let initialRefreshDelay: Duration
  private let automaticRefreshInterval: Duration
  private let now: @Sendable () -> Date
  private var lifecycleTask: Task<Void, Never>?
  private var operationTask: Task<Void, Never>?
  private var activeRefreshTask: Task<Void, Never>?
  private var activeRefreshWaiters: [CheckedContinuation<Void, Never>] = []
  private var pendingRefreshMode: RefreshMode?
  private var pendingRefreshWaiters: [CheckedContinuation<Void, Never>] = []
  private var refreshGeneration: UInt64 = 0
  private var operationGeneration: UInt64 = 0

  init(
    inventoryService: any AutomationInventoryRefreshing,
    manager: any AutomationManaging,
    capabilityDecisionProvider: any AutomationCapabilityDecisionProviding =
      UnavailableAutomationCapabilityDecisionProvider(),
    destinationProvider: any AutomationManagementDestinationProviding =
      UnavailableAutomationManagementDestinationProvider(),
    initialRefreshDelay: Duration = .milliseconds(350),
    automaticRefreshInterval: Duration = .seconds(60),
    sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.inventoryService = inventoryService
    self.manager = manager
    self.capabilityDecisionProvider = capabilityDecisionProvider
    self.destinationProvider = destinationProvider
    self.initialRefreshDelay = max(.zero, initialRefreshDelay)
    self.automaticRefreshInterval = max(.seconds(60), automaticRefreshInterval)
    self.sleep = sleep
    self.now = now
  }

  deinit {
    lifecycleTask?.cancel()
    operationTask?.cancel()
    activeRefreshTask?.cancel()
    for waiter in activeRefreshWaiters + pendingRefreshWaiters { waiter.resume() }
  }

  func start() {
    guard lifecycleTask == nil else { return }
    let delay = initialRefreshDelay
    let interval = automaticRefreshInterval
    let sleep = sleep
    lifecycleTask = Task { [weak self] in
      do {
        try await sleep(delay)
        try Task.checkCancellation()
        self?.refreshAutomatically()
        while !Task.isCancelled {
          try await sleep(interval)
          try Task.checkCancellation()
          self?.refreshAutomatically()
        }
      } catch is CancellationError {
        return
      } catch {
        return
      }
    }
  }

  func stop() {
    lifecycleTask?.cancel()
    lifecycleTask = nil
    refreshGeneration &+= 1
    activeRefreshTask?.cancel()
    activeRefreshTask = nil
    pendingRefreshMode = nil
    for waiter in activeRefreshWaiters + pendingRefreshWaiters { waiter.resume() }
    activeRefreshWaiters.removeAll()
    pendingRefreshWaiters.removeAll()
    isRefreshing = false
  }

  func refresh() {
    requestRefresh(mode: .force)
  }

  func dismissOperationResult() {
    operationResult = nil
    operationResultRecordID = nil
  }

  func duplicateDestination(for record: AutomationRecord, label: String) -> URL? {
    destinationProvider.duplicateDestination(for: record, label: label)
  }

  func importDestination(for record: AutomationRecord, suggestedFilename: String) -> URL? {
    destinationProvider.importDestination(for: record, suggestedFilename: suggestedFilename)
  }

  func perform(
    _ operation: AutomationOperation,
    record: AutomationRecord,
    expectedChecksum: String?,
    linkedProcesses: [ClassifiedDevProcess]
  ) {
    guard pendingOperation == nil else { return }
    let pending = AutomationPendingOperation(
      recordID: record.id,
      operation: operation,
      startedAt: now()
    )
    pendingOperation = pending
    operationGeneration &+= 1
    let generation = operationGeneration
    let manager = manager
    operationTask = Task { [weak self] in
      let result = await manager.perform(
        operation,
        record: record,
        expectedChecksum: expectedChecksum,
        linkedProcesses: linkedProcesses
      )
      guard let self,
            !Task.isCancelled,
            operationGeneration == generation,
            pendingOperation == pending else { return }
      operationResult = result
      operationResultRecordID = record.id
      // AutomationManager returns only after its authoritative refresh. Read
      // that cached generation instead of forcing every source to scan again.
      await waitForRefresh(mode: .automatic)
      guard !Task.isCancelled,
            operationGeneration == generation,
            pendingOperation == pending else { return }
      pendingOperation = nil
      operationTask = nil
    }
  }

  private func refreshAutomatically() {
    requestRefresh(mode: .automatic)
  }

  private func requestRefresh(mode: RefreshMode) {
    enqueueRefresh(mode: mode, waiter: nil)
  }

  private func waitForRefresh(mode: RefreshMode) async {
    await withCheckedContinuation { continuation in
      enqueueRefresh(mode: mode, waiter: continuation)
    }
  }

  private func enqueueRefresh(
    mode: RefreshMode,
    waiter: CheckedContinuation<Void, Never>?
  ) {
    guard activeRefreshTask == nil else {
      pendingRefreshMode = pendingRefreshMode?.merged(with: mode) ?? mode
      if let waiter { pendingRefreshWaiters.append(waiter) }
      return
    }
    startRefresh(mode: mode, waiters: waiter.map { [$0] } ?? [])
  }

  private func startRefresh(
    mode: RefreshMode,
    waiters: [CheckedContinuation<Void, Never>]
  ) {
    precondition(activeRefreshTask == nil)
    refreshGeneration &+= 1
    let generation = refreshGeneration
    let service = inventoryService
    let capabilityDecisionProvider = capabilityDecisionProvider
    let manager = manager
    activeRefreshWaiters = waiters
    isRefreshing = true
    activeRefreshTask = Task { [weak self] in
      let refreshed: AutomationInventorySnapshot
      switch mode {
      case .automatic:
        refreshed = await service.refresh(force: false)
      case .force:
        refreshed = await service.refresh(force: true)
      case .afterCurrent:
        refreshed = await service.refreshAfterCurrent()
      }
      let decisions = await capabilityDecisionProvider.decisions(for: refreshed.records)
      let backups = await manager.restorationManifests()
      self?.completeRefresh(
        generation: generation,
        snapshot: refreshed,
        capabilityDecisions: decisions,
        backups: backups
      )
    }
  }

  private func completeRefresh(
    generation: UInt64,
    snapshot refreshed: AutomationInventorySnapshot,
    capabilityDecisions: [AutomationRecord.ID: AutomationCapabilityDecision],
    backups refreshedBackups: [AutomationBackup]
  ) {
    guard generation == refreshGeneration else { return }
    activeRefreshTask = nil
    let completedWaiters = activeRefreshWaiters
    activeRefreshWaiters.removeAll()

    // Every ID-validated completion is a coherent publication point. A queued
    // refresh may replace it later, but must not hide post-operation evidence
    // from the waiter that requested this generation.
    snapshot = refreshed
    capabilitySnapshot = AutomationCapabilitySnapshot(
      inventoryGeneration: refreshed.generation,
      decisionsByRecordID: completedCapabilityDecisions(
        for: refreshed.records,
        provided: capabilityDecisions
      )
    )
    backups = refreshedBackups
    for waiter in completedWaiters { waiter.resume() }

    if let pendingMode = pendingRefreshMode {
      let waiters = pendingRefreshWaiters
      self.pendingRefreshMode = nil
      pendingRefreshWaiters.removeAll()
      startRefresh(mode: pendingMode, waiters: waiters)
    } else {
      isRefreshing = false
    }
  }

  private func completedCapabilityDecisions(
    for records: [AutomationRecord],
    provided: [AutomationRecord.ID: AutomationCapabilityDecision]
  ) -> [AutomationRecord.ID: AutomationCapabilityDecision] {
    Dictionary(uniqueKeysWithValues: records.map { record in
      if let decision = provided[record.id] {
        return (record.id, decision)
      }
      return (
        record.id,
        AutomationCapabilityDecision(
          capabilities: record.capabilities.intersection([.exportRecord]),
          reason: "DevScope could not verify source ownership and path safety for management."
        )
      )
    })
  }
}
