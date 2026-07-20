import XCTest
@testable import DevScopeCore

final class AutomationNotificationPolicyTests: XCTestCase {
  func testDefaultPreferencesStayOffAndOnlyDirectOptInRequestsAuthorization() {
    var policy = AutomationNotificationPolicy(maximumRetainedEventIdentities: 8)

    XCTAssertEqual(policy.preferences, AutomationNotificationPreferences())
    XCTAssertEqual(
      policy.setPreference(.unexpectedExit, isEnabled: false),
      .none
    )
    XCTAssertEqual(
      policy.setPreference(.unexpectedExit, isEnabled: true),
      .requestAuthorization
    )
  }

  func testVerifiedEventsUseSafeContentAndBoundedIdentityDeduplication() {
    var policy = AutomationNotificationPolicy(maximumRetainedEventIdentities: 2)
    XCTAssertEqual(policy.setPreference(.unexpectedExit, isEnabled: true), .requestAuthorization)
    policy.recordAuthorizationResult(granted: true)

    let first = unexpectedExit(label: "first", pid: 41)
    let second = unexpectedExit(label: "second", pid: 42)
    let third = unexpectedExit(label: "third", pid: 43)

    let content = policy.notification(for: first)
    XCTAssertEqual(content?.title, "Automation stopped unexpectedly")
    XCTAssertEqual(content?.body, "A verified user automation exited unexpectedly.")
    XCTAssertNil(policy.notification(for: first), "The same verified event must be deduplicated.")
    XCTAssertNotNil(policy.notification(for: second))
    XCTAssertNotNil(policy.notification(for: third))
    XCTAssertNotNil(
      policy.notification(for: first),
      "The oldest event identity should be eligible again after bounded eviction."
    )

    XCTAssertEqual(
      policy.setPreference(.repeatedFailure, isEnabled: true),
      .none,
      "An already authorized notifier must not prompt for each preference."
    )
  }

  func testAuthorizationRequestIsSingleFlightButCanRetryAfterDenial() {
    var policy = AutomationNotificationPolicy(maximumRetainedEventIdentities: 8)

    XCTAssertEqual(
      policy.setPreference(.unexpectedExit, isEnabled: true),
      .requestAuthorization
    )
    XCTAssertEqual(
      policy.setPreference(.repeatedFailure, isEnabled: true),
      .none,
      "A second opt-in while the first system prompt is pending must not request again."
    )
    policy.recordAuthorizationResult(granted: false)
    XCTAssertEqual(
      policy.setPreference(.crossedLongRunningThreshold, isEnabled: true),
      .requestAuthorization,
      "A later direct opt-in may retry after denial."
    )
  }

  private func unexpectedExit(label: String, pid: Int32) -> AutomationEvent {
    .unexpectedExit(
      recordID: AutomationRecord.ID(
        source: .launchAgent,
        ownerUID: 501,
        label: label,
        sourcePath: "/Users/test/Library/LaunchAgents/\(label).plist"
      ),
      process: ProcessIdentity(
        pid: pid,
        birthToken: ProcessBirthToken(seconds: UInt64(pid), microseconds: 0)
      )
    )
  }
}
