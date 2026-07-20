import DevScopeCore
import XCTest
@testable import DevScope

@MainActor
final class AutomationStoreTests: XCTestCase {
  func testRefreshPublishesCapabilityDecisionsWithTheSameInventoryGeneration() async {
    let record = automationRecord(capabilities: [.exportRecord])
    let expected = AutomationCapabilityDecision(
      capabilities: [.startNow, .disable, .exportRecord],
      reason: "Some lifecycle operations are unavailable."
    )
    let inventory = ImmediateInventoryService(snapshot: AutomationInventorySnapshot(
      generation: 17,
      records: [record],
      health: [:],
      refreshedAt: Date(timeIntervalSince1970: 17)
    ))
    let store = AutomationStore(
      inventoryService: inventory,
      manager: ImmediateAutomationManager(),
      capabilityDecisionProvider: FixedCapabilityDecisionProvider(
        decisions: [record.id: expected]
      )
    )

    store.refresh()
    await eventually { !store.isRefreshing && store.snapshot.generation == 17 }

    XCTAssertEqual(store.capabilitySnapshot.inventoryGeneration, 17)
    XCTAssertEqual(store.capabilitySnapshot.decisionsByRecordID[record.id], expected)
  }

  func testMissingCapabilityDecisionFailsClosedToPublishedInspectionOnlyExport() async {
    let record = automationRecord(capabilities: [.disable, .exportRecord])
    let store = AutomationStore(
      inventoryService: ImmediateInventoryService(snapshot: AutomationInventorySnapshot(
        generation: 21,
        records: [record],
        health: [:],
        refreshedAt: Date(timeIntervalSince1970: 21)
      )),
      manager: ImmediateAutomationManager(),
      capabilityDecisionProvider: FixedCapabilityDecisionProvider(decisions: [:])
    )

    store.refresh()
    await eventually { !store.isRefreshing && store.snapshot.generation == 21 }

    let decision = store.capabilitySnapshot.decisionsByRecordID[record.id]
    XCTAssertEqual(decision?.capabilities, [.exportRecord])
    XCTAssertEqual(
      decision?.reason,
      "DevScope could not verify source ownership and path safety for management."
    )
  }

  func testImportDestinationIsTheSelectedChecksumBoundSourceWhileDuplicateUsesSibling() {
    let record = automationRecord(
      capabilities: [.importRecord, .duplicate]
    )
    let provider = AutomationManagementDestinationProvider(
      transactionRoot: URL(fileURLWithPath: "/tmp/transactions")
    )

    XCTAssertEqual(
      provider.importDestination(for: record, suggestedFilename: "other.plist"),
      record.sourceURL
    )
    XCTAssertEqual(
      provider.duplicateDestination(for: record, label: "Store.Copy"),
      record.sourceURL?.deletingLastPathComponent().appendingPathComponent("Store.Copy.plist")
    )
    XCTAssertNil(provider.duplicateDestination(for: record, label: "../escape"))
  }

  func testCompletedSnapshotPublishesBeforeQueuedOperationRefreshCanFinish() async {
    let inventory = GatedInventoryService()
    let manager = ImmediateAutomationManager()
    let store = AutomationStore(inventoryService: inventory, manager: manager)
    let record = automationRecord()

    store.refresh()
    await inventory.waitUntilCall(1)
    store.perform(.disable, record: record, expectedChecksum: nil, linkedProcesses: [])
    await inventory.release(call: 1, generation: 1)
    await inventory.waitUntilCall(2)

    XCTAssertEqual(store.snapshot.generation, 1)
    XCTAssertNotNil(store.pendingOperation)

    await inventory.release(call: 2, generation: 2)
    await eventually { store.pendingOperation == nil }
    XCTAssertEqual(store.snapshot.generation, 2)
  }

  func testOperationCompletionReadsTheManagerRefreshedCacheWithoutForcingAnotherGeneration() async {
    let inventory = GatedInventoryService()
    let store = AutomationStore(
      inventoryService: inventory,
      manager: ImmediateAutomationManager()
    )

    store.perform(
      .disable,
      record: automationRecord(),
      expectedChecksum: nil,
      linkedProcesses: []
    )
    await inventory.waitUntilCall(1)

    let callKinds = await inventory.callKinds()
    XCTAssertEqual(callKinds, ["automatic"])
    await inventory.release(call: 1, generation: 1)
    await eventually { store.pendingOperation == nil }
  }

  func testRefreshQueueIsBoundedToOneTrailingRequest() async {
    let inventory = GatedInventoryService()
    let store = AutomationStore(
      inventoryService: inventory,
      manager: ImmediateAutomationManager()
    )

    store.refresh()
    await inventory.waitUntilCall(1)
    for _ in 0..<20 { store.refresh() }
    await inventory.release(call: 1, generation: 1)
    await inventory.waitUntilCall(2)
    let callsWhileTrailing = await inventory.callCount()
    XCTAssertEqual(callsWhileTrailing, 2)
    await inventory.release(call: 2, generation: 2)
    await eventually { !store.isRefreshing }
    let finalCalls = await inventory.callCount()
    XCTAssertEqual(finalCalls, 2)
  }

  func testStopInvalidatesOldCompletionAndRestartCanPublishNewGeneration() async {
    let inventory = GatedInventoryService()
    let store = AutomationStore(
      inventoryService: inventory,
      manager: ImmediateAutomationManager()
    )

    store.refresh()
    await inventory.waitUntilCall(1)
    store.stop()
    store.refresh()
    await inventory.waitUntilCall(2)
    await inventory.release(call: 1, generation: 41)
    await Task.yield()
    XCTAssertNotEqual(store.snapshot.generation, 41)
    await inventory.release(call: 2, generation: 42)
    await eventually { store.snapshot.generation == 42 }
  }

  func testStopPreservesAuthorizedOperationUntilResultAndEvidenceArePublished() async {
    let manager = GatedAutomationManager()
    let store = AutomationStore(
      inventoryService: ImmediateInventoryService(
        snapshot: ProcessStoreLiveSnapshot.emptyAutomationInventory
      ),
      manager: manager
    )
    store.perform(.disable, record: automationRecord(), expectedChecksum: nil, linkedProcesses: [])
    await manager.waitUntilCalled()
    XCTAssertNotNil(store.pendingOperation)

    store.stop()
    XCTAssertNotNil(store.pendingOperation)
    await manager.release()
    await eventually { store.pendingOperation == nil }
    XCTAssertEqual(store.operationResult?.status, .succeeded)
    XCTAssertEqual(store.operationResultRecordID, automationRecord().id)
  }

  func testLifecycleUsesOne350MillisecondInitialDelayAndAtLeast60SecondCadence() async {
    let inventory = GatedInventoryService()
    let sleeper = ManualSleeper()
    let store = AutomationStore(
      inventoryService: inventory,
      manager: ImmediateAutomationManager(),
      sleep: { try await sleeper.sleep($0) }
    )

    store.start()
    store.start()
    await sleeper.waitUntilCall(1)
    let firstDuration = await sleeper.duration(call: 1)
    let initialCallCount = await sleeper.callCount()
    XCTAssertEqual(firstDuration, .milliseconds(350))
    XCTAssertEqual(initialCallCount, 1)
    await sleeper.release(call: 1)
    await inventory.waitUntilCall(1)
    await sleeper.waitUntilCall(2)
    let observedCadence = await sleeper.duration(call: 2)
    let cadence = try! XCTUnwrap(observedCadence)
    XCTAssertGreaterThanOrEqual(cadence, .seconds(60))

    store.stop()
    store.start()
    await sleeper.waitUntilCall(3)
    let restartedDuration = await sleeper.duration(call: 3)
    XCTAssertEqual(restartedDuration, .milliseconds(350))
    store.stop()
    await sleeper.releaseAll()
    await inventory.releaseAll()
  }
}

private actor GatedInventoryService: AutomationInventoryRefreshing {
  private struct Pending {
    let call: Int
    let continuation: CheckedContinuation<AutomationInventorySnapshot, Never>
  }

  private var calls = 0
  private var kinds: [String] = []
  private var pending: [Int: Pending] = [:]
  private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

  func refresh(force: Bool) async -> AutomationInventorySnapshot {
    kinds.append(force ? "force" : "automatic")
    return await next()
  }

  func refreshAfterCurrent() async -> AutomationInventorySnapshot {
    kinds.append("afterCurrent")
    return await next()
  }

  private func next() async -> AutomationInventorySnapshot {
    calls += 1
    let call = calls
    let ready = waiters.filter { $0.0 <= calls }
    waiters.removeAll { $0.0 <= calls }
    for (_, waiter) in ready { waiter.resume() }
    return await withCheckedContinuation { continuation in
      pending[call] = Pending(call: call, continuation: continuation)
    }
  }

  func waitUntilCall(_ target: Int) async {
    guard calls < target else { return }
    await withCheckedContinuation { waiters.append((target, $0)) }
  }

  func release(call: Int, generation: UInt64) {
    pending.removeValue(forKey: call)?.continuation.resume(returning: AutomationInventorySnapshot(
      generation: generation,
      records: [],
      health: [:],
      refreshedAt: Date(timeIntervalSince1970: TimeInterval(generation))
    ))
  }

  func callCount() -> Int { calls }
  func callKinds() -> [String] { kinds }

  func releaseAll() {
    for (call, value) in pending.sorted(by: { $0.key < $1.key }) {
      value.continuation.resume(returning: AutomationInventorySnapshot(
        generation: UInt64(call), records: [], health: [:], refreshedAt: .distantPast
      ))
    }
    pending.removeAll()
  }
}

private actor ImmediateAutomationManager: AutomationManaging {
  func perform(
    _ operation: AutomationOperation,
    record: AutomationRecord,
    expectedChecksum: String?,
    linkedProcesses: [ClassifiedDevProcess]
  ) async -> AutomationOperationResult {
    AutomationOperationResult(
      operation: operation,
      status: .succeeded,
      appliedSteps: [],
      verificationEvidence: [],
      rollback: .notNeeded,
      manualRecovery: nil
    )
  }
}

private actor GatedAutomationManager: AutomationManaging {
  private var continuation: CheckedContinuation<Void, Never>?
  private var callWaiter: CheckedContinuation<Void, Never>?
  private var called = false

  func perform(
    _ operation: AutomationOperation,
    record: AutomationRecord,
    expectedChecksum: String?,
    linkedProcesses: [ClassifiedDevProcess]
  ) async -> AutomationOperationResult {
    called = true
    callWaiter?.resume()
    callWaiter = nil
    await withCheckedContinuation { continuation = $0 }
    return AutomationOperationResult(
      operation: operation, status: .succeeded, appliedSteps: [],
      verificationEvidence: [], rollback: .notNeeded, manualRecovery: nil
    )
  }

  func waitUntilCalled() async {
    guard !called else { return }
    await withCheckedContinuation { callWaiter = $0 }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

private actor ManualSleeper {
  private var calls: [Int: (Duration, CheckedContinuation<Void, Never>)] = [:]
  private var nextCall = 0
  private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

  func sleep(_ duration: Duration) async throws {
    nextCall += 1
    let call = nextCall
    let ready = waiters.filter { $0.0 <= nextCall }
    waiters.removeAll { $0.0 <= nextCall }
    for (_, waiter) in ready { waiter.resume() }
    await withCheckedContinuation { calls[call] = (duration, $0) }
    try Task.checkCancellation()
  }

  func waitUntilCall(_ target: Int) async {
    guard nextCall < target else { return }
    await withCheckedContinuation { waiters.append((target, $0)) }
  }

  func duration(call: Int) -> Duration? { calls[call]?.0 }
  func callCount() -> Int { nextCall }

  func release(call: Int) {
    calls.removeValue(forKey: call)?.1.resume()
  }

  func releaseAll() {
    let continuations = calls.values.map(\.1)
    calls.removeAll()
    for continuation in continuations { continuation.resume() }
  }
}

@MainActor
private func eventually(
  _ predicate: @MainActor () -> Bool,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  for _ in 0..<100 where !predicate() {
    await Task.yield()
  }
  if !predicate() {
    XCTFail("Timed out waiting for asynchronous store state.", file: file, line: line)
  }
}

private func automationRecord(
  capabilities: Set<AutomationCapability> = []
) -> AutomationRecord {
  AutomationRecord(
    id: AutomationRecord.ID(rawValue: "store-test"),
    kind: .launchAgent,
    sourceKind: .launchAgent,
    label: "Store Test",
    displayName: "Store Test",
    providerBundleIdentifier: nil,
    ownerUID: 501,
    ownership: .user,
    executable: "/bin/true",
    arguments: [],
    environment: [:],
    workingDirectory: nil,
    schedule: AutomationSchedule(triggers: [.demand], summary: "On demand"),
    sourceURL: URL(fileURLWithPath: "/tmp/store-test.plist"),
    sourceChecksum: nil,
    enabledState: .enabled,
    loadState: .unknown,
    approvalState: .notApplicable,
    state: .idle,
    evidence: [],
    capabilities: capabilities,
    validationFindings: []
  )
}

private actor ImmediateInventoryService: AutomationInventoryRefreshing {
  let snapshot: AutomationInventorySnapshot

  init(snapshot: AutomationInventorySnapshot) {
    self.snapshot = snapshot
  }

  func refresh(force: Bool) async -> AutomationInventorySnapshot { snapshot }
  func refreshAfterCurrent() async -> AutomationInventorySnapshot { snapshot }
}

private struct FixedCapabilityDecisionProvider: AutomationCapabilityDecisionProviding {
  let decisions: [AutomationRecord.ID: AutomationCapabilityDecision]

  func decisions(
    for records: [AutomationRecord]
  ) async -> [AutomationRecord.ID: AutomationCapabilityDecision] {
    decisions
  }
}
