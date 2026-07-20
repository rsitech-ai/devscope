import XCTest
@testable import DevScopeCore

final class AutomationInventoryServiceTests: XCTestCase {
  func testTimedOutSourceFailsIndependentlyAndPreservesHealthyRecords() async {
    let hanging = CancellationAwareHangingAutomationSource(kind: .serviceManagement)
    let healthy = FakeAutomationSource(snapshot: .healthy(
      kind: .launchAgent,
      records: [Fixtures.userAgent]
    ))
    let service = AutomationInventoryService(
      sources: [hanging, healthy],
      sourceTimeout: .milliseconds(20)
    )

    let snapshot = await service.refresh(force: true)

    XCTAssertEqual(snapshot.records.map(\.label), ["com.example.backup"])
    XCTAssertEqual(snapshot.health[.serviceManagement]?.state, .failed)
    XCTAssertEqual(
      snapshot.health[.serviceManagement]?.message,
      "Automation source refresh exceeded its configured time limit."
    )
    let observedCancellation = await hanging.waitForCancellation()
    XCTAssertTrue(observedCancellation)
  }

  func testTimedOutSourceReturnsEvenWhenSourceIgnoresCancellation() async {
    let hanging = CancellationIgnoringAutomationSource(kind: .serviceManagement)
    let healthy = FakeAutomationSource(snapshot: .healthy(
      kind: .launchAgent,
      records: [Fixtures.userAgent]
    ))
    let service = AutomationInventoryService(
      sources: [hanging, healthy],
      sourceTimeout: .milliseconds(20)
    )
    let started = ContinuousClock.now

    let snapshot = await service.refresh(force: true)
    let elapsed = ContinuousClock.now - started
    await hanging.release()

    XCTAssertLessThan(elapsed, .seconds(1))
    XCTAssertEqual(snapshot.records.map(\.label), ["com.example.backup"])
    XCTAssertEqual(snapshot.health[.serviceManagement]?.state, .failed)
    XCTAssertEqual(
      snapshot.health[.serviceManagement]?.message,
      "Automation source refresh exceeded its configured time limit."
    )
  }

  func testForcedRefreshQuarantinesCancellationIgnoringSourceUntilItCompletes() async {
    let hanging = CancellationIgnoringAutomationSource(kind: .serviceManagement)
    let service = AutomationInventoryService(
      sources: [hanging],
      sourceTimeout: .milliseconds(20)
    )

    let timedOut = await service.refresh(force: true)
    XCTAssertEqual(
      timedOut.health[.serviceManagement]?.message,
      "Automation source refresh exceeded its configured time limit."
    )

    for _ in 0..<4 {
      let quarantined = await service.refresh(force: true)
      XCTAssertEqual(
        quarantined.health[.serviceManagement]?.message,
        "A previous timed-out automation source refresh is still completing; a new call was not started."
      )
    }
    let blockedMetrics = await hanging.metrics()
    XCTAssertEqual(blockedMetrics.invocations, 1)
    XCTAssertEqual(blockedMetrics.active, 1)
    XCTAssertEqual(blockedMetrics.maximumActive, 1)

    await hanging.release()
    let becameIdle = await hanging.waitUntilIdle()
    XCTAssertTrue(becameIdle)

    let recovered = await service.refresh(force: true)
    let recoveredMetrics = await hanging.metrics()
    XCTAssertEqual(recovered.health[.serviceManagement]?.state, .healthy)
    XCTAssertEqual(recoveredMetrics.invocations, 2)
    XCTAssertEqual(recoveredMetrics.maximumActive, 1)
  }

  func testFailedBackgroundSourceDoesNotEraseHealthyLaunchdRecords() async {
    let launchd = FakeAutomationSource(snapshot: .healthy(
      kind: .launchAgent,
      records: [Fixtures.userAgent]
    ))
    let background = FakeAutomationSource(snapshot: .failed(
      kind: .serviceManagement,
      message: "Background Task Management output unavailable"
    ))
    let service = AutomationInventoryService(sources: [launchd, background])

    let snapshot = await service.refresh(force: true)

    XCTAssertEqual(snapshot.records.map(\.label), ["com.example.backup"])
    XCTAssertEqual(snapshot.health[.serviceManagement]?.state, .failed)
  }

  func testExactPlistAndBackgroundIdentityDeduplicateToOneRecord() async {
    let backgroundIdentity = copyRecord(
      Fixtures.backgroundCopyOfUserAgent,
      sourceURL: .some(nil)
    )
    let service = AutomationInventoryService(sources: [
      FakeAutomationSource(snapshot: .healthy(
        kind: .launchAgent,
        records: [Fixtures.userAgent]
      )),
      FakeAutomationSource(snapshot: .healthy(
        kind: .serviceManagement,
        records: [backgroundIdentity]
      )),
    ])

    let snapshot = await service.refresh(force: true)

    XCTAssertEqual(snapshot.records.count, 1)
    XCTAssertEqual(snapshot.records[0].evidence.count, 2)
  }

  func testBoundedRefreshIntervalReturnsCachedGenerationUntilBoundary() async {
    let clock = ControllableAutomationClock(Date(timeIntervalSince1970: 10_000))
    let source = CountingAutomationSource(snapshot: .healthy(
      kind: .launchAgent,
      records: [Fixtures.userAgent]
    ))
    let service = AutomationInventoryService(
      sources: [source],
      minimumRefreshInterval: 60,
      now: clock.now
    )

    let first = await service.refresh()
    clock.advance(by: 59)
    let cached = await service.refresh()
    clock.advance(by: 1)
    let refreshed = await service.refresh()
    let invocationCount = await source.invocationCount()

    XCTAssertEqual(first.generation, 1)
    XCTAssertEqual(cached, first)
    XCTAssertEqual(refreshed.generation, 2)
    XCTAssertEqual(invocationCount, 2)
  }

  func testConcurrentRefreshesShareOneRealRefreshAndGeneration() async {
    let source = CountingAutomationSource(
      snapshot: .healthy(kind: .launchAgent, records: [Fixtures.userAgent]),
      delayNanoseconds: 50_000_000
    )
    let service = AutomationInventoryService(sources: [source])

    async let first = service.refresh(force: true)
    async let second = service.refresh(force: true)
    let snapshots = await [first, second]
    let invocationCount = await source.invocationCount()

    XCTAssertEqual(snapshots.map(\.generation), [1, 1])
    XCTAssertEqual(snapshots[0], snapshots[1])
    XCTAssertEqual(invocationCount, 1)
  }

  func testRefreshAfterCurrentStartsOneNewGenerationAfterPreexistingScan() async {
    let source = GatedAutomationSource(snapshot: .healthy(
      kind: .launchAgent,
      records: [Fixtures.userAgent]
    ))
    let service = AutomationInventoryService(sources: [source])

    let preexisting = Task { await service.refresh(force: true) }
    await source.waitUntilInvocation(1)
    let afterCurrent = Task { await service.refreshAfterCurrent() }
    await Task.yield()
    let countWhileBlocked = await source.invocationCount()
    XCTAssertEqual(countWhileBlocked, 1)

    await source.releaseInvocation(1)
    await source.waitUntilInvocation(2)
    let preexistingSnapshot = await preexisting.value
    XCTAssertEqual(preexistingSnapshot.generation, 1)
    await source.releaseInvocation(2)

    let afterCurrentSnapshot = await afterCurrent.value
    let finalCount = await source.invocationCount()
    XCTAssertEqual(afterCurrentSnapshot.generation, 2)
    XCTAssertEqual(finalCount, 2)
  }

  func testDuplicateSourceKindsPreserveWorstHealthDeterministically() async {
    let failed = AutomationSourceSnapshot.failed(
      kind: .serviceManagement,
      message: "Generic failure",
      refreshedAt: Date(timeIntervalSince1970: 100)
    )
    let healthy = AutomationSourceSnapshot.healthy(
      kind: .serviceManagement,
      records: [],
      refreshedAt: Date(timeIntervalSince1970: 200)
    )
    let service = AutomationInventoryService(sources: [
      FakeAutomationSource(snapshot: failed),
      FakeAutomationSource(snapshot: healthy),
    ])

    let snapshot = await service.refresh(force: true)

    XCTAssertEqual(snapshot.health[.serviceManagement], failed.health)
  }

  func testDisplayNameResemblanceNeverDeduplicatesDistinctRecords() async {
    let lookalike = copyRecord(
      Fixtures.backgroundCopyOfUserAgent,
      label: "com.example.unrelated",
      displayName: Fixtures.userAgent.displayName,
      providerBundleIdentifier: "com.example.different-owner",
      executable: "/bin/date",
      sourceURL: URL(fileURLWithPath: "/tmp/devscope-fixtures/unrelated.plist")
    )
    let service = AutomationInventoryService(sources: [
      FakeAutomationSource(snapshot: .healthy(
        kind: .launchAgent,
        records: [Fixtures.userAgent]
      )),
      FakeAutomationSource(snapshot: .healthy(
        kind: .serviceManagement,
        records: [lookalike]
      )),
    ])

    let snapshot = await service.refresh(force: true)

    XCTAssertEqual(snapshot.records.count, 2)
  }

  func testEqualRankRecordsWithDifferentCapabilitySetsMergeIdenticallyWhenReversed() async {
    let editPrimary = copyRecord(
      Fixtures.backgroundCopyOfUserAgent,
      capabilities: [.edit],
      evidence: [AutomationEvidence(
        strength: .strong,
        source: "edit evidence",
        detail: "Exact synthetic identity"
      )]
    )
    let disablePrimary = copyRecord(
      Fixtures.backgroundCopyOfUserAgent,
      capabilities: [.disable],
      evidence: [AutomationEvidence(
        strength: .strong,
        source: "disable evidence",
        detail: "Exact synthetic identity"
      )]
    )
    let forward = AutomationInventoryService(sources: [
      FakeAutomationSource(snapshot: .healthy(
        kind: .serviceManagement,
        records: [editPrimary]
      )),
      FakeAutomationSource(snapshot: .healthy(
        kind: .serviceManagement,
        records: [disablePrimary]
      )),
    ])
    let reverse = AutomationInventoryService(sources: [
      FakeAutomationSource(snapshot: .healthy(
        kind: .serviceManagement,
        records: [disablePrimary]
      )),
      FakeAutomationSource(snapshot: .healthy(
        kind: .serviceManagement,
        records: [editPrimary]
      )),
    ])

    let forwardRecords = await forward.refresh(force: true).records
    let reverseRecords = await reverse.refresh(force: true).records

    XCTAssertEqual(forwardRecords, reverseRecords)
    XCTAssertEqual(forwardRecords.count, 1)
    XCTAssertEqual(forwardRecords[0].capabilities, [.disable])
    XCTAssertEqual(
      forwardRecords[0].evidence.map(\.source),
      ["disable evidence", "edit evidence"]
    )
  }

  func testEqualComparatorKeysAttachAmbiguousBridgeDeterministicallyWhenReversed() async {
    let tiedID = AutomationRecord.ID(rawValue: "synthetic-component-tie")
    let firstAnchor = copyRecord(
      Fixtures.backgroundCopyOfUserAgent,
      id: tiedID,
      label: "com.example.component-tie",
      executable: .some(nil),
      sourceURL: URL(fileURLWithPath: "/tmp/devscope-fixtures/component-a"),
      capabilities: [.exportRecord],
      evidence: [AutomationEvidence(
        strength: .strong,
        source: "first anchor evidence",
        detail: "Conflicting synthetic source identity"
      )]
    )
    let secondAnchor = copyRecord(
      Fixtures.backgroundCopyOfUserAgent,
      id: tiedID,
      label: "com.example.component-tie",
      providerBundleIdentifier: .some(nil),
      executable: "/tmp/devscope-fixtures/component-bridge",
      sourceURL: URL(fileURLWithPath: "/tmp/devscope-fixtures/component-b"),
      capabilities: [.exportRecord],
      evidence: [AutomationEvidence(
        strength: .strong,
        source: "second anchor evidence",
        detail: "Conflicting synthetic source identity"
      )]
    )
    let bridge = copyRecord(
      Fixtures.backgroundCopyOfUserAgent,
      id: tiedID,
      label: "com.example.component-tie",
      executable: "/tmp/devscope-fixtures/component-bridge",
      sourceURL: .some(nil),
      capabilities: [.exportRecord],
      evidence: [AutomationEvidence(
        strength: .strong,
        source: "bridge evidence",
        detail: "Compatible with either synthetic anchor alone"
      )]
    )
    let forward = AutomationInventoryService(sources: [
      FakeAutomationSource(snapshot: .healthy(
        kind: .serviceManagement,
        records: [firstAnchor, secondAnchor]
      )),
      FakeAutomationSource(snapshot: .healthy(
        kind: .serviceManagement,
        records: [bridge]
      )),
    ])
    let reverse = AutomationInventoryService(sources: [
      FakeAutomationSource(snapshot: .healthy(
        kind: .serviceManagement,
        records: [bridge]
      )),
      FakeAutomationSource(snapshot: .healthy(
        kind: .serviceManagement,
        records: [secondAnchor, firstAnchor]
      )),
    ])

    let forwardRecords = await forward.refresh(force: true).records
    let reverseRecords = await reverse.refresh(force: true).records

    XCTAssertEqual(forwardRecords.count, 2)
    XCTAssertEqual(forwardRecords, reverseRecords)
    XCTAssertEqual(forwardRecords.filter { record in
      record.evidence.contains { $0.source == "bridge evidence" }
    }.count, 1)
    XCTAssertFalse(forwardRecords.contains { record in
      let sources = Set(record.evidence.map(\.source))
      return sources.contains("first anchor evidence")
        && sources.contains("second anchor evidence")
    })
  }

  func testTransitiveIdentityBridgeRejectsConflictingBundleComponentsInEitherOrder() async {
    let bridge = copyRecord(
      Fixtures.backgroundCopyOfUserAgent,
      label: "com.example.bridge",
      executable: "/tmp/devscope-fixtures/bridge",
      sourceURL: .some(nil),
      ownership: .thirdPartySystem,
      capabilities: [.disable],
      evidence: [AutomationEvidence(
        strength: .strong,
        source: "bridge bundle evidence",
        detail: "Exact bundle identity"
      )]
    )
    let pathCopy = copyRecord(
      Fixtures.backgroundCopyOfUserAgent,
      label: "com.example.bridge",
      providerBundleIdentifier: "com.example.other-owner",
      executable: "/tmp/devscope-fixtures/folder/../bridge",
      sourceURL: .some(nil),
      capabilities: [.edit],
      evidence: [AutomationEvidence(
        strength: .strong,
        source: "bridge path evidence",
        detail: "Exact label and canonical executable"
      )]
    )
    let bundleAnchor = copyRecord(
      Fixtures.userAgent,
      label: "com.example.bridge",
      executable: "/tmp/devscope-fixtures/bridge",
      sourceURL: .some(nil),
      capabilities: [.startNow]
    )
    let forward = AutomationInventoryService(sources: [
      FakeAutomationSource(snapshot: .healthy(
        kind: .launchAgent,
        records: [bundleAnchor]
      )),
      FakeAutomationSource(snapshot: .healthy(
        kind: .serviceManagement,
        records: [pathCopy, bridge]
      )),
    ])
    let reverse = AutomationInventoryService(sources: [
      FakeAutomationSource(snapshot: .healthy(
        kind: .serviceManagement,
        records: [bridge, pathCopy]
      )),
      FakeAutomationSource(snapshot: .healthy(
        kind: .launchAgent,
        records: [bundleAnchor]
      )),
    ])

    let forwardRecords = await forward.refresh(force: true).records
    let reverseRecords = await reverse.refresh(force: true).records

    XCTAssertEqual(forwardRecords.count, 2)
    XCTAssertEqual(forwardRecords, reverseRecords)
    let retainedAnchor = forwardRecords.first {
      $0.providerBundleIdentifier == "com.example.devscope-fixture-owner"
    }
    let rejectedConflict = forwardRecords.first {
      $0.providerBundleIdentifier == "com.example.other-owner"
    }
    XCTAssertEqual(retainedAnchor?.id, bundleAnchor.id)
    XCTAssertEqual(retainedAnchor?.evidence.count, 2)
    XCTAssertEqual(retainedAnchor?.capabilities, [.startNow])
    XCTAssertEqual(rejectedConflict?.id, pathCopy.id)
    XCTAssertEqual(rejectedConflict?.evidence.count, 1)
    XCTAssertEqual(rejectedConflict?.capabilities, [.edit])
  }

  func testExactBundleEdgeRejectsConflictingLabelExecutableIdentitiesInEitherOrder() async {
    let first = copyRecord(Fixtures.userAgent, sourceURL: .some(nil))
    let second = copyRecord(
      Fixtures.backgroundCopyOfUserAgent,
      label: "com.example.conflicting-label",
      executable: "/bin/date",
      sourceURL: .some(nil)
    )
    let forward = AutomationInventoryService(sources: [
      FakeAutomationSource(snapshot: .healthy(
        kind: .serviceManagement,
        records: [first, second]
      )),
    ])
    let reverse = AutomationInventoryService(sources: [
      FakeAutomationSource(snapshot: .healthy(
        kind: .serviceManagement,
        records: [second, first]
      )),
    ])

    let forwardRecords = await forward.refresh(force: true).records
    let reverseRecords = await reverse.refresh(force: true).records

    XCTAssertEqual(forwardRecords.count, 2)
    XCTAssertEqual(forwardRecords, reverseRecords)
  }

  func testExactBundleEdgeRejectsConflictingSourceReferencesInEitherOrder() async {
    let first = Fixtures.userAgent
    let second = Fixtures.backgroundCopyOfUserAgent
    let forward = AutomationInventoryService(sources: [
      FakeAutomationSource(snapshot: .healthy(
        kind: .serviceManagement,
        records: [first, second]
      )),
    ])
    let reverse = AutomationInventoryService(sources: [
      FakeAutomationSource(snapshot: .healthy(
        kind: .serviceManagement,
        records: [second, first]
      )),
    ])

    let forwardRecords = await forward.refresh(force: true).records
    let reverseRecords = await reverse.refresh(force: true).records

    XCTAssertEqual(forwardRecords.count, 2)
    XCTAssertEqual(forwardRecords, reverseRecords)
  }

  func testCompatibleOrMissingStrongIdentitiesStillMergeTransitivelyInEitherOrder() async {
    let bundleAnchor = copyRecord(
      Fixtures.userAgent,
      label: "com.example.bundle-anchor",
      executable: .some(nil),
      sourceURL: .some(nil),
      capabilities: [.startNow]
    )
    let bridge = copyRecord(
      Fixtures.backgroundCopyOfUserAgent,
      label: "com.example.compatible-bridge",
      executable: "/tmp/devscope-fixtures/compatible-bridge",
      sourceURL: .some(nil),
      ownership: .thirdPartySystem,
      capabilities: [.disable],
      evidence: [AutomationEvidence(
        strength: .strong,
        source: "compatible bundle bridge",
        detail: "Exact bundle identity"
      )]
    )
    let pathClosure = copyRecord(
      Fixtures.backgroundCopyOfUserAgent,
      label: "com.example.compatible-bridge",
      providerBundleIdentifier: .some(nil),
      executable: "/tmp/devscope-fixtures/folder/../compatible-bridge",
      sourceURL: .some(nil),
      capabilities: [.edit],
      evidence: [AutomationEvidence(
        strength: .strong,
        source: "compatible path closure",
        detail: "Exact label and canonical executable"
      )]
    )
    let forward = AutomationInventoryService(sources: [
      FakeAutomationSource(snapshot: .healthy(kind: .launchAgent, records: [bundleAnchor])),
      FakeAutomationSource(snapshot: .healthy(
        kind: .serviceManagement,
        records: [pathClosure, bridge]
      )),
    ])
    let reverse = AutomationInventoryService(sources: [
      FakeAutomationSource(snapshot: .healthy(
        kind: .serviceManagement,
        records: [bridge, pathClosure]
      )),
      FakeAutomationSource(snapshot: .healthy(kind: .launchAgent, records: [bundleAnchor])),
    ])

    let forwardRecords = await forward.refresh(force: true).records
    let reverseRecords = await reverse.refresh(force: true).records

    XCTAssertEqual(forwardRecords.count, 1)
    XCTAssertEqual(forwardRecords, reverseRecords)
    XCTAssertEqual(forwardRecords[0].id, bundleAnchor.id)
    XCTAssertEqual(forwardRecords[0].evidence.count, 3)
    XCTAssertEqual(forwardRecords[0].capabilities, [.startNow])
  }

  func testExactCanonicalSourceReferenceDeduplicatesIndependentOfInputOrder() async {
    let sharedURL = URL(fileURLWithPath: "/tmp/devscope-fixtures/folder/../shared-source")
    let first = copyRecord(
      Fixtures.userAgent,
      label: "com.example.first",
      providerBundleIdentifier: .some(nil),
      executable: .some(nil),
      sourceURL: sharedURL
    )
    let second = copyRecord(
      Fixtures.backgroundCopyOfUserAgent,
      label: "com.example.second",
      providerBundleIdentifier: "com.example.second",
      executable: .some(nil),
      sourceURL: URL(fileURLWithPath: "/tmp/devscope-fixtures/shared-source")
    )
    let forward = AutomationInventoryService(sources: [
      FakeAutomationSource(snapshot: .healthy(
        kind: .serviceManagement,
        records: [first, second]
      )),
    ])
    let reverse = AutomationInventoryService(sources: [
      FakeAutomationSource(snapshot: .healthy(
        kind: .serviceManagement,
        records: [second, first]
      )),
    ])

    let forwardRecords = await forward.refresh(force: true).records
    let reverseRecords = await reverse.refresh(force: true).records

    XCTAssertEqual(forwardRecords.count, 1)
    XCTAssertEqual(forwardRecords, reverseRecords)
    XCTAssertEqual(forwardRecords[0].id, first.id)
  }

  func testForcedRefreshBypassesThrottleAndThenBecomesCachedGeneration() async {
    let clock = ControllableAutomationClock(Date(timeIntervalSince1970: 20_000))
    let source = CountingAutomationSource(snapshot: .healthy(
      kind: .launchAgent,
      records: [Fixtures.userAgent]
    ))
    let service = AutomationInventoryService(
      sources: [source],
      minimumRefreshInterval: 60,
      now: clock.now
    )

    let first = await service.refresh()
    let forced = await service.refresh(force: true)
    let cached = await service.refresh()
    let invocationCount = await source.invocationCount()

    XCTAssertEqual(first.generation, 1)
    XCTAssertEqual(forced.generation, 2)
    XCTAssertEqual(cached, forced)
    XCTAssertEqual(invocationCount, 2)
  }

  func testCommandSignatureParticipatesInDeterministicPrimaryOrdering() async {
    let alpha = copyRecord(Fixtures.userAgent, commandSignature: "alpha")
    let omega = copyRecord(Fixtures.userAgent, commandSignature: "omega")
    let forward = AutomationInventoryService(sources: [
      FakeAutomationSource(snapshot: .healthy(kind: .launchAgent, records: [omega, alpha])),
    ])
    let reverse = AutomationInventoryService(sources: [
      FakeAutomationSource(snapshot: .healthy(kind: .launchAgent, records: [alpha, omega])),
    ])

    let forwardRecords = await forward.refresh(force: true).records
    let reverseRecords = await reverse.refresh(force: true).records

    XCTAssertEqual(forwardRecords, reverseRecords)
    XCTAssertEqual(forwardRecords.first?.commandSignature, "alpha")
  }
}

private actor CancellationAwareHangingAutomationSource: AutomationSource {
  nonisolated let kind: AutomationSourceKind
  private var wasCancelled = false

  init(kind: AutomationSourceKind) {
    self.kind = kind
  }

  func snapshot() async -> AutomationSourceSnapshot {
    do {
      try await Task.sleep(for: .seconds(30))
    } catch is CancellationError {
      wasCancelled = true
    } catch {}
    return .healthy(kind: kind, records: [])
  }

  func waitForCancellation() async -> Bool {
    for _ in 0..<100 {
      if wasCancelled { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return false
  }
}

private actor CancellationIgnoringAutomationSource: AutomationSource {
  nonisolated let kind: AutomationSourceKind
  private var isReleased = false
  private var invocations = 0
  private var active = 0
  private var maximumActive = 0

  init(kind: AutomationSourceKind) {
    self.kind = kind
  }

  func snapshot() async -> AutomationSourceSnapshot {
    invocations += 1
    active += 1
    maximumActive = max(maximumActive, active)
    defer { active -= 1 }
    while !isReleased {
      try? await Task.sleep(for: .milliseconds(5))
      await Task.yield()
    }
    return .healthy(kind: kind, records: [])
  }

  func release() {
    isReleased = true
  }

  func metrics() -> (invocations: Int, active: Int, maximumActive: Int) {
    (invocations, active, maximumActive)
  }

  func waitUntilIdle() async -> Bool {
    for _ in 0..<100 {
      if active == 0 { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return false
  }
}

private actor GatedAutomationSource: AutomationSource {
  nonisolated let kind: AutomationSourceKind
  private let value: AutomationSourceSnapshot
  private var count = 0
  private var invocationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var releaseWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

  init(snapshot: AutomationSourceSnapshot) {
    kind = snapshot.health.kind
    value = snapshot
  }

  func snapshot() async -> AutomationSourceSnapshot {
    count += 1
    let invocation = count
    let ready = invocationWaiters.filter { $0.0 <= count }
    invocationWaiters.removeAll { $0.0 <= count }
    for (_, waiter) in ready { waiter.resume() }
    await withCheckedContinuation { continuation in
      releaseWaiters[invocation] = continuation
    }
    return value
  }

  func waitUntilInvocation(_ target: Int) async {
    guard count < target else { return }
    await withCheckedContinuation { continuation in
      invocationWaiters.append((target, continuation))
    }
  }

  func releaseInvocation(_ invocation: Int) {
    releaseWaiters.removeValue(forKey: invocation)?.resume()
  }

  func invocationCount() -> Int { count }
}

private func copyRecord(
  _ record: AutomationRecord,
  id: AutomationRecord.ID? = nil,
  label: String? = nil,
  displayName: String? = nil,
  providerBundleIdentifier: String?? = nil,
  executable: String?? = nil,
  commandSignature: String?? = nil,
  sourceURL: URL?? = nil,
  ownership: AutomationOwnership? = nil,
  capabilities: Set<AutomationCapability>? = nil,
  evidence: [AutomationEvidence]? = nil
) -> AutomationRecord {
  let label = label ?? record.label
  let bundleIdentifier = providerBundleIdentifier ?? record.providerBundleIdentifier
  let executable = executable ?? record.executable
  let sourceURL = sourceURL ?? record.sourceURL
  return AutomationRecord(
    id: id ?? AutomationRecord.ID(
      source: record.sourceKind,
      ownerUID: record.ownerUID ?? 0,
      label: label,
      sourcePath: sourceURL?.path ?? executable ?? label
    ),
    kind: record.kind,
    sourceKind: record.sourceKind,
    label: label,
    displayName: displayName ?? record.displayName,
    providerBundleIdentifier: bundleIdentifier,
    ownerUID: record.ownerUID,
    ownership: ownership ?? record.ownership,
    executable: executable,
    arguments: record.arguments,
    commandSignature: commandSignature ?? record.commandSignature,
    environment: record.environment,
    workingDirectory: record.workingDirectory,
    schedule: record.schedule,
    sourceURL: sourceURL,
    sourceChecksum: record.sourceChecksum,
    enabledState: record.enabledState,
    loadState: record.loadState,
    approvalState: record.approvalState,
    state: record.state,
    evidence: evidence ?? record.evidence,
    capabilities: capabilities ?? record.capabilities,
    validationFindings: record.validationFindings
  )
}
