import XCTest
@testable import DevScopeCore

final class AutomationCapabilityPolicyTests: XCTestCase {
  func testApprovedPathAllowsVerifiedMissingChildButRejectsPrefixEscapeAndSymlink() {
    let root = URL(fileURLWithPath: "/Users/test/Library/LaunchAgents")
    let destination = root.appending(path: "new.plist")

    XCTAssertTrue(AutomationPathAuthorization.isApprovedDestination(
      destination,
      approvedRoot: root,
      destinationExists: false,
      verifiedMetadataURL: root,
      metadataIsSymbolicLink: false
    ))
    XCTAssertFalse(AutomationPathAuthorization.isApprovedDestination(
      URL(fileURLWithPath: "/Users/test/Library/LaunchAgents-escape/new.plist"),
      approvedRoot: root,
      destinationExists: false,
      verifiedMetadataURL: URL(fileURLWithPath: "/Users/test/Library/LaunchAgents-escape"),
      metadataIsSymbolicLink: false
    ))
    XCTAssertFalse(AutomationPathAuthorization.isApprovedDestination(
      destination,
      approvedRoot: root,
      destinationExists: true,
      verifiedMetadataURL: destination,
      metadataIsSymbolicLink: true
    ))
  }

  func testCurrentUserLaunchAgentReceivesFullCapabilities() {
    let decision = AutomationCapabilityPolicy.decision(
      for: Fixtures.userAgent,
      context: .fixture(currentUID: 501, canonicalPathIsApproved: true, ownerUID: 501)
    )

    XCTAssertEqual(decision.capabilities, Set(AutomationCapability.allCases))
    XCTAssertNil(decision.reason)
  }

  func testLaunchAgentWithUnresolvedRuntimeStateIsInspectionOnly() {
    let unresolved = copyRecord(
      Fixtures.userAgent,
      ownership: .user,
      enabledState: .unknown,
      loadState: .unknown
    )
    let decision = AutomationCapabilityPolicy.decision(
      for: unresolved,
      context: .fixture(currentUID: 501, canonicalPathIsApproved: true, ownerUID: 501)
    )

    XCTAssertEqual(decision.capabilities, [.exportRecord])
    XCTAssertEqual(
      decision.reason,
      "DevScope could not verify this LaunchAgent's enabled and loaded state, so management is unavailable."
    )
  }

  func testSymlinkEscapeIsReadOnly() {
    let decision = AutomationCapabilityPolicy.decision(
      for: Fixtures.userAgent,
      context: .fixture(
        currentUID: 501,
        canonicalPathIsApproved: false,
        ownerUID: 501,
        isSymlink: true
      )
    )

    XCTAssertEqual(decision.capabilities, [.exportRecord])
    XCTAssertEqual(decision.reason, "The source resolves outside your LaunchAgents folder.")
  }

  func testManagedAutomationHasExactInspectionOnlyReason() {
    let decision = AutomationCapabilityPolicy.decision(
      for: copyRecord(Fixtures.userAgent, ownership: .managed),
      context: .fixture(
        currentUID: 501,
        canonicalPathIsApproved: true,
        ownerUID: 501,
        isManaged: true
      )
    )

    XCTAssertEqual(decision.capabilities, [.exportRecord])
    XCTAssertEqual(decision.reason, "This automation is managed by your organization.")
  }

  func testModernCrossAppBackgroundItemIsInspectionOnly() {
    let decision = AutomationCapabilityPolicy.decision(
      for: Fixtures.backgroundCopyOfUserAgent,
      context: .fixture(currentUID: 501, canonicalPathIsApproved: true, ownerUID: 501)
    )

    XCTAssertEqual(decision.capabilities, [.exportRecord])
    XCTAssertEqual(
      decision.reason,
      "Modern background items must be managed by their owning app or System Settings."
    )
  }

  func testWrongOwnerAndSymbolicLinkHaveDistinctReasons() {
    let wrongOwner = AutomationCapabilityPolicy.decision(
      for: Fixtures.userAgent,
      context: .fixture(currentUID: 501, canonicalPathIsApproved: true, ownerUID: 502)
    )
    let symbolicLink = AutomationCapabilityPolicy.decision(
      for: Fixtures.userAgent,
      context: .fixture(
        currentUID: 501,
        canonicalPathIsApproved: true,
        ownerUID: 501,
        isSymlink: true
      )
    )

    XCTAssertEqual(wrongOwner.reason, "The automation source is not owned by the current user.")
    XCTAssertEqual(symbolicLink.reason, "Symbolic-link automation sources are inspection only.")
  }

  func testCronExposesOnlyInstalledCapabilitiesWithSourceSpecificReason() {
    let cronRecord = automationRecord(
      copying: Fixtures.userAgent,
      kind: .cron,
      sourceKind: .crontab,
      sourceURL: nil
    )
    let decision = AutomationCapabilityPolicy.decision(
      for: cronRecord,
      context: .fixture(
        currentUID: 501,
        canonicalPathIsApproved: true,
        ownerUID: 501,
        implementedCapabilities: [.exportRecord]
      )
    )

    XCTAssertEqual(decision.capabilities, [.exportRecord])
    XCTAssertEqual(
      decision.reason,
      "Current-user crontab management is unavailable until recoverable source access is installed."
    )
  }

  func testExportAvailabilityIsGatedConsistentlyAndSurvivesPartialMutationAdapters() {
    let protected = AutomationCapabilityPolicy.decision(
      for: copyRecord(Fixtures.userAgent, ownership: .managed),
      context: .fixture(
        currentUID: 501,
        canonicalPathIsApproved: true,
        ownerUID: 501,
        isManaged: true,
        implementedCapabilities: []
      )
    )
    XCTAssertFalse(protected.capabilities.contains(.exportRecord))

    let partialUser = AutomationCapabilityPolicy.decision(
      for: Fixtures.userAgent,
      context: .fixture(
        currentUID: 501,
        canonicalPathIsApproved: true,
        ownerUID: 501,
        implementedCapabilities: [.disable, .exportRecord]
      )
    )
    XCTAssertEqual(partialUser.capabilities, [.disable, .exportRecord])
  }
}

private func copyRecord(
  _ record: AutomationRecord,
  ownership: AutomationOwnership,
  enabledState: AutomationEnabledState? = nil,
  loadState: AutomationLoadState? = nil
) -> AutomationRecord {
  AutomationRecord(
    id: record.id,
    kind: record.kind,
    sourceKind: record.sourceKind,
    label: record.label,
    displayName: record.displayName,
    providerBundleIdentifier: record.providerBundleIdentifier,
    ownerUID: record.ownerUID,
    ownership: ownership,
    executable: record.executable,
    arguments: record.arguments,
    commandSignature: record.commandSignature,
    environment: record.environment,
    workingDirectory: record.workingDirectory,
    schedule: record.schedule,
    sourceURL: record.sourceURL,
    sourceChecksum: record.sourceChecksum,
    enabledState: enabledState ?? record.enabledState,
    loadState: loadState ?? record.loadState,
    approvalState: record.approvalState,
    state: record.state,
    evidence: record.evidence,
    capabilities: record.capabilities,
    validationFindings: record.validationFindings
  )
}

private func automationRecord(
  copying record: AutomationRecord,
  kind: AutomationKind,
  sourceKind: AutomationSourceKind,
  sourceURL: URL?
) -> AutomationRecord {
  AutomationRecord(
    id: record.id,
    kind: kind,
    sourceKind: sourceKind,
    label: record.label,
    displayName: record.displayName,
    providerBundleIdentifier: record.providerBundleIdentifier,
    ownerUID: record.ownerUID,
    ownership: record.ownership,
    executable: record.executable,
    arguments: record.arguments,
    commandSignature: record.commandSignature,
    environment: record.environment,
    workingDirectory: record.workingDirectory,
    schedule: record.schedule,
    sourceURL: sourceURL,
    sourceChecksum: record.sourceChecksum,
    enabledState: record.enabledState,
    loadState: record.loadState,
    approvalState: record.approvalState,
    state: record.state,
    evidence: record.evidence,
    capabilities: record.capabilities,
    validationFindings: record.validationFindings
  )
}
