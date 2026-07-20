import DevScopeCore
import XCTest
@testable import DevScope

@MainActor
final class AutomationNotifierTests: XCTestCase {
  func testDirectOptInRequestsOnceAndDuplicateVerifiedEventDeliversOnce() async {
    let center = RecordingNotificationCenter(granted: true)
    let notifier = AutomationNotifier(notificationCenter: center)
    let event = AutomationEvent.crossedLongRunningThreshold(
      process: ProcessIdentity(
        pid: 7_001,
        birthToken: ProcessBirthToken(seconds: 123, microseconds: 4)
      ),
      recordID: AutomationRecord.ID(rawValue: "notification-record")
    )

    await notifier.consume([event])
    let deliveryCountBeforeOptIn = await center.deliveryCount()
    XCTAssertEqual(deliveryCountBeforeOptIn, 0)

    await notifier.setPreference(.crossedLongRunningThreshold, isEnabled: true)
    await notifier.setPreference(.unexpectedExit, isEnabled: true)
    await notifier.consume([event, event])

    let authorizationRequests = await center.authorizationRequestCount()
    let deliveryCount = await center.deliveryCount()
    let lastDelivery = await center.lastDelivery()
    XCTAssertEqual(authorizationRequests, 1)
    XCTAssertEqual(deliveryCount, 1)
    let delivered = try! XCTUnwrap(lastDelivery)
    XCTAssertEqual(delivered.title, "Long-running process detected")
    XCTAssertFalse(delivered.body.contains("7_001"))
    XCTAssertFalse(delivered.body.contains("notification-record"))
  }

  func testDisablingPreferenceNeverRequestsAuthorizationOrDelivers() async {
    let center = RecordingNotificationCenter(granted: true)
    let notifier = AutomationNotifier(notificationCenter: center)
    await notifier.setPreference(.repeatedFailure, isEnabled: false)
    await notifier.consume([.repeatedFailure(
      recordID: AutomationRecord.ID(rawValue: "private-record"),
      observedExitCount: 3
    )])

    let authorizationRequests = await center.authorizationRequestCount()
    let deliveryCount = await center.deliveryCount()
    XCTAssertEqual(authorizationRequests, 0)
    XCTAssertEqual(deliveryCount, 0)
  }

  func testDeniedAuthorizationPublishesBlockedDeliveryWithoutClearingOptIn() async {
    let center = RecordingNotificationCenter(granted: false)
    let notifier = AutomationNotifier(notificationCenter: center)

    await notifier.synchronize(AutomationNotificationPreferences(
      crossedLongRunningThreshold: true,
      unexpectedExit: true,
      repeatedFailure: true
    ))

    XCTAssertEqual(notifier.deliveryState, .denied)
    XCTAssertEqual(notifier.preferences, AutomationNotificationPreferences(
      crossedLongRunningThreshold: true,
      unexpectedExit: true,
      repeatedFailure: true
    ))
    let requests = await center.authorizationRequestCount()
    XCTAssertEqual(requests, 1)
  }

  func testAuthorizationRequestErrorIsNotReportedAsUserDenial() async {
    let notifier = AutomationNotifier(notificationCenter: FailingNotificationCenter())

    await notifier.setPreference(.unexpectedExit, isEnabled: true)

    XCTAssertEqual(notifier.deliveryState, .authorizationFailed)
    XCTAssertTrue(notifier.preferences.unexpectedExit)
  }

  func testDeliveryRetriesOnceInsideTheProductionConsumePathAndDeduplicatesSuccess() async {
    let center = FlakyNotificationCenter(failingAttempts: [1])
    let notifier = AutomationNotifier(
      notificationCenter: center,
      retryDelay: .zero,
      sleep: { _ in }
    )
    let event = AutomationEvent.repeatedFailure(
      recordID: AutomationRecord.ID(rawValue: "retryable-record"),
      observedExitCount: 3
    )
    await notifier.setPreference(.repeatedFailure, isEnabled: true)

    await notifier.consume([event])
    XCTAssertEqual(notifier.deliveryState, .enabled)

    await notifier.consume([event])
    XCTAssertEqual(notifier.deliveryState, .enabled)
    let attempts = await center.deliveryAttempts()
    XCTAssertEqual(attempts, 2)
  }

  func testOneFailureKeepsTheWholeDeliveryBatchVisibleEvenIfALaterEventSucceeds() async {
    let center = FlakyNotificationCenter(failingAttempts: [1, 2])
    let notifier = AutomationNotifier(
      notificationCenter: center,
      retryDelay: .zero,
      sleep: { _ in }
    )
    await notifier.setPreference(.repeatedFailure, isEnabled: true)

    await notifier.consume([
      .repeatedFailure(
        recordID: AutomationRecord.ID(rawValue: "failed-record"),
        observedExitCount: 3
      ),
      .repeatedFailure(
        recordID: AutomationRecord.ID(rawValue: "successful-record"),
        observedExitCount: 3
      ),
    ])

    XCTAssertEqual(notifier.deliveryState, .deliveryFailed)
    let attempts = await center.deliveryAttempts()
    XCTAssertEqual(attempts, 3)
  }

  func testConcurrentConsumeCallsSerializeAndCannotHideAnExhaustedRetry() async {
    let center = FlakyNotificationCenter(failingAttempts: [1, 2])
    let sleeper = GatedRetrySleeper()
    let notifier = AutomationNotifier(
      notificationCenter: center,
      retryDelay: .seconds(2),
      sleep: { _ in try await sleeper.sleep() }
    )
    await notifier.setPreference(.repeatedFailure, isEnabled: true)
    let firstEvent = AutomationEvent.repeatedFailure(
      recordID: AutomationRecord.ID(rawValue: "first-concurrent-record"),
      observedExitCount: 3
    )
    let secondEvent = AutomationEvent.repeatedFailure(
      recordID: AutomationRecord.ID(rawValue: "second-concurrent-record"),
      observedExitCount: 3
    )

    let first = Task { await notifier.consume([firstEvent]) }
    await sleeper.waitUntilCalled()
    let second = Task { await notifier.consume([secondEvent]) }

    let deadline = ContinuousClock.now + .milliseconds(100)
    while await center.deliveryAttempts() == 1, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(1))
    }
    let attemptsWhileFirstRetryWasSleeping = await center.deliveryAttempts()
    XCTAssertEqual(attemptsWhileFirstRetryWasSleeping, 1)

    await sleeper.releaseAll()
    await first.value
    await second.value

    XCTAssertEqual(notifier.deliveryState, .deliveryFailed)
    let finalAttempts = await center.deliveryAttempts()
    XCTAssertEqual(finalAttempts, 3)
  }
}

private struct FailingNotificationCenter: AutomationNotificationCenterClient {
  struct Failure: Error {}
  func requestAuthorization() async throws -> Bool { throw Failure() }
  func deliver(_ content: AutomationNotificationContent) async throws {}
}

private actor RecordingNotificationCenter: AutomationNotificationCenterClient {
  private let granted: Bool
  private var requestCount = 0
  private var deliveries: [AutomationNotificationContent] = []

  init(granted: Bool) {
    self.granted = granted
  }

  func requestAuthorization() async throws -> Bool {
    requestCount += 1
    return granted
  }

  func deliver(_ content: AutomationNotificationContent) async throws {
    deliveries.append(content)
  }

  func authorizationRequestCount() -> Int { requestCount }
  func deliveryCount() -> Int { deliveries.count }
  func lastDelivery() -> AutomationNotificationContent? { deliveries.last }
}

private actor FlakyNotificationCenter: AutomationNotificationCenterClient {
  struct Failure: Error {}
  private let failingAttempts: Set<Int>
  private var attempts = 0

  init(failingAttempts: Set<Int>) {
    self.failingAttempts = failingAttempts
  }

  func requestAuthorization() async throws -> Bool { true }

  func deliver(_ content: AutomationNotificationContent) async throws {
    attempts += 1
    if failingAttempts.contains(attempts) { throw Failure() }
  }

  func deliveryAttempts() -> Int { attempts }
}

private actor GatedRetrySleeper {
  private var wasCalled = false
  private var callWaiters: [CheckedContinuation<Void, Never>] = []
  private var sleepWaiters: [CheckedContinuation<Void, Never>] = []

  func sleep() async throws {
    wasCalled = true
    let waiters = callWaiters
    callWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    await withCheckedContinuation { sleepWaiters.append($0) }
  }

  func waitUntilCalled() async {
    guard !wasCalled else { return }
    await withCheckedContinuation { callWaiters.append($0) }
  }

  func releaseAll() {
    let waiters = sleepWaiters
    sleepWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }
}
