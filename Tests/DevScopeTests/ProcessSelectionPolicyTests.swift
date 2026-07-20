import DevScopeCore
import XCTest
@testable import DevScope

final class ProcessSelectionPolicyTests: XCTestCase {
  func testPIDReuseClearsSelectionInsteadOfSelectingTheReplacementProcess() {
    let original = item(pid: 42, birth: 100, cpu: 1)
    let replacement = item(pid: 42, birth: 200, cpu: 2)

    let result = ProcessSelectionPolicy.reconcile(
      selectedProcessID: 42,
      retainedProcess: original,
      currentProcesses: [replacement]
    )

    XCTAssertNil(result.selectedProcessID)
    XCTAssertNil(result.retainedProcess)
  }

  func testSameBirthRefreshesTheRetainedSelectionWithCurrentMetrics() {
    let original = item(pid: 42, birth: 100, cpu: 1)
    let refreshed = item(pid: 42, birth: 100, cpu: 9)

    let result = ProcessSelectionPolicy.reconcile(
      selectedProcessID: 42,
      retainedProcess: original,
      currentProcesses: [refreshed]
    )

    XCTAssertEqual(result.selectedProcessID, 42)
    XCTAssertEqual(result.retainedProcess, refreshed)
  }

  func testSelectingDifferentPIDAdoptsTheNewProcessInsteadOfComparingOldIdentity() {
    let previouslySelected = item(pid: 41, birth: 100, cpu: 1)
    let newlySelected = item(pid: 42, birth: 200, cpu: 2)

    let result = ProcessSelectionPolicy.reconcile(
      selectedProcessID: 42,
      retainedProcess: previouslySelected,
      currentProcesses: [previouslySelected, newlySelected]
    )

    XCTAssertEqual(result.selectedProcessID, 42)
    XCTAssertEqual(result.retainedProcess, newlySelected)
  }

  func testMissingCurrentProcessPreservesTheEndedSelectionForInspection() {
    let original = item(pid: 42, birth: 100, cpu: 1)

    let result = ProcessSelectionPolicy.reconcile(
      selectedProcessID: 42,
      retainedProcess: original,
      currentProcesses: []
    )

    XCTAssertEqual(result.selectedProcessID, 42)
    XCTAssertEqual(result.retainedProcess, original)
  }

  func testSelectionClearsWhenOnlyOneSnapshotHasVerifiableBirthIdentity() {
    let known = item(pid: 42, birth: 100, cpu: 1)
    let unknown = item(pid: 42, birth: nil, cpu: 2)

    for (retained, current) in [(known, unknown), (unknown, known)] {
      let result = ProcessSelectionPolicy.reconcile(
        selectedProcessID: 42,
        retainedProcess: retained,
        currentProcesses: [current]
      )
      XCTAssertNil(result.selectedProcessID)
      XCTAssertNil(result.retainedProcess)
    }
  }

  func testSelectionClearsWhenNeitherSnapshotHasVerifiableBirthIdentity() {
    let retained = item(pid: 42, birth: nil, cpu: 1)
    let current = item(pid: 42, birth: nil, cpu: 2)

    let result = ProcessSelectionPolicy.reconcile(
      selectedProcessID: 42,
      retainedProcess: retained,
      currentProcesses: [current]
    )

    XCTAssertNil(result.selectedProcessID)
    XCTAssertNil(result.retainedProcess)
  }

  private func item(pid: Int32, birth: UInt64?, cpu: Double) -> ClassifiedDevProcess {
    ClassifiedDevProcess(
      process: DevProcess(
        pid: pid,
        parentPID: 1,
        executable: "/bin/sleep",
        command: "/bin/sleep 10",
        resourceUsage: DevProcessResourceUsage(
          cpuPercent: cpu,
          residentMemoryBytes: 1,
          elapsedTime: "00:10"
        ),
        birthToken: birth.map { ProcessBirthToken(seconds: $0, microseconds: 1) }
      ),
      classification: DevProcessClassification(
        kind: .other,
        displayName: "sleep",
        projectHint: nil,
        tags: []
      )
    )
  }
}
