import XCTest
@testable import DevScopeCore

final class AutomationModelsTests: XCTestCase {
  func testRecordIdentityDoesNotContainCommandSecrets() {
    let id = AutomationRecord.ID(
      source: .launchAgent,
      ownerUID: 501,
      label: "com.example.backup",
      sourcePath: "/Users/example/Library/LaunchAgents/com.example.backup.plist"
    )

    XCTAssertEqual(id.rawValue.count, 64)
    XCTAssertFalse(id.rawValue.contains("example"))
  }

  func testRecordIdentityUsesEveryCanonicalSourceComponent() {
    let base = AutomationRecord.ID(
      source: .launchAgent,
      ownerUID: 501,
      label: "com.example.fixture",
      sourcePath: "/tmp/devscope-fixtures/folder/../fixture.plist"
    )

    XCTAssertEqual(base, AutomationRecord.ID(
      source: .launchAgent,
      ownerUID: 501,
      label: "com.example.fixture",
      sourcePath: "/tmp/devscope-fixtures/fixture.plist"
    ))
    XCTAssertNotEqual(base, AutomationRecord.ID(
      source: .launchDaemon,
      ownerUID: 501,
      label: "com.example.fixture",
      sourcePath: "/tmp/devscope-fixtures/fixture.plist"
    ))
    XCTAssertNotEqual(base, AutomationRecord.ID(
      source: .launchAgent,
      ownerUID: 502,
      label: "com.example.fixture",
      sourcePath: "/tmp/devscope-fixtures/fixture.plist"
    ))
    XCTAssertNotEqual(base, AutomationRecord.ID(
      source: .launchAgent,
      ownerUID: 501,
      label: "com.example.other-fixture",
      sourcePath: "/tmp/devscope-fixtures/fixture.plist"
    ))
    XCTAssertNotEqual(base, AutomationRecord.ID(
      source: .launchAgent,
      ownerUID: 501,
      label: "com.example.fixture",
      sourcePath: "/tmp/devscope-fixtures/other-fixture.plist"
    ))
  }

  func testRecordIdentityDistinguishesDelimiterAmbiguousFieldTuples() {
    let delimiterInPath = AutomationRecord.ID(
      source: .launchAgent,
      ownerUID: 501,
      label: "com.example.fixture",
      sourcePath: "/tmp/first\u{1F}/tmp/second.plist"
    )
    let delimiterInLabel = AutomationRecord.ID(
      source: .launchAgent,
      ownerUID: 501,
      label: "com.example.fixture\u{1F}/tmp/first",
      sourcePath: "/tmp/second.plist"
    )

    XCTAssertNotEqual(delimiterInPath, delimiterInLabel)
  }

  func testSnapshotFactoriesPreserveRecordsAndSourceFailure() {
    let refreshedAt = Date(timeIntervalSince1970: 1_000)
    let record = AutomationRecord(
      id: AutomationRecord.ID(rawValue: "record-id"),
      kind: .launchAgent,
      sourceKind: .launchAgent,
      label: "com.example.synthetic-backup",
      displayName: "Synthetic Backup",
      providerBundleIdentifier: nil,
      ownerUID: 501,
      ownership: .user,
      executable: "/bin/sleep",
      arguments: ["60"],
      environment: [:],
      workingDirectory: nil,
      schedule: AutomationSchedule(triggers: [.runAtLoad], summary: "At load"),
      sourceURL: URL(fileURLWithPath: "/tmp/com.example.synthetic-backup.plist"),
      sourceChecksum: nil,
      enabledState: .enabled,
      loadState: .loaded,
      approvalState: .notApplicable,
      state: .running,
      evidence: [AutomationEvidence(
        strength: .strong,
        source: "synthetic fixture",
        detail: "Exact label and executable"
      )],
      capabilities: [.disableAndStop],
      validationFindings: []
    )

    let healthy = AutomationSourceSnapshot.healthy(
      kind: .launchAgent,
      records: [record],
      refreshedAt: refreshedAt
    )
    let failed = AutomationSourceSnapshot.failed(
      kind: .serviceManagement,
      message: "Synthetic source failure",
      refreshedAt: refreshedAt
    )

    XCTAssertEqual(healthy.records, [record])
    XCTAssertEqual(healthy.health, AutomationSourceHealth(
      kind: .launchAgent,
      state: .healthy,
      message: nil,
      refreshedAt: refreshedAt
    ))
    XCTAssertTrue(failed.records.isEmpty)
    XCTAssertEqual(failed.health.state, .failed)
    XCTAssertEqual(failed.health.message, "Synthetic source failure")
  }
}
