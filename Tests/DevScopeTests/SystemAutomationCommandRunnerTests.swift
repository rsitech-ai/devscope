import Darwin
import Foundation
import XCTest
@testable import DevScope
import DevScopeCore

final class SystemAutomationCommandRunnerTests: XCTestCase {
  func testOrdinaryCommandCapturesBothStreamsEnvironmentAndExitStatus() async throws {
    let result = try await SystemAutomationCommandRunner().run(AutomationCommand(
      executable: "/bin/sh",
      arguments: [
        "-c",
        "printf '%s' \"$DEVSCOPE_RUNNER_TEST\"; printf 'stderr-value' >&2; exit 7",
      ],
      environment: ["DEVSCOPE_RUNNER_TEST": "stdout-value"]
    ))

    XCTAssertEqual(result.status, 7)
    XCTAssertEqual(String(data: result.standardOutput, encoding: .utf8), "stdout-value")
    XCTAssertEqual(String(data: result.standardError, encoding: .utf8), "stderr-value")
  }

  func testCaptureLimitDrainsAllOutputThenRejectsPartialResult() async throws {
    let processGroup = LockedValue<pid_t?>(nil)
    let runner = SystemAutomationCommandRunner(
      hooks: .init(afterSpawnBeforeInstall: { processGroup.set($0) }),
      maximumCapturedBytes: 64
    )
    let fallback = cleanupFallback(processGroup)
    defer {
      fallback.cancel()
      killGroupIfPresent(processGroup.value)
    }
    let started = ContinuousClock.now

    do {
      _ = try await runner.run(AutomationCommand(
        executable: "/bin/sh",
        arguments: [
          "-c",
          "/usr/bin/yes 1234567890 | /usr/bin/head -c 200000",
        ]
      ))
      XCTFail("Expected outputLimitExceeded")
    } catch SystemAutomationCommandError.outputLimitExceeded {
      // Expected only after the output pipe reaches EOF.
    } catch {
      XCTFail("Expected outputLimitExceeded, received \(error)")
    }

    XCTAssertLessThan(ContinuousClock.now - started, .seconds(4))
    await assertProcessGone(processGroup.value)
  }

  func testExecutionTimeoutTerminatesTheSpawnedProcessGroupAndFailsClosed() async throws {
    let processGroup = LockedValue<pid_t?>(nil)
    let runner = SystemAutomationCommandRunner(
      hooks: .init(afterSpawnBeforeInstall: { processGroup.set($0) }),
      executionTimeout: .milliseconds(50)
    )
    let fallback = cleanupFallback(processGroup)
    defer {
      fallback.cancel()
      killGroupIfPresent(processGroup.value)
    }
    let started = ContinuousClock.now

    do {
      _ = try await runner.run(AutomationCommand(
        executable: "/bin/sleep",
        arguments: ["30"]
      ))
      XCTFail("Expected executionTimedOut")
    } catch SystemAutomationCommandError.executionTimedOut {
      // Expected after the runner terminates and reaps the process group.
    } catch {
      XCTFail("Expected executionTimedOut, received \(error)")
    }

    XCTAssertLessThan(ContinuousClock.now - started, .seconds(4))
    await assertProcessGone(processGroup.value)
  }

  func testAlreadyCancelledTaskDoesNotSpawnAChild() async throws {
    let gate = DispatchSemaphore(value: 0)
    let spawnCount = LockedValue(0)
    let runner = SystemAutomationCommandRunner(hooks: .init(
      afterSpawnBeforeInstall: { _ in spawnCount.mutate { $0 += 1 } }
    ))
    let task = Task {
      _ = waitSynchronously(gate, timeout: .now() + 5)
      return try await runner.run(AutomationCommand(executable: "/bin/true", arguments: []))
    }

    task.cancel()
    gate.signal()
    await assertCancellation(from: task)
    XCTAssertEqual(spawnCount.value, 0)
  }

  func testCancellationRequestedBeforePIDInstallationStillTerminatesSpawnedGroup() async throws {
    let spawned = DispatchSemaphore(value: 0)
    let allowInstallation = DispatchSemaphore(value: 0)
    let processGroup = LockedValue<pid_t?>(nil)
    let runner = SystemAutomationCommandRunner(hooks: .init(
      afterSpawnBeforeInstall: { pid in
        processGroup.set(pid)
        spawned.signal()
        _ = allowInstallation.wait(timeout: .now() + 5)
      }
    ))
    let task = Task {
      try await runner.run(AutomationCommand(executable: "/bin/sleep", arguments: ["30"]))
    }

    XCTAssertEqual(spawned.wait(timeout: .now() + 5), .success)
    let fallback = cleanupFallback(processGroup)
    defer {
      fallback.cancel()
      killGroupIfPresent(processGroup.value)
    }
    task.cancel()
    allowInstallation.signal()

    let started = ContinuousClock.now
    await assertCancellation(from: task)
    XCTAssertLessThan(ContinuousClock.now - started, .seconds(4))
    await assertProcessGone(processGroup.value)
  }

  func testCancellationEscalatesFromTERMToKILLForTermIgnoringProcessGroup() async throws {
    let installed = DispatchSemaphore(value: 0)
    let processGroup = LockedValue<pid_t?>(nil)
    let runner = SystemAutomationCommandRunner(hooks: .init(
      afterInstall: { pid in
        processGroup.set(pid)
        installed.signal()
      }
    ))
    let task = Task {
      try await runner.run(AutomationCommand(
        executable: "/bin/sh",
        arguments: ["-c", "trap '' TERM; while :; do sleep 1; done"]
      ))
    }

    XCTAssertEqual(installed.wait(timeout: .now() + 5), .success)
    let fallback = cleanupFallback(processGroup)
    defer {
      fallback.cancel()
      killGroupIfPresent(processGroup.value)
    }
    let started = ContinuousClock.now
    task.cancel()
    await assertCancellation(from: task)
    let elapsed = ContinuousClock.now - started
    XCTAssertGreaterThanOrEqual(elapsed, .seconds(1.8))
    XCTAssertLessThan(elapsed, .seconds(4))
    await assertProcessGone(processGroup.value)
  }

  func testCancellationKillsPipeHoldingDescendantAfterLeaderExits() async throws {
    let leaderExited = DispatchSemaphore(value: 0)
    let processGroup = LockedValue<pid_t?>(nil)
    let pidFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("devscope-runner-child-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: pidFile) }
    let runner = SystemAutomationCommandRunner(hooks: .init(
      afterSpawnBeforeInstall: { processGroup.set($0) },
      afterLeaderExitObserved: { _ in leaderExited.signal() }
    ))
    let task = Task {
      try await runner.run(AutomationCommand(
        executable: "/bin/sh",
        arguments: [
          "-c",
          "(trap '' TERM; exec /bin/sleep 30) & child=$!; echo $child > \(pidFile.path); exit 0",
        ]
      ))
    }

    let didObserveLeaderExit = await waitForSignal(leaderExited, timeout: .seconds(5))
    XCTAssertTrue(didObserveLeaderExit)
    let descendantPID = try XCTUnwrap(readPID(from: pidFile))
    let fallback = cleanupFallback(processGroup)
    defer {
      fallback.cancel()
      killGroupIfPresent(processGroup.value)
      _ = Darwin.kill(descendantPID, SIGKILL)
    }
    let started = ContinuousClock.now
    task.cancel()
    await assertCancellation(from: task)
    XCTAssertLessThan(ContinuousClock.now - started, .seconds(4))
    await assertProcessGone(descendantPID)
  }

  func testExecutionTimeoutKillsPipeHoldingDescendantAfterLeaderExits() async throws {
    let processGroup = LockedValue<pid_t?>(nil)
    let descendantPID = LockedValue<pid_t?>(nil)
    let pidFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("devscope-runner-timeout-child-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: pidFile) }
    let runner = SystemAutomationCommandRunner(
      hooks: .init(afterSpawnBeforeInstall: { pid in
        processGroup.set(pid)
        descendantPID.set(waitForPID(from: pidFile, deadline: .now() + .seconds(2)))
      }),
      executionTimeout: .milliseconds(50)
    )
    let fallback = cleanupFallback(processGroup)
    defer {
      fallback.cancel()
      killGroupIfPresent(processGroup.value)
      if let descendantPID = descendantPID.value {
        _ = Darwin.kill(descendantPID, SIGKILL)
      }
    }
    let started = ContinuousClock.now

    do {
      _ = try await runner.run(AutomationCommand(
        executable: "/bin/sh",
        arguments: [
          "-c",
          "(trap '' TERM; exec /bin/sleep 30) & child=$!; echo $child > \(pidFile.path); exit 0",
        ]
      ))
      XCTFail("Expected executionTimedOut")
    } catch SystemAutomationCommandError.executionTimedOut {
      // Expected after the deadline terminates the pipe-holding descendant.
    } catch {
      XCTFail("Expected executionTimedOut, received \(error)")
    }

    XCTAssertLessThan(ContinuousClock.now - started, .seconds(4))
    await assertProcessGone(try XCTUnwrap(descendantPID.value))
  }

  private func assertCancellation(from task: Task<AutomationCommandResult, Error>) async {
    do {
      _ = try await task.value
      XCTFail("Expected CancellationError")
    } catch is CancellationError {
      // Expected.
    } catch {
      XCTFail("Expected CancellationError, received \(error)")
    }
  }

  private func cleanupFallback(_ processGroup: LockedValue<pid_t?>) -> Task<Void, Never> {
    Task.detached {
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled else { return }
      killGroupIfPresent(processGroup.value)
    }
  }

  private func assertProcessGone(_ pid: pid_t?) async {
    guard let pid else {
      XCTFail("Missing spawned PID")
      return
    }
    for _ in 0..<100 {
      errno = 0
      if Darwin.kill(pid, 0) == -1, errno == ESRCH { return }
      try? await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("Process \(pid) was not reaped")
  }

}

private final class LockedValue<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Value

  init(_ value: Value) {
    storage = value
  }

  var value: Value { lock.withLock { storage } }

  func set(_ value: Value) {
    lock.withLock { storage = value }
  }

  func mutate(_ body: (inout Value) -> Void) {
    lock.withLock { body(&storage) }
  }
}

private func killGroupIfPresent(_ processGroup: pid_t?) {
  guard let processGroup, processGroup > 0 else { return }
  _ = Darwin.kill(-processGroup, SIGKILL)
}

private func waitSynchronously(
  _ semaphore: DispatchSemaphore,
  timeout: DispatchTime
) -> DispatchTimeoutResult {
  semaphore.wait(timeout: timeout)
}

private func waitForSignal(
  _ semaphore: DispatchSemaphore,
  timeout: Duration
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if waitSynchronously(semaphore, timeout: .now()) == .success { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return waitSynchronously(semaphore, timeout: .now()) == .success
}

private func waitForPID(from url: URL, deadline: DispatchTime) -> pid_t? {
  repeat {
    if let pid = readPID(from: url) { return pid }
    Darwin.usleep(1_000)
  } while DispatchTime.now() < deadline
  return readPID(from: url)
}

private func readPID(from url: URL) -> pid_t? {
  guard let text = try? String(contentsOf: url, encoding: .utf8),
        let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
  else { return nil }
  return pid
}
