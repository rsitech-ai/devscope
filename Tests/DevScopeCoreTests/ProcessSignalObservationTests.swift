import XCTest
@testable import DevScopeCore

final class ProcessSignalObservationTests: XCTestCase {
  func testSameBirthWithMetadataEnrichmentIsStillRunning() {
    let birthToken = ProcessBirthToken(seconds: 1_000, microseconds: 100)
    let original = DevProcess(
      pid: 42,
      parentPID: 1,
      executable: "node",
      command: "node",
      birthToken: birthToken
    )
    let enriched = DevProcess(
      pid: 42,
      parentPID: 99,
      executable: "/opt/homebrew/bin/node",
      command: "/opt/homebrew/bin/node server.js",
      currentDirectory: "/tmp/project",
      birthToken: birthToken
    )
    let target = ProcessIdentity(process: original)

    let summary = ProcessSignalObservation.observe(
      targets: [target],
      in: [enriched]
    )

    XCTAssertEqual(
      summary.observations,
      [ProcessSignalTargetObservation(target: target, state: .stillRunning)]
    )
    XCTAssertFalse(summary.verifiesAllTargetsStopped)
  }

  func testAbsentTargetIsExitedOrReplacedAndVerifiesStopped() {
    let target = ProcessIdentity(
      process: DevProcess(
        pid: 42,
        parentPID: 1,
        executable: "node",
        command: "node",
        birthToken: ProcessBirthToken(seconds: 1_000, microseconds: 100)
      )
    )

    let summary = ProcessSignalObservation.observe(targets: [target], in: [])

    XCTAssertEqual(
      summary.observations,
      [ProcessSignalTargetObservation(target: target, state: .exitedOrReplaced)]
    )
    XCTAssertTrue(summary.verifiesAllTargetsStopped)
  }

  func testReusedPIDIsExitedOrReplacedAndVerifiesOriginalStopped() {
    let target = ProcessIdentity(
      process: DevProcess(
        pid: 42,
        parentPID: 1,
        executable: "node",
        command: "node",
        birthToken: ProcessBirthToken(seconds: 1_000, microseconds: 100)
      )
    )
    let replacement = DevProcess(
      pid: 42,
      parentPID: 1,
      executable: "node",
      command: "node",
      birthToken: ProcessBirthToken(seconds: 1_000, microseconds: 101)
    )

    let summary = ProcessSignalObservation.observe(
      targets: [target],
      in: [replacement]
    )

    XCTAssertEqual(summary.exitedOrReplaced, [target])
    XCTAssertTrue(summary.verifiesAllTargetsStopped)
  }

  func testUnknownExpectedOrCurrentBirthIsUnverifiableAndNeverSuccess() {
    let unknownExpected = ProcessIdentity(
      process: DevProcess(
        pid: 41,
        parentPID: 1,
        executable: "node",
        command: "node"
      )
    )
    let knownExpected = ProcessIdentity(
      process: DevProcess(
        pid: 42,
        parentPID: 1,
        executable: "node",
        command: "node",
        birthToken: ProcessBirthToken(seconds: 1_000, microseconds: 100)
      )
    )
    let currentProcesses = [
      DevProcess(
        pid: 41,
        parentPID: 1,
        executable: "node",
        command: "node",
        birthToken: ProcessBirthToken(seconds: 1_000, microseconds: 99)
      ),
      DevProcess(
        pid: 42,
        parentPID: 1,
        executable: "node",
        command: "node"
      ),
    ]

    let summary = ProcessSignalObservation.observe(
      targets: [unknownExpected, knownExpected],
      in: currentProcesses
    )

    XCTAssertEqual(summary.unverifiable, [unknownExpected, knownExpected])
    XCTAssertFalse(summary.verifiesAllTargetsStopped)
  }

  func testPartialAllStoppedPresentationNeverClaimsFullCompletion() {
    let signaled = ProcessIdentity(
      process: DevProcess(
        pid: 12,
        parentPID: 11,
        executable: "node",
        command: "node worker.js",
        birthToken: ProcessBirthToken(seconds: 1_000, microseconds: 12)
      )
    )
    let failed = ProcessIdentity(
      process: DevProcess(
        pid: 11,
        parentPID: 10,
        executable: "node",
        command: "node server.js",
        birthToken: ProcessBirthToken(seconds: 1_000, microseconds: 11)
      )
    )
    let observation = ProcessSignalObservation.observe(targets: [signaled], in: [])

    let presentation = ProcessPartialSignalVerificationPresentation.make(
      signalName: "TERM",
      observation: observation,
      failedTarget: failed,
      reason: "PID 11 was reused"
    )

    XCTAssertEqual(presentation.title, "Partial result verified")
    XCTAssertEqual(
      presentation.detail,
      "1 signaled process stopped. PID 11 failed: PID 11 was reused. The failed target and all remaining tree targets were not signaled."
    )
    XCTAssertFalse(presentation.title.contains("Process stopped"))
  }

  func testPartialPendingPresentationRetainsStillRunningAndUnverifiableStates() {
    let token = ProcessBirthToken(seconds: 1_000, microseconds: 1)
    let stopped = identity(pid: 12, birthToken: token)
    let stillRunning = identity(pid: 13, birthToken: token)
    let unverifiable = identity(pid: 14, birthToken: token)
    let failed = identity(pid: 11, birthToken: token)
    let currentProcesses = [
      process(pid: 13, birthToken: token),
      process(pid: 14, birthToken: nil),
    ]
    let observation = ProcessSignalObservation.observe(
      targets: [stopped, stillRunning, unverifiable],
      in: currentProcesses
    )

    let presentation = ProcessPartialSignalVerificationPresentation.make(
      signalName: "TERM",
      observation: observation,
      failedTarget: failed,
      reason: "permission denied"
    )

    XCTAssertEqual(presentation.title, "Partial result not fully verified")
    XCTAssertEqual(
      presentation.detail,
      "1 signaled process stopped. Still running: 13. Could not verify: 14. PID 11 failed: permission denied. The failed target and all remaining tree targets were not signaled."
    )
  }

  private func identity(
    pid: Int32,
    birthToken: ProcessBirthToken?
  ) -> ProcessIdentity {
    ProcessIdentity(process: process(pid: pid, birthToken: birthToken))
  }

  private func process(
    pid: Int32,
    birthToken: ProcessBirthToken?
  ) -> DevProcess {
    DevProcess(
      pid: pid,
      parentPID: 1,
      executable: "node",
      command: "node worker.js",
      birthToken: birthToken
    )
  }
}
