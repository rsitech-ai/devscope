import XCTest
@testable import DevScopeCore

final class AutomationEventDetectorTests: XCTestCase {
  func testLongRunningTransitionEmitsOnceAndNilBirthNeverNotifies() {
    var detector = AutomationEventDetector()
    let before = presentation(elapsed: "03:59:59")
    let boundary = presentation(elapsed: "04:00:00")
    let after = presentation(elapsed: "04:00:01")

    XCTAssertEqual(detector.events(
      previous: before, current: boundary, now: Date(timeIntervalSince1970: 14_400)
    ), [.crossedLongRunningThreshold(
      process: eventIdentity(process(elapsed: "04:00:00")),
      recordID: expectedRecord.id
    )])
    XCTAssertTrue(detector.events(
      previous: boundary, current: after, now: Date(timeIntervalSince1970: 14_401)
    ).isEmpty)

    let nilBefore = presentation(elapsed: "03:59:59", birthToken: nil)
    let nilBoundary = presentation(elapsed: "04:00:00", birthToken: nil)
    XCTAssertTrue(detector.events(
      previous: nilBefore, current: nilBoundary, now: Date(timeIntervalSince1970: 20_000)
    ).isEmpty)
  }

  func testUnexpectedExitRequiresTwoCompleteHealthyExpectedRunningAbsences() {
    var detector = AutomationEventDetector()
    let running = presentation(elapsed: "00:01:00")
    let absent = presentation(processes: [])

    XCTAssertTrue(detector.events(previous: nil, current: running, now: date(1_000)).isEmpty)
    XCTAssertTrue(detector.events(previous: running, current: absent, now: date(1_001)).isEmpty)
    XCTAssertEqual(detector.events(previous: absent, current: absent, now: date(1_002)), [
      .unexpectedExit(
        recordID: expectedRecord.id,
        process: eventIdentity(process(elapsed: "00:01:00"))
      ),
    ])
    XCTAssertTrue(detector.events(previous: absent, current: absent, now: date(1_003)).isEmpty)
  }

  func testIncompleteOrFailedSourceResetsExitConfirmation() {
    var detector = AutomationEventDetector()
    let running = presentation(elapsed: "00:01:00")
    let incomplete = presentation(complete: false, processes: [])
    let absent = presentation(processes: [])
    let failed = presentation(sourceHealth: .failed, processes: [])

    XCTAssertTrue(detector.events(previous: running, current: incomplete, now: date(2_000)).isEmpty)
    XCTAssertTrue(detector.events(previous: incomplete, current: absent, now: date(2_001)).isEmpty)
    XCTAssertTrue(detector.events(previous: absent, current: failed, now: date(2_002)).isEmpty)
    XCTAssertTrue(detector.events(previous: failed, current: absent, now: date(2_003)).isEmpty)
    XCTAssertTrue(detector.events(previous: absent, current: absent, now: date(2_004)).isEmpty)
  }

  func testUnhealthyPreviousSourceCannotSeedExitConfirmation() {
    var detector = AutomationEventDetector()
    let unhealthyRunning = presentation(elapsed: "00:01:00", sourceHealth: .failed)
    let healthyAbsent = presentation(processes: [])

    XCTAssertTrue(detector.events(
      previous: unhealthyRunning, current: healthyAbsent, now: date(2_100)
    ).isEmpty)
    XCTAssertTrue(detector.events(
      previous: healthyAbsent, current: healthyAbsent, now: date(2_101)
    ).isEmpty)
  }

  func testLongRunningPIDRecycleEmitsTransitionForNewBirthIdentity() {
    var detector = AutomationEventDetector()
    let old = presentation(elapsed: "04:00:00")
    let newBirth = ProcessBirthToken(seconds: 30_000, microseconds: 7)
    let recycled = presentation(elapsed: "04:00:01", birthToken: newBirth)

    XCTAssertEqual(detector.events(
      previous: old, current: recycled, now: date(30_001)
    ), [.crossedLongRunningThreshold(
      process: ProcessIdentity(pid: Fixtures.runningBackup.pid, birthToken: newBirth),
      recordID: expectedRecord.id
    )])
  }

  func testLongRunningTransitionDoesNotAttributeAnAmbiguousProcessToOneAutomation() throws {
    var detector = AutomationEventDetector()
    let before = presentation(elapsed: "03:59:59")
    let boundary = presentation(elapsed: "04:00:00")
    let identity = try XCTUnwrap(boundary.processIdentitiesByID[Fixtures.runningBackup.pid])
    let primaryLink = try XCTUnwrap(boundary.linksByProcessID[Fixtures.runningBackup.pid])
    let secondLink = AutomationProcessLink(
      recordID: AutomationRecord.ID(rawValue: "second-strong-record"),
      processIdentity: identity,
      strength: .strong,
      evidence: []
    )
    let ambiguous = AutomationPresentationSnapshot(
      inventory: boundary.inventory,
      linksByProcessID: boundary.linksByProcessID,
      allLinksByProcessID: [identity.pid: [primaryLink, secondLink]],
      longRunningProcessIDs: boundary.longRunningProcessIDs,
      longRunningProcessIdentities: boundary.longRunningProcessIdentities,
      processIdentitiesByID: boundary.processIdentitiesByID,
      isProcessSnapshotComplete: boundary.isProcessSnapshotComplete
    )

    XCTAssertEqual(detector.events(
      previous: before, current: ambiguous, now: Date(timeIntervalSince1970: 14_400)
    ), [.crossedLongRunningThreshold(
      process: eventIdentity(process(elapsed: "04:00:00")),
      recordID: nil
    )])
  }

  func testUnexpectedExitDoesNotAttributeOneAmbiguousProcessToMultipleAutomations() throws {
    var detector = AutomationEventDetector()
    let running = presentation(elapsed: "00:01:00")
    let identity = try XCTUnwrap(running.processIdentitiesByID[Fixtures.runningBackup.pid])
    let primaryLink = try XCTUnwrap(running.linksByProcessID[Fixtures.runningBackup.pid])
    let secondRecord = copyExpectedRecord(
      id: AutomationRecord.ID(rawValue: "second-strong-record")
    )
    let secondLink = AutomationProcessLink(
      recordID: secondRecord.id,
      processIdentity: identity,
      strength: .strong,
      evidence: []
    )
    let inventory = AutomationInventorySnapshot(
      generation: running.inventory.generation,
      records: [expectedRecord, secondRecord],
      health: running.inventory.health,
      refreshedAt: running.inventory.refreshedAt
    )
    let ambiguousRunning = AutomationPresentationSnapshot(
      inventory: inventory,
      linksByProcessID: running.linksByProcessID,
      allLinksByProcessID: [identity.pid: [primaryLink, secondLink]],
      longRunningProcessIDs: running.longRunningProcessIDs,
      longRunningProcessIdentities: running.longRunningProcessIdentities,
      processIdentitiesByID: running.processIdentitiesByID,
      isProcessSnapshotComplete: true
    )
    let ambiguousAbsent = AutomationPresentationSnapshot(
      inventory: inventory,
      linksByProcessID: [:],
      allLinksByProcessID: [:],
      longRunningProcessIDs: [],
      longRunningProcessIdentities: [],
      processIdentitiesByID: [:],
      isProcessSnapshotComplete: true
    )

    XCTAssertTrue(detector.events(
      previous: ambiguousRunning, current: ambiguousAbsent, now: date(2_200)
    ).isEmpty)
    XCTAssertTrue(detector.events(
      previous: ambiguousAbsent, current: ambiguousAbsent, now: date(2_201)
    ).isEmpty)
  }

  func testPIDReplacementDoesNotBecomeUnexpectedExit() {
    var detector = AutomationEventDetector()
    let running = presentation(elapsed: "00:01:00")
    let replacement = process(
      elapsed: "00:00:01",
      birthToken: ProcessBirthToken(seconds: 9_999, microseconds: 9)
    )
    let replaced = presentation(processes: [replacement])

    XCTAssertTrue(detector.events(previous: running, current: replaced, now: date(3_000)).isEmpty)
    XCTAssertTrue(detector.events(previous: replaced, current: replaced, now: date(3_001)).isEmpty)
  }

  func testThreeVerifiedExitsAtInclusiveTenMinuteBoundaryEmitRepeatedFailureOnce() {
    var detector = AutomationEventDetector()
    var previous = presentation(elapsed: "00:01:00")
    var emitted: [[AutomationEvent]] = []

    for timestamp in [1_000.0, 1_300.0, 1_600.0] {
      let absent = presentation(processes: [])
      _ = detector.events(previous: previous, current: absent, now: date(timestamp - 1))
      emitted.append(detector.events(previous: absent, current: absent, now: date(timestamp)))
      previous = presentation(elapsed: "00:01:00")
      _ = detector.events(previous: absent, current: previous, now: date(timestamp + 0.5))
    }

    XCTAssertEqual(emitted[0].count, 1)
    XCTAssertEqual(emitted[1].count, 1)
    XCTAssertEqual(emitted[2], [
      .unexpectedExit(
        recordID: expectedRecord.id,
        process: eventIdentity(process(elapsed: "00:01:00"))
      ),
      .repeatedFailure(recordID: expectedRecord.id, observedExitCount: 3),
    ])
  }

  func testRepeatedFailureIsSuppressedWhileThreeExitsRemainInWindow() {
    var detector = AutomationEventDetector()
    let outputs = [4_000.0, 4_100.0, 4_200.0, 4_300.0].map { timestamp in
      emitVerifiedExit(detector: &detector, timestamp: timestamp)
    }

    XCTAssertEqual(outputs.flatMap { $0 }.filter {
      if case .repeatedFailure = $0 { return true }
      return false
    }.count, 1)
    XCTAssertEqual(outputs.map(\.count), [1, 1, 2, 1])
  }
}

private let expectedRecord: AutomationRecord = {
  let source = Fixtures.runningUserAgent
  return AutomationRecord(
    id: source.id, kind: source.kind, sourceKind: source.sourceKind,
    label: source.label, displayName: source.displayName,
    providerBundleIdentifier: source.providerBundleIdentifier, ownerUID: source.ownerUID,
    ownership: .user, executable: source.executable, arguments: source.arguments,
    commandSignature: source.commandSignature, environment: source.environment,
    workingDirectory: source.workingDirectory,
    schedule: AutomationSchedule(triggers: [.keepAlive], summary: "Keep alive"),
    sourceURL: source.sourceURL, sourceChecksum: source.sourceChecksum,
    enabledState: .enabled, loadState: .loaded, approvalState: source.approvalState,
    state: .running, evidence: source.evidence, capabilities: source.capabilities,
    validationFindings: source.validationFindings
  )
}()

private func copyExpectedRecord(id: AutomationRecord.ID) -> AutomationRecord {
  AutomationRecord(
    id: id, kind: expectedRecord.kind, sourceKind: expectedRecord.sourceKind,
    label: "\(expectedRecord.label).second", displayName: expectedRecord.displayName,
    providerBundleIdentifier: expectedRecord.providerBundleIdentifier,
    ownerUID: expectedRecord.ownerUID, ownership: expectedRecord.ownership,
    executable: expectedRecord.executable, arguments: expectedRecord.arguments,
    commandSignature: expectedRecord.commandSignature, environment: expectedRecord.environment,
    workingDirectory: expectedRecord.workingDirectory, schedule: expectedRecord.schedule,
    sourceURL: expectedRecord.sourceURL, sourceChecksum: expectedRecord.sourceChecksum,
    enabledState: expectedRecord.enabledState, loadState: expectedRecord.loadState,
    approvalState: expectedRecord.approvalState, state: expectedRecord.state,
    evidence: expectedRecord.evidence, capabilities: expectedRecord.capabilities,
    validationFindings: expectedRecord.validationFindings
  )
}

private func process(
  elapsed: String,
  birthToken: ProcessBirthToken? = ProcessBirthToken(seconds: 10_000, microseconds: 42)
) -> DevProcess {
  DevProcess(
    pid: Fixtures.runningBackup.pid, parentPID: 1,
    executable: Fixtures.runningBackup.executable, command: Fixtures.runningBackup.command,
    argumentVector: Fixtures.runningBackup.argumentVector,
    resourceUsage: DevProcessResourceUsage(
      cpuPercent: 0, residentMemoryBytes: 0, elapsedTime: elapsed
    ),
    birthToken: birthToken
  )
}

private func presentation(
  elapsed: String = "00:00:00",
  birthToken: ProcessBirthToken? = ProcessBirthToken(seconds: 10_000, microseconds: 42),
  complete: Bool = true,
  sourceHealth: AutomationSourceHealthState = .healthy,
  processes: [DevProcess]? = nil
) -> AutomationPresentationSnapshot {
  let inventory = AutomationInventorySnapshot(
    generation: 7,
    records: [expectedRecord],
    health: [.launchAgent: AutomationSourceHealth(
      kind: .launchAgent, state: sourceHealth, message: nil, refreshedAt: date(0)
    )],
    refreshedAt: date(0)
  )
  return AutomationPresentationSnapshot.build(
    inventory: inventory,
    processes: processes ?? [process(elapsed: elapsed, birthToken: birthToken)],
    longRunningThreshold: 14_400,
    now: date(20_000),
    isProcessSnapshotComplete: complete
  )
}

private func date(_ seconds: TimeInterval) -> Date {
  Date(timeIntervalSince1970: seconds)
}

private func eventIdentity(_ process: DevProcess) -> ProcessIdentity {
  ProcessIdentity(pid: process.pid, birthToken: process.birthToken)
}

private func emitVerifiedExit(
  detector: inout AutomationEventDetector,
  timestamp: TimeInterval
) -> [AutomationEvent] {
  let running = presentation(elapsed: "00:01:00")
  let absent = presentation(processes: [])
  _ = detector.events(previous: running, current: absent, now: date(timestamp - 1))
  let events = detector.events(previous: absent, current: absent, now: date(timestamp))
  _ = detector.events(previous: absent, current: running, now: date(timestamp + 0.1))
  return events
}
