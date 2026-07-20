import Darwin
import Foundation
import XCTest
@testable import DevScopeCore

final class ProcessKillerTests: XCTestCase {
  func testTerminateSignalsWhenLiveIdentityMatchesExpectedBirth() throws {
    let process = process(pid: 42, birthToken: token(100))
    let recorder = SignalRecorder()
    let killer = ProcessKiller(
      identityResolver: { _ in .identity(ProcessIdentity(process: process)) },
      signalSender: { pid, signal in recorder.record(pid: pid, signal: signal) }
    )

    let targets = try killer.terminate(classified(process), currentProcessID: 9_000)

    XCTAssertEqual(targets, [ProcessIdentity(process: process)])
    XCTAssertEqual(recorder.signals, [RecordedSignal(pid: 42, signal: SIGTERM)])
  }

  func testForceTerminateUsesKillSignalAfterIdentityValidation() throws {
    let process = process(pid: 42, birthToken: token(100))
    let recorder = SignalRecorder()
    let killer = matchingKiller(for: [process], recorder: recorder)

    let targets = try killer.forceTerminate(
      classified(process),
      currentProcessID: 9_000
    )

    XCTAssertEqual(targets, [ProcessIdentity(process: process)])
    XCTAssertEqual(recorder.signals, [RecordedSignal(pid: 42, signal: SIGKILL)])
  }

  func testTerminateRejectsMissingExpectedBirthWithoutSendingSignal() {
    let process = process(pid: 42, birthToken: nil)
    let recorder = SignalRecorder()
    let killer = ProcessKiller(
      identityResolver: { _ in .identity(ProcessIdentity(process: process)) },
      signalSender: { pid, signal in recorder.record(pid: pid, signal: signal) }
    )

    XCTAssertThrowsError(
      try killer.terminate(classified(process), currentProcessID: 9_000)
    ) { error in
      XCTAssertEqual(error as? ProcessKillError, .expectedIdentityUnavailable(pid: 42))
    }
    XCTAssertTrue(recorder.signals.isEmpty)
  }

  func testTerminateRejectsLiveIdentityWithMissingBirthWithoutSendingSignal() {
    let process = process(pid: 42, birthToken: token(100))
    let liveWithoutBirth = self.process(pid: 42, birthToken: nil)
    let recorder = SignalRecorder()
    let killer = ProcessKiller(
      identityResolver: { _ in .identity(ProcessIdentity(process: liveWithoutBirth)) },
      signalSender: { pid, signal in recorder.record(pid: pid, signal: signal) }
    )

    XCTAssertThrowsError(
      try killer.terminate(classified(process), currentProcessID: 9_000)
    ) { error in
      XCTAssertEqual(error as? ProcessKillError, .liveIdentityUnavailable(pid: 42))
    }
    XCTAssertTrue(recorder.signals.isEmpty)
  }

  func testTerminateRejectsReusedPIDWithoutSendingSignal() {
    let process = process(pid: 42, birthToken: token(100))
    let replacement = self.process(pid: 42, birthToken: token(101))
    let recorder = SignalRecorder()
    let killer = ProcessKiller(
      identityResolver: { _ in .identity(ProcessIdentity(process: replacement)) },
      signalSender: { pid, signal in recorder.record(pid: pid, signal: signal) }
    )

    XCTAssertThrowsError(
      try killer.terminate(classified(process), currentProcessID: 9_000)
    ) { error in
      XCTAssertEqual(error as? ProcessKillError, .identityMismatch(pid: 42))
    }
    XCTAssertTrue(recorder.signals.isEmpty)
  }

  func testTerminateRejectsTargetThatEndedAfterConfirmationWithoutSendingSignal() {
    let process = process(pid: 42, birthToken: token(100))
    let recorder = SignalRecorder()
    let killer = ProcessKiller(
      identityResolver: { _ in .notRunning },
      signalSender: { pid, signal in recorder.record(pid: pid, signal: signal) }
    )

    XCTAssertThrowsError(
      try killer.terminate(classified(process), currentProcessID: 9_000)
    ) { error in
      XCTAssertEqual(error as? ProcessKillError, .targetNotRunning(pid: 42))
    }
    XCTAssertTrue(recorder.signals.isEmpty)
  }

  func testTerminateRechecksIdentityAfterGlobalPreflightBeforeSendingSignal() {
    let process = process(pid: 42, birthToken: token(100))
    let replacement = self.process(pid: 42, birthToken: token(101))
    let resolver = IdentityResolutionScript(resolutions: [
      42: [
        .identity(ProcessIdentity(process: process)),
        .identity(ProcessIdentity(process: replacement)),
      ]
    ])
    let recorder = SignalRecorder()
    let killer = ProcessKiller(
      identityResolver: resolver.resolve,
      signalSender: { pid, signal in recorder.record(pid: pid, signal: signal) }
    )

    XCTAssertThrowsError(
      try killer.terminate(classified(process), currentProcessID: 9_000)
    ) { error in
      XCTAssertEqual(error as? ProcessKillError, .identityMismatch(pid: 42))
    }
    XCTAssertTrue(recorder.signals.isEmpty)
  }

  func testTerminateTreeSignalsDescendantsBeforeTheirAncestors() throws {
    let root = process(pid: 10, parentPID: 1, birthToken: token(10))
    let child = process(pid: 11, parentPID: 10, birthToken: token(11))
    let grandchild = process(pid: 12, parentPID: 11, birthToken: token(12))
    let processes = [root, child, grandchild]
    let liveByPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
    let recorder = SignalRecorder()
    let killer = ProcessKiller(
      identityResolver: { pid in
        liveByPID[pid].map { .identity(ProcessIdentity(process: $0)) } ?? .notRunning
      },
      signalSender: { pid, signal in recorder.record(pid: pid, signal: signal) }
    )

    let targets = try killer.terminateTree(
      root: classified(root),
      processes: processes,
      classifiedProcesses: processes.map { classified($0) },
      currentProcessID: 9_000
    )

    XCTAssertEqual(targets.map(\.pid), [12, 11, 10])
    XCTAssertEqual(
      recorder.signals,
      [12, 11, 10].map { RecordedSignal(pid: $0, signal: SIGTERM) }
    )
  }

  func testForceTerminateTreeSignalsDescendantsBeforeAncestorsWithKill() throws {
    let root = process(pid: 10, parentPID: 1, birthToken: token(10))
    let child = process(pid: 11, parentPID: 10, birthToken: token(11))
    let grandchild = process(pid: 12, parentPID: 11, birthToken: token(12))
    let processes = [root, child, grandchild]
    let recorder = SignalRecorder()
    let killer = matchingKiller(for: processes, recorder: recorder)

    let targets = try killer.forceTerminateTree(
      root: classified(root),
      processes: processes,
      classifiedProcesses: processes.map { classified($0) },
      currentProcessID: 9_000
    )

    XCTAssertEqual(targets.map(\.pid), [12, 11, 10])
    XCTAssertEqual(
      recorder.signals,
      [12, 11, 10].map { RecordedSignal(pid: $0, signal: SIGKILL) }
    )
  }

  func testTerminateTreeRejectsDevScopeDescendantWithoutSendingAnySignal() {
    let root = process(pid: 10, parentPID: 1, birthToken: token(10))
    let devScope = process(
      pid: 42,
      parentPID: 10,
      executable: "/Applications/DevScope.app/Contents/MacOS/DevScope",
      birthToken: token(42)
    )
    let processes = [root, devScope]
    let recorder = SignalRecorder()
    let killer = matchingKiller(for: processes, recorder: recorder)

    XCTAssertThrowsError(
      try killer.terminateTree(
        root: classified(root),
        processes: processes,
        classifiedProcesses: [classified(root), classified(devScope, kind: .macApp)],
        currentProcessID: 42
      )
    ) { error in
      XCTAssertEqual(
        error as? ProcessKillError,
        .protectedTarget(pid: 42, reason: "DevScope cannot terminate itself")
      )
    }
    XCTAssertTrue(recorder.signals.isEmpty)
  }

  func testTerminateTreeRejectsCriticalSystemDescendantWithoutSendingAnySignal() {
    let root = process(pid: 10, parentPID: 1, birthToken: token(10))
    let windowServer = process(
      pid: 88,
      parentPID: 10,
      executable: "/System/Library/CoreServices/WindowServer",
      birthToken: token(88)
    )
    let processes = [root, windowServer]
    let recorder = SignalRecorder()
    let killer = matchingKiller(for: processes, recorder: recorder)

    XCTAssertThrowsError(
      try killer.terminateTree(
        root: classified(root),
        processes: processes,
        classifiedProcesses: [classified(root), classified(windowServer, kind: .systemService)],
        currentProcessID: 9_000
      )
    ) { error in
      XCTAssertEqual(
        error as? ProcessKillError,
        .protectedTarget(
          pid: 88,
          reason: "Critical macOS system infrastructure is protected"
        )
      )
    }
    XCTAssertTrue(recorder.signals.isEmpty)
  }

  func testTerminateTreeRejectsUnclassifiedDescendantWithoutSendingAnySignal() {
    let root = process(pid: 10, parentPID: 1, birthToken: token(10))
    let child = process(pid: 11, parentPID: 10, birthToken: token(11))
    let processes = [root, child]
    let recorder = SignalRecorder()
    let killer = matchingKiller(for: processes, recorder: recorder)

    XCTAssertThrowsError(
      try killer.terminateTree(
        root: classified(root),
        processes: processes,
        classifiedProcesses: [classified(root)],
        currentProcessID: 9_000
      )
    ) { error in
      XCTAssertEqual(
        error as? ProcessKillError,
        .targetClassificationUnavailable(pid: 11)
      )
    }
    XCTAssertTrue(recorder.signals.isEmpty)
  }

  func testTerminateTreeRejectsDescendantWithUnknownBirthWithoutSendingAnySignal() {
    let root = process(pid: 10, parentPID: 1, birthToken: token(10))
    let child = process(pid: 11, parentPID: 10, birthToken: nil)
    let processes = [root, child]
    let recorder = SignalRecorder()
    let killer = matchingKiller(for: processes, recorder: recorder)

    XCTAssertThrowsError(
      try killer.terminateTree(
        root: classified(root),
        processes: processes,
        classifiedProcesses: processes.map { classified($0) },
        currentProcessID: 9_000
      )
    ) { error in
      XCTAssertEqual(
        error as? ProcessKillError,
        .expectedIdentityUnavailable(pid: 11)
      )
    }
    XCTAssertTrue(recorder.signals.isEmpty)
  }

  func testTerminateTreePreflightRejectsOneReusedDescendantWithoutSendingAnySignal() {
    let root = process(pid: 10, parentPID: 1, birthToken: token(10))
    let firstChild = process(pid: 11, parentPID: 10, birthToken: token(11))
    let reusedChild = process(pid: 12, parentPID: 10, birthToken: token(12))
    let processes = [root, firstChild, reusedChild]
    let replacement = process(pid: 11, parentPID: 10, birthToken: token(99))
    let liveByPID: [Int32: DevProcess] = [10: root, 11: replacement, 12: reusedChild]
    let recorder = SignalRecorder()
    let killer = ProcessKiller(
      identityResolver: { pid in
        liveByPID[pid].map { .identity(ProcessIdentity(process: $0)) } ?? .notRunning
      },
      signalSender: { pid, signal in recorder.record(pid: pid, signal: signal) }
    )

    XCTAssertThrowsError(
      try killer.terminateTree(
        root: classified(root),
        processes: processes,
        classifiedProcesses: processes.map { classified($0) },
        currentProcessID: 9_000
      )
    ) { error in
      XCTAssertEqual(error as? ProcessKillError, .identityMismatch(pid: 11))
    }
    XCTAssertTrue(recorder.signals.isEmpty)
  }

  func testTerminateTreeReportsAlreadySignaledDescendantWhenLaterIdentityChanges() {
    let root = process(pid: 10, parentPID: 1, birthToken: token(10))
    let child = process(pid: 11, parentPID: 10, birthToken: token(11))
    let grandchild = process(pid: 12, parentPID: 11, birthToken: token(12))
    let replacement = process(pid: 11, parentPID: 10, birthToken: token(99))
    let processes = [root, child, grandchild]
    let resolver = IdentityResolutionScript(resolutions: [
      10: [.identity(ProcessIdentity(process: root))],
      11: [
        .identity(ProcessIdentity(process: child)),
        .identity(ProcessIdentity(process: replacement)),
      ],
      12: [
        .identity(ProcessIdentity(process: grandchild)),
        .identity(ProcessIdentity(process: grandchild)),
      ],
    ])
    let recorder = SignalRecorder()
    let killer = ProcessKiller(
      identityResolver: resolver.resolve,
      signalSender: { pid, signal in recorder.record(pid: pid, signal: signal) }
    )

    XCTAssertThrowsError(
      try killer.terminateTree(
        root: classified(root),
        processes: processes,
        classifiedProcesses: processes.map { classified($0) },
        currentProcessID: 9_000
      )
    ) { error in
      guard let failure = error as? ProcessSignalExecutionFailure else {
        return XCTFail("Expected structured partial execution failure, got \(error)")
      }
      XCTAssertEqual(
        failure.signaledIdentities,
        [ProcessIdentity(process: grandchild)]
      )
      XCTAssertEqual(failure.failedTarget, ProcessIdentity(process: child))
      XCTAssertEqual(
        failure.underlyingError as? ProcessKillError,
        .identityMismatch(pid: 11)
      )
      XCTAssertEqual(
        failure.localizedDescription,
        "Signaled 1 process before PID 11 failed: PID 11 no longer belongs to the selected process"
      )
    }
    XCTAssertEqual(recorder.signals, [RecordedSignal(pid: 12, signal: SIGTERM)])
  }

  func testTerminateTreeReportsAlreadySignaledDescendantWhenLaterSenderFails() {
    let root = process(pid: 10, parentPID: 1, birthToken: token(10))
    let child = process(pid: 11, parentPID: 10, birthToken: token(11))
    let grandchild = process(pid: 12, parentPID: 11, birthToken: token(12))
    let processes = [root, child, grandchild]
    let liveByPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
    let recorder = SignalRecorder()
    let senderFailure = ProcessKillError.signalFailed(pid: 11, errnoCode: EPERM)
    let killer = ProcessKiller(
      identityResolver: { pid in
        liveByPID[pid].map { .identity(ProcessIdentity(process: $0)) } ?? .notRunning
      },
      signalSender: { pid, signal in
        guard pid != 11 else { throw senderFailure }
        recorder.record(pid: pid, signal: signal)
      }
    )

    XCTAssertThrowsError(
      try killer.terminateTree(
        root: classified(root),
        processes: processes,
        classifiedProcesses: processes.map { classified($0) },
        currentProcessID: 9_000
      )
    ) { error in
      guard let failure = error as? ProcessSignalExecutionFailure else {
        return XCTFail("Expected structured partial execution failure, got \(error)")
      }
      XCTAssertEqual(
        failure.signaledIdentities,
        [ProcessIdentity(process: grandchild)]
      )
      XCTAssertEqual(failure.failedTarget, ProcessIdentity(process: child))
      XCTAssertEqual(failure.underlyingError as? ProcessKillError, senderFailure)
    }
    XCTAssertEqual(recorder.signals, [RecordedSignal(pid: 12, signal: SIGTERM)])
  }

  func testTerminateTreeFirstSenderFailureStaysOrdinaryAndStopsLaterTargets() {
    let root = process(pid: 10, parentPID: 1, birthToken: token(10))
    let child = process(pid: 11, parentPID: 10, birthToken: token(11))
    let grandchild = process(pid: 12, parentPID: 11, birthToken: token(12))
    let processes = [root, child, grandchild]
    let liveByPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
    let recorder = SignalRecorder()
    let senderFailure = ProcessKillError.signalFailed(pid: 12, errnoCode: EPERM)
    let killer = ProcessKiller(
      identityResolver: { pid in
        liveByPID[pid].map { .identity(ProcessIdentity(process: $0)) } ?? .notRunning
      },
      signalSender: { pid, signal in
        guard pid != 12 else { throw senderFailure }
        recorder.record(pid: pid, signal: signal)
      }
    )

    XCTAssertThrowsError(
      try killer.terminateTree(
        root: classified(root),
        processes: processes,
        classifiedProcesses: processes.map { classified($0) },
        currentProcessID: 9_000
      )
    ) { error in
      XCTAssertEqual(error as? ProcessKillError, senderFailure)
      XCTAssertFalse(error is ProcessSignalExecutionFailure)
    }
    XCTAssertTrue(recorder.signals.isEmpty)
  }

  func testTerminateTreeRejectsStaleDescendantClassificationWithoutSendingAnySignal() {
    let root = process(pid: 10, parentPID: 1, birthToken: token(10))
    let child = process(pid: 11, parentPID: 10, birthToken: token(11))
    let staleClassifiedChild = process(pid: 11, parentPID: 10, birthToken: token(99))
    let processes = [root, child]
    let recorder = SignalRecorder()
    let killer = matchingKiller(for: processes, recorder: recorder)

    XCTAssertThrowsError(
      try killer.terminateTree(
        root: classified(root),
        processes: processes,
        classifiedProcesses: [classified(root), classified(staleClassifiedChild)],
        currentProcessID: 9_000
      )
    ) { error in
      XCTAssertEqual(
        error as? ProcessKillError,
        .targetClassificationMismatch(pid: 11)
      )
    }
    XCTAssertTrue(recorder.signals.isEmpty)
  }

  private func process(
    pid: Int32,
    parentPID: Int32 = 1,
    executable: String = "/opt/homebrew/bin/node",
    birthToken: ProcessBirthToken?
  ) -> DevProcess {
    DevProcess(
      pid: pid,
      parentPID: parentPID,
      executable: executable,
      command: "node server.js",
      birthToken: birthToken
    )
  }

  private func classified(
    _ process: DevProcess,
    kind: DevRuntimeKind = .javascript
  ) -> ClassifiedDevProcess {
    ClassifiedDevProcess(
      process: process,
      classification: DevProcessClassification(
        kind: kind,
        displayName: "Node",
        projectHint: nil
      )
    )
  }

  private func token(_ microseconds: UInt64) -> ProcessBirthToken {
    ProcessBirthToken(seconds: 1_000, microseconds: microseconds)
  }

  private func matchingKiller(
    for processes: [DevProcess],
    recorder: SignalRecorder
  ) -> ProcessKiller {
    let liveByPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
    return ProcessKiller(
      identityResolver: { pid in
        liveByPID[pid].map { .identity(ProcessIdentity(process: $0)) } ?? .notRunning
      },
      signalSender: { pid, signal in recorder.record(pid: pid, signal: signal) }
    )
  }
}

private struct RecordedSignal: Equatable {
  let pid: Int32
  let signal: Int32
}

private final class SignalRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedSignals: [RecordedSignal] = []

  var signals: [RecordedSignal] {
    lock.withLock { recordedSignals }
  }

  func record(pid: Int32, signal: Int32) {
    lock.withLock {
      recordedSignals.append(RecordedSignal(pid: pid, signal: signal))
    }
  }
}

private final class IdentityResolutionScript: @unchecked Sendable {
  private let lock = NSLock()
  private var resolutions: [Int32: [ProcessLiveIdentityResolution]]

  init(resolutions: [Int32: [ProcessLiveIdentityResolution]]) {
    self.resolutions = resolutions
  }

  func resolve(pid: Int32) -> ProcessLiveIdentityResolution {
    lock.withLock {
      guard var scripted = resolutions[pid], !scripted.isEmpty else {
        return .notRunning
      }
      let resolution = scripted.removeFirst()
      resolutions[pid] = scripted
      return resolution
    }
  }
}
