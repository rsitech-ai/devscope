import DevScopeCore
import Foundation
import XCTest
@testable import DevScope

@MainActor
final class ProcessStoreAutomationTests: XCTestCase {
  func testManualRefreshRequestedDuringAutomaticScanRunsAsTrailingFullRefresh() async {
    let scanner = SequencedBlockingProcessScanner(result: [])
    let store = ProcessStore(scanner: scanner, gpuMetricProvider: NilGPUMetricProvider())
    store.usesAppleNaming = false

    store.refresh()
    let firstScanStarted = await scanner.waitUntilCallCount(1)
    XCTAssertTrue(firstScanStarted)
    scanner.releaseCall(0)
    await eventuallyProcessStore { !store.isRefreshing }

    store.refresh(isAutomatic: true)
    let automaticScanStarted = await scanner.waitUntilCallCount(2)
    XCTAssertTrue(automaticScanStarted)
    store.refresh()
    scanner.releaseCall(1)

    let trailingManualScanStarted = await scanner.waitUntilCallCount(3)
    XCTAssertTrue(trailingManualScanStarted)
    scanner.releaseCall(2)
    await eventuallyProcessStore { !store.isRefreshing }

    XCTAssertEqual(scanner.includeCurrentDirectoryRequests, [true, false, true])
  }

  func testContextChangedDuringInFlightScanWinsAtSinglePublication() async {
    let process = DevProcess(
      pid: 8_001,
      parentPID: 1,
      executable: "/bin/sleep",
      command: "/bin/sleep 20000",
      argumentVector: ["/bin/sleep", "20000"],
      resourceUsage: DevProcessResourceUsage(
        cpuPercent: 0,
        residentMemoryBytes: 1,
        elapsedTime: "05:00:00"
      ),
      birthToken: ProcessBirthToken(seconds: 500, microseconds: 1),
      launchLabel: "com.example.context-race"
    )
    let scanner = BlockingProcessScanner(result: [process])
    let store = ProcessStore(scanner: scanner, gpuMetricProvider: NilGPUMetricProvider())
    store.usesAppleNaming = false

    store.refresh()
    await scanner.waitUntilStarted()
    let inventory = AutomationInventorySnapshot(
      generation: 12,
      records: [automationRecordForContextRace()],
      health: [.launchAgent: AutomationSourceHealth(
        kind: .launchAgent,
        state: .healthy,
        message: nil,
        refreshedAt: Date(timeIntervalSince1970: 12)
      )],
      refreshedAt: Date(timeIntervalSince1970: 12)
    )
    store.updateAutomationContext(inventory: inventory, longRunningThreshold: 1)
    scanner.release()
    await eventuallyProcessStore { !store.isRefreshing }

    XCTAssertEqual(store.liveSnapshot.automationInventory.generation, 12)
    XCTAssertEqual(
      store.liveSnapshot.automationLinksByProcessID[process.pid]?.recordID,
      inventory.records[0].id
    )
    XCTAssertEqual(store.liveSnapshot.longRunningProcessIDs, [process.pid])
    XCTAssertEqual(store.liveSnapshot.processes.map(\.pid), [process.pid])
  }
}

private final class SequencedBlockingProcessScanner: ProcessProviding, @unchecked Sendable {
  private let condition = NSCondition()
  private let result: [DevProcess]
  private var requests: [Bool] = []
  private var releasedCalls: Set<Int> = []

  init(result: [DevProcess]) {
    self.result = result
  }

  var includeCurrentDirectoryRequests: [Bool] {
    condition.withLock { requests }
  }

  func snapshot(includeCurrentDirectories: Bool) throws -> [DevProcess] {
    condition.lock()
    let callIndex = requests.count
    requests.append(includeCurrentDirectories)
    condition.broadcast()
    while !releasedCalls.contains(callIndex) {
      condition.wait()
    }
    condition.unlock()
    return result
  }

  func waitUntilCallCount(
    _ expectedCount: Int,
    timeout: Duration = .seconds(1)
  ) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if condition.withLock({ requests.count >= expectedCount }) {
        return true
      }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return condition.withLock { requests.count >= expectedCount }
  }

  func releaseCall(_ callIndex: Int) {
    condition.withLock {
      releasedCalls.insert(callIndex)
      condition.broadcast()
    }
  }
}

private final class BlockingProcessScanner: ProcessProviding, @unchecked Sendable {
  private let started = DispatchSemaphore(value: 0)
  private let gate = DispatchSemaphore(value: 0)
  private let result: [DevProcess]

  init(result: [DevProcess]) {
    self.result = result
  }

  func snapshot(includeCurrentDirectories: Bool) throws -> [DevProcess] {
    started.signal()
    gate.wait()
    return result
  }

  func waitUntilStarted() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        self.started.wait()
        continuation.resume()
      }
    }
  }

  func release() {
    gate.signal()
  }
}

private struct NilGPUMetricProvider: GPUMetricProviding {
  func snapshot() throws -> DevGPUMetric? { nil }
}

@MainActor
private func eventuallyProcessStore(
  _ predicate: @MainActor () -> Bool,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  for _ in 0..<1_000 where !predicate() {
    try? await Task.sleep(for: .milliseconds(1))
  }
  if !predicate() {
    XCTFail("Timed out waiting for asynchronous process-store state.", file: file, line: line)
  }
}

private func automationRecordForContextRace() -> AutomationRecord {
  AutomationRecord(
    id: AutomationRecord.ID(rawValue: "context-race-record"),
    kind: .launchAgent,
    sourceKind: .launchAgent,
    label: "com.example.context-race",
    displayName: "Context Race",
    providerBundleIdentifier: nil,
    ownerUID: 501,
    ownership: .user,
    executable: "/bin/sleep",
    arguments: ["20000"],
    environment: [:],
    workingDirectory: nil,
    schedule: AutomationSchedule(triggers: [.runAtLoad], summary: "At load"),
    sourceURL: URL(fileURLWithPath: "/tmp/com.example.context-race.plist"),
    sourceChecksum: "context-race",
    enabledState: .enabled,
    loadState: .loaded,
    approvalState: .notApplicable,
    state: .running,
    evidence: [],
    capabilities: [.exportRecord],
    validationFindings: []
  )
}
