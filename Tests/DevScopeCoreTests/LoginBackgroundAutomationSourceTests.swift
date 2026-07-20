import CryptoKit
import Foundation
import XCTest
@testable import DevScopeCore

final class LoginBackgroundAutomationSourceTests: XCTestCase {
  func testBackgroundDiagnosticPolicyFailsClosedOnMacOS27AndLater() {
    XCTAssertEqual(
      BackgroundTaskDiagnosticPolicy.forOperatingSystemMajorVersion(14),
      .available
    )
    XCTAssertEqual(
      BackgroundTaskDiagnosticPolicy.forOperatingSystemMajorVersion(26),
      .available
    )
    XCTAssertEqual(
      BackgroundTaskDiagnosticPolicy.forOperatingSystemMajorVersion(27),
      .administratorApprovalRequired
    )
    XCTAssertEqual(
      BackgroundTaskDiagnosticPolicy.forOperatingSystemMajorVersion(28),
      .administratorApprovalRequired
    )
  }

  func testBackgroundDiagnosticRequiringAdministratorApprovalNeverInvokesRunner() async {
    let runner = RecordingAutomationCommandRunner()
    let source = BackgroundTaskAutomationSource(
      runner: runner,
      diagnosticPolicy: .administratorApprovalRequired,
      now: { Date(timeIntervalSince1970: 3_000) }
    )

    let first = await source.snapshot()
    let second = await source.snapshot()
    let fingerprint = await source.currentRawOutputHash()

    XCTAssertTrue(first.records.isEmpty)
    XCTAssertEqual(first, second)
    XCTAssertEqual(first.health.kind, .serviceManagement)
    XCTAssertEqual(first.health.state, .permissionRequired)
    XCTAssertEqual(
      first.health.message,
      "macOS 27 or later requires administrator approval for this Background Items diagnostic. "
        + "Review Background Items in System Settings; DevScope did not run the diagnostic."
    )
    XCTAssertEqual(first.health.refreshedAt, Date(timeIntervalSince1970: 3_000))
    XCTAssertNil(fingerprint)
    XCTAssertTrue(runner.invocations.isEmpty)
  }

  func testLegacyLoginItemSuccessNormalizesCurrentUserEvidence() async {
    let adapter = StubLegacyLoginItemAdapter(result: .success([
      LegacyLoginItemDescriptor(
        name: "Synthetic Login Fixture",
        path: "/tmp/devscope-fixtures/Synthetic Login Fixture.app",
        isHidden: false
      ),
    ]))
    let source = LegacyLoginItemAutomationSource(
      adapter: adapter,
      currentUID: 501,
      now: { Date(timeIntervalSince1970: 1_000) }
    )

    let snapshot = await source.snapshot()

    XCTAssertEqual(snapshot.health.state, .healthy)
    XCTAssertEqual(snapshot.records.count, 1)
    XCTAssertEqual(snapshot.records[0].sourceKind, .legacyLoginItem)
    XCTAssertEqual(snapshot.records[0].ownerUID, 501)
    XCTAssertEqual(snapshot.records[0].ownership, .user)
    XCTAssertEqual(snapshot.records[0].schedule.triggers, [.atLogin])
    XCTAssertEqual(snapshot.records[0].capabilities, [.exportRecord])
    let recoveryData = try! LegacyLoginItemRecoveryDocument.encode(
      selectedRecord: snapshot.records[0],
      descriptor: LegacyLoginItemDescriptor(
        name: "Synthetic Login Fixture",
        path: "/tmp/devscope-fixtures/Synthetic Login Fixture.app",
        isHidden: false
      ),
      currentUID: 501
    )
    XCTAssertEqual(snapshot.records[0].sourceChecksum, sha256(recoveryData))
  }

  func testLegacyLoginItemChecksumBindsHiddenStateAndCanonicalPath() async {
    let visible = await legacySnapshot(LegacyLoginItemDescriptor(
      name: "Synthetic Login Fixture",
      path: "/tmp/devscope-fixtures/Synthetic Login Fixture.app",
      isHidden: false
    ))
    let hidden = await legacySnapshot(LegacyLoginItemDescriptor(
      name: "Synthetic Login Fixture",
      path: "/tmp/devscope-fixtures/Synthetic Login Fixture.app",
      isHidden: true
    ))
    let changedPath = await legacySnapshot(LegacyLoginItemDescriptor(
      name: "Synthetic Login Fixture",
      path: "/tmp/devscope-fixtures/Changed Fixture.app",
      isHidden: false
    ))

    XCTAssertNotNil(visible.sourceChecksum)
    XCTAssertNotEqual(visible.sourceChecksum, hidden.sourceChecksum)
    XCTAssertNotEqual(visible.sourceChecksum, changedPath.sourceChecksum)
  }

  func testLegacyLoginItemDenialRequiresExplicitUserActionWithoutLeakingDetails() async {
    let source = LegacyLoginItemAutomationSource(
      adapter: StubLegacyLoginItemAdapter(result: .failure(.permissionDenied)),
      currentUID: 501,
      now: { Date(timeIntervalSince1970: 1_000) }
    )

    let snapshot = await source.snapshot()

    XCTAssertTrue(snapshot.records.isEmpty)
    XCTAssertEqual(snapshot.health.state, .permissionRequired)
    XCTAssertEqual(
      snapshot.health.message,
      "Allow DevScope to inspect current-user login items in System Settings."
    )
  }

  func testBackgroundDiagnosticUsesExactObservedBoundaryFieldsAndFingerprint() async {
    let output = Data("""
      Background Task Management diagnostic
        Items: 1
        #1:
          Name: Synthetic Backup Fixture
          Identifier: com.example.backup
          URL: file:///tmp/devscope-fixtures/background-backup.plist
          Bundle Identifier: com.example.devscope-fixture-owner
          Executable Path: /bin/sleep
          Disposition: enabled, allowed
          Parent Identifier: com.example.devscope-fixture-owner
          Team Identifier: SYNTHETIC1
          Developer Name: Synthetic Developer
          Type: agent
      """.utf8)
    let runner = RecordingAutomationCommandRunner(result: .success(
      AutomationCommandResult(status: 0, standardOutput: output, standardError: Data())
    ))
    let source = BackgroundTaskAutomationSource(
      runner: runner,
      diagnosticPolicy: .available,
      now: { Date(timeIntervalSince1970: 2_000) }
    )

    let snapshot = await source.snapshot()
    let fingerprint = await source.currentRawOutputHash()

    XCTAssertEqual(
      runner.invocations,
      [AutomationCommand(executable: "/usr/bin/sfltool", arguments: ["dumpbtm"])]
    )
    XCTAssertEqual(snapshot.health.state, .healthy)
    XCTAssertEqual(snapshot.records.count, 1)
    XCTAssertEqual(snapshot.records[0].label, "com.example.backup")
    XCTAssertEqual(snapshot.records[0].providerBundleIdentifier, "com.example.devscope-fixture-owner")
    XCTAssertEqual(snapshot.records[0].executable, "/bin/sleep")
    XCTAssertEqual(snapshot.records[0].state, .unresolved)
    XCTAssertEqual(snapshot.records[0].capabilities, [.exportRecord])
    XCTAssertEqual(snapshot.records[0].sourceChecksum, fingerprint)
    XCTAssertEqual(
      fingerprint,
      SHA256.hash(data: output).map { String(format: "%02x", $0) }.joined()
    )
  }

  func testBackgroundDiagnosticFormatDriftFailsWithoutGuessingOrLeakingRawOutput() async {
    let privatePath = "/Users/example/Library/secret-token-value"
    let output = Data("""
      Background Task Management changed format
      Identifier: com.example.looks-valid
      Executable Path: \(privatePath)
      """.utf8)
    let runner = RecordingAutomationCommandRunner(result: .success(
      AutomationCommandResult(status: 0, standardOutput: output, standardError: Data())
    ))
    let source = BackgroundTaskAutomationSource(runner: runner, diagnosticPolicy: .available)

    let snapshot = await source.snapshot()
    let fingerprint = await source.currentRawOutputHash()

    XCTAssertTrue(snapshot.records.isEmpty)
    XCTAssertEqual(snapshot.health.state, .failed)
    XCTAssertFalse(snapshot.health.message?.contains(privatePath) ?? true)
    XCTAssertEqual(fingerprint?.count, 64)
  }

  func testBackgroundDiagnosticRejectsUnobservedExecutableAndParentURLAliases() async {
    let output = Data("""
      #1:
        Name: Alias Only
        Identifier: com.example.alias-only
        Executable URL: file:///tmp/devscope-fixtures/alias-helper
        Parent URL: file:///tmp/devscope-fixtures/Alias.app
      """.utf8)
    let runner = RecordingAutomationCommandRunner(result: .success(
      AutomationCommandResult(status: 0, standardOutput: output, standardError: Data())
    ))
    let source = BackgroundTaskAutomationSource(runner: runner, diagnosticPolicy: .available)

    let snapshot = await source.snapshot()

    XCTAssertTrue(snapshot.records.isEmpty)
    XCTAssertEqual(snapshot.health.state, .failed)
    XCTAssertEqual(
      snapshot.health.message,
      "Some Background Task Management records were unresolved."
    )
  }

  func testBackgroundDiagnosticKeepsUsableRecordsAndReportsUnresolvedBoundedRecords() async {
    let output = Data("""
      #1:
        Name: Bundle Identity
        Bundle Identifier: com.example.bundle-identity
        Unknown Secret: /Users/example/private-value
      #2:
        Name: Display Name Is Not Identity
        Developer Name: Synthetic Developer
        Type: agent
        Disposition: allowed
      """.utf8)
    let runner = RecordingAutomationCommandRunner(result: .success(
      AutomationCommandResult(status: 0, standardOutput: output, standardError: Data())
    ))
    let source = BackgroundTaskAutomationSource(runner: runner, diagnosticPolicy: .available)

    let snapshot = await source.snapshot()

    XCTAssertEqual(snapshot.records.map(\.label), ["com.example.bundle-identity"])
    XCTAssertEqual(snapshot.health.state, .partial)
    XCTAssertEqual(
      snapshot.health.message,
      "Some Background Task Management records were unresolved."
    )
    XCTAssertFalse(snapshot.records[0].evidence.contains {
      $0.detail.contains("private-value")
    })
  }

  func testBackgroundDiagnosticBoundaryRequiresASCIIDigits() async {
    let output = Data("""
      #١:
        Identifier: com.example.unicode-boundary
        Executable Path: /bin/sleep
      """.utf8)
    let runner = RecordingAutomationCommandRunner(result: .success(
      AutomationCommandResult(status: 0, standardOutput: output, standardError: Data())
    ))
    let source = BackgroundTaskAutomationSource(runner: runner, diagnosticPolicy: .available)

    let snapshot = await source.snapshot()

    XCTAssertTrue(snapshot.records.isEmpty)
    XCTAssertEqual(snapshot.health.state, .failed)
    XCTAssertEqual(
      snapshot.health.message,
      "Background Task Management record boundaries were not recognized."
    )
  }

  func testBackgroundDiagnosticBoundaryDriftQuarantinesFollowingFields() async {
    let privatePath = "/Users/example/private-drift-value"
    let output = Data("""
      #1:
        Identifier: com.example.valid-before-drift
        Executable Path: /bin/sleep
      #١:
        Bundle Identifier: com.example.must-not-augment-first
      #malformed:
        Identifier: com.example.must-not-replace-first
        Executable Path: \(privatePath)
      """.utf8)
    let runner = RecordingAutomationCommandRunner(result: .success(
      AutomationCommandResult(status: 0, standardOutput: output, standardError: Data())
    ))
    let source = BackgroundTaskAutomationSource(runner: runner, diagnosticPolicy: .available)

    let snapshot = await source.snapshot()

    XCTAssertEqual(snapshot.records.map(\.label), ["com.example.valid-before-drift"])
    let record = snapshot.records.first
    XCTAssertEqual(record?.executable, "/bin/sleep")
    XCTAssertNil(record?.providerBundleIdentifier)
    XCTAssertEqual(snapshot.health.state, .partial)
    XCTAssertFalse(snapshot.health.message?.contains(privatePath) ?? true)
    XCTAssertFalse(snapshot.records.contains { record in
      record.label.contains("must-not")
        || record.executable?.contains("private-drift-value") == true
        || record.evidence.contains { $0.detail.contains("must-not") }
    })
  }

  func testBackgroundDiagnosticExactBoundaryRecoversAfterDriftQuarantine() async {
    let output = Data("""
      #1:
        Identifier: com.example.before-drift
        Executable Path: /bin/sleep
      #٢:
        Identifier: com.example.quarantined-unicode
        Executable Path: /bin/date
      #not-a-number:
        Bundle Identifier: com.example.quarantined-malformed
      #2:
        Identifier: com.example.after-drift
        Executable Path: /usr/bin/true
      """.utf8)
    let runner = RecordingAutomationCommandRunner(result: .success(
      AutomationCommandResult(status: 0, standardOutput: output, standardError: Data())
    ))
    let source = BackgroundTaskAutomationSource(runner: runner, diagnosticPolicy: .available)

    let snapshot = await source.snapshot()

    XCTAssertEqual(
      snapshot.records.map(\.label),
      ["com.example.before-drift", "com.example.after-drift"]
    )
    XCTAssertEqual(snapshot.records.map(\.executable), ["/bin/sleep", "/usr/bin/true"])
    XCTAssertEqual(snapshot.health.state, .partial)
    XCTAssertFalse(snapshot.records.contains { record in
      record.label.contains("quarantined")
        || record.providerBundleIdentifier?.contains("quarantined") == true
    })
  }

  func testLegacyProductionAdapterUsesOnlyFixedArgumentFreeProgramText() async throws {
    let privatePath = "/tmp/devscope-fixtures/User Controlled.app"
    let output = try JSONSerialization.data(withJSONObject: [[
      "name": "User Controlled",
      "path": privatePath,
      "hidden": false,
    ]])
    let runner = RecordingAutomationCommandRunner(result: .success(
      AutomationCommandResult(status: 0, standardOutput: output, standardError: Data())
    ))
    let adapter = OSACommandLegacyLoginItemAdapter(runner: runner)

    let items = try await adapter.currentUserLoginItems()

    XCTAssertEqual(items.map(\.path), [privatePath])
    XCTAssertEqual(runner.invocations.count, 1)
    XCTAssertEqual(runner.invocations[0].executable, "/usr/bin/osascript")
    XCTAssertEqual(Array(runner.invocations[0].arguments.prefix(3)), ["-l", "JavaScript", "-e"])
    XCTAssertEqual(runner.invocations[0].arguments.count, 4)
    XCTAssertFalse(runner.invocations[0].arguments[3].contains(privatePath))
  }

  func testBackgroundCommandAndEncodingFailuresRemainGenericAndSecretFree() async {
    let privateDetail = "/Users/example/private-token"
    let failedRunner = RecordingAutomationCommandRunner(result: .success(
      AutomationCommandResult(
        status: 1,
        standardOutput: Data(privateDetail.utf8),
        standardError: Data(privateDetail.utf8)
      )
    ))
    let invalidUTF8Runner = RecordingAutomationCommandRunner(result: .success(
      AutomationCommandResult(
        status: 0,
        standardOutput: Data([0xFF, 0xFE]),
        standardError: Data(privateDetail.utf8)
      )
    ))

    let failedSource = BackgroundTaskAutomationSource(
      runner: failedRunner,
      diagnosticPolicy: .available
    )
    let invalidUTF8Source = BackgroundTaskAutomationSource(
      runner: invalidUTF8Runner,
      diagnosticPolicy: .available
    )
    let failed = await failedSource.snapshot()
    let invalidUTF8 = await invalidUTF8Source.snapshot()
    let failedFingerprint = await failedSource.currentRawOutputHash()

    for snapshot in [failed, invalidUTF8] {
      XCTAssertTrue(snapshot.records.isEmpty)
      XCTAssertEqual(snapshot.health.state, .failed)
      XCTAssertFalse(snapshot.health.message?.contains(privateDetail) ?? true)
    }
    XCTAssertEqual(
      failedFingerprint,
      SHA256.hash(data: Data(privateDetail.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    )
  }

  func testLegacyProductionAdapterMapsAppleEventsFailureToPermissionDenial() async {
    let runner = RecordingAutomationCommandRunner(result: .success(
      AutomationCommandResult(
        status: 1,
        standardOutput: Data(),
        standardError: Data("private Apple Events detail".utf8)
      )
    ))
    let adapter = OSACommandLegacyLoginItemAdapter(runner: runner)

    do {
      _ = try await adapter.currentUserLoginItems()
      XCTFail("Expected permission denial")
    } catch {
      XCTAssertEqual(error as? LegacyLoginItemAdapterError, .permissionDenied)
    }
  }

  func testBackgroundDiagnosticConflictingRecognizedFieldsAreUnresolved() async {
    let output = Data("""
      #1:
        Identifier: com.example.first
        Identifier: com.example.second
        Executable Path: /bin/sleep
      """.utf8)
    let runner = RecordingAutomationCommandRunner(result: .success(
      AutomationCommandResult(status: 0, standardOutput: output, standardError: Data())
    ))
    let source = BackgroundTaskAutomationSource(runner: runner, diagnosticPolicy: .available)

    let snapshot = await source.snapshot()

    XCTAssertTrue(snapshot.records.isEmpty)
    XCTAssertEqual(snapshot.health.state, .failed)
    XCTAssertEqual(
      snapshot.health.message,
      "Some Background Task Management records were unresolved."
    )
  }
}

private func legacySnapshot(
  _ descriptor: LegacyLoginItemDescriptor
) async -> AutomationRecord {
  let source = LegacyLoginItemAutomationSource(
    adapter: StubLegacyLoginItemAdapter(result: .success([descriptor])),
    currentUID: 501,
    now: { Date(timeIntervalSince1970: 1_000) }
  )
  let snapshot = await source.snapshot()
  return try! XCTUnwrap(snapshot.records.first)
}

private func sha256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private struct StubLegacyLoginItemAdapter: LegacyLoginItemListing {
  let result: Result<[LegacyLoginItemDescriptor], LegacyLoginItemAdapterError>

  func currentUserLoginItems() async throws -> [LegacyLoginItemDescriptor] {
    try result.get()
  }
}
