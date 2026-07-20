import CryptoKit
import XCTest
@testable import DevScopeCore

final class AutomationManagerTests: XCTestCase {
  func testStartNowVerifiesAStrongFreshProcessLinkWithoutInventingInventoryRuntimeState() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let checksum = sha256(sourceData)
    let record = copyRecord(
      Fixtures.userAgent,
      sourceChecksum: checksum,
      loadState: .loaded,
      state: .idle
    )
    let process = classifiedAutomationProcess(
      pid: 62_001,
      birth: ProcessBirthToken(seconds: 20_000, microseconds: 1)
    )
    let snapshot = AutomationInventorySnapshot(
      generation: 8,
      records: [record],
      health: [
        .launchAgent: AutomationSourceHealth(
          kind: .launchAgent,
          state: .healthy,
          message: nil,
          refreshedAt: Date(timeIntervalSince1970: 20_000)
        ),
      ],
      refreshedAt: Date(timeIntervalSince1970: 20_000)
    )
    let manager = makeManager(
      fileSystem: InMemoryAutomationFileSystem(files: [sourceURL: sourceData]),
      executor: RecordingAutomationMutationExecutor(results: [
        .success(AutomationExecutorResult(
          postconditions: [.targetResolved, .currentRunStarted],
          evidence: ["fixture started"]
        )),
      ]),
      refresh: { snapshot },
      refreshProcesses: { [process.process] }
    )

    let result = await manager.perform(
      .startNow,
      record: record,
      expectedChecksum: checksum,
      linkedProcesses: []
    )

    XCTAssertEqual(result.status, .succeeded)
    XCTAssertTrue(result.verificationEvidence.contains(
      "Fresh process truth confirms a strong link to the requested automation."
    ))
  }

  func testStaleChecksumBlocksBeforeBackupOrApply() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = Data("original source".utf8)
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let executor = RecordingAutomationMutationExecutor()
    let manager = makeManager(fileSystem: fileSystem, executor: executor)

    let result = await manager.perform(
      .disable,
      record: Fixtures.userAgent,
      expectedChecksum: "stale-checksum",
      linkedProcesses: []
    )

    XCTAssertEqual(result.status, .rejected("The automation source changed since it was inspected."))
    XCTAssertEqual(fileSystem.recordedOperations, [])
    let invocationCount = await executor.invocationCount()
    XCTAssertEqual(invocationCount, 0)
  }

  func testWrongOwnerBlocksBeforeBackupOrApply() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = Data("original source".utf8)
    let fileSystem = InMemoryAutomationFileSystem(
      files: [sourceURL: sourceData],
      metadata: [
        sourceURL: AutomationFileMetadata(
          canonicalURL: sourceURL,
          ownerUID: 502,
          isSymbolicLink: false,
          modificationDate: Date(timeIntervalSince1970: 1_000),
          resourceIdentifier: "wrong-owner-source"
        ),
      ]
    )
    let executor = RecordingAutomationMutationExecutor()
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      context: .fixture(currentUID: 501, canonicalPathIsApproved: true, ownerUID: 502)
    )

    let result = await manager.perform(
      .disable,
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    XCTAssertEqual(result.status, .rejected("The automation source is not owned by the current user."))
    XCTAssertEqual(fileSystem.recordedOperations, [])
    let invocationCount = await executor.invocationCount()
    XCTAssertEqual(invocationCount, 0)
  }

  func testSuccessfulDisableCreatesOwnerOnlyBackupAndVerifiesRefreshedState() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let checksum = sha256(sourceData)
    let disabledRecord = copyRecord(
      Fixtures.userAgent,
      sourceChecksum: checksum,
      enabledState: .disabled,
      state: .disabled
    )
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let executor = RecordingAutomationMutationExecutor(results: [
      .success(AutomationExecutorResult(
        postconditions: [.futureLaunchesDisabled],
        evidence: ["launchctl confirmed disabled"]
      )),
    ])
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      refresh: { snapshot(records: [disabledRecord]) }
    )

    let result = await manager.perform(
      .disable,
      record: Fixtures.userAgent,
      expectedChecksum: checksum,
      linkedProcesses: []
    )

    XCTAssertEqual(result.status, .succeeded)
    XCTAssertNotNil(result.backup)
    XCTAssertEqual(result.rollback, .notNeeded)
    XCTAssertEqual(result.verificationEvidence, [
      "Executor evidence redacted.",
      "Refreshed inventory confirms future launches are disabled.",
    ])
    XCTAssertTrue(fileSystem.recordedOperations.contains {
      if case .createDirectory(_, permissions: 0o700) = $0 { return true }
      return false
    })
    XCTAssertTrue(fileSystem.recordedOperations.contains {
      if case .writeTemporary(_, permissions: 0o600) = $0 { return true }
      return false
    })
  }

  func testBackupPostWriteCanonicalMetadataMustVerifyBeforePublication() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let backupURL = URL(fileURLWithPath:
      "/tmp/devscope-fixtures/recovery/11111111-2222-3333-4444-555555555555.backup"
    )
    let fileSystem = InMemoryAutomationFileSystem(
      files: [sourceURL: sourceData],
      metadataAfterReplace: [backupURL: AutomationFileMetadata(
        canonicalURL: URL(fileURLWithPath: "/tmp/outside-recovery/forged.backup"),
        ownerUID: 501,
        isSymbolicLink: false,
        modificationDate: Date(timeIntervalSince1970: 1_000),
        resourceIdentifier: "forged-backup",
        permissions: 0o600
      )]
    )
    let executor = RecordingAutomationMutationExecutor()
    let manager = makeManager(fileSystem: fileSystem, executor: executor)

    let result = await manager.perform(
      .disable,
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    XCTAssertEqual(
      result.status,
      .failed("DevScope could not create owner-only recovery evidence.")
    )
    XCTAssertTrue(
      fileSystem.itemExists(at: backupURL),
      "A post-write identity mismatch must not authorize deleting the replacement leaf."
    )
    XCTAssertFalse(fileSystem.recordedOperations.contains {
      if case .remove(let removedURL) = $0 { return removedURL == backupURL }
      return false
    })
    let invocationCount = await executor.invocationCount()
    XCTAssertEqual(invocationCount, 0)
  }

  func testExportReturnsRedactedArtifactWithoutSourceIOOrExecutorSideEffects() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let secret = "PRIVATE_TOKEN=do-not-export"
    let sourceData = Data(secret.utf8)
    let sourceChecksum = sha256(sourceData)
    let record = AutomationRecord(
      id: Fixtures.userAgent.id,
      kind: Fixtures.userAgent.kind,
      sourceKind: Fixtures.userAgent.sourceKind,
      label: Fixtures.userAgent.label,
      displayName: Fixtures.userAgent.displayName,
      providerBundleIdentifier: nil,
      ownerUID: 501,
      ownership: .user,
      executable: "/bin/sh",
      arguments: ["-c", secret],
      environment: ["TOKEN": secret],
      workingDirectory: "/private/workspace",
      schedule: Fixtures.userAgent.schedule,
      sourceURL: sourceURL,
      sourceChecksum: sourceChecksum,
      enabledState: .enabled,
      loadState: .loaded,
      approvalState: .notApplicable,
      state: .running,
      evidence: [AutomationEvidence(strength: .strong, source: "test", detail: secret)],
      capabilities: [.exportRecord],
      validationFindings: [secret]
    )
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let executor = RecordingAutomationMutationExecutor(results: [.failure(.applyFailed)])
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      context: .fixture(
        currentUID: 501,
        canonicalPathIsApproved: true,
        ownerUID: 501,
        implementedCapabilities: [.exportRecord]
      )
    )

    let result = await manager.perform(
      .exportRecord(redacted: true),
      record: record,
      expectedChecksum: record.sourceChecksum,
      linkedProcesses: []
    )

    XCTAssertEqual(result.status, .succeeded)
    XCTAssertEqual(result.rollback, .notNeeded)
    XCTAssertNil(result.backup)
    let artifact = try! XCTUnwrap(result.exportArtifact)
    XCTAssertTrue(artifact.isRedacted)
    XCTAssertEqual(artifact.mediaType, "application/json")
    XCTAssertFalse(String(decoding: artifact.data, as: UTF8.self).contains(secret))
    XCTAssertFalse(fileSystem.recordedOperations.contains {
      if case .createDirectory = $0 { return true }
      return false
    })
    let invocationCount = await executor.invocationCount()
    XCTAssertEqual(invocationCount, 0)
  }

  func testUnredactedUserExportReturnsExactChecksumVerifiedSourceBytes() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let checksum = sha256(sourceData)
    let record = copyRecord(Fixtures.userAgent, sourceChecksum: checksum)
    let executor = RecordingAutomationMutationExecutor(results: [.failure(.applyFailed)])
    let manager = makeManager(fileSystem: InMemoryAutomationFileSystem(files: [
      sourceURL: sourceData,
    ]), executor: executor)

    let result = await manager.perform(
      .exportRecord(redacted: false),
      record: record,
      expectedChecksum: checksum,
      linkedProcesses: []
    )

    XCTAssertEqual(result.status, .succeeded)
    let artifact = try! XCTUnwrap(result.exportArtifact)
    XCTAssertFalse(artifact.isRedacted)
    XCTAssertEqual(artifact.format, "source.plist")
    XCTAssertEqual(artifact.mediaType, "application/x-plist")
    XCTAssertEqual(artifact.data, sourceData)
    let invocationCount = await executor.invocationCount()
    XCTAssertEqual(invocationCount, 0)
  }

  func testProtectedRecordExportForcesRedactionAndNeedsNoReadableSource() async {
    let secret = "--private-system-argument"
    let record = AutomationRecord(
      id: AutomationRecord.ID(
        source: .serviceManagement,
        ownerUID: 0,
        label: "com.example.protected",
        sourcePath: "bundle:com.example.protected"
      ),
      kind: .backgroundItem,
      sourceKind: .serviceManagement,
      label: "com.example.protected",
      displayName: "Protected Background Item",
      providerBundleIdentifier: "com.example.protected",
      ownerUID: nil,
      ownership: .thirdPartySystem,
      executable: "/private/protected/helper",
      arguments: [secret],
      environment: ["SECRET": secret],
      workingDirectory: nil,
      schedule: AutomationSchedule(triggers: [.demand], summary: "On demand"),
      sourceURL: nil,
      sourceChecksum: "diagnostic-generation",
      enabledState: .unknown,
      loadState: .unknown,
      approvalState: .unknown,
      state: .unresolved,
      evidence: [AutomationEvidence(strength: .strong, source: "diagnostic", detail: secret)],
      capabilities: [.exportRecord],
      validationFindings: []
    )
    let executor = RecordingAutomationMutationExecutor(results: [.failure(.applyFailed)])
    let manager = makeManager(
      fileSystem: InMemoryAutomationFileSystem(files: [:]),
      executor: executor,
      context: .fixture(
        currentUID: 501,
        canonicalPathIsApproved: false,
        ownerUID: nil,
        implementedCapabilities: [.exportRecord]
      )
    )

    let result = await manager.perform(
      .exportRecord(redacted: false),
      record: record,
      expectedChecksum: record.sourceChecksum,
      linkedProcesses: []
    )

    XCTAssertEqual(result.status, .succeeded)
    let artifact = try! XCTUnwrap(result.exportArtifact)
    XCTAssertTrue(artifact.isRedacted)
    XCTAssertFalse(String(decoding: artifact.data, as: UTF8.self).contains(secret))
    let invocationCount = await executor.invocationCount()
    XCTAssertEqual(invocationCount, 0)
  }

  func testInvalidEditedSourceLeavesOriginalUnchangedAndNeverApplies() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let checksum = sha256(sourceData)
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let executor = RecordingAutomationMutationExecutor()
    let manager = makeManager(fileSystem: fileSystem, executor: executor)
    let payload = AutomationEditPayload(
      label: Fixtures.userAgent.label,
      executable: "/bin/sleep",
      arguments: ["14400"],
      environment: [:],
      workingDirectory: nil,
      schedule: Fixtures.userAgent.schedule,
      rawRepresentation: Data("not a property list".utf8)
    )

    let result = await manager.perform(
      .edit(payload),
      record: Fixtures.userAgent,
      expectedChecksum: checksum,
      linkedProcesses: []
    )

    XCTAssertEqual(result.status, .rejected("The launchd property list is not semantically valid."))
    XCTAssertEqual(fileSystem.storedData(at: sourceURL), sourceData)
    let invocationCount = await executor.invocationCount()
    XCTAssertEqual(invocationCount, 0)
  }

  func testFailedApplyRestoresBackupAndPriorEnabledState() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let checksum = sha256(sourceData)
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let executor = RecordingAutomationMutationExecutor(results: [
      .failure(.applyFailed),
      .success(AutomationExecutorResult(
        postconditions: [.futureLaunchesEnabled],
        evidence: ["prior state restored"]
      )),
    ])
    let manager = makeManager(fileSystem: fileSystem, executor: executor)
    let editedData = validLaunchAgentData(arguments: ["7200"])
    let payload = AutomationEditPayload(
      label: Fixtures.userAgent.label,
      executable: "/bin/sleep",
      arguments: ["7200"],
      environment: [:],
      workingDirectory: nil,
      schedule: Fixtures.userAgent.schedule,
      rawRepresentation: editedData
    )

    let result = await manager.perform(
      .edit(payload),
      record: Fixtures.userAgent,
      expectedChecksum: checksum,
      linkedProcesses: []
    )

    XCTAssertEqual(result.status, .failed("The automation operation failed; the prior source and loaded state were restored."))
    XCTAssertEqual(result.rollback, .restored(try! XCTUnwrap(result.backup?.id)))
    XCTAssertEqual(fileSystem.storedData(at: sourceURL), sourceData)
    let operations = await executor.recordedOperations()
    XCTAssertEqual(operations, [.edit(payload)])
  }

  func testPostInstallIdentityFailureRestoresOriginalBeforeExecutorRuns() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let editedData = validLaunchAgentData(arguments: ["7200"])
    let fileSystem = InMemoryAutomationFileSystem(
      files: [sourceURL: sourceData],
      metadataFailuresAfterReplace: [sourceURL: 1]
    )
    let executor = RecordingAutomationMutationExecutor()
    let manager = makeManager(fileSystem: fileSystem, executor: executor)
    let payload = AutomationEditPayload(
      label: Fixtures.userAgent.label,
      executable: "/bin/sleep",
      arguments: ["7200"],
      environment: [:],
      workingDirectory: nil,
      schedule: Fixtures.userAgent.schedule,
      rawRepresentation: editedData
    )

    let result = await manager.perform(
      .edit(payload),
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    XCTAssertEqual(
      result.status,
      .failed("The automation operation failed; the prior source and loaded state were restored.")
    )
    XCTAssertEqual(result.rollback, .restored(try! XCTUnwrap(result.backup?.id)))
    XCTAssertEqual(fileSystem.storedData(at: sourceURL), sourceData)
    XCTAssertFalse(result.appliedSteps.contains { $0.localizedCaseInsensitiveContains("cron") })
    let invocationCount = await executor.invocationCount()
    XCTAssertEqual(invocationCount, 0)
  }

  func testPostInstallByteMismatchNeverReachesExecutor() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let editedData = validLaunchAgentData(arguments: ["7200"])
    let unreviewedData = validLaunchAgentData(arguments: ["attacker"])
    let fileSystem = InMemoryAutomationFileSystem(
      files: [sourceURL: sourceData],
      dataAfterReplace: [sourceURL: unreviewedData]
    )
    let executor = RecordingAutomationMutationExecutor()
    let manager = makeManager(fileSystem: fileSystem, executor: executor)
    let payload = AutomationEditPayload(
      label: Fixtures.userAgent.label,
      executable: "/bin/sleep",
      arguments: ["7200"],
      environment: [:],
      workingDirectory: nil,
      schedule: Fixtures.userAgent.schedule,
      rawRepresentation: editedData
    )

    let result = await manager.perform(
      .edit(payload),
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    XCTAssertEqual(
      result.status,
      .partialFailure("HIGH SEVERITY: the operation failed and automatic rollback did not complete.")
    )
    XCTAssertEqual(fileSystem.storedData(at: sourceURL), unreviewedData)
    let invocationCount = await executor.invocationCount()
    XCTAssertEqual(invocationCount, 0)
  }

  func testPartialReplacePreservesRecoveryEvidenceAndNeverInvokesExecutor() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let editedData = validLaunchAgentData(arguments: ["7200"])
    let fileSystem = InMemoryAutomationFileSystem(
      files: [sourceURL: sourceData],
      partialReplaceAfterCommit: [sourceURL]
    )
    let executor = RecordingAutomationMutationExecutor()
    let manager = makeManager(fileSystem: fileSystem, executor: executor)
    let payload = AutomationEditPayload(
      label: Fixtures.userAgent.label,
      executable: "/bin/sleep",
      arguments: ["7200"],
      environment: [:],
      workingDirectory: nil,
      schedule: Fixtures.userAgent.schedule,
      rawRepresentation: editedData
    )

    let result = await manager.perform(
      .edit(payload),
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    XCTAssertNotNil(result.fileMutationEvidence)
    XCTAssertNotNil(result.fileMutationEvidence?.recoveryHandle)
    XCTAssertEqual(result.fileMutationEvidence?.commitState, .committed)
    let invocationCount = await executor.invocationCount()
    XCTAssertEqual(invocationCount, 0)
  }

  func testPartialTrashMovePreservesRecoveryEvidenceAndNeverInvokesExecutor() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let fileSystem = InMemoryAutomationFileSystem(
      files: [sourceURL: sourceData],
      partialTrashAfterCommit: [sourceURL]
    )
    let executor = RecordingAutomationMutationExecutor()
    let manager = makeManager(fileSystem: fileSystem, executor: executor)

    let result = await manager.perform(
      .remove,
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    XCTAssertNotNil(result.fileMutationEvidence)
    XCTAssertNotNil(result.fileMutationEvidence?.recoveryHandle)
    XCTAssertEqual(result.fileMutationEvidence?.kind, .trash)
    XCTAssertEqual(fileSystem.storedData(at: sourceURL), sourceData)
    let invocationCount = await executor.invocationCount()
    XCTAssertEqual(invocationCount, 0)
  }

  func testPartialBackupInstallIsReportedWithRecoveryHandleBeforeSourceMutation() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let fileSystem = InMemoryAutomationFileSystem(
      files: [sourceURL: sourceData],
      partialReplaceAfterCommit: [deterministicFirstBackupURL()]
    )
    let executor = RecordingAutomationMutationExecutor()
    let refreshCount = LockedCallCounter()
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      refresh: {
        _ = refreshCount.incrementAndGet()
        return Fixtures.inventoryGeneration7
      }
    )

    let result = await manager.perform(
      .disable,
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    XCTAssertEqual(
      result.status,
      .partialFailure("HIGH SEVERITY: recovery evidence installation was only partially completed.")
    )
    XCTAssertNotNil(result.fileMutationEvidence?.recoveryHandle)
    XCTAssertEqual(refreshCount.current(), 1)
    let invocationCount = await executor.invocationCount()
    XCTAssertEqual(invocationCount, 0)
  }

  func testUnchangedBackupReplacementCleansExactStagedFileAndRemainsOrdinary() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let backupURL = deterministicFirstBackupURL()
    let fileSystem = InMemoryAutomationFileSystem(
      files: [sourceURL: sourceData],
      unchangedReplaceOccurrences: [backupURL: [1]]
    )
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: RecordingAutomationMutationExecutor()
    )

    let result = await manager.perform(
      .disable,
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    XCTAssertEqual(
      result.status,
      .failed("DevScope could not create owner-only recovery evidence.")
    )
    XCTAssertNil(result.fileMutationEvidence)
    XCTAssertNil(fileSystem.storedData(at: backupURL))
    let stagedURLs = fileSystem.recordedOperations.compactMap { operation -> URL? in
      guard case .writeTemporary(let url, _) = operation else { return nil }
      return url
    }
    XCTAssertEqual(stagedURLs.count, 1)
    XCTAssertFalse(fileSystem.itemExists(at: try! XCTUnwrap(stagedURLs.first)))
  }

  func testUnchangedReplacementCleanupFailureSurfacesExactStagedRecoveryHandle() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let backupURL = deterministicFirstBackupURL()
    let fileSystem = InMemoryAutomationFileSystem(
      files: [sourceURL: sourceData],
      unchangedReplaceOccurrences: [backupURL: [1]],
      unchangedReplaceRetainsStaged: true,
      failStagedRemoves: true
    )
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: RecordingAutomationMutationExecutor()
    )

    let result = await manager.perform(
      .disable,
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    guard case .partialFailure = result.status else {
      return XCTFail("Expected partial failure, got \(result.status)")
    }
    let handle = try! XCTUnwrap(result.fileMutationEvidence?.recoveryHandle)
    XCTAssertTrue(handle.fileURL.lastPathComponent.hasPrefix(".devscope-fixture-"))
    XCTAssertTrue(fileSystem.itemExists(at: handle.fileURL))
    XCTAssertEqual(fileSystem.storedData(at: handle.fileURL), sourceData)
  }

  func testPartialManifestInstallIsReportedWithRecoveryHandleBeforeSourceMutation() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let fileSystem = InMemoryAutomationFileSystem(
      files: [sourceURL: sourceData],
      partialReplaceAfterCommit: [deterministicFirstManifestURL()]
    )
    let executor = RecordingAutomationMutationExecutor()
    let refreshCount = LockedCallCounter()
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      refresh: {
        _ = refreshCount.incrementAndGet()
        return Fixtures.inventoryGeneration7
      }
    )

    let result = await manager.perform(
      .disable,
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    XCTAssertEqual(
      result.status,
      .partialFailure("HIGH SEVERITY: recovery evidence installation was only partially completed.")
    )
    XCTAssertEqual(result.fileMutationEvidence?.resultURL, deterministicFirstManifestURL())
    XCTAssertNil(fileSystem.storedData(at: deterministicFirstManifestURL()))
    XCTAssertNil(fileSystem.storedData(at: deterministicFirstBackupURL()))
    XCTAssertTrue(result.fileMutationEvidence?.recoveryHandles.isEmpty == true)
    XCTAssertEqual(refreshCount.current(), 1)
    let invocationCount = await executor.invocationCount()
    XCTAssertEqual(invocationCount, 0)
  }

  func testObservedNonRecoveryCollisionIsReportedButNeverDeletedOrPromoted() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let manifestURL = deterministicFirstManifestURL()
    let collisionURL = manifestURL.deletingLastPathComponent()
      .appendingPathComponent("attacker.keep")
    let collisionData = Data("attacker-owned".utf8)
    let fileSystem = InMemoryAutomationFileSystem(
      files: [
        sourceURL: sourceData,
        collisionURL: collisionData,
      ],
      partialReplaceAfterCommit: [manifestURL],
      partialReplaceObservedOnly: [manifestURL: [collisionURL]]
    )
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: RecordingAutomationMutationExecutor()
    )

    let result = await manager.perform(
      .disable,
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    guard case .partialFailure = result.status else {
      return XCTFail("Expected partial failure, got \(result.status)")
    }
    let evidence = try! XCTUnwrap(result.fileMutationEvidence)
    XCTAssertEqual(fileSystem.storedData(at: collisionURL), collisionData)
    XCTAssertTrue(evidence.observedFiles.contains { $0.fileURL == collisionURL })
    XCTAssertFalse(evidence.recoveryHandles.contains { $0.fileURL == collisionURL })
    XCTAssertNil(fileSystem.storedData(at: manifestURL))
    XCTAssertNil(fileSystem.storedData(at: deterministicFirstBackupURL()))
  }

  func testManifestFailureCannotHidePartialBackupCleanup() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let fileSystem = InMemoryAutomationFileSystem(
      files: [sourceURL: sourceData],
      dataAfterReplace: [deterministicFirstManifestURL(): Data("corrupt".utf8)],
      partialRemoveAfterCommit: [deterministicFirstBackupURL()]
    )
    let executor = RecordingAutomationMutationExecutor()
    let refreshCount = LockedCallCounter()
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      refresh: {
        _ = refreshCount.incrementAndGet()
        return Fixtures.inventoryGeneration7
      }
    )

    let result = await manager.perform(
      .disable,
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    guard case .partialFailure = result.status else {
      return XCTFail("Expected partial failure, got \(result.status)")
    }
    XCTAssertEqual(result.fileMutationEvidence?.kind, .remove)
    XCTAssertNotNil(result.fileMutationEvidence?.recoveryHandle)
    XCTAssertEqual(refreshCount.current(), 1)
    let invocationCount = await executor.invocationCount()
    XCTAssertEqual(invocationCount, 0)
  }

  func testCorruptCommittedManifestIsRemovedWithItsBackupBeforeOrdinaryFailure() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let backupURL = deterministicFirstBackupURL()
    let manifestURL = deterministicFirstManifestURL()
    let fileSystem = InMemoryAutomationFileSystem(
      files: [sourceURL: sourceData],
      dataAfterReplace: [manifestURL: Data("corrupt".utf8)]
    )
    let executor = RecordingAutomationMutationExecutor()
    let manager = makeManager(fileSystem: fileSystem, executor: executor)

    let result = await manager.perform(
      .disable,
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    XCTAssertEqual(
      result.status,
      .failed("DevScope could not create owner-only recovery evidence.")
    )
    XCTAssertNil(fileSystem.storedData(at: backupURL))
    XCTAssertNil(fileSystem.storedData(at: manifestURL))
    let restarted = makeManager(
      fileSystem: fileSystem,
      executor: RecordingAutomationMutationExecutor()
    )
    let manifests = await restarted.restorationManifests()
    XCTAssertTrue(manifests.isEmpty)
    let invocationCount = await executor.invocationCount()
    XCTAssertEqual(invocationCount, 0)
  }

  func testVerifiedUnchangedBackupCleanupRemainsAnOrdinaryFailure() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let backupURL = deterministicFirstBackupURL()
    let fileSystem = InMemoryAutomationFileSystem(
      files: [sourceURL: sourceData],
      dataAfterReplace: [backupURL: Data("corrupt".utf8)],
      unchangedRemoves: [backupURL]
    )
    let executor = RecordingAutomationMutationExecutor()
    let manager = makeManager(fileSystem: fileSystem, executor: executor)

    let result = await manager.perform(
      .disable,
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    XCTAssertEqual(
      result.status,
      .failed("DevScope could not create owner-only recovery evidence.")
    )
    XCTAssertNil(result.fileMutationEvidence)
    XCTAssertEqual(fileSystem.storedData(at: backupURL), Data("corrupt".utf8))
    let invocationCount = await executor.invocationCount()
    XCTAssertEqual(invocationCount, 0)
  }

  func testRawBackupCleanupFailureBeforeMutationRemainsOrdinary() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let backupURL = deterministicFirstBackupURL()
    let fileSystem = InMemoryAutomationFileSystem(
      files: [sourceURL: sourceData],
      dataAfterReplace: [backupURL: Data("corrupt".utf8)],
      failingRemoves: [backupURL]
    )
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: RecordingAutomationMutationExecutor()
    )

    let result = await manager.perform(
      .disable,
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    XCTAssertEqual(
      result.status,
      .failed("DevScope could not create owner-only recovery evidence.")
    )
    XCTAssertNil(result.fileMutationEvidence)
    XCTAssertEqual(fileSystem.storedData(at: backupURL), Data("corrupt".utf8))
  }

  func testVerifiedUnchangedCleanupIsPartialAfterAnotherArtifactWasDeleted() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let backupURL = deterministicFirstBackupURL()
    let manifestURL = deterministicFirstManifestURL()
    let fileSystem = InMemoryAutomationFileSystem(
      files: [sourceURL: sourceData],
      dataAfterReplace: [manifestURL: Data("corrupt".utf8)],
      unchangedRemoves: [backupURL]
    )
    let executor = RecordingAutomationMutationExecutor()
    let manager = makeManager(fileSystem: fileSystem, executor: executor)

    let result = await manager.perform(
      .disable,
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    XCTAssertEqual(
      result.status,
      .partialFailure("HIGH SEVERITY: recovery evidence installation was only partially completed.")
    )
    XCTAssertNil(fileSystem.storedData(at: manifestURL))
    XCTAssertNotNil(fileSystem.storedData(at: backupURL))
    XCTAssertTrue(result.fileMutationEvidence?.recoveryHandles.contains {
      $0.fileURL == backupURL
    } == true)
    let invocationCount = await executor.invocationCount()
    XCTAssertEqual(invocationCount, 0)
  }

  func testFailedVerificationRestoresAndReappliesPriorState() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let checksum = sha256(sourceData)
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let executor = RecordingAutomationMutationExecutor(results: [
      .success(AutomationExecutorResult(
        postconditions: [.futureLaunchesDisabled],
        evidence: ["disable command returned success"]
      )),
      .success(AutomationExecutorResult(
        postconditions: [.futureLaunchesEnabled],
        evidence: ["prior state restored"]
      )),
    ])
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      refresh: { snapshot(records: [Fixtures.userAgent]) }
    )

    let result = await manager.perform(
      .disable,
      record: Fixtures.userAgent,
      expectedChecksum: checksum,
      linkedProcesses: []
    )

    XCTAssertEqual(result.status, .failed("The automation operation failed; the prior source and loaded state were restored."))
    XCTAssertEqual(result.rollback, .restored(try! XCTUnwrap(result.backup?.id)))
    let operations = await executor.recordedOperations()
    XCTAssertEqual(operations, [.disable])
  }

  func testFailedRollbackReportsHighSeverityPartialFailure() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let checksum = sha256(sourceData)
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let executor = RecordingAutomationMutationExecutor(results: [
      .failure(.applyFailed),
    ], restorationFails: true)
    let manager = makeManager(fileSystem: fileSystem, executor: executor)

    let result = await manager.perform(
      .disable,
      record: Fixtures.userAgent,
      expectedChecksum: checksum,
      linkedProcesses: []
    )

    XCTAssertEqual(
      result.status,
      .partialFailure("HIGH SEVERITY: the operation failed and automatic rollback did not complete.")
    )
    XCTAssertEqual(result.rollback, .failed("Automatic rollback did not complete."))
    XCTAssertEqual(
      result.manualRecovery,
      "Use DevScope Restore with the recorded recovery identifier before retrying."
    )
    XCTAssertNotEqual(result.status, .succeeded)
  }

  func testConcurrentRequestsAreSerializedAcrossExecutorAwait() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let checksum = sha256(sourceData)
    let disabledRecord = copyRecord(
      Fixtures.userAgent,
      sourceChecksum: checksum,
      enabledState: .disabled,
      state: .disabled
    )
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let success = AutomationExecutorResult(
      postconditions: [.futureLaunchesDisabled],
      evidence: []
    )
    let executor = RecordingAutomationMutationExecutor(
      results: [.success(success), .success(success)],
      delayNanoseconds: 50_000_000
    )
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      refresh: { snapshot(records: [disabledRecord]) }
    )

    async let first = manager.perform(
      .disable,
      record: Fixtures.userAgent,
      expectedChecksum: checksum,
      linkedProcesses: []
    )
    async let second = manager.perform(
      .disable,
      record: Fixtures.userAgent,
      expectedChecksum: checksum,
      linkedProcesses: []
    )
    let results = await [first, second]

    XCTAssertTrue(results.allSatisfy { $0.status == .succeeded })
    let maximumConcurrency = await executor.maximumConcurrency()
    XCTAssertEqual(maximumConcurrency, 1)
  }

  func testRemoveMovesSourceToTrashBeforeApplyingTypedRemoval() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let checksum = sha256(sourceData)
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let executor = RecordingAutomationMutationExecutor(results: [
      .success(AutomationExecutorResult(
        postconditions: [.sourceRemoved, .targetUnresolved],
        evidence: ["service unloaded"]
      )),
    ])
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      refresh: { snapshot(records: []) }
    )

    let result = await manager.perform(
      .remove,
      record: Fixtures.userAgent,
      expectedChecksum: checksum,
      linkedProcesses: []
    )

    XCTAssertEqual(result.status, .succeeded)
    XCTAssertNil(fileSystem.storedData(at: sourceURL))
    XCTAssertTrue(fileSystem.recordedOperations.contains {
      if case .moveToTrash(let removedURL, _) = $0 { return removedURL == sourceURL }
      return false
    })
  }

  func testRemoveRejectsSourceRecreatedAtSameCanonicalPath() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let recreatedData = validLaunchAgentData(label: "com.example.recreated")
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let executor = RecordingAutomationMutationExecutor(
      results: [.success(AutomationExecutorResult(
        postconditions: [.sourceRemoved, .targetUnresolved],
        evidence: []
      ))],
      onApply: { fileSystem.setStoredData(recreatedData, at: sourceURL) }
    )
    let recreated = copyRecord(
      Fixtures.userAgent,
      id: AutomationRecord.ID(
        source: .launchAgent,
        ownerUID: 501,
        label: "com.example.recreated",
        sourcePath: sourceURL.path
      ),
      label: "com.example.recreated",
      sourceChecksum: sha256(recreatedData)
    )
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      refresh: { snapshot(records: [recreated]) }
    )

    let result = await manager.perform(
      .remove,
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    XCTAssertNotEqual(result.status, .succeeded)
    XCTAssertEqual(fileSystem.storedData(at: sourceURL), recreatedData)
    XCTAssertTrue(result.verificationEvidence.contains { $0.contains("transaction identity") })
  }

  func testRestoreUsesBackupFirstWhenRemovedSourceNoLongerExists() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let checksum = sha256(sourceData)
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let refreshCount = LockedCallCounter()
    let restoredRecord = copyRecord(Fixtures.userAgent, sourceChecksum: checksum)
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: RecordingAutomationMutationExecutor(results: [
        .success(AutomationExecutorResult(
          postconditions: [.sourceRemoved, .targetUnresolved],
          evidence: []
        )),
        .success(AutomationExecutorResult(
          postconditions: [.sourceInstalled, .sourceChecksum(checksum)],
          evidence: []
        )),
      ]),
      refresh: {
        refreshCount.incrementAndGet() == 1
          ? snapshot(records: [])
          : snapshot(records: [restoredRecord])
      }
    )
    let removed = await manager.perform(
      .remove,
      record: Fixtures.userAgent,
      expectedChecksum: checksum,
      linkedProcesses: []
    )
    let backupID = try! XCTUnwrap(removed.backup?.id)
    XCTAssertNil(fileSystem.storedData(at: sourceURL))

    let restored = await manager.perform(
      .restore(backupID),
      record: Fixtures.userAgent,
      expectedChecksum: nil,
      linkedProcesses: []
    )

    XCTAssertEqual(restored.status, .succeeded)
    XCTAssertEqual(fileSystem.storedData(at: sourceURL), sourceData)
  }

  func testRestoreRejectsExternallyEditedExistingDestinationWithoutMutation() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let externalData = validLaunchAgentData(arguments: ["external"])
    let checksum = sha256(sourceData)
    let disabled = copyRecord(
      Fixtures.userAgent,
      sourceChecksum: checksum,
      enabledState: .disabled,
      state: .disabled
    )
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let executor = RecordingAutomationMutationExecutor(results: [
      .success(AutomationExecutorResult(postconditions: [.futureLaunchesDisabled], evidence: [])),
    ])
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      refresh: { snapshot(records: [disabled]) }
    )
    let first = await manager.perform(
      .disable,
      record: Fixtures.userAgent,
      expectedChecksum: checksum,
      linkedProcesses: []
    )
    let backupID = try! XCTUnwrap(first.backup?.id)
    fileSystem.setStoredData(externalData, at: sourceURL)

    let restored = await manager.perform(
      .restore(backupID),
      record: disabled,
      expectedChecksum: checksum,
      linkedProcesses: []
    )

    XCTAssertEqual(
      restored.status,
      .rejected("The restore destination changed since it was inspected.")
    )
    XCTAssertEqual(fileSystem.storedData(at: sourceURL), externalData)
    let invocationCount = await executor.invocationCount()
    XCTAssertEqual(invocationCount, 1)
  }

  func testFailedRestoreIntoAbsentDestinationRollsBackToAbsenceNormally() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let checksum = sha256(sourceData)
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let refreshCount = LockedCallCounter()
    let executor = RecordingAutomationMutationExecutor(results: [
      .success(AutomationExecutorResult(
        postconditions: [.sourceRemoved, .targetUnresolved],
        evidence: []
      )),
      .failure(.applyFailed),
    ])
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      refresh: {
        _ = refreshCount.incrementAndGet()
        return snapshot(records: [])
      }
    )
    let removed = await manager.perform(
      .remove,
      record: Fixtures.userAgent,
      expectedChecksum: checksum,
      linkedProcesses: []
    )
    let backupID = try! XCTUnwrap(removed.backup?.id)

    let restored = await manager.perform(
      .restore(backupID),
      record: Fixtures.userAgent,
      expectedChecksum: nil,
      linkedProcesses: []
    )

    XCTAssertEqual(
      restored.status,
      .failed("The automation operation failed; the prior absent source state was restored.")
    )
    XCTAssertNotNil({ if case .restored = restored.rollback { return true }; return nil }())
    XCTAssertNil(fileSystem.storedData(at: sourceURL))
    let restorationStates = await executor.recordedRestorationStates()
    XCTAssertTrue(restorationStates.isEmpty)
  }

  func testManualRestoreOfAbsentBackupRemovesInstalledDestination() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let destination = sourceURL.deletingLastPathComponent()
      .appendingPathComponent("duplicate.plist")
    let sourceData = validLaunchAgentData()
    let duplicateData = validLaunchAgentData(label: "com.example.duplicate")
    let duplicateID = AutomationRecord.ID(
      source: .launchAgent,
      ownerUID: 501,
      label: "com.example.duplicate",
      sourcePath: destination.path
    )
    let duplicateRecord = copyRecord(
      Fixtures.userAgent,
      id: duplicateID,
      label: "com.example.duplicate",
      sourceURL: destination,
      sourceChecksum: sha256(duplicateData),
      enabledState: .disabled,
      loadState: .unloaded
    )
    let refreshCount = LockedCallCounter()
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: RecordingAutomationMutationExecutor(results: [
        .success(AutomationExecutorResult(
          postconditions: [
            .sourceInstalled,
            .sourceChecksum(sha256(duplicateData)),
            .futureLaunchesDisabled,
          ],
          evidence: []
        )),
        .success(AutomationExecutorResult(
          postconditions: [.sourceRemoved, .targetUnresolved],
          evidence: []
        )),
      ]),
      refresh: {
        refreshCount.incrementAndGet() == 1
          ? snapshot(records: [duplicateRecord])
          : snapshot(records: [])
      }
    )
    let duplicate = await manager.perform(
      .duplicate(AutomationEditPayload(
        label: "com.example.duplicate",
        executable: "/bin/sleep",
        arguments: ["14400"],
        environment: [:],
        workingDirectory: nil,
        schedule: Fixtures.userAgent.schedule,
        rawRepresentation: duplicateData,
        destination: destination
      )),
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )
    let backup = try! XCTUnwrap(duplicate.backup)
    XCTAssertFalse(backup.sourceExisted)
    XCTAssertEqual(fileSystem.storedData(at: destination), duplicateData)

    let restored = await manager.perform(
      .restore(backup.id),
      record: duplicateRecord,
      expectedChecksum: sha256(duplicateData),
      linkedProcesses: []
    )

    XCTAssertEqual(restored.status, .succeeded)
    XCTAssertNil(fileSystem.storedData(at: destination))
  }

  func testLaunchdDuplicateFailsAndRollsBackUnlessTheCopyIsDisabledAndUnloaded() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let destination = sourceURL.deletingLastPathComponent()
      .appendingPathComponent("enabled-duplicate.plist")
    let sourceData = validLaunchAgentData()
    let duplicateData = validLaunchAgentData(label: "com.example.enabled-duplicate")
    let duplicateRecord = copyRecord(
      Fixtures.userAgent,
      id: AutomationRecord.ID(
        source: .launchAgent,
        ownerUID: 501,
        label: "com.example.enabled-duplicate",
        sourcePath: destination.path
      ),
      label: "com.example.enabled-duplicate",
      sourceURL: destination,
      sourceChecksum: sha256(duplicateData),
      enabledState: .enabled,
      loadState: .unloaded
    )
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: RecordingAutomationMutationExecutor(results: [
        .success(AutomationExecutorResult(
          postconditions: [
            .sourceInstalled,
            .sourceChecksum(sha256(duplicateData)),
            .futureLaunchesDisabled,
          ],
          evidence: []
        )),
      ]),
      refresh: { snapshot(records: [duplicateRecord]) }
    )

    let result = await manager.perform(
      .duplicate(AutomationEditPayload(
        label: duplicateRecord.label,
        executable: "/bin/sleep",
        arguments: ["14400"],
        environment: [:],
        workingDirectory: nil,
        schedule: Fixtures.userAgent.schedule,
        rawRepresentation: duplicateData,
        destination: destination
      )),
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    XCTAssertNotEqual(result.status, .succeeded)
    XCTAssertNil(fileSystem.storedData(at: destination))
  }

  func testPartialRemovalWhileRestoringAbsenceIsReportedAndSkipsExecutor() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let destination = sourceURL.deletingLastPathComponent()
      .appendingPathComponent("partial-duplicate.plist")
    let sourceData = validLaunchAgentData()
    let duplicateData = validLaunchAgentData(label: "com.example.partial-duplicate")
    let duplicateRecord = copyRecord(
      Fixtures.userAgent,
      id: AutomationRecord.ID(
        source: .launchAgent,
        ownerUID: 501,
        label: "com.example.partial-duplicate",
        sourcePath: destination.path
      ),
      label: "com.example.partial-duplicate",
      sourceURL: destination,
      sourceChecksum: sha256(duplicateData),
      enabledState: .disabled,
      loadState: .unloaded
    )
    let executor = RecordingAutomationMutationExecutor(results: [
      .success(AutomationExecutorResult(
        postconditions: [
          .sourceInstalled,
          .sourceChecksum(sha256(duplicateData)),
          .futureLaunchesDisabled,
        ],
        evidence: []
      )),
    ])
    let fileSystem = InMemoryAutomationFileSystem(
      files: [sourceURL: sourceData],
      partialRemoveAfterCommit: [destination]
    )
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      refresh: { snapshot(records: [duplicateRecord]) }
    )
    let duplicate = await manager.perform(
      .duplicate(AutomationEditPayload(
        label: duplicateRecord.label,
        executable: "/bin/sleep",
        arguments: ["14400"],
        environment: [:],
        workingDirectory: nil,
        schedule: Fixtures.userAgent.schedule,
        rawRepresentation: duplicateData,
        destination: destination
      )),
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    let restored = await manager.perform(
      .restore(try! XCTUnwrap(duplicate.backup?.id)),
      record: duplicateRecord,
      expectedChecksum: sha256(duplicateData),
      linkedProcesses: []
    )

    guard case .partialFailure = restored.status else {
      return XCTFail("Expected partial failure, got \(restored.status)")
    }
    XCTAssertEqual(restored.fileMutationEvidence?.kind, .remove)
    XCTAssertNotNil(restored.fileMutationEvidence?.recoveryHandle)
    XCTAssertEqual(fileSystem.storedData(at: destination), duplicateData)
    let invocationCount = await executor.invocationCount()
    XCTAssertEqual(invocationCount, 1)
  }

  func testRestoreAcceptsVerifiedRenamedSuccessorButRejectsUnrelatedRecord() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let originalData = validLaunchAgentData()
    let renamedLabel = "com.example.renamed"
    let renamedData = validLaunchAgentData(label: renamedLabel)
    let originalChecksum = sha256(originalData)
    let renamedChecksum = sha256(renamedData)
    let renamedID = AutomationRecord.ID(
      source: .launchAgent,
      ownerUID: 501,
      label: renamedLabel,
      sourcePath: sourceURL.path
    )
    let renamedRecord = copyRecord(
      Fixtures.userAgent,
      id: renamedID,
      label: renamedLabel,
      sourceChecksum: renamedChecksum
    )
    let restoredRecord = copyRecord(Fixtures.userAgent, sourceChecksum: originalChecksum)
    let refreshCount = LockedCallCounter()
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: originalData])
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: RecordingAutomationMutationExecutor(results: [
        .success(AutomationExecutorResult(
          postconditions: [.sourceInstalled, .sourceChecksum(renamedChecksum)], evidence: []
        )),
        .success(AutomationExecutorResult(
          postconditions: [.sourceInstalled, .sourceChecksum(originalChecksum)], evidence: []
        )),
      ]),
      refresh: {
        refreshCount.incrementAndGet() == 1
          ? snapshot(records: [renamedRecord])
          : snapshot(records: [restoredRecord])
      }
    )
    let renamed = await manager.perform(
      .edit(AutomationEditPayload(
        label: renamedLabel,
        executable: "/bin/sleep",
        arguments: ["14400"],
        environment: [:],
        workingDirectory: nil,
        schedule: Fixtures.userAgent.schedule,
        rawRepresentation: renamedData
      )),
      record: Fixtures.userAgent,
      expectedChecksum: originalChecksum,
      linkedProcesses: []
    )
    let backupID = try! XCTUnwrap(renamed.backup?.id)

    let restored = await manager.perform(
      .restore(backupID),
      record: renamedRecord,
      expectedChecksum: renamedChecksum,
      linkedProcesses: []
    )
    XCTAssertEqual(restored.status, .succeeded)
    XCTAssertEqual(fileSystem.storedData(at: sourceURL), originalData)

    let unrelated = copyRecord(
      renamedRecord,
      id: AutomationRecord.ID(rawValue: "unrelated-record")
    )
    let rejected = await manager.perform(
      .restore(backupID), record: unrelated, expectedChecksum: originalChecksum, linkedProcesses: []
    )
    XCTAssertEqual(
      rejected.status,
      .rejected("The selected recovery backup does not belong to this automation.")
    )
  }

  func testImportRejectsExistingWrongOwnerDestinationBeforeBackup() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let destination = sourceURL.deletingLastPathComponent().appendingPathComponent("import.plist")
    let sourceData = validLaunchAgentData()
    let importedData = validLaunchAgentData(label: "com.example.imported")
    let fileSystem = InMemoryAutomationFileSystem(
      files: [sourceURL: sourceData, destination: importedData],
      metadata: [
        destination: AutomationFileMetadata(
          canonicalURL: destination,
          ownerUID: 0,
          isSymbolicLink: false,
          modificationDate: Date(timeIntervalSince1970: 1_000),
          resourceIdentifier: "root-owned-destination"
        ),
      ]
    )
    let executor = RecordingAutomationMutationExecutor()
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      destinationContext: { _, _ in
        .fixture(currentUID: 501, canonicalPathIsApproved: true, ownerUID: 0)
      }
    )
    let operation = AutomationOperation.importRecord(AutomationImportPayload(
      destination: destination,
      data: importedData,
      expectedKind: .launchAgent,
      expectedDestinationChecksum: sha256(importedData)
    ))

    let result = await manager.perform(
      operation,
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    XCTAssertEqual(result.status, .rejected("The intended destination is not owned by the current user."))
    XCTAssertEqual(fileSystem.recordedOperations, [])
  }

  func testResultRedactsOperationPayloadAndExecutorEvidence() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let checksum = sha256(sourceData)
    let secret = "TOP-SECRET-TOKEN"
    let editedData = validLaunchAgentData(
      label: Fixtures.userAgent.label,
      arguments: [secret],
      environment: ["TOKEN": secret],
      workingDirectory: "/tmp/\(secret)"
    )
    let editedChecksum = sha256(editedData)
    let editedRecord = copyRecord(
      Fixtures.userAgent,
      sourceChecksum: editedChecksum,
      enabledState: .enabled,
      state: .idle
    )
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let executor = RecordingAutomationMutationExecutor(results: [
      .success(AutomationExecutorResult(
        postconditions: [.sourceInstalled, .sourceChecksum(editedChecksum)],
        evidence: ["executor saw \(secret)"]
      )),
    ])
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      refresh: { snapshot(records: [editedRecord]) }
    )
    let operation = AutomationOperation.edit(AutomationEditPayload(
      label: Fixtures.userAgent.label,
      executable: "/bin/sleep",
      arguments: [secret],
      environment: ["TOKEN": secret],
      workingDirectory: "/tmp/\(secret)",
      schedule: Fixtures.userAgent.schedule,
      rawRepresentation: editedData
    ))

    let result = await manager.perform(
      operation,
      record: Fixtures.userAgent,
      expectedChecksum: checksum,
      linkedProcesses: []
    )

    XCTAssertEqual(result.status, .succeeded)
    XCTAssertFalse(String(describing: result).contains(secret))
  }

  func testImportCannotVerifyAgainstUnchangedOriginalRecord() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let destination = sourceURL.deletingLastPathComponent().appendingPathComponent("imported.plist")
    let sourceData = validLaunchAgentData()
    let importedData = validLaunchAgentData(label: "com.example.imported")
    let importedChecksum = sha256(importedData)
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let executor = RecordingAutomationMutationExecutor(results: [
      .success(AutomationExecutorResult(
        postconditions: [.sourceInstalled, .sourceChecksum(importedChecksum)],
        evidence: []
      )),
    ])
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      refresh: { snapshot(records: [Fixtures.userAgent]) }
    )

    let result = await manager.perform(
      .importRecord(AutomationImportPayload(
        destination: destination,
        data: importedData,
        expectedKind: .launchAgent
      )),
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    XCTAssertNotEqual(result.status, .succeeded)
    XCTAssertNil(fileSystem.storedData(at: destination))
    guard let backupID = result.backup?.id else {
      return XCTFail("Expected recovery backup, got \(result.status)")
    }
    XCTAssertEqual(result.rollback, .restored(backupID))
  }

  func testLabelChangingEditVerifiesNewIdentityAtSameDestination() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let newLabel = "com.example.renamed"
    let editedData = validLaunchAgentData(label: newLabel)
    let editedChecksum = sha256(editedData)
    let newID = AutomationRecord.ID(
      source: .launchAgent,
      ownerUID: 501,
      label: newLabel,
      sourcePath: sourceURL.path
    )
    let editedRecord = copyRecord(
      Fixtures.userAgent,
      id: newID,
      label: newLabel,
      sourceURL: sourceURL,
      sourceChecksum: editedChecksum
    )
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let executor = RecordingAutomationMutationExecutor(results: [
      .success(AutomationExecutorResult(
        postconditions: [.sourceInstalled, .sourceChecksum(editedChecksum)],
        evidence: []
      )),
    ])
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      refresh: { snapshot(records: [editedRecord]) }
    )
    let payload = AutomationEditPayload(
      label: newLabel,
      executable: "/bin/sleep",
      arguments: ["14400"],
      environment: [:],
      workingDirectory: nil,
      schedule: Fixtures.userAgent.schedule,
      rawRepresentation: editedData
    )

    let result = await manager.perform(
      .edit(payload),
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    XCTAssertEqual(result.status, .succeeded)
  }

  func testPartialSuccessorManifestReplacementPreservesEvidenceThroughSourceRollback() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let newLabel = "com.example.partial-successor"
    let editedData = validLaunchAgentData(label: newLabel)
    let editedChecksum = sha256(editedData)
    let editedRecord = copyRecord(
      Fixtures.userAgent,
      id: AutomationRecord.ID(
        source: .launchAgent,
        ownerUID: 501,
        label: newLabel,
        sourcePath: sourceURL.path
      ),
      label: newLabel,
      sourceURL: sourceURL,
      sourceChecksum: editedChecksum
    )
    let disabledRecord = copyRecord(
      Fixtures.userAgent,
      sourceChecksum: sha256(sourceData),
      enabledState: .disabled,
      state: .disabled
    )
    let manifestURL = deterministicFirstManifestURL()
    let fileSystem = InMemoryAutomationFileSystem(
      files: [sourceURL: sourceData],
      partialReplaceAfterCommitOccurrences: [manifestURL: [2]]
    )
    let preState = AutomationPreTransactionState(
      sourceExisted: true,
      enabledState: Fixtures.userAgent.enabledState,
      loadState: Fixtures.userAgent.loadState,
      linkedProcesses: []
    )
    let executor = RecordingAutomationMutationExecutor(results: [
      .success(AutomationExecutorResult(
        postconditions: [.sourceInstalled, .sourceChecksum(editedChecksum)],
        evidence: []
      )),
    ] + Array(repeating: .success(AutomationExecutorResult(
      postconditions: [.futureLaunchesDisabled],
      evidence: []
    )), count: 20))
    let refreshCount = LockedCallCounter()
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      refresh: {
        switch refreshCount.incrementAndGet() {
        case 1: snapshot(records: [editedRecord])
        case 2: snapshot(records: [Fixtures.userAgent])
        default: snapshot(records: [disabledRecord])
        }
      }
    )
    let result = await manager.perform(
      .edit(AutomationEditPayload(
        label: newLabel,
        executable: "/bin/sleep",
        arguments: ["14400"],
        environment: [:],
        workingDirectory: nil,
        schedule: Fixtures.userAgent.schedule,
        rawRepresentation: editedData
      )),
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    XCTAssertEqual(
      result.status,
      .partialFailure(
        "HIGH SEVERITY: the filesystem reported a partial mutation; automatic rollback restored the prior state."
      )
    )
    XCTAssertEqual(result.rollback, .restored(try! XCTUnwrap(result.backup?.id)))
    XCTAssertEqual(result.fileMutationEvidence?.kind, .replace)
    XCTAssertNotNil(result.fileMutationEvidence?.recoveryHandle)
    XCTAssertNil(result.rollbackFileMutationEvidence)
    XCTAssertEqual(refreshCount.current(), 2)
    XCTAssertEqual(fileSystem.storedData(at: sourceURL), sourceData)
    let invocationCount = await executor.invocationCount()
    XCTAssertEqual(invocationCount, 1)
    let restorationStates = await executor.recordedRestorationStates()
    XCTAssertEqual(restorationStates, [preState])

    let restoredBackupID = try! XCTUnwrap(result.backup?.id)
    let restored = await manager.restorationManifests()
    XCTAssertTrue(restored.contains { $0.id == restoredBackupID })
    await assertLiveRecoveryInventoryMatchesRestartAfterRetentionChurn(
      manager: manager,
      fileSystem: fileSystem,
      expectedChecksum: sha256(sourceData)
    )
  }

  func testSuccessorCompensationRetentionSurvivesLaterCleanupPartial() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let sourceChecksum = sha256(sourceData)
    let newLabel = "com.example.successor-cleanup-partial"
    let editedData = validLaunchAgentData(label: newLabel)
    let editedChecksum = sha256(editedData)
    let editedRecord = copyRecord(
      Fixtures.userAgent,
      id: AutomationRecord.ID(
        source: .launchAgent,
        ownerUID: 501,
        label: newLabel,
        sourcePath: sourceURL.path
      ),
      label: newLabel,
      sourceURL: sourceURL,
      sourceChecksum: editedChecksum
    )
    let disabledRecord = copyRecord(
      Fixtures.userAgent,
      sourceChecksum: sourceChecksum,
      enabledState: .disabled,
      state: .disabled
    )
    let manifestURL = deterministicFirstManifestURL()
    let fileSystem = InMemoryAutomationFileSystem(
      files: [sourceURL: sourceData],
      partialReplaceAfterCommitOccurrences: [manifestURL: [2]],
      partialReplaceRetainsStagedOccurrences: [manifestURL: [2]],
      failStagedRemoves: true
    )
    let executor = RecordingAutomationMutationExecutor(results: [
      .success(AutomationExecutorResult(
        postconditions: [.sourceInstalled, .sourceChecksum(editedChecksum)],
        evidence: []
      )),
    ] + Array(repeating: .success(AutomationExecutorResult(
      postconditions: [.futureLaunchesDisabled],
      evidence: []
    )), count: 20))
    let refreshCount = LockedCallCounter()
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      refresh: {
        switch refreshCount.incrementAndGet() {
        case 1: snapshot(records: [editedRecord])
        case 2: snapshot(records: [Fixtures.userAgent])
        default: snapshot(records: [disabledRecord])
        }
      }
    )

    let result = await manager.perform(
      .edit(AutomationEditPayload(
        label: newLabel,
        executable: "/bin/sleep",
        arguments: ["14400"],
        environment: [:],
        workingDirectory: nil,
        schedule: Fixtures.userAgent.schedule,
        rawRepresentation: editedData
      )),
      record: Fixtures.userAgent,
      expectedChecksum: sourceChecksum,
      linkedProcesses: []
    )

    guard case .partialFailure = result.status else {
      return XCTFail("Expected partial failure, got \(result.status)")
    }
    let evidence = try! XCTUnwrap(result.fileMutationEvidence)
    let stagedRecovery = try! XCTUnwrap(evidence.recoveryHandles.first {
      $0.fileURL.lastPathComponent.hasSuffix(".tmp")
    })
    XCTAssertTrue(fileSystem.itemExists(at: stagedRecovery.fileURL))
    let restoredBackupID = try! XCTUnwrap(result.backup?.id)
    let restored = await manager.restorationManifests()
    XCTAssertTrue(restored.contains { $0.id == restoredBackupID })

    await assertLiveRecoveryInventoryMatchesRestartAfterRetentionChurn(
      manager: manager,
      fileSystem: fileSystem,
      expectedChecksum: sourceChecksum
    )
  }

  private func assertLiveRecoveryInventoryMatchesRestartAfterRetentionChurn(
    manager: AutomationManager,
    fileSystem: InMemoryAutomationFileSystem,
    expectedChecksum: String
  ) async {
    for _ in 0..<20 {
      let succeeded = await manager.perform(
        .disable,
        record: Fixtures.userAgent,
        expectedChecksum: expectedChecksum,
        linkedProcesses: []
      )
      XCTAssertEqual(succeeded.status, .succeeded)
    }
    let live = await manager.restorationManifests()
    let restarted = makeManager(
      fileSystem: fileSystem,
      executor: RecordingAutomationMutationExecutor()
    )
    let reloaded = await restarted.restorationManifests()
    XCTAssertEqual(live, reloaded)
    XCTAssertEqual(live.count, 20)
  }

  func testSuccessorRefusesFreshManifestOccupantAndReportsItAsObservationOnly() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let newLabel = "com.example.fresh-successor-collision"
    let editedData = validLaunchAgentData(label: newLabel)
    let editedChecksum = sha256(editedData)
    let editedRecord = copyRecord(
      Fixtures.userAgent,
      id: AutomationRecord.ID(
        source: .launchAgent,
        ownerUID: 501,
        label: newLabel,
        sourcePath: sourceURL.path
      ),
      label: newLabel,
      sourceURL: sourceURL,
      sourceChecksum: editedChecksum
    )
    let manifestURL = deterministicFirstManifestURL()
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let preState = AutomationPreTransactionState(
      sourceExisted: true,
      enabledState: Fixtures.userAgent.enabledState,
      loadState: Fixtures.userAgent.loadState,
      linkedProcesses: []
    )
    let executor = RecordingAutomationMutationExecutor(results: [
      .success(AutomationExecutorResult(
        postconditions: [.sourceInstalled, .sourceChecksum(editedChecksum)], evidence: []
      )),
      .success(AutomationExecutorResult(
        postconditions: [.preTransactionStateRestored(preState)], evidence: []
      )),
    ])
    let refreshCount = LockedCallCounter()
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      refresh: {
        let call = refreshCount.incrementAndGet()
        if call == 1 {
          let validPriorManifest = try! fileSystem.read(manifestURL)
          fileSystem.setStoredData(validPriorManifest, at: manifestURL)
          fileSystem.setMetadata(AutomationFileMetadata(
            canonicalURL: manifestURL,
            ownerUID: 501,
            isSymbolicLink: false,
            modificationDate: Date(timeIntervalSince1970: 9_999),
            resourceIdentifier: "fixture:fresh-manifest-occupant",
            permissions: 0o600
          ), for: manifestURL)
        }
        return call == 1
          ? snapshot(records: [editedRecord])
          : snapshot(records: [Fixtures.userAgent])
      }
    )

    let result = await manager.perform(
      .edit(AutomationEditPayload(
        label: newLabel,
        executable: "/bin/sleep",
        arguments: ["14400"],
        environment: [:],
        workingDirectory: nil,
        schedule: Fixtures.userAgent.schedule,
        rawRepresentation: editedData
      )),
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    XCTAssertEqual(
      try! fileSystem.metadata(for: manifestURL).resourceIdentifier,
      "fixture:fresh-manifest-occupant"
    )
    let evidence = try! XCTUnwrap(result.fileMutationEvidence)
    XCTAssertTrue(evidence.observedFiles.contains { $0.fileURL == manifestURL })
    XCTAssertFalse(evidence.recoveryHandles.contains { $0.fileURL == manifestURL })
    XCTAssertEqual(result.rollback, .restored(try! XCTUnwrap(result.backup?.id)))
    let live = await manager.restorationManifests()
    let restarted = makeManager(
      fileSystem: fileSystem,
      executor: RecordingAutomationMutationExecutor()
    )
    let reloaded = await restarted.restorationManifests()
    XCTAssertTrue(live.isEmpty)
    XCTAssertEqual(reloaded.count, 1)
    XCTAssertEqual(reloaded.first?.id, result.backup?.id)
    XCTAssertEqual(fileSystem.recordedOperations.filter { operation in
      guard case .replace(let destination, _) = operation else { return false }
      return destination == manifestURL
    }.count, 1)
  }

  func testSuccessorRefusesMissingManifestWithoutRecreatingItFromAmbientState() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let newLabel = "com.example.missing-successor-manifest"
    let editedData = validLaunchAgentData(label: newLabel)
    let editedChecksum = sha256(editedData)
    let editedRecord = copyRecord(
      Fixtures.userAgent,
      id: AutomationRecord.ID(
        source: .launchAgent,
        ownerUID: 501,
        label: newLabel,
        sourcePath: sourceURL.path
      ),
      label: newLabel,
      sourceURL: sourceURL,
      sourceChecksum: editedChecksum
    )
    let manifestURL = deterministicFirstManifestURL()
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let preState = AutomationPreTransactionState(
      sourceExisted: true,
      enabledState: Fixtures.userAgent.enabledState,
      loadState: Fixtures.userAgent.loadState,
      linkedProcesses: []
    )
    let executor = RecordingAutomationMutationExecutor(results: [
      .success(AutomationExecutorResult(
        postconditions: [.sourceInstalled, .sourceChecksum(editedChecksum)], evidence: []
      )),
      .success(AutomationExecutorResult(
        postconditions: [.preTransactionStateRestored(preState)], evidence: []
      )),
    ])
    let refreshCount = LockedCallCounter()
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      refresh: {
        let call = refreshCount.incrementAndGet()
        if call == 1 {
          let rootURL = manifestURL.deletingLastPathComponent()
          let root = try! XCTUnwrap(AutomationDirectoryAuthorization(
            directoryURL: rootURL,
            resourceIdentifier: try! fileSystem.metadata(for: rootURL).resourceIdentifier
          ))
          let manifest = try! XCTUnwrap(AutomationFileAuthorization(
            fileURL: manifestURL,
            directory: root,
            expectation: .existing(resourceIdentifier: try! XCTUnwrap(
              try! fileSystem.metadata(for: manifestURL).resourceIdentifier
            ))
          ))
          _ = try! fileSystem.removeItem(manifest)
        }
        return call == 1 ? snapshot(records: [editedRecord]) : snapshot(records: [Fixtures.userAgent])
      }
    )

    let result = await manager.perform(
      .edit(AutomationEditPayload(
        label: newLabel,
        executable: "/bin/sleep",
        arguments: ["14400"],
        environment: [:],
        workingDirectory: nil,
        schedule: Fixtures.userAgent.schedule,
        rawRepresentation: editedData
      )),
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    XCTAssertFalse(fileSystem.itemExists(at: manifestURL))
    let evidence = try! XCTUnwrap(result.fileMutationEvidence)
    XCTAssertFalse(evidence.observedFiles.contains { $0.fileURL == manifestURL })
    XCTAssertFalse(evidence.recoveryHandles.contains { $0.fileURL == manifestURL })
    XCTAssertEqual(result.rollback, .restored(try! XCTUnwrap(result.backup?.id)))
    let live = await manager.restorationManifests()
    let restarted = makeManager(
      fileSystem: fileSystem,
      executor: RecordingAutomationMutationExecutor()
    )
    let reloaded = await restarted.restorationManifests()
    XCTAssertEqual(live, reloaded)
    XCTAssertTrue(live.isEmpty)
  }

  func testSuccessorDoesNotPromoteFreshValidManifestAndBackupPairDuringLiveReconcile() async {
    await assertValidRecoveryAuthorityReplacementIsQuarantined(replaceRoot: false)
  }

  func testSuccessorDoesNotPromoteRecoveryPairFromReplacedRootDuringLiveReconcile() async {
    await assertValidRecoveryAuthorityReplacementIsQuarantined(replaceRoot: true)
  }

  private func assertValidRecoveryAuthorityReplacementIsQuarantined(
    replaceRoot: Bool
  ) async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let newLabel = replaceRoot
      ? "com.example.replaced-recovery-root" : "com.example.fresh-recovery-pair"
    let editedData = validLaunchAgentData(label: newLabel)
    let editedChecksum = sha256(editedData)
    let editedRecord = copyRecord(
      Fixtures.userAgent,
      id: AutomationRecord.ID(
        source: .launchAgent,
        ownerUID: 501,
        label: newLabel,
        sourcePath: sourceURL.path
      ),
      label: newLabel,
      sourceURL: sourceURL,
      sourceChecksum: editedChecksum
    )
    let manifestURL = deterministicFirstManifestURL()
    let backupURL = deterministicFirstBackupURL()
    let recoveryRoot = manifestURL.deletingLastPathComponent()
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let executor = RecordingAutomationMutationExecutor(results: [
      .success(AutomationExecutorResult(
        postconditions: [.sourceInstalled, .sourceChecksum(editedChecksum)], evidence: []
      )),
    ])
    let refreshCount = LockedCallCounter()
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      refresh: {
        let call = refreshCount.incrementAndGet()
        if call == 1 {
          if replaceRoot {
            fileSystem.setMetadata(AutomationFileMetadata(
              canonicalURL: recoveryRoot,
              ownerUID: 501,
              isSymbolicLink: false,
              modificationDate: Date(timeIntervalSince1970: 9_999),
              resourceIdentifier: "fixture:fresh-recovery-root",
              permissions: 0o700
            ), for: recoveryRoot)
          } else {
            for (url, identity) in [
              (manifestURL, "fixture:fresh-valid-manifest"),
              (backupURL, "fixture:fresh-valid-backup"),
            ] {
              let validBytes = try! fileSystem.read(url)
              fileSystem.setStoredData(validBytes, at: url)
              fileSystem.setMetadata(AutomationFileMetadata(
                canonicalURL: url,
                ownerUID: 501,
                isSymbolicLink: false,
                modificationDate: Date(timeIntervalSince1970: 9_999),
                resourceIdentifier: identity,
                permissions: 0o600
              ), for: url)
            }
          }
        }
        return call == 1 ? snapshot(records: [editedRecord]) : snapshot(records: [Fixtures.userAgent])
      }
    )

    let result = await manager.perform(
      .edit(AutomationEditPayload(
        label: newLabel,
        executable: "/bin/sleep",
        arguments: ["14400"],
        environment: [:],
        workingDirectory: nil,
        schedule: Fixtures.userAgent.schedule,
        rawRepresentation: editedData
      )),
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    let evidence = try! XCTUnwrap(result.fileMutationEvidence)
    XCTAssertTrue(evidence.observedFiles.contains { $0.fileURL == manifestURL })
    XCTAssertTrue(evidence.observedFiles.contains { $0.fileURL == backupURL })
    XCTAssertFalse(evidence.recoveryHandles.contains { $0.fileURL == manifestURL })
    XCTAssertFalse(evidence.recoveryHandles.contains { $0.fileURL == backupURL })
    XCTAssertEqual(fileSystem.storedData(at: backupURL), sourceData)
    XCTAssertNotNil(try? PropertyListSerialization.propertyList(
      from: try! XCTUnwrap(fileSystem.storedData(at: manifestURL)),
      options: [],
      format: nil
    ))
    XCTAssertEqual(fileSystem.recordedOperations.filter { operation in
      guard case .replace(let destination, _) = operation else { return false }
      return destination == manifestURL
    }.count, 1)
    XCTAssertEqual(fileSystem.recordedOperations.filter { operation in
      guard case .replace(let destination, _) = operation else { return false }
      return destination == backupURL
    }.count, 1)
    if replaceRoot {
      XCTAssertEqual(
        try! fileSystem.metadata(for: recoveryRoot).resourceIdentifier,
        "fixture:fresh-recovery-root"
      )
    } else {
      XCTAssertEqual(
        try! fileSystem.metadata(for: manifestURL).resourceIdentifier,
        "fixture:fresh-valid-manifest"
      )
      XCTAssertEqual(
        try! fileSystem.metadata(for: backupURL).resourceIdentifier,
        "fixture:fresh-valid-backup"
      )
    }
    let live = await manager.restorationManifests()
    XCTAssertTrue(live.isEmpty)
    let restarted = makeManager(
      fileSystem: fileSystem,
      executor: RecordingAutomationMutationExecutor()
    )
    let reloaded = await restarted.restorationManifests()
    XCTAssertEqual(reloaded.count, 1)
    XCTAssertEqual(reloaded.first?.id, result.backup?.id)
  }

  func testSuccessorRevalidatesBackupAfterManifestCommitBeforePublishingMaps() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let newLabel = "com.example.backup-toctou"
    let editedData = validLaunchAgentData(label: newLabel)
    let editedChecksum = sha256(editedData)
    let editedRecord = copyRecord(
      Fixtures.userAgent,
      id: AutomationRecord.ID(
        source: .launchAgent,
        ownerUID: 501,
        label: newLabel,
        sourcePath: sourceURL.path
      ),
      label: newLabel,
      sourceURL: sourceURL,
      sourceChecksum: editedChecksum
    )
    let backupURL = deterministicFirstBackupURL()
    let manifestURL = deterministicFirstManifestURL()
    let attackerData = Data("attacker-backup-after-final-preflight".utf8)
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let backupReads = LockedCallCounter()
    fileSystem.setReadObserver { url, _ in
      guard url == backupURL, backupReads.incrementAndGet() == 3 else { return }
      fileSystem.setStoredData(attackerData, at: backupURL)
      fileSystem.setMetadata(AutomationFileMetadata(
        canonicalURL: backupURL,
        ownerUID: 501,
        isSymbolicLink: false,
        modificationDate: Date(timeIntervalSince1970: 20_000),
        resourceIdentifier: "fixture:attacker-backup-after-preflight",
        permissions: 0o600
      ), for: backupURL)
    }
    let preState = AutomationPreTransactionState(
      sourceExisted: true,
      enabledState: Fixtures.userAgent.enabledState,
      loadState: Fixtures.userAgent.loadState,
      linkedProcesses: []
    )
    let executor = RecordingAutomationMutationExecutor(results: [
      .success(AutomationExecutorResult(
        postconditions: [.sourceInstalled, .sourceChecksum(editedChecksum)], evidence: []
      )),
      .success(AutomationExecutorResult(
        postconditions: [.preTransactionStateRestored(preState)], evidence: []
      )),
    ])
    let refreshes = LockedCallCounter()
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      refresh: {
        refreshes.incrementAndGet() == 1
          ? snapshot(records: [editedRecord]) : snapshot(records: [Fixtures.userAgent])
      }
    )

    let result = await manager.perform(
      .edit(AutomationEditPayload(
        label: newLabel,
        executable: "/bin/sleep",
        arguments: ["14400"],
        environment: [:],
        workingDirectory: nil,
        schedule: Fixtures.userAgent.schedule,
        rawRepresentation: editedData
      )),
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    XCTAssertNotEqual(result.status, .succeeded)
    XCTAssertEqual(fileSystem.storedData(at: backupURL), attackerData)
    XCTAssertFalse(fileSystem.recordedOperations.contains { operation in
      guard case .remove(let removedURL) = operation else { return false }
      return removedURL == backupURL
    })
    let evidence = result.fileMutationEvidence
    XCTAssertNotNil(evidence)
    XCTAssertTrue(evidence?.observedFiles.contains { $0.fileURL == backupURL } == true)
    XCTAssertFalse(evidence?.recoveryHandles.contains { $0.fileURL == backupURL } == true)
    let restoredManifest = try! XCTUnwrap(fileSystem.storedData(at: manifestURL))
    let plist = try! XCTUnwrap(
      PropertyListSerialization.propertyList(from: restoredManifest, format: nil)
        as? [String: Any]
    )
    XCTAssertEqual(
      plist["authorizedRecordIDs"] as? [String],
      [Fixtures.userAgent.id.rawValue]
    )
    let live = await manager.restorationManifests()
    let restarted = makeManager(
      fileSystem: fileSystem,
      executor: RecordingAutomationMutationExecutor()
    )
    let reloaded = await restarted.restorationManifests()
    XCTAssertEqual(live, reloaded)
    XCTAssertTrue(live.isEmpty)
  }

  func testSuccessorRechecksBackupIdentityAfterFinalContentVerification() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let newLabel = "com.example.backup-identity-toctou"
    let editedData = validLaunchAgentData(label: newLabel)
    let editedChecksum = sha256(editedData)
    let editedRecord = copyRecord(
      Fixtures.userAgent,
      id: AutomationRecord.ID(
        source: .launchAgent,
        ownerUID: 501,
        label: newLabel,
        sourcePath: sourceURL.path
      ),
      label: newLabel,
      sourceURL: sourceURL,
      sourceChecksum: editedChecksum
    )
    let backupURL = deterministicFirstBackupURL()
    let manifestURL = deterministicFirstManifestURL()
    let replacementIdentity = "fixture:same-byte-backup-after-final-read"
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let backupReads = LockedCallCounter()
    fileSystem.setReadObserver { url, _ in
      guard url == backupURL, backupReads.incrementAndGet() == 4 else { return }
      fileSystem.setStoredData(sourceData, at: backupURL)
      fileSystem.setMetadata(AutomationFileMetadata(
        canonicalURL: backupURL,
        ownerUID: 501,
        isSymbolicLink: false,
        modificationDate: Date(timeIntervalSince1970: 30_000),
        resourceIdentifier: replacementIdentity,
        permissions: 0o600
      ), for: backupURL)
    }
    let preState = AutomationPreTransactionState(
      sourceExisted: true,
      enabledState: Fixtures.userAgent.enabledState,
      loadState: Fixtures.userAgent.loadState,
      linkedProcesses: []
    )
    let executor = RecordingAutomationMutationExecutor(results: [
      .success(AutomationExecutorResult(
        postconditions: [.sourceInstalled, .sourceChecksum(editedChecksum)], evidence: []
      )),
      .success(AutomationExecutorResult(
        postconditions: [.preTransactionStateRestored(preState)], evidence: []
      )),
    ])
    let refreshes = LockedCallCounter()
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      refresh: {
        refreshes.incrementAndGet() == 1
          ? snapshot(records: [editedRecord]) : snapshot(records: [Fixtures.userAgent])
      }
    )

    let result = await manager.perform(
      .edit(AutomationEditPayload(
        label: newLabel,
        executable: "/bin/sleep",
        arguments: ["14400"],
        environment: [:],
        workingDirectory: nil,
        schedule: Fixtures.userAgent.schedule,
        rawRepresentation: editedData
      )),
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    XCTAssertNotEqual(result.status, .succeeded)
    XCTAssertEqual(fileSystem.storedData(at: backupURL), sourceData)
    XCTAssertEqual(
      try! fileSystem.metadata(for: backupURL).resourceIdentifier,
      replacementIdentity
    )
    XCTAssertFalse(fileSystem.recordedOperations.contains { operation in
      guard case .remove(let removedURL) = operation else { return false }
      return removedURL == backupURL
    })
    let evidence = result.fileMutationEvidence
    XCTAssertNotNil(evidence)
    XCTAssertTrue(evidence?.observedFiles.contains { $0.fileURL == backupURL } == true)
    XCTAssertFalse(evidence?.recoveryHandles.contains { $0.fileURL == backupURL } == true)
    let restoredManifest = try! XCTUnwrap(fileSystem.storedData(at: manifestURL))
    let plist = try! XCTUnwrap(
      PropertyListSerialization.propertyList(from: restoredManifest, format: nil)
        as? [String: Any]
    )
    XCTAssertEqual(
      plist["authorizedRecordIDs"] as? [String],
      [Fixtures.userAgent.id.rawValue]
    )
    let live = await manager.restorationManifests()
    XCTAssertTrue(live.isEmpty)
    let restarted = makeManager(
      fileSystem: fileSystem,
      executor: RecordingAutomationMutationExecutor()
    )
    let reloaded = await restarted.restorationManifests()
    XCTAssertEqual(reloaded.count, 1)
    XCTAssertEqual(reloaded.first?.id, result.backup?.id)
  }

  func testSuccessorRechecksInstalledManifestIdentityAfterFinalRead() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let newLabel = "com.example.manifest-identity-toctou"
    let editedData = validLaunchAgentData(label: newLabel)
    let editedChecksum = sha256(editedData)
    let editedRecord = copyRecord(
      Fixtures.userAgent,
      id: AutomationRecord.ID(
        source: .launchAgent,
        ownerUID: 501,
        label: newLabel,
        sourcePath: sourceURL.path
      ),
      label: newLabel,
      sourceURL: sourceURL,
      sourceChecksum: editedChecksum
    )
    let manifestURL = deterministicFirstManifestURL()
    let replacementIdentity = "fixture:same-byte-manifest-after-final-read"
    let replacementBytes = LockedDataCapture()
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let manifestReads = LockedCallCounter()
    fileSystem.setReadObserver { url, data in
      guard url == manifestURL, manifestReads.incrementAndGet() == 3 else { return }
      replacementBytes.set(data)
      fileSystem.setStoredData(data, at: manifestURL)
      fileSystem.setMetadata(AutomationFileMetadata(
        canonicalURL: manifestURL,
        ownerUID: 501,
        isSymbolicLink: false,
        modificationDate: Date(timeIntervalSince1970: 40_000),
        resourceIdentifier: replacementIdentity,
        permissions: 0o600
      ), for: manifestURL)
    }
    let preState = AutomationPreTransactionState(
      sourceExisted: true,
      enabledState: Fixtures.userAgent.enabledState,
      loadState: Fixtures.userAgent.loadState,
      linkedProcesses: []
    )
    let executor = RecordingAutomationMutationExecutor(results: [
      .success(AutomationExecutorResult(
        postconditions: [.sourceInstalled, .sourceChecksum(editedChecksum)], evidence: []
      )),
      .success(AutomationExecutorResult(
        postconditions: [.preTransactionStateRestored(preState)], evidence: []
      )),
    ])
    let refreshes = LockedCallCounter()
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      refresh: {
        refreshes.incrementAndGet() == 1
          ? snapshot(records: [editedRecord]) : snapshot(records: [Fixtures.userAgent])
      }
    )

    let result = await manager.perform(
      .edit(AutomationEditPayload(
        label: newLabel,
        executable: "/bin/sleep",
        arguments: ["14400"],
        environment: [:],
        workingDirectory: nil,
        schedule: Fixtures.userAgent.schedule,
        rawRepresentation: editedData
      )),
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    XCTAssertNotEqual(result.status, .succeeded)
    XCTAssertEqual(fileSystem.storedData(at: manifestURL), replacementBytes.current())
    XCTAssertEqual(
      try! fileSystem.metadata(for: manifestURL).resourceIdentifier,
      replacementIdentity
    )
    XCTAssertFalse(fileSystem.recordedOperations.contains { operation in
      guard case .remove(let removedURL) = operation else { return false }
      return removedURL == manifestURL
    })
    let evidence = result.fileMutationEvidence
    XCTAssertNotNil(evidence)
    XCTAssertTrue(evidence?.observedFiles.contains { $0.fileURL == manifestURL } == true)
    XCTAssertFalse(evidence?.recoveryHandles.contains { $0.fileURL == manifestURL } == true)
    let plist = try! XCTUnwrap(
      PropertyListSerialization.propertyList(
        from: try! XCTUnwrap(fileSystem.storedData(at: manifestURL)),
        format: nil
      ) as? [String: Any]
    )
    XCTAssertEqual(
      plist["authorizedRecordIDs"] as? [String],
      [Fixtures.userAgent.id.rawValue, editedRecord.id.rawValue].sorted()
    )
    let live = await manager.restorationManifests()
    XCTAssertTrue(live.isEmpty)
    let restarted = makeManager(
      fileSystem: fileSystem,
      executor: RecordingAutomationMutationExecutor()
    )
    let reloaded = await restarted.restorationManifests()
    XCTAssertEqual(reloaded.count, 1)
    XCTAssertEqual(reloaded.first?.id, result.backup?.id)
  }

  func testSuccessorManifestPostverificationFailureRestoresPriorManifest() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let newLabel = "com.example.corrupt-successor"
    let editedData = validLaunchAgentData(label: newLabel)
    let editedChecksum = sha256(editedData)
    let editedRecord = copyRecord(
      Fixtures.userAgent,
      id: AutomationRecord.ID(
        source: .launchAgent,
        ownerUID: 501,
        label: newLabel,
        sourcePath: sourceURL.path
      ),
      label: newLabel,
      sourceURL: sourceURL,
      sourceChecksum: editedChecksum
    )
    let disabledRecord = copyRecord(
      Fixtures.userAgent,
      sourceChecksum: sha256(sourceData),
      enabledState: .disabled,
      state: .disabled
    )
    let manifestURL = deterministicFirstManifestURL()
    let fileSystem = InMemoryAutomationFileSystem(
      files: [sourceURL: sourceData],
      dataAfterReplaceOccurrences: [manifestURL: [2: Data("corrupt".utf8)]]
    )
    let executor = RecordingAutomationMutationExecutor(results: [
      .success(AutomationExecutorResult(
        postconditions: [.sourceInstalled, .sourceChecksum(editedChecksum)], evidence: []
      )),
    ] + Array(repeating: .success(AutomationExecutorResult(
      postconditions: [.futureLaunchesDisabled],
      evidence: []
    )), count: 20))
    let refreshCount = LockedCallCounter()
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      refresh: {
        switch refreshCount.incrementAndGet() {
        case 1: snapshot(records: [editedRecord])
        case 2: snapshot(records: [Fixtures.userAgent])
        default: snapshot(records: [disabledRecord])
        }
      }
    )
    let result = await manager.perform(
      .edit(AutomationEditPayload(
        label: newLabel,
        executable: "/bin/sleep",
        arguments: ["14400"],
        environment: [:],
        workingDirectory: nil,
        schedule: Fixtures.userAgent.schedule,
        rawRepresentation: editedData
      )),
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    guard case .partialFailure = result.status else {
      return XCTFail("Expected partial failure, got \(result.status)")
    }
    XCTAssertEqual(result.rollback, .restored(try! XCTUnwrap(result.backup?.id)))
    XCTAssertEqual(result.fileMutationEvidence?.kind, .replace)
    XCTAssertNil(result.rollbackFileMutationEvidence)
    XCTAssertEqual(refreshCount.current(), 2)
    XCTAssertEqual(fileSystem.storedData(at: sourceURL), sourceData)
    let restoredBackupID = try! XCTUnwrap(result.backup?.id)
    let restored = await manager.restorationManifests()
    XCTAssertTrue(restored.contains { $0.id == restoredBackupID })
    await assertLiveRecoveryInventoryMatchesRestartAfterRetentionChurn(
      manager: manager,
      fileSystem: fileSystem,
      expectedChecksum: sha256(sourceData)
    )
  }

  func testSuccessorCompensationAndSourceRollbackPartialsRemainSeparatelyVisible() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let newLabel = "com.example.aggregate-successor"
    let editedData = validLaunchAgentData(label: newLabel)
    let editedChecksum = sha256(editedData)
    let editedRecord = copyRecord(
      Fixtures.userAgent,
      id: AutomationRecord.ID(
        source: .launchAgent,
        ownerUID: 501,
        label: newLabel,
        sourcePath: sourceURL.path
      ),
      label: newLabel,
      sourceURL: sourceURL,
      sourceChecksum: editedChecksum
    )
    let manifestURL = deterministicFirstManifestURL()
    let fileSystem = InMemoryAutomationFileSystem(
      files: [sourceURL: sourceData],
      dataAfterReplaceOccurrences: [manifestURL: [2: Data("corrupt".utf8)]],
      partialReplaceAfterCommitOccurrences: [
        manifestURL: [3],
        sourceURL: [2],
      ]
    )
    let executor = RecordingAutomationMutationExecutor(results: [
      .success(AutomationExecutorResult(
        postconditions: [.sourceInstalled, .sourceChecksum(editedChecksum)], evidence: []
      )),
    ])
    let refreshCount = LockedCallCounter()
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      refresh: {
        _ = refreshCount.incrementAndGet()
        return snapshot(records: [editedRecord])
      }
    )
    let result = await manager.perform(
      .edit(AutomationEditPayload(
        label: newLabel,
        executable: "/bin/sleep",
        arguments: ["14400"],
        environment: [:],
        workingDirectory: nil,
        schedule: Fixtures.userAgent.schedule,
        rawRepresentation: editedData
      )),
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    XCTAssertEqual(
      result.status,
      .partialFailure(
        "HIGH SEVERITY: the operation failed and automatic rollback reached a partial filesystem state."
      )
    )
    XCTAssertEqual(result.rollback, .failed("Automatic rollback did not complete."))
    let manifestEvidence = try! XCTUnwrap(result.fileMutationEvidence)
    let rollbackEvidence = try! XCTUnwrap(result.rollbackFileMutationEvidence)
    XCTAssertEqual(manifestEvidence.resultURL, manifestURL)
    XCTAssertGreaterThanOrEqual(manifestEvidence.recoveryHandles.count, 1)
    XCTAssertEqual(rollbackEvidence.resultURL, sourceURL)
    XCTAssertGreaterThanOrEqual(rollbackEvidence.recoveryHandles.count, 1)
    XCTAssertEqual(refreshCount.current(), 2)
    for evidence in [manifestEvidence, rollbackEvidence] {
      for recovery in evidence.recoveryHandles {
        XCTAssertTrue(fileSystem.itemExists(at: recovery.fileURL))
        guard case .existing(let expectedIdentity) = recovery.expectation else {
          return XCTFail("Recovery handle must bind an existing exact entry.")
        }
        XCTAssertEqual(
          try! fileSystem.metadata(for: recovery.fileURL).resourceIdentifier,
          expectedIdentity
        )
      }
    }
    let restarted = makeManager(
      fileSystem: fileSystem,
      executor: RecordingAutomationMutationExecutor()
    )
    let manifests = await restarted.restorationManifests()
    XCTAssertEqual(manifests.first?.authorizedRecordIDs, [Fixtures.userAgent.id])
  }

  func testExternalEditDuringExecutorSuspensionIsNeverOverwrittenByRollback() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let editedData = validLaunchAgentData(arguments: ["7200"])
    let externalData = validLaunchAgentData(arguments: ["3600"])
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let executor = RecordingAutomationMutationExecutor(
      results: [.failure(.applyFailed)],
      onApply: { fileSystem.setStoredData(externalData, at: sourceURL) }
    )
    let manager = makeManager(fileSystem: fileSystem, executor: executor)
    let payload = AutomationEditPayload(
      label: Fixtures.userAgent.label,
      executable: "/bin/sleep",
      arguments: ["7200"],
      environment: [:],
      workingDirectory: nil,
      schedule: Fixtures.userAgent.schedule,
      rawRepresentation: editedData
    )

    let result = await manager.perform(
      .edit(payload),
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    XCTAssertEqual(
      result.status,
      .partialFailure("HIGH SEVERITY: the operation failed and automatic rollback did not complete.")
    )
    XCTAssertEqual(fileSystem.storedData(at: sourceURL), externalData)
  }

  func testRollbackRefusesWhenDestinationAuthorizationChangesDuringExecutorAwait() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let editedData = validLaunchAgentData(arguments: ["7200"])
    let authorizationRevoked = LockedFlag()
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let executor = RecordingAutomationMutationExecutor(
      results: [.failure(.applyFailed)],
      onApply: { authorizationRevoked.set() }
    )
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      destinationContext: { _, _ in
        .fixture(
          currentUID: 501,
          canonicalPathIsApproved: !authorizationRevoked.value,
          ownerUID: 501
        )
      }
    )

    let result = await manager.perform(
      .edit(AutomationEditPayload(
        label: Fixtures.userAgent.label,
        executable: "/bin/sleep",
        arguments: ["7200"],
        environment: [:],
        workingDirectory: nil,
        schedule: Fixtures.userAgent.schedule,
        rawRepresentation: editedData
      )),
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    XCTAssertEqual(
      result.status,
      .partialFailure("HIGH SEVERITY: the operation failed and automatic rollback did not complete.")
    )
    XCTAssertEqual(fileSystem.storedData(at: sourceURL), editedData)
  }

  func testStopAndCompoundStopRequireRefreshedBirthAndRelaunchProof() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let originalBirth = ProcessBirthToken(seconds: 1_000, microseconds: 1)
    let relaunchedBirth = ProcessBirthToken(seconds: 2_000, microseconds: 2)
    let controlled = classifiedAutomationProcess(pid: 700, birth: originalBirth)
    let relaunched = classifiedAutomationProcess(pid: 701, birth: relaunchedBirth)

    for operation in [AutomationOperation.stopCurrentRun, .disableAndStop] {
      let refreshedRecord = operation == .disableAndStop
        ? copyRecord(Fixtures.userAgent, enabledState: .disabled, state: .disabled)
        : Fixtures.userAgent
      let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
      let manager = makeManager(
        fileSystem: fileSystem,
        executor: RecordingAutomationMutationExecutor(results: [
          .success(AutomationExecutorResult(
            postconditions: operation == .disableAndStop
              ? [.futureLaunchesDisabled, .noLinkedProcess]
              : [.noLinkedProcess],
            evidence: []
          )),
        ]),
        refresh: { snapshot(records: [refreshedRecord]) },
        refreshProcesses: { [relaunched.process] }
      )

      let result = await manager.perform(
        operation,
        record: Fixtures.userAgent,
        expectedChecksum: sha256(sourceData),
        linkedProcesses: [controlled]
      )
      XCTAssertNotEqual(result.status, .succeeded)
      XCTAssertTrue(result.verificationEvidence.contains {
        $0.contains("controlled or relaunched process")
      })
    }
  }

  func testStopRejectsStrongBirthlessRelaunchCandidate() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let controlled = classifiedAutomationProcess(
      pid: 700,
      birth: ProcessBirthToken(seconds: 1_000, microseconds: 1)
    )
    let birthless = DevProcess(
      pid: 701,
      parentPID: 1,
      executable: "/bin/sleep",
      command: "/bin/sleep 14400",
      argumentVector: ["/bin/sleep", "14400"],
      birthToken: nil,
      launchLabel: Fixtures.userAgent.label
    )
    let manager = makeManager(
      fileSystem: InMemoryAutomationFileSystem(files: [sourceURL: sourceData]),
      executor: RecordingAutomationMutationExecutor(results: [
        .success(AutomationExecutorResult(postconditions: [.noLinkedProcess], evidence: [])),
      ]),
      refreshProcesses: { [birthless] }
    )

    let result = await manager.perform(
      .stopCurrentRun,
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: [controlled]
    )

    XCTAssertNotEqual(result.status, .succeeded)
    XCTAssertTrue(result.verificationEvidence.contains { $0.contains("relaunched process") })
  }

  func testStopFailsClosedWhenLiveProcessVerificationIsUnavailable() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let controlled = classifiedAutomationProcess(
      pid: 700,
      birth: ProcessBirthToken(seconds: 1_000, microseconds: 1)
    )
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: RecordingAutomationMutationExecutor(results: [
        .success(AutomationExecutorResult(
          postconditions: [.noLinkedProcess],
          evidence: []
        )),
      ]),
      refreshProcesses: {
        throw AutomationManagerConfigurationError.runtimeProcessVerificationUnavailable
      }
    )

    let result = await manager.perform(
      .stopCurrentRun,
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: [controlled]
    )

    XCTAssertNotEqual(result.status, .succeeded)
    XCTAssertTrue(result.verificationEvidence.contains {
      $0.contains("Live process verification was unavailable")
    })
  }

  func testDurableManifestReloadsInANewManager() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let checksum = sha256(sourceData)
    let disabledRecord = copyRecord(
      Fixtures.userAgent,
      sourceChecksum: checksum,
      enabledState: .disabled,
      state: .disabled
    )
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let success = AutomationExecutorResult(
      postconditions: [.futureLaunchesDisabled],
      evidence: []
    )
    let first = makeManager(
      fileSystem: fileSystem,
      executor: RecordingAutomationMutationExecutor(results: [.success(success)]),
      refresh: { snapshot(records: [disabledRecord]) }
    )
    let result = await first.perform(
      .disable,
      record: Fixtures.userAgent,
      expectedChecksum: checksum,
      linkedProcesses: []
    )
    let second = makeManager(
      fileSystem: fileSystem,
      executor: RecordingAutomationMutationExecutor()
    )

    let manifests = await second.restorationManifests()
    XCTAssertEqual(manifests.map(\.id), [try! XCTUnwrap(result.backup?.id)])
    XCTAssertEqual(manifests.first?.backupURL.path, "/redacted")
  }

  func testSourceLessCronCanUseRecoverableTransactionIdentity() async {
    let transactionURL = URL(fileURLWithPath: "/tmp/devscope-fixtures/current-crontab")
    let data = Data("0 9 * * 1 /bin/sleep 1\n".utf8)
    let checksum = sha256(data)
    let fileSystem = InMemoryAutomationFileSystem(files: [transactionURL: data])
    let metadata = try! fileSystem.metadata(for: transactionURL)
    let cron = AutomationRecord(
      id: AutomationRecord.ID(
        source: .crontab,
        ownerUID: 501,
        label: "cron-entry",
        sourcePath: "/.devscope/current-user-crontab/test"
      ),
      kind: .cron,
      sourceKind: .crontab,
      label: "Cron entry 1",
      displayName: "Cron entry 1",
      providerBundleIdentifier: nil,
      ownerUID: 501,
      ownership: .user,
      executable: nil,
      arguments: [],
      commandSignature: "/bin/sleep 1",
      environment: [:],
      workingDirectory: nil,
      schedule: AutomationSchedule(triggers: [.cron("0 9 * * 1")], summary: "Cron"),
      sourceURL: nil,
      sourceChecksum: checksum,
      enabledState: .enabled,
      loadState: .unknown,
      approvalState: .notApplicable,
      state: .idle,
      evidence: [],
      capabilities: [.exportRecord],
      validationFindings: []
    )
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: RecordingAutomationMutationExecutor(results: [
        .success(AutomationExecutorResult(postconditions: [.targetResolved], evidence: [])),
      ]),
      context: .fixture(
        currentUID: 501,
        canonicalPathIsApproved: true,
        ownerUID: 501,
        implementedCapabilities: [.exportRecord]
      ),
      recoverableSource: { _ in
        AutomationRecoverableSource(
          transactionURL: transactionURL,
          data: data,
          checksum: checksum,
          metadata: metadata
        )
      }
    )

    let result = await manager.perform(
      .exportRecord(redacted: true),
      record: cron,
      expectedChecksum: checksum,
      linkedProcesses: []
    )

    XCTAssertEqual(result.status, .succeeded)
  }

  func testPartialRecoverableTransactionSourceIsNeverDowngradedToPreflightRejection() async {
    let transactionURL = URL(fileURLWithPath: "/tmp/devscope-fixtures/partial-crontab")
    let data = Data("0 9 * * 1 /bin/sleep 1\n".utf8)
    let checksum = sha256(data)
    let entry = try! XCTUnwrap(CronParser.parse(String(decoding: data, as: UTF8.self)).entries.first)
    let cron = cronRecord(entry: entry, checksum: checksum)
    let fileSystem = InMemoryAutomationFileSystem(
      directories: [transactionURL.deletingLastPathComponent()]
    )
    let executor = RecordingAutomationMutationExecutor()
    let refreshCount = LockedCallCounter()
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      context: .fixture(currentUID: 501, canonicalPathIsApproved: true, ownerUID: 501),
      recoverableSource: { _ in
        fileSystem.setStoredData(data, at: transactionURL)
        let directoryMetadata = try fileSystem.metadata(
          for: transactionURL.deletingLastPathComponent()
        )
        let directory = try XCTUnwrap(AutomationDirectoryAuthorization(
          directoryURL: transactionURL.deletingLastPathComponent(),
          resourceIdentifier: directoryMetadata.resourceIdentifier
        ))
        let metadata = try fileSystem.metadata(for: transactionURL)
        let recovery = try XCTUnwrap(AutomationFileAuthorization(
          fileURL: transactionURL,
          directory: directory,
          expectation: .existing(resourceIdentifier: try XCTUnwrap(metadata.resourceIdentifier))
        ))
        throw AutomationFilePartialMutation(
          kind: .replace,
          commitState: .committed,
          observedFiles: [recovery],
          recoveryHandle: recovery,
          resultURL: transactionURL
        )
      },
      refresh: {
        _ = refreshCount.incrementAndGet()
        return Fixtures.inventoryGeneration7
      }
    )

    let result = await manager.perform(
      .disable,
      record: cron,
      expectedChecksum: checksum,
      linkedProcesses: []
    )

    XCTAssertEqual(
      result.status,
      .partialFailure("HIGH SEVERITY: recoverable source materialization reached a partial filesystem state.")
    )
    XCTAssertEqual(result.fileMutationEvidence?.recoveryHandle?.fileURL, transactionURL)
    XCTAssertEqual(result.fileMutationEvidence?.commitState, .committed)
    XCTAssertEqual(refreshCount.current(), 1)
    XCTAssertEqual(fileSystem.storedData(at: transactionURL), data)
    let invocationCount = await executor.invocationCount()
    XCTAssertEqual(invocationCount, 0)
  }

  func testSecondRecoverableSourcePartialPreservesEvidenceRefreshesAndSkipsExecutor() async {
    let transactionURL = URL(fileURLWithPath: "/tmp/devscope-fixtures/second-partial-crontab")
    let initial = Data("0 9 * * 1 /bin/sleep 1\n".utf8)
    let materialized = Data("0 10 * * 1 /bin/sleep 2\n".utf8)
    let checksum = sha256(initial)
    let entry = try! XCTUnwrap(
      CronParser.parse(String(decoding: initial, as: UTF8.self)).entries.first
    )
    let cron = cronRecord(entry: entry, checksum: checksum)
    let fileSystem = InMemoryAutomationFileSystem(files: [transactionURL: initial])
    let executor = RecordingAutomationMutationExecutor()
    let sourceCalls = LockedCallCounter()
    let refreshCount = LockedCallCounter()
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      context: .fixture(currentUID: 501, canonicalPathIsApproved: true, ownerUID: 501),
      recoverableSource: { _ in
        if sourceCalls.incrementAndGet() == 1 {
          return AutomationRecoverableSource(
            transactionURL: transactionURL,
            data: initial,
            checksum: checksum,
            metadata: try fileSystem.metadata(for: transactionURL)
          )
        }
        fileSystem.setStoredData(materialized, at: transactionURL)
        let directoryMetadata = try fileSystem.metadata(
          for: transactionURL.deletingLastPathComponent()
        )
        let directory = try XCTUnwrap(AutomationDirectoryAuthorization(
          directoryURL: transactionURL.deletingLastPathComponent(),
          resourceIdentifier: directoryMetadata.resourceIdentifier
        ))
        let metadata = try fileSystem.metadata(for: transactionURL)
        let recovery = try XCTUnwrap(AutomationFileAuthorization(
          fileURL: transactionURL,
          directory: directory,
          expectation: .existing(resourceIdentifier: try XCTUnwrap(metadata.resourceIdentifier))
        ))
        throw AutomationFilePartialMutation(
          kind: .replace,
          commitState: .committed,
          observedFiles: [recovery],
          recoveryHandle: recovery,
          resultURL: transactionURL
        )
      },
      refresh: {
        _ = refreshCount.incrementAndGet()
        return Fixtures.inventoryGeneration7
      }
    )

    let result = await manager.perform(
      .disable,
      record: cron,
      expectedChecksum: checksum,
      linkedProcesses: []
    )

    XCTAssertEqual(
      result.status,
      .partialFailure(
        "HIGH SEVERITY: recoverable source materialization reached a partial filesystem state."
      )
    )
    XCTAssertNotNil(result.backup)
    XCTAssertEqual(result.fileMutationEvidence?.recoveryHandle?.fileURL, transactionURL)
    XCTAssertEqual(result.fileMutationEvidence?.commitState, .committed)
    XCTAssertEqual(sourceCalls.current(), 2)
    XCTAssertEqual(refreshCount.current(), 1)
    XCTAssertEqual(fileSystem.storedData(at: transactionURL), materialized)
    let invocationCount = await executor.invocationCount()
    XCTAssertEqual(invocationCount, 0)
  }

  func testRecoverableSourceRevalidationRejectsAdapterSnapshotThatDiffersFromDisk() async {
    let transactionURL = URL(fileURLWithPath: "/tmp/devscope-fixtures/current-crontab")
    let data = Data("0 9 * * 1 /bin/sleep 1\n".utf8)
    let changed = Data("0 10 * * 1 /bin/sleep 2\n".utf8)
    let checksum = sha256(data)
    let fileSystem = InMemoryAutomationFileSystem(files: [transactionURL: data])
    let metadata = try! fileSystem.metadata(for: transactionURL)
    let calls = LockedCallCounter()
    let cron = cronRecord(entry: try! XCTUnwrap(CronParser.parse(String(decoding: data, as: UTF8.self)).entries.first), checksum: checksum)
    let executor = RecordingAutomationMutationExecutor()
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      context: .fixture(currentUID: 501, canonicalPathIsApproved: true, ownerUID: 501),
      recoverableSource: { _ in
        if calls.incrementAndGet() == 2 { fileSystem.setStoredData(changed, at: transactionURL) }
        return AutomationRecoverableSource(
          transactionURL: transactionURL,
          data: data,
          checksum: checksum,
          metadata: metadata
        )
      }
    )

    let result = await manager.perform(
      .disable,
      record: cron,
      expectedChecksum: checksum,
      linkedProcesses: []
    )

    XCTAssertEqual(
      result.status,
      .failed("The recoverable source identity changed immediately before mutation.")
    )
    let invocationCount = await executor.invocationCount()
    XCTAssertEqual(invocationCount, 0)
  }

  func testCronEditBindsRawDocumentToReviewedFieldsAndImportVerifiesStableEntryIdentity() async {
    let transactionURL = URL(fileURLWithPath: "/tmp/devscope-fixtures/current-crontab")
    let data = Data("SHELL=/bin/sh\n0 9 * * 1 /usr/bin/echo hello\n".utf8)
    let checksum = sha256(data)
    let actualSnapshot = await CronAutomationSource(
      commandRunner: RecordingAutomationCommandRunner(result: .success(AutomationCommandResult(
        status: 0,
        standardOutput: data,
        standardError: Data()
      ))),
      currentUID: 501,
      currentUsername: "test-user"
    ).snapshot()
    let cron = try! XCTUnwrap(actualSnapshot.records.first)
    XCTAssertEqual(cron.sourceChecksum, checksum)
    let fileSystem = InMemoryAutomationFileSystem(files: [transactionURL: data])
    let captured: @Sendable (AutomationRecord) async throws -> AutomationRecoverableSource = { _ in
      AutomationRecoverableSource(
        transactionURL: transactionURL,
        data: try fileSystem.read(transactionURL),
        checksum: sha256(try fileSystem.read(transactionURL)),
        metadata: try fileSystem.metadata(for: transactionURL)
      )
    }
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: RecordingAutomationMutationExecutor(results: [
        .success(AutomationExecutorResult(
          postconditions: [.sourceInstalled, .sourceChecksum(checksum)], evidence: []
        )),
      ]),
      context: .fixture(currentUID: 501, canonicalPathIsApproved: true, ownerUID: 501),
      recoverableSource: captured,
      refresh: { snapshot(records: [cron]) }
    )

    let mismatched = await manager.perform(
      .edit(AutomationEditPayload(
        label: cron.label,
        executable: "/usr/bin/echo",
        arguments: ["reviewed-other-command"],
        environment: ["SHELL": "/bin/sh"],
        workingDirectory: nil,
        schedule: cron.schedule,
        rawRepresentation: data
      )),
      record: cron,
      expectedChecksum: checksum,
      linkedProcesses: []
    )
    XCTAssertEqual(
      mismatched.status,
      .rejected("The rendered crontab does not match the reviewed command, schedule, and environment.")
    )

    let imported = await manager.perform(
      .importRecord(AutomationImportPayload(
        destination: transactionURL,
        data: data,
        expectedKind: .cron,
        expectedDestinationChecksum: checksum
      )),
      record: cron,
      expectedChecksum: checksum,
      linkedProcesses: []
    )
    XCTAssertEqual(imported.status, .succeeded)
  }

  func testCronEditRejectsAmbiguousIntendedEntryAndStaleRefreshedContent() async {
    let transactionURL = URL(fileURLWithPath: "/tmp/devscope-fixtures/current-crontab")
    let original = Data("0 9 * * 1 /usr/bin/echo original\n".utf8)
    let entry = try! XCTUnwrap(CronParser.parse(String(decoding: original, as: UTF8.self)).entries.first)
    let record = cronRecord(entry: entry, checksum: sha256(original))
    let ambiguous = Data("0 9 * * 1 /usr/bin/echo changed\n0 9 * * 1 /usr/bin/echo changed\n".utf8)
    let changed = Data("0 9 * * 1 /usr/bin/echo changed\n".utf8)
    let staleRecord = cronRecord(entry: entry, checksum: sha256(changed))
    let fileSystem = InMemoryAutomationFileSystem(files: [transactionURL: original])
    let captured: @Sendable (AutomationRecord) async throws -> AutomationRecoverableSource = { _ in
      let data = try fileSystem.read(transactionURL)
      return AutomationRecoverableSource(
        transactionURL: transactionURL,
        data: data,
        checksum: sha256(data),
        metadata: try fileSystem.metadata(for: transactionURL)
      )
    }
    let executor = RecordingAutomationMutationExecutor(results: [
      .success(AutomationExecutorResult(
        postconditions: [.sourceInstalled, .sourceChecksum(sha256(changed))],
        evidence: []
      )),
    ])
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      context: .fixture(currentUID: 501, canonicalPathIsApproved: true, ownerUID: 501),
      recoverableSource: captured,
      refresh: { snapshot(records: [staleRecord]) }
    )
    let payload: (Data) -> AutomationEditPayload = { data in
      AutomationEditPayload(
        label: record.label,
        executable: "/usr/bin/echo",
        arguments: ["changed"],
        environment: [:],
        workingDirectory: nil,
        schedule: record.schedule,
        rawRepresentation: data
      )
    }

    let rejected = await manager.perform(
      .edit(payload(ambiguous)),
      record: record,
      expectedChecksum: sha256(original),
      linkedProcesses: []
    )
    XCTAssertEqual(
      rejected.status,
      .rejected("The intended cron entry is missing or ambiguous in the rendered document.")
    )

    let stale = await manager.perform(
      .edit(payload(changed)),
      record: record,
      expectedChecksum: sha256(original),
      linkedProcesses: []
    )
    XCTAssertNotEqual(stale.status, .succeeded)
  }

  func testCronEditRejectsAddOnlyDocumentThatKeepsSelectedEntry() async {
    let transactionURL = URL(fileURLWithPath: "/tmp/devscope-fixtures/current-crontab")
    let original = Data("0 9 * * 1 /usr/bin/echo original\n".utf8)
    let addOnly = Data("0 9 * * 1 /usr/bin/echo original\n0 10 * * 1 /usr/bin/echo changed\n".utf8)
    let originalRecords = await realCronRecords(original)
    let addOnlyRecords = await realCronRecords(addOnly)
    let selected = try! XCTUnwrap(originalRecords.first)
    let intended = try! XCTUnwrap(addOnlyRecords.last)
    let fileSystem = InMemoryAutomationFileSystem(files: [transactionURL: original])
    let executor = RecordingAutomationMutationExecutor(results: [
      .success(AutomationExecutorResult(
        postconditions: [.sourceInstalled, .sourceChecksum(sha256(addOnly))],
        evidence: []
      )),
    ])
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      context: .fixture(currentUID: 501, canonicalPathIsApproved: true, ownerUID: 501),
      recoverableSource: recoverableCronSource(transactionURL, fileSystem: fileSystem),
      refresh: { snapshot(records: [intended]) }
    )

    let result = await manager.perform(
      .edit(AutomationEditPayload(
        label: selected.label,
        executable: "/usr/bin/echo",
        arguments: ["changed"],
        environment: [:],
        workingDirectory: nil,
        schedule: AutomationSchedule(triggers: [.cron("0 10 * * 1")], summary: "reviewed"),
        rawRepresentation: addOnly
      )),
      record: selected,
      expectedChecksum: sha256(original),
      linkedProcesses: []
    )

    XCTAssertEqual(
      result.status,
      .rejected("A cron edit must replace exactly the selected entry and preserve unrelated entries.")
    )
    let invocationCount = await executor.invocationCount()
    XCTAssertEqual(invocationCount, 0)
  }

  func testCronEditRejectsChangingUnselectedIdenticalOccurrence() async {
    let transactionURL = URL(fileURLWithPath: "/tmp/devscope-fixtures/current-crontab")
    let original = Data("0 9 * * 1 /usr/bin/echo same\n0 9 * * 1 /usr/bin/echo same\n".utf8)
    let wrongOccurrence = Data("0 9 * * 1 /usr/bin/echo same\n0 9 * * 1 /usr/bin/echo changed\n".utf8)
    let originalRecords = await realCronRecords(original)
    let intendedRecords = await realCronRecords(wrongOccurrence)
    let selected = try! XCTUnwrap(originalRecords.first)
    let intended = try! XCTUnwrap(intendedRecords.last)
    let fileSystem = InMemoryAutomationFileSystem(files: [transactionURL: original])
    let executor = RecordingAutomationMutationExecutor(results: [
      .success(AutomationExecutorResult(
        postconditions: [.sourceInstalled, .sourceChecksum(sha256(wrongOccurrence))],
        evidence: []
      )),
    ])
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      context: .fixture(currentUID: 501, canonicalPathIsApproved: true, ownerUID: 501),
      recoverableSource: recoverableCronSource(transactionURL, fileSystem: fileSystem),
      refresh: { snapshot(records: [intended]) }
    )

    let result = await manager.perform(
      .edit(AutomationEditPayload(
        label: selected.label,
        executable: "/usr/bin/echo",
        arguments: ["changed"],
        environment: [:],
        workingDirectory: nil,
        schedule: selected.schedule,
        rawRepresentation: wrongOccurrence
      )),
      record: selected,
      expectedChecksum: sha256(original),
      linkedProcesses: []
    )

    XCTAssertEqual(
      result.status,
      .rejected("The intended cron entry does not replace the selected occurrence.")
    )
    let invocationCount = await executor.invocationCount()
    XCTAssertEqual(invocationCount, 0)
  }

  func testRealCronSourceDuplicateSucceedsAndFailedDuplicateRollsBack() async {
    let transactionURL = URL(fileURLWithPath: "/tmp/devscope-fixtures/current-crontab")
    let original = Data("0 9 * * 1 /usr/bin/echo original\n".utf8)
    let duplicated = Data("0 9 * * 1 /usr/bin/echo original\n0 10 * * 1 /usr/bin/echo copy\n".utf8)
    let originalRecords = await realCronRecords(original)
    let duplicatedRecords = await realCronRecords(duplicated)
    let selected = try! XCTUnwrap(originalRecords.first)
    let duplicatedRecord = try! XCTUnwrap(duplicatedRecords.last)
    let payload = AutomationEditPayload(
      label: selected.label,
      executable: "/usr/bin/echo",
      arguments: ["copy"],
      environment: [:],
      workingDirectory: nil,
      schedule: AutomationSchedule(triggers: [.cron("0 10 * * 1")], summary: "reviewed"),
      rawRepresentation: duplicated,
      destination: transactionURL,
      expectedDestinationChecksum: sha256(original)
    )

    let successFS = InMemoryAutomationFileSystem(files: [transactionURL: original])
    let success = makeManager(
      fileSystem: successFS,
      executor: RecordingAutomationMutationExecutor(results: [
        .success(AutomationExecutorResult(
          postconditions: [.sourceInstalled, .sourceChecksum(sha256(duplicated))],
          evidence: []
        )),
      ]),
      context: .fixture(currentUID: 501, canonicalPathIsApproved: true, ownerUID: 501),
      recoverableSource: recoverableCronSource(transactionURL, fileSystem: successFS),
      refresh: { snapshot(records: [duplicatedRecord]) }
    )
    let succeeded = await success.perform(
      .duplicate(payload),
      record: selected,
      expectedChecksum: sha256(original),
      linkedProcesses: []
    )
    XCTAssertEqual(succeeded.status, .succeeded)

    let rollbackFS = InMemoryAutomationFileSystem(files: [transactionURL: original])
    let rollback = makeManager(
      fileSystem: rollbackFS,
      executor: RecordingAutomationMutationExecutor(results: [.failure(.applyFailed)]),
      context: .fixture(currentUID: 501, canonicalPathIsApproved: true, ownerUID: 501),
      recoverableSource: recoverableCronSource(transactionURL, fileSystem: rollbackFS),
      refresh: { snapshot(records: [selected]) }
    )
    let failed = await rollback.perform(
      .duplicate(payload),
      record: selected,
      expectedChecksum: sha256(original),
      linkedProcesses: []
    )
    XCTAssertEqual(failed.rollback, .restored(try! XCTUnwrap(failed.backup?.id)))
    XCTAssertEqual(rollbackFS.storedData(at: transactionURL), original)
  }

  func testCronDuplicateRejectsSameSchedulePrependThatReusesSelectedID() async {
    let transactionURL = URL(fileURLWithPath: "/tmp/devscope-fixtures/current-crontab")
    let original = Data("0 9 * * 1 /usr/bin/echo original\n".utf8)
    let prepended = Data("0 9 * * 1 /usr/bin/echo copy\n0 9 * * 1 /usr/bin/echo original\n".utf8)
    let originalRecords = await realCronRecords(original)
    let selected = try! XCTUnwrap(originalRecords.first)
    let fileSystem = InMemoryAutomationFileSystem(files: [transactionURL: original])
    let executor = RecordingAutomationMutationExecutor()
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      context: .fixture(currentUID: 501, canonicalPathIsApproved: true, ownerUID: 501),
      recoverableSource: recoverableCronSource(transactionURL, fileSystem: fileSystem)
    )

    let result = await manager.perform(
      .duplicate(AutomationEditPayload(
        label: selected.label,
        executable: "/usr/bin/echo",
        arguments: ["copy"],
        environment: [:],
        workingDirectory: nil,
        schedule: selected.schedule,
        rawRepresentation: prepended,
        destination: transactionURL,
        expectedDestinationChecksum: sha256(original)
      )),
      record: selected,
      expectedChecksum: sha256(original),
      linkedProcesses: []
    )

    XCTAssertEqual(result.status, .rejected("The added cron entry identity is not distinct."))
    let invocationCount = await executor.invocationCount()
    XCTAssertEqual(invocationCount, 0)
  }

  func testRealCronSourcePresentRestoreSucceedsAndFailedRestoreRollsBack() async {
    let transactionURL = URL(fileURLWithPath: "/tmp/devscope-fixtures/current-crontab")
    let original = Data("0 9 * * 1 /usr/bin/echo original\n".utf8)
    let edited = Data("0 10 * * 1 /usr/bin/echo changed\n".utf8)
    let originalRecords = await realCronRecords(original)
    let editedRecords = await realCronRecords(edited)
    let originalRecord = try! XCTUnwrap(originalRecords.first)
    let editedRecord = try! XCTUnwrap(editedRecords.first)
    let editPayload = AutomationEditPayload(
      label: originalRecord.label,
      executable: "/usr/bin/echo",
      arguments: ["changed"],
      environment: [:],
      workingDirectory: nil,
      schedule: editedRecord.schedule,
      rawRepresentation: edited
    )

    for restoreSucceeds in [true, false] {
      let fileSystem = InMemoryAutomationFileSystem(files: [transactionURL: original])
      let refreshCount = LockedCallCounter()
      let executor = RecordingAutomationMutationExecutor(results: [
        .success(AutomationExecutorResult(
          postconditions: [.sourceInstalled, .sourceChecksum(sha256(edited))],
          evidence: []
        )),
        restoreSucceeds
          ? .success(AutomationExecutorResult(
            postconditions: [.sourceInstalled, .sourceChecksum(sha256(original))],
            evidence: []
          ))
          : .failure(.applyFailed),
      ])
      let manager = makeManager(
        fileSystem: fileSystem,
        executor: executor,
        context: .fixture(currentUID: 501, canonicalPathIsApproved: true, ownerUID: 501),
        recoverableSource: recoverableCronSource(transactionURL, fileSystem: fileSystem),
        refresh: {
          let call = refreshCount.incrementAndGet()
          return restoreSucceeds && call > 1
            ? snapshot(records: [originalRecord])
            : snapshot(records: [editedRecord])
        }
      )
      let edit = await manager.perform(
        .edit(editPayload),
        record: originalRecord,
        expectedChecksum: sha256(original),
        linkedProcesses: []
      )
      let backupID = try! XCTUnwrap(edit.backup?.id)
      let restored = await manager.perform(
        .restore(backupID),
        record: editedRecord,
        expectedChecksum: sha256(edited),
        linkedProcesses: []
      )

      if restoreSucceeds {
        XCTAssertEqual(restored.status, .succeeded)
        XCTAssertEqual(fileSystem.storedData(at: transactionURL), original)
      } else {
        XCTAssertEqual(restored.rollback, .restored(try! XCTUnwrap(restored.backup?.id)))
        XCTAssertEqual(fileSystem.storedData(at: transactionURL), edited)
      }
    }
  }

  func testDestinationResourceIdentityChangeBlocksBeforeReplacement() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData(arguments: ["14400"])
    let editedData = validLaunchAgentData(arguments: ["7200"])
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let calls = LockedCallCounter()
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: RecordingAutomationMutationExecutor(),
      destinationContext: { _, _ in
        if calls.incrementAndGet() == 2 {
          fileSystem.setMetadata(
            AutomationFileMetadata(
              canonicalURL: sourceURL,
              ownerUID: 501,
              isSymbolicLink: false,
              modificationDate: Date(timeIntervalSince1970: 2_000),
              resourceIdentifier: "replacement-identity"
            ),
            for: sourceURL
          )
        }
        return .fixture(currentUID: 501, canonicalPathIsApproved: true, ownerUID: 501)
      }
    )
    let payload = AutomationEditPayload(
      label: Fixtures.userAgent.label,
      executable: "/bin/sleep",
      arguments: ["7200"],
      environment: [:],
      workingDirectory: nil,
      schedule: Fixtures.userAgent.schedule,
      rawRepresentation: editedData
    )

    let result = await manager.perform(
      .edit(payload),
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    XCTAssertEqual(
      result.status,
      .failed("The intended destination identity changed immediately before mutation.")
    )
    XCTAssertEqual(fileSystem.storedData(at: sourceURL), sourceData)
  }

  func testImportRejectsSymlinkAndPathEscapeDestinations() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let destination = sourceURL.deletingLastPathComponent().appendingPathComponent("linked.plist")
    let sourceData = validLaunchAgentData()
    let importedData = validLaunchAgentData(label: "com.example.linked")
    let fileSystem = InMemoryAutomationFileSystem(
      files: [sourceURL: sourceData, destination: importedData],
      metadata: [
        destination: AutomationFileMetadata(
          canonicalURL: destination,
          ownerUID: 501,
          isSymbolicLink: true,
          modificationDate: Date(timeIntervalSince1970: 1_000),
          resourceIdentifier: "symlink-destination"
        ),
      ]
    )
    let operation = AutomationOperation.importRecord(AutomationImportPayload(
      destination: destination,
      data: importedData,
      expectedKind: .launchAgent,
      expectedDestinationChecksum: sha256(importedData)
    ))
    let symlinkManager = makeManager(
      fileSystem: fileSystem,
      executor: RecordingAutomationMutationExecutor(),
      destinationContext: { _, _ in
        .fixture(
          currentUID: 501,
          canonicalPathIsApproved: true,
          ownerUID: 501,
          isSymlink: true
        )
      }
    )
    let symlinkResult = await symlinkManager.perform(
      operation,
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )
    let escapeManager = makeManager(
      fileSystem: fileSystem,
      executor: RecordingAutomationMutationExecutor(),
      destinationContext: { _, _ in
        .fixture(currentUID: 501, canonicalPathIsApproved: false, ownerUID: 501)
      }
    )
    let escapeResult = await escapeManager.perform(
      operation,
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    XCTAssertEqual(symlinkResult.status, .rejected("The intended destination is a symbolic link."))
    XCTAssertEqual(
      escapeResult.status,
      .rejected("The intended destination resolves outside the approved automation folder.")
    )
  }

  func testRollbackRestoresDisabledButLoadedPreStateExactly() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let preStateRecord = copyRecord(
      Fixtures.userAgent,
      sourceChecksum: sha256(sourceData),
      enabledState: .disabled,
      loadState: .loaded,
      state: .running
    )
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let executor = RecordingAutomationMutationExecutor(results: [.failure(.applyFailed)])
    let originalBirth = ProcessBirthToken(seconds: 1_000, microseconds: 1)
    let controlled = classifiedAutomationProcess(pid: 700, birth: originalBirth)
    let relaunched = classifiedAutomationProcess(
      pid: 701,
      birth: ProcessBirthToken(seconds: 2_000, microseconds: 2)
    )
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      refresh: { snapshot(records: [preStateRecord]) },
      refreshProcesses: { [relaunched.process] }
    )

    let result = await manager.perform(
      .disable,
      record: preStateRecord,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: [controlled]
    )

    XCTAssertEqual(result.rollback, .restored(try! XCTUnwrap(result.backup?.id)))
    let states = await executor.recordedRestorationStates()
    XCTAssertEqual(states, [AutomationPreTransactionState(
      enabledState: .disabled,
      loadState: .loaded,
      linkedProcesses: [AutomationLinkedProcessIdentity(
        processID: controlled.process.pid,
        birthToken: originalBirth
      )]
    )])
  }

  func testRecoveryRetentionKeepsTwentyNewestIncludingCurrentRollbackEvidence() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let checksum = sha256(sourceData)
    let disabledRecord = copyRecord(
      Fixtures.userAgent,
      sourceChecksum: checksum,
      enabledState: .disabled,
      state: .disabled
    )
    let success = AutomationExecutorResult(
      postconditions: [.futureLaunchesDisabled],
      evidence: []
    )
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let executor = RecordingAutomationMutationExecutor(
      results: Array(repeating: .success(success), count: 21)
    )
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      refresh: { snapshot(records: [disabledRecord]) }
    )
    var latestID: AutomationBackup.ID?
    for _ in 0..<21 {
      let result = await manager.perform(
        .disable,
        record: Fixtures.userAgent,
        expectedChecksum: checksum,
        linkedProcesses: []
      )
      XCTAssertEqual(result.status, .succeeded)
      latestID = result.backup?.id
    }

    let manifests = await manager.restorationManifests()
    XCTAssertEqual(manifests.count, 20)
    XCTAssertTrue(manifests.contains { $0.id == latestID })
  }

  func testPruneRestoresManifestWhenBackupDeletionFailsAndRestartSeesConsistentPair() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let checksum = sha256(sourceData)
    let disabledRecord = copyRecord(
      Fixtures.userAgent,
      sourceChecksum: checksum,
      enabledState: .disabled,
      state: .disabled
    )
    let success = AutomationExecutorResult(
      postconditions: [.futureLaunchesDisabled],
      evidence: []
    )
    let fileSystem = InMemoryAutomationFileSystem(
      files: [sourceURL: sourceData],
      failingRemoves: [deterministicFirstBackupURL()]
    )
    let executor = RecordingAutomationMutationExecutor(
      results: Array(repeating: .success(success), count: 21)
    )
    let refreshCount = LockedCallCounter()
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      refresh: {
        _ = refreshCount.incrementAndGet()
        return snapshot(records: [disabledRecord])
      }
    )
    for _ in 0..<20 {
      let result = await manager.perform(
        .disable,
        record: Fixtures.userAgent,
        expectedChecksum: checksum,
        linkedProcesses: []
      )
      XCTAssertEqual(result.status, .succeeded)
    }

    let failedPrune = await manager.perform(
      .disable,
      record: Fixtures.userAgent,
      expectedChecksum: checksum,
      linkedProcesses: []
    )

    XCTAssertEqual(
      failedPrune.status,
      .partialFailure("HIGH SEVERITY: recovery evidence installation was only partially completed.")
    )
    XCTAssertEqual(failedPrune.fileMutationEvidence?.kind, .remove)
    XCTAssertTrue(fileSystem.itemExists(at: deterministicFirstManifestURL()))
    XCTAssertTrue(fileSystem.itemExists(at: deterministicFirstBackupURL()))
    XCTAssertEqual(refreshCount.current(), 21)
    let invocationCount = await executor.invocationCount()
    XCTAssertEqual(invocationCount, 20)

    let live = await manager.restorationManifests()
    let restarted = makeManager(
      fileSystem: fileSystem,
      executor: RecordingAutomationMutationExecutor()
    )
    let restartedManifests = await restarted.restorationManifests()
    XCTAssertEqual(live, restartedManifests)
    XCTAssertEqual(restartedManifests.count, 21)
    XCTAssertTrue(restartedManifests.contains {
      $0.backupURL.path == "/redacted" && $0.id.rawValue.uuidString.hasSuffix("555555555555")
    })
  }

  func testPruneReportsAttackerManifestAsObservedButNeverAsRecoveryHandle() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let checksum = sha256(sourceData)
    let disabledRecord = copyRecord(
      Fixtures.userAgent,
      sourceChecksum: checksum,
      enabledState: .disabled,
      state: .disabled
    )
    let manifestURL = deterministicFirstManifestURL()
    let backupURL = deterministicFirstBackupURL()
    let attackerData = Data("attacker-manifest".utf8)
    let success = AutomationExecutorResult(
      postconditions: [.futureLaunchesDisabled],
      evidence: []
    )
    let fileSystem = InMemoryAutomationFileSystem(
      files: [sourceURL: sourceData],
      failingRemoves: [backupURL],
      filesInstalledBeforeRemoveFailure: [backupURL: [manifestURL: attackerData]]
    )
    let executor = RecordingAutomationMutationExecutor(
      results: Array(repeating: .success(success), count: 21)
    )
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      refresh: { snapshot(records: [disabledRecord]) }
    )
    for _ in 0..<20 {
      let result = await manager.perform(
        .disable,
        record: Fixtures.userAgent,
        expectedChecksum: checksum,
        linkedProcesses: []
      )
      XCTAssertEqual(result.status, .succeeded)
    }

    let failedPrune = await manager.perform(
      .disable,
      record: Fixtures.userAgent,
      expectedChecksum: checksum,
      linkedProcesses: []
    )

    guard case .partialFailure = failedPrune.status else {
      return XCTFail("Expected partial failure, got \(failedPrune.status)")
    }
    let evidence = try! XCTUnwrap(failedPrune.fileMutationEvidence)
    XCTAssertEqual(fileSystem.storedData(at: manifestURL), attackerData)
    XCTAssertTrue(evidence.observedFiles.contains { $0.fileURL == manifestURL })
    XCTAssertFalse(evidence.recoveryHandles.contains { $0.fileURL == manifestURL })
    XCTAssertTrue(evidence.recoveryHandles.contains { $0.fileURL == backupURL })
    let invocationCount = await executor.invocationCount()
    XCTAssertEqual(invocationCount, 20)

    let currentManifests = await manager.restorationManifests()
    let restarted = makeManager(
      fileSystem: fileSystem,
      executor: RecordingAutomationMutationExecutor()
    )
    let restartedManifests = await restarted.restorationManifests()
    XCTAssertEqual(currentManifests, restartedManifests)
    XCTAssertEqual(currentManifests.count, 20)
  }

  func testPrePruneManifestAndBackupReplacementsAreNeverMutatedAndMapsMatchRestart() async {
    for replacesManifest in [true, false] {
      let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
      let sourceData = validLaunchAgentData()
      let checksum = sha256(sourceData)
      let disabledRecord = copyRecord(
        Fixtures.userAgent,
        sourceChecksum: checksum,
        enabledState: .disabled,
        state: .disabled
      )
      let success = AutomationExecutorResult(
        postconditions: [.futureLaunchesDisabled],
        evidence: []
      )
      let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
      let executor = RecordingAutomationMutationExecutor(
        results: Array(repeating: .success(success), count: 21)
      )
      let manager = makeManager(
        fileSystem: fileSystem,
        executor: executor,
        refresh: { snapshot(records: [disabledRecord]) }
      )
      for _ in 0..<20 {
        let result = await manager.perform(
          .disable,
          record: Fixtures.userAgent,
          expectedChecksum: checksum,
          linkedProcesses: []
        )
        XCTAssertEqual(result.status, .succeeded)
      }

      let targetURL = replacesManifest
        ? deterministicFirstManifestURL() : deterministicFirstBackupURL()
      let pairedURL = replacesManifest
        ? deterministicFirstBackupURL() : deterministicFirstManifestURL()
      let pairedData = fileSystem.storedData(at: pairedURL)
      let attackerData = Data(
        (replacesManifest ? "fresh-manifest-before-prune" : "fresh-backup-before-prune").utf8
      )
      fileSystem.setStoredData(attackerData, at: targetURL)
      fileSystem.setMetadata(AutomationFileMetadata(
        canonicalURL: targetURL,
        ownerUID: 501,
        isSymbolicLink: false,
        modificationDate: Date(timeIntervalSince1970: 9_999),
        resourceIdentifier: replacesManifest
          ? "fixture:fresh-manifest-before-prune" : "fixture:fresh-backup-before-prune",
        permissions: 0o600
      ), for: targetURL)

      let result = await manager.perform(
        .disable,
        record: Fixtures.userAgent,
        expectedChecksum: checksum,
        linkedProcesses: []
      )

      XCTAssertEqual(result.status, .succeeded)
      XCTAssertEqual(fileSystem.storedData(at: targetURL), attackerData)
      XCTAssertEqual(fileSystem.storedData(at: pairedURL), pairedData)
      XCTAssertFalse(fileSystem.recordedOperations.contains { operation in
        guard case .remove(let removedURL) = operation else { return false }
        return removedURL == targetURL || removedURL == pairedURL
      })
      let live = await manager.restorationManifests()
      let restarted = makeManager(
        fileSystem: fileSystem,
        executor: RecordingAutomationMutationExecutor()
      )
      let reloaded = await restarted.restorationManifests()
      XCTAssertEqual(live, reloaded)
      XCTAssertEqual(live.count, 20)
    }
  }

  func testRawAndUnchangedFirstPruneArtifactFailuresRemainOrdinary() async {
    for returnsUnchanged in [false, true] {
      let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
      let sourceData = validLaunchAgentData()
      let checksum = sha256(sourceData)
      let disabledRecord = copyRecord(
        Fixtures.userAgent,
        sourceChecksum: checksum,
        enabledState: .disabled,
        state: .disabled
      )
      let manifestURL = deterministicFirstManifestURL()
      let fileSystem = InMemoryAutomationFileSystem(
        files: [sourceURL: sourceData],
        failingRemoves: returnsUnchanged ? [] : [manifestURL],
        unchangedRemoves: returnsUnchanged ? [manifestURL] : []
      )
      let executor = RecordingAutomationMutationExecutor(results: Array(
        repeating: .success(AutomationExecutorResult(
          postconditions: [.futureLaunchesDisabled], evidence: []
        )),
        count: 21
      ))
      let manager = makeManager(
        fileSystem: fileSystem,
        executor: executor,
        refresh: { snapshot(records: [disabledRecord]) }
      )
      for _ in 0..<20 {
        let succeeded = await manager.perform(
          .disable,
          record: Fixtures.userAgent,
          expectedChecksum: checksum,
          linkedProcesses: []
        )
        XCTAssertEqual(
          succeeded.status,
          .succeeded
        )
      }

      let failed = await manager.perform(
        .disable,
        record: Fixtures.userAgent,
        expectedChecksum: checksum,
        linkedProcesses: []
      )

      XCTAssertEqual(
        failed.status,
        .failed("DevScope could not create owner-only recovery evidence.")
      )
      XCTAssertNil(failed.fileMutationEvidence)
      XCTAssertTrue(fileSystem.itemExists(at: manifestURL))
      XCTAssertTrue(fileSystem.itemExists(at: deterministicFirstBackupURL()))
      let live = await manager.restorationManifests()
      let restarted = makeManager(
        fileSystem: fileSystem,
        executor: RecordingAutomationMutationExecutor()
      )
      let reloaded = await restarted.restorationManifests()
      XCTAssertEqual(live, reloaded)
      XCTAssertEqual(live.count, 21)
      let invocationCount = await executor.invocationCount()
      XCTAssertEqual(invocationCount, 20)
    }
  }

  func testForgedManifestCannotLoadOrPruneBackupOutsideRecoveryRoot() async {
    let recoveryRoot = URL(fileURLWithPath: "/tmp/devscope-fixtures/recovery")
    let externalBackup = URL(fileURLWithPath: "/tmp/devscope-fixtures/do-not-delete.backup")
    let uuid = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    let manifestURL = recoveryRoot.appendingPathComponent(
      "\(uuid.uuidString.lowercased()).manifest.plist"
    )
    let externalData = Data("external-owner-data".utf8)
    let manifest = try! PropertyListSerialization.data(
      fromPropertyList: [
        "version": 2,
        "id": uuid.uuidString.lowercased(),
        "recordID": Fixtures.userAgent.id.rawValue,
        "sourcePath": try! XCTUnwrap(Fixtures.userAgent.sourceURL).path,
        "backupPath": externalBackup.path,
        "checksum": sha256(externalData),
        "createdAt": Date(timeIntervalSince1970: 1).timeIntervalSince1970,
        "sourceExisted": true,
        "ownerUID": 501,
        "kind": AutomationKind.launchAgent.rawValue,
        "sourceKind": AutomationSourceKind.launchAgent.rawValue,
        "authorizedRecordIDs": [Fixtures.userAgent.id.rawValue],
        "parentResourceIdentifier": "fixture:/tmp/devscope-fixtures",
      ],
      format: .binary,
      options: 0
    )
    let fileSystem = InMemoryAutomationFileSystem(
      files: [manifestURL: manifest, externalBackup: externalData],
      metadata: [
        recoveryRoot: AutomationFileMetadata(
          canonicalURL: recoveryRoot,
          ownerUID: 501,
          isSymbolicLink: false,
          modificationDate: Date(timeIntervalSince1970: 1),
          resourceIdentifier: "recovery-root",
          permissions: 0o700
        ),
        manifestURL: AutomationFileMetadata(
          canonicalURL: manifestURL,
          ownerUID: 501,
          isSymbolicLink: false,
          modificationDate: Date(timeIntervalSince1970: 1),
          resourceIdentifier: "forged-manifest",
          permissions: 0o600
        ),
        externalBackup: AutomationFileMetadata(
          canonicalURL: externalBackup,
          ownerUID: 501,
          isSymbolicLink: false,
          modificationDate: Date(timeIntervalSince1970: 1),
          resourceIdentifier: "external-backup",
          permissions: 0o600
        ),
      ],
      directories: [recoveryRoot]
    )
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: RecordingAutomationMutationExecutor()
    )

    let manifests = await manager.restorationManifests()
    XCTAssertEqual(manifests, [])
    XCTAssertEqual(fileSystem.storedData(at: externalBackup), externalData)
  }

  func testCronDisableStagesTheCompleteLosslessDocumentBeforeTheExecutor() async {
    let transactionURL = URL(fileURLWithPath: "/tmp/devscope-fixtures/current-crontab")
    let original = Data("SHELL=/bin/zsh\n# preserve me\n0 * * * * /usr/bin/true\n".utf8)
    let intended = Data("SHELL=/bin/zsh\n# preserve me\n# devscope-disabled: 0 * * * * /usr/bin/true\n".utf8)
    let originalRecords = await realCronRecords(original)
    let intendedRecords = await realCronRecords(intended)
    let record = try! XCTUnwrap(originalRecords.first)
    let disabled = try! XCTUnwrap(intendedRecords.first)
    let fileSystem = InMemoryAutomationFileSystem(files: [transactionURL: original])
    let executor = RecordingAutomationMutationExecutor(results: [
      .success(AutomationExecutorResult(
        postconditions: [.futureLaunchesDisabled, .sourceChecksum(sha256(intended))],
        evidence: []
      )),
    ])
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      recoverableSource: recoverableCronSource(transactionURL, fileSystem: fileSystem),
      refresh: { snapshot(records: [disabled]) }
    )

    let result = await manager.perform(
      .disable,
      record: record,
      expectedChecksum: sha256(original),
      linkedProcesses: []
    )

    XCTAssertEqual(result.status, .succeeded)
    XCTAssertEqual(fileSystem.storedData(at: transactionURL), intended)
  }

  func testCronRemoveInstallsTheRemainingDocumentWithoutTrashingTheTransactionSource() async {
    let transactionURL = URL(fileURLWithPath: "/tmp/devscope-fixtures/current-crontab")
    let original = Data("# preserve me\n0 * * * * /usr/bin/true\n30 * * * * /usr/bin/false\n".utf8)
    let intended = Data("# preserve me\n30 * * * * /usr/bin/false\n".utf8)
    let records = await realCronRecords(original)
    let record = try! XCTUnwrap(records.first)
    let remaining = await realCronRecords(intended)
    let fileSystem = InMemoryAutomationFileSystem(files: [transactionURL: original])
    let executor = RecordingAutomationMutationExecutor(results: [
      .success(AutomationExecutorResult(
        postconditions: [.sourceRemoved, .sourceChecksum(sha256(intended))],
        evidence: []
      )),
    ])
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      recoverableSource: recoverableCronSource(transactionURL, fileSystem: fileSystem),
      refresh: { snapshot(records: remaining) }
    )

    let result = await manager.perform(
      .remove,
      record: record,
      expectedChecksum: sha256(original),
      linkedProcesses: []
    )

    XCTAssertEqual(result.status, .succeeded)
    XCTAssertEqual(fileSystem.storedData(at: transactionURL), intended)
    XCTAssertFalse(fileSystem.recordedOperations.contains { operation in
      if case .moveToTrash = operation { return true }
      return false
    })
  }

  func testConfirmedCronRunNowCanFinishImmediatelyAndRedactsTheExactCommandFromResult() async {
    let transactionURL = URL(fileURLWithPath: "/tmp/devscope-fixtures/current-crontab")
    let secretCommand = "/usr/bin/curl -H 'Authorization: secret-value' https://example.invalid"
    let data = Data("0 * * * * \(secretCommand)\n".utf8)
    let records = await realCronRecords(data)
    let record = try! XCTUnwrap(records.first)
    let fileSystem = InMemoryAutomationFileSystem(files: [transactionURL: data])
    let executor = RecordingAutomationMutationExecutor(results: [
      .success(AutomationExecutorResult(
        postconditions: [.targetResolved, .runCompleted],
        evidence: []
      )),
    ])
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      recoverableSource: recoverableCronSource(transactionURL, fileSystem: fileSystem),
      refresh: { snapshot(records: [record]) }
    )
    let confirmation = AutomationRunToCompletionConfirmation(
      recordID: record.id,
      sourceChecksum: record.sourceChecksum,
      exactCommand: secretCommand
    )

    let result = await manager.perform(
      .confirmedRunToCompletion(confirmation),
      record: record,
      expectedChecksum: record.sourceChecksum,
      linkedProcesses: []
    )

    XCTAssertEqual(result.status, .succeeded)
    guard case .confirmedRunToCompletion(let redacted) = result.operation else {
      return XCTFail("Expected the typed confirmed operation")
    }
    XCTAssertEqual(redacted.recordID, record.id)
    XCTAssertEqual(redacted.exactCommand, "<redacted>")
    XCTAssertFalse(String(describing: result).contains(secretCommand))
  }

  func testConfirmedCronRunRejectsAStaleRecordGenerationBeforeExecutorInvocation() async {
    let transactionURL = URL(fileURLWithPath: "/tmp/devscope-fixtures/current-crontab")
    let staleData = Data("0 * * * * /usr/bin/old-command\n".utf8)
    let currentData = Data("0 * * * * /usr/bin/current-command\n".utf8)
    let staleRecords = await realCronRecords(staleData)
    let staleRecord = try! XCTUnwrap(staleRecords.first)
    let currentChecksum = try! XCTUnwrap(CronDocumentChecksum.checksum(currentData))
    let fileSystem = InMemoryAutomationFileSystem(files: [transactionURL: currentData])
    let executor = RecordingAutomationMutationExecutor()
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: executor,
      recoverableSource: recoverableCronSource(transactionURL, fileSystem: fileSystem)
    )
    let confirmation = AutomationRunToCompletionConfirmation(
      recordID: staleRecord.id,
      sourceChecksum: staleRecord.sourceChecksum,
      exactCommand: staleRecord.commandSignature!
    )

    let result = await manager.perform(
      .confirmedRunToCompletion(confirmation),
      record: staleRecord,
      expectedChecksum: currentChecksum,
      linkedProcesses: []
    )

    XCTAssertEqual(
      result.status,
      .rejected("The confirmed cron command belongs to a stale source generation.")
    )
    let invocationCount = await executor.invocationCount()
    XCTAssertEqual(invocationCount, 0)
  }

  func testCronRollbackDoesNotOverwriteAnExternalEditAfterManagerVerificationFails() async {
    let transactionURL = URL(fileURLWithPath: "/tmp/devscope-fixtures/current-crontab")
    let original = Data("0 * * * * /usr/bin/true\n".utf8)
    let intended = Data("# devscope-disabled: 0 * * * * /usr/bin/true\n".utf8)
    let external = Data("15 * * * * /usr/bin/external\n".utf8)
    let records = await realCronRecords(original)
    let record = try! XCTUnwrap(records.first)
    let runner = ScriptedManagerCommandRunner(results: [
      AutomationCommandResult(status: 0, standardOutput: Data(), standardError: Data()),
      AutomationCommandResult(status: 0, standardOutput: intended, standardError: Data()),
      AutomationCommandResult(status: 0, standardOutput: external, standardError: Data()),
    ])
    let fileSystem = InMemoryAutomationFileSystem(files: [transactionURL: original])
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: CronAutomationExecutor(
        runner: runner,
        fileSystem: fileSystem,
        currentUID: 501
      ),
      recoverableSource: recoverableCronSource(transactionURL, fileSystem: fileSystem),
      refresh: { snapshot(records: await realCronRecords(original)) }
    )

    let result = await manager.perform(
      .disable,
      record: record,
      expectedChecksum: record.sourceChecksum,
      linkedProcesses: []
    )

    XCTAssertEqual(
      result.status,
      .partialFailure("HIGH SEVERITY: the operation failed and automatic rollback did not complete.")
    )
    XCTAssertEqual(fileSystem.storedData(at: transactionURL), original)
    XCTAssertEqual(runner.invocations.count, 3)
    XCTAssertEqual(
      runner.invocations.filter { $0.executable == "/usr/bin/crontab" && $0.arguments != ["-l"] }.count,
      1,
      "Rollback must not install the backup over an externally changed live crontab."
    )
  }

  func testLegacyDisableUsesSelectedPathAbsenceAndPreservesRecoveryDescriptor() async {
    let descriptorURL = URL(fileURLWithPath: "/tmp/devscope-fixtures/legacy-login-items.json")
    let selected = LegacyLoginItemDescriptor(
      name: "Backup",
      path: "/Applications/Backup.app",
      isHidden: false
    )
    let records = await realLegacyLoginItemRecords([selected])
    let record = try! XCTUnwrap(records.first)
    let descriptorData = legacyRecoveryDescriptorData(record: record, isHidden: false)
    XCTAssertEqual(record.sourceChecksum, sha256(descriptorData))
    let fileSystem = InMemoryAutomationFileSystem(files: [descriptorURL: descriptorData])
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: RecordingAutomationMutationExecutor(results: [
        .success(AutomationExecutorResult(postconditions: [.futureLaunchesDisabled], evidence: [])),
      ]),
      recoverableSource: recoverableLegacySource(descriptorURL, fileSystem: fileSystem),
      refresh: { snapshot(records: [], health: .legacyLoginItem, state: .healthy) }
    )

    let result = await manager.perform(
      .disable,
      record: record,
      expectedChecksum: record.sourceChecksum,
      linkedProcesses: []
    )

    XCTAssertEqual(result.status, .succeeded)
    XCTAssertEqual(fileSystem.storedData(at: descriptorURL), descriptorData)
    XCTAssertFalse(fileSystem.recordedOperations.contains { if case .moveToTrash = $0 { true } else { false } })
  }

  func testLegacyRemoveAllowsUnrelatedItemsAndPreservesRecoveryDescriptor() async {
    let descriptorURL = URL(fileURLWithPath: "/tmp/devscope-fixtures/legacy-login-items.json")
    let selected = LegacyLoginItemDescriptor(
      name: "Backup",
      path: "/Applications/Backup.app",
      isHidden: false
    )
    let unrelated = LegacyLoginItemDescriptor(
      name: "Keep",
      path: "/Applications/Keep.app",
      isHidden: false
    )
    let initialRecords = await realLegacyLoginItemRecords([selected, unrelated])
    let record = try! XCTUnwrap(initialRecords.first { $0.executable == selected.path })
    let descriptorData = legacyRecoveryDescriptorData(record: record, isHidden: false)
    XCTAssertEqual(record.sourceChecksum, sha256(descriptorData))
    let remaining = await realLegacyLoginItemRecords([unrelated])
    let fileSystem = InMemoryAutomationFileSystem(files: [descriptorURL: descriptorData])
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: RecordingAutomationMutationExecutor(results: [
        .success(AutomationExecutorResult(postconditions: [.sourceRemoved], evidence: [])),
      ]),
      recoverableSource: recoverableLegacySource(descriptorURL, fileSystem: fileSystem),
      refresh: { snapshot(records: remaining, health: .legacyLoginItem, state: .healthy) }
    )

    let result = await manager.perform(
      .remove,
      record: record,
      expectedChecksum: record.sourceChecksum,
      linkedProcesses: []
    )

    XCTAssertEqual(result.status, .succeeded)
    XCTAssertEqual(fileSystem.storedData(at: descriptorURL), descriptorData)
    XCTAssertTrue(remaining.contains { $0.executable == unrelated.path })
    XCTAssertFalse(fileSystem.recordedOperations.contains { if case .moveToTrash = $0 { true } else { false } })
  }

  func testLegacyAbsenceRequiresHealthyAuthoritativeSourceForEveryUnhealthyState() async {
    let descriptorURL = URL(fileURLWithPath: "/tmp/devscope-fixtures/legacy-login-items.json")
    let selected = LegacyLoginItemDescriptor(
      name: "Backup",
      path: "/Applications/Backup.app",
      isHidden: true
    )
    let records = await realLegacyLoginItemRecords([selected])
    let record = try! XCTUnwrap(records.first)
    let descriptorData = legacyRecoveryDescriptorData(record: record, isHidden: true)

    for operation in [AutomationOperation.disable, .remove] {
      for healthState in [
        AutomationSourceHealthState.failed,
        .partial,
        .permissionRequired,
      ] {
        let refreshCount = LockedCallCounter()
        let fileSystem = InMemoryAutomationFileSystem(files: [descriptorURL: descriptorData])
        let postcondition: AutomationPostcondition = operation == .disable
          ? .futureLaunchesDisabled
          : .sourceRemoved
        let executor = RecordingAutomationMutationExecutor(results: [
          .success(AutomationExecutorResult(postconditions: [postcondition], evidence: [])),
        ])
        let manager = makeManager(
          fileSystem: fileSystem,
          executor: executor,
          recoverableSource: recoverableLegacySource(descriptorURL, fileSystem: fileSystem),
          refresh: {
            refreshCount.incrementAndGet() == 1
              ? snapshot(records: [], health: .legacyLoginItem, state: healthState)
              : snapshot(records: [record], health: .legacyLoginItem, state: .healthy)
          }
        )

        let result = await manager.perform(
          operation,
          record: record,
          expectedChecksum: sha256(descriptorData),
          linkedProcesses: []
        )
        let message = "\(operation) \(healthState.rawValue)"
        XCTAssertNotEqual(result.status, .succeeded, message)
        XCTAssertEqual(result.rollback, .restored(try! XCTUnwrap(result.backup?.id)), message)
        XCTAssertTrue(
          result.verificationEvidence.contains { $0.lowercased().contains("authoritative") },
          message
        )
      }
    }
  }

  func testCronDisableAndStopUsesOwnedGenerationForSnapshotAndPollFailures() async {
    let transactionURL = URL(fileURLWithPath: "/tmp/devscope-fixtures/current-crontab")
    let original = Data("* * * * * /usr/bin/true\n".utf8)
    let intended = Data("# devscope-disabled: * * * * * /usr/bin/true\n".utf8)
    let records = await realCronRecords(original)
    let record = try! XCTUnwrap(records.first)
    let (classified, processes) = managerCronProcessFixture()

    for postInstallFailure in ["snapshot", "poll"] {
      let runner = ScriptedManagerCommandRunner(results: [
        AutomationCommandResult(status: 0, standardOutput: Data(), standardError: Data()),
        AutomationCommandResult(status: 0, standardOutput: intended, standardError: Data()),
        AutomationCommandResult(status: 0, standardOutput: intended, standardError: Data()),
        AutomationCommandResult(status: 0, standardOutput: Data(), standardError: Data()),
        AutomationCommandResult(status: 0, standardOutput: original, standardError: Data()),
      ])
      let signalCount = LockedCallCounter()
      let resolver: ProcessKiller.IdentityResolver = { _ in
        .identity(ProcessIdentity(process: classified.process))
      }
      let fileSystem = InMemoryAutomationFileSystem(files: [transactionURL: original])
      let executor = CronAutomationExecutor(
        runner: runner,
        fileSystem: fileSystem,
        currentUID: 501,
        processKiller: ProcessKiller(
          identityResolver: resolver,
          signalSender: { _, _ in _ = signalCount.incrementAndGet() }
        ),
        currentProcessID: 99_999,
        processIdentityResolver: resolver,
        processSnapshot: {
          if postInstallFailure == "snapshot" {
            throw AutomationExecutorError.processControlUnavailable
          }
          return processes
        },
        now: { Date(timeIntervalSince1970: 3_600) },
        terminationVerificationPolicy: .init(maximumAttempts: 1, interval: .zero),
        verificationSleep: { _ in }
      )
      let manager = makeManager(
        fileSystem: fileSystem,
        executor: executor,
        recoverableSource: recoverableCronSource(transactionURL, fileSystem: fileSystem),
        refresh: { snapshot(records: records) },
        refreshProcesses: { processes }
      )

      let result = await manager.perform(
        .disableAndStop,
        record: record,
        expectedChecksum: record.sourceChecksum,
        linkedProcesses: [classified]
      )

      XCTAssertEqual(
        result.status,
        .partialFailure("HIGH SEVERITY: the operation failed and automatic rollback did not complete."),
        postInstallFailure
      )
      XCTAssertEqual(fileSystem.storedData(at: transactionURL), original, postInstallFailure)
      XCTAssertEqual(runner.invocations.count, 5, postInstallFailure)
      XCTAssertEqual(runner.invocations[2].arguments, ["-l"], postInstallFailure)
      XCTAssertNotEqual(runner.invocations[3].arguments, ["-l"], postInstallFailure)
      XCTAssertEqual(signalCount.current(), postInstallFailure == "poll" ? 1 : 0)
    }
  }

  func testManagerPassesImmutableVerifiedCronBytesAfterBackupPathMutation() async {
    let transactionURL = URL(fileURLWithPath: "/tmp/devscope-fixtures/current-crontab")
    let original = Data("0 * * * * /usr/bin/true\n5 * * * * /usr/bin/keep\n".utf8)
    let intended = Data("# devscope-disabled: 0 * * * * /usr/bin/true\n5 * * * * /usr/bin/keep\n".utf8)
    let altered = Data("0 * * * * /usr/bin/true\n10 * * * * /usr/bin/unrelated-change\n".utf8)
    let records = await realCronRecords(original)
    let record = try! XCTUnwrap(records.first)
    let fileSystem = InMemoryAutomationFileSystem(files: [transactionURL: original])
    let callIndex = LockedCallCounter()
    let runner = HookedManagerCommandRunner { command in
      switch callIndex.incrementAndGet() {
      case 1:
        return AutomationCommandResult(status: 0, standardOutput: Data(), standardError: Data())
      case 2:
        fileSystem.setReadObserver { url, _ in
          guard url.pathExtension == "backup" else { return }
          fileSystem.setReadObserver(nil)
          fileSystem.setStoredData(altered, at: url)
        }
        return AutomationCommandResult(status: 0, standardOutput: intended, standardError: Data())
      case 3:
        return AutomationCommandResult(status: 0, standardOutput: intended, standardError: Data())
      case 4:
        XCTAssertEqual(fileSystem.storedData(at: URL(fileURLWithPath: command.arguments[0])), original)
        return AutomationCommandResult(status: 0, standardOutput: Data(), standardError: Data())
      default:
        return AutomationCommandResult(status: 0, standardOutput: original, standardError: Data())
      }
    }
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: CronAutomationExecutor(runner: runner, fileSystem: fileSystem, currentUID: 501),
      recoverableSource: recoverableCronSource(transactionURL, fileSystem: fileSystem),
      refresh: { snapshot(records: records) }
    )

    let result = await manager.perform(
      .disable,
      record: record,
      expectedChecksum: record.sourceChecksum,
      linkedProcesses: []
    )

    XCTAssertEqual(result.status, .failed("The automation operation failed; the prior source and loaded state were restored."))
    XCTAssertEqual(runner.invocations.count, 5)
    XCTAssertEqual(fileSystem.storedData(at: deterministicFirstBackupURL()), altered)
  }

  func testManagerPassesImmutableVerifiedLegacyHiddenValueAfterBackupPathMutation() async {
    let descriptorURL = URL(fileURLWithPath: "/tmp/devscope-fixtures/legacy-login-items.json")
    let selected = LegacyLoginItemDescriptor(
      name: "Backup",
      path: "/Applications/Backup.app",
      isHidden: true
    )
    let records = await realLegacyLoginItemRecords([selected])
    let record = try! XCTUnwrap(records.first)
    let original = legacyRecoveryDescriptorData(record: record, isHidden: true)
    let altered = legacyRecoveryDescriptorData(record: record, isHidden: false)
    let fileSystem = InMemoryAutomationFileSystem(files: [descriptorURL: original])
    let commandIndex = LockedCallCounter()
    let runner = HookedManagerCommandRunner { command in
      if commandIndex.incrementAndGet() == 1 {
        fileSystem.setReadObserver { url, _ in
          guard url.pathExtension == "backup" else { return }
          fileSystem.setReadObserver(nil)
          fileSystem.setStoredData(altered, at: url)
        }
      } else {
        XCTAssertEqual(Array(command.arguments.suffix(4)), ["--", "add", selected.path, "true"])
      }
      return AutomationCommandResult(status: 0, standardOutput: Data(), standardError: Data())
    }
    let listing = SequencedManagerLegacyLoginItemListing(values: [[], [selected]])
    let manager = makeManager(
      fileSystem: fileSystem,
      executor: LegacyLoginItemAutomationExecutor(
        runner: runner,
        listing: listing,
        currentUID: 501
      ),
      recoverableSource: recoverableLegacySource(descriptorURL, fileSystem: fileSystem),
      refresh: { snapshot(records: records, health: .legacyLoginItem, state: .healthy) }
    )

    let result = await manager.perform(
      .disable,
      record: record,
      expectedChecksum: sha256(original),
      linkedProcesses: []
    )

    XCTAssertEqual(result.status, .failed("The automation operation failed; the prior source and loaded state were restored."))
    XCTAssertEqual(runner.invocations.count, 2)
    XCTAssertEqual(fileSystem.storedData(at: deterministicFirstBackupURL()), altered)
  }

  func testBackupCorruptionBeforeManagerAuthenticationNeverReachesRecoveryExecutor() async {
    let sourceURL = try! XCTUnwrap(Fixtures.userAgent.sourceURL)
    let sourceData = validLaunchAgentData()
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: sourceData])
    let executor = RecordingAutomationMutationExecutor(
      results: [.failure(.applyFailed)],
      onApply: {
        fileSystem.setStoredData(Data("corrupted".utf8), at: deterministicFirstBackupURL())
      }
    )
    let manager = makeManager(fileSystem: fileSystem, executor: executor)

    let result = await manager.perform(
      .startNow,
      record: Fixtures.userAgent,
      expectedChecksum: sha256(sourceData),
      linkedProcesses: []
    )

    XCTAssertEqual(
      result.status,
      .partialFailure("HIGH SEVERITY: the operation failed and automatic rollback did not complete.")
    )
    let restorationStates = await executor.recordedRestorationStates()
    XCTAssertTrue(restorationStates.isEmpty)
  }
}

private extension AutomationManagerTests {
  func makeManager(
    fileSystem: InMemoryAutomationFileSystem,
    executor: any AutomationMutationApplying,
    context: AutomationCapabilityContext = .fixture(
      currentUID: 501,
      canonicalPathIsApproved: true,
      ownerUID: 501
    ),
    destinationContext: @escaping @Sendable (
      AutomationRecord,
      URL
    ) throws -> AutomationCapabilityContext = { _, _ in
      .fixture(currentUID: 501, canonicalPathIsApproved: true, ownerUID: 501)
    },
    recoverableSource: @escaping @Sendable (
      AutomationRecord
    ) async throws -> AutomationRecoverableSource = { _ in
      throw AutomationManagerConfigurationError.recoverableSourceUnavailable
    },
    refresh: @escaping @Sendable () async -> AutomationInventorySnapshot = {
      Fixtures.inventoryGeneration7
    },
    refreshProcesses: @escaping @Sendable () async throws -> [DevProcess] = { [] }
  ) -> AutomationManager {
    let uuidSequence = DeterministicAutomationUUIDSequence()
    return AutomationManager(
      fileSystem: fileSystem,
      executor: executor,
      capabilityContext: { _ in context },
      destinationContext: destinationContext,
      recoverableSource: recoverableSource,
      refresh: refresh,
      refreshProcesses: refreshProcesses,
      backupDirectory: URL(fileURLWithPath: "/tmp/devscope-fixtures/recovery"),
      currentUID: 501,
      now: { Date(timeIntervalSince1970: 20_000) },
      makeUUID: { uuidSequence.next() }
    )
  }
}

private final class DeterministicAutomationUUIDSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var sequence: UInt8 = 0x55

  func next() -> UUID {
    lock.withLock {
      defer { sequence &+= 1 }
      return UUID(uuid: (
        0x11, 0x11, 0x11, 0x11,
        0x22, 0x22,
        0x33, 0x33,
        0x44, 0x44,
        0x55, 0x55, 0x55, 0x55, 0x55, sequence
      ))
    }
  }
}

private final class LockedCallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func incrementAndGet() -> Int {
    lock.withLock {
      value += 1
      return value
    }
  }

  func current() -> Int { lock.withLock { value } }
}

private final class LockedDataCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Data?

  func set(_ data: Data) { lock.withLock { value = data } }

  func current() -> Data? { lock.withLock { value } }
}

private final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var isSet = false

  var value: Bool { lock.withLock { isSet } }

  func set() {
    lock.withLock { isSet = true }
  }
}

private final class ScriptedManagerCommandRunner: AutomationCommandRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var results: [AutomationCommandResult]
  private var commands: [AutomationCommand] = []

  init(results: [AutomationCommandResult]) {
    self.results = results
  }

  var invocations: [AutomationCommand] {
    lock.withLock { commands }
  }

  func run(_ command: AutomationCommand) async throws -> AutomationCommandResult {
    lock.withLock {
      commands.append(command)
      guard !results.isEmpty else {
        return AutomationCommandResult(status: 0, standardOutput: Data(), standardError: Data())
      }
      return results.removeFirst()
    }
  }
}

private final class HookedManagerCommandRunner: AutomationCommandRunning, @unchecked Sendable {
  private let lock = NSLock()
  private let handler: @Sendable (AutomationCommand) -> AutomationCommandResult
  private var commands: [AutomationCommand] = []

  init(handler: @escaping @Sendable (AutomationCommand) -> AutomationCommandResult) {
    self.handler = handler
  }

  var invocations: [AutomationCommand] { lock.withLock { commands } }

  func run(_ command: AutomationCommand) async throws -> AutomationCommandResult {
    lock.withLock { commands.append(command) }
    return handler(command)
  }
}

private final class SequencedManagerLegacyLoginItemListing: LegacyLoginItemListing, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [[LegacyLoginItemDescriptor]]

  init(values: [[LegacyLoginItemDescriptor]]) { self.values = values }

  func currentUserLoginItems() async throws -> [LegacyLoginItemDescriptor] {
    lock.withLock { values.isEmpty ? [] : values.removeFirst() }
  }
}

private enum AutomationManagerFixtureError: Error {
  case applyFailed
  case rollbackFailed
}

private actor RecordingAutomationMutationExecutor: AutomationMutationApplying {
  private var invocations = 0
  private var operations: [AutomationOperation] = []
  private var results: [Result<AutomationExecutorResult, AutomationManagerFixtureError>]
  private let delayNanoseconds: UInt64
  private let restorationFails: Bool
  private let onApply: @Sendable () -> Void
  private var activeInvocations = 0
  private var maximumActiveInvocations = 0
  private var restorationStates: [AutomationPreTransactionState] = []

  init(
    results: [Result<AutomationExecutorResult, AutomationManagerFixtureError>] = [
      .success(AutomationExecutorResult(postconditions: [], evidence: [])),
    ],
    delayNanoseconds: UInt64 = 0,
    restorationFails: Bool = false,
    onApply: @escaping @Sendable () -> Void = {}
  ) {
    self.results = results
    self.delayNanoseconds = delayNanoseconds
    self.restorationFails = restorationFails
    self.onApply = onApply
  }

  func apply(
    _ operation: AutomationOperation,
    to record: AutomationRecord,
    linkedProcesses: [ClassifiedDevProcess],
    proposedSourceURL: URL?
  ) async throws -> AutomationExecutorResult {
    invocations += 1
    onApply()
    operations.append(operation)
    activeInvocations += 1
    maximumActiveInvocations = max(maximumActiveInvocations, activeInvocations)
    defer { activeInvocations -= 1 }
    guard !results.isEmpty else {
      return AutomationExecutorResult(postconditions: [], evidence: [])
    }
    let result = results.removeFirst()
    if delayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: delayNanoseconds)
    }
    return try result.get()
  }

  func invocationCount() -> Int {
    invocations
  }

  func recordedOperations() -> [AutomationOperation] {
    operations
  }

  func maximumConcurrency() -> Int {
    maximumActiveInvocations
  }

  func recordedRestorationStates() -> [AutomationPreTransactionState] {
    restorationStates
  }

  func restorePreTransactionState(
    _ state: AutomationPreTransactionState,
    for record: AutomationRecord,
    recovery: AutomationVerifiedRecoveryInput,
    linkedProcesses: [ClassifiedDevProcess],
    expectedAppliedState: AutomationExecutorAppliedState?
  ) async throws -> AutomationExecutorResult {
    if restorationFails { throw AutomationManagerFixtureError.rollbackFailed }
    restorationStates.append(state)
    return AutomationExecutorResult(
      postconditions: [.preTransactionStateRestored(state)],
      evidence: []
    )
  }
}

private func validLaunchAgentData(
  label: String = "com.example.backup",
  arguments: [String] = ["14400"],
  environment: [String: String] = [:],
  workingDirectory: String? = nil
) -> Data {
  var propertyList: [String: Any] = [
    "Label": label,
    "ProgramArguments": ["/bin/sleep"] + arguments,
    "RunAtLoad": true,
    "StartInterval": 14_400,
  ]
  if !environment.isEmpty {
    propertyList["EnvironmentVariables"] = environment
  }
  if let workingDirectory {
    propertyList["WorkingDirectory"] = workingDirectory
  }
  return try! PropertyListSerialization.data(
    fromPropertyList: propertyList,
    format: .xml,
    options: 0
  )
}

private func snapshot(
  records: [AutomationRecord],
  health sourceKind: AutomationSourceKind? = nil,
  state: AutomationSourceHealthState = .healthy
) -> AutomationInventorySnapshot {
  var health = Fixtures.inventoryGeneration7.health
  if let sourceKind {
    health[sourceKind] = AutomationSourceHealth(
      kind: sourceKind,
      state: state,
      message: state == .healthy ? nil : "fixture \(state.rawValue)",
      refreshedAt: Date(timeIntervalSince1970: 20_001)
    )
  }
  return AutomationInventorySnapshot(
    generation: 8,
    records: records,
    health: health,
    refreshedAt: Date(timeIntervalSince1970: 20_001)
  )
}

private func copyRecord(
  _ record: AutomationRecord,
  id: AutomationRecord.ID? = nil,
  label: String? = nil,
  sourceURL: URL? = nil,
  sourceChecksum: String? = nil,
  enabledState: AutomationEnabledState? = nil,
  loadState: AutomationLoadState? = nil,
  state: AutomationState? = nil
) -> AutomationRecord {
  AutomationRecord(
    id: id ?? record.id,
    kind: record.kind,
    sourceKind: record.sourceKind,
    label: label ?? record.label,
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
    sourceURL: sourceURL ?? record.sourceURL,
    sourceChecksum: sourceChecksum ?? record.sourceChecksum,
    enabledState: enabledState ?? record.enabledState,
    loadState: loadState ?? record.loadState,
    approvalState: record.approvalState,
    state: state ?? record.state,
    evidence: record.evidence,
    capabilities: record.capabilities,
    validationFindings: record.validationFindings
  )
}

private func sha256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func deterministicFirstBackupURL() -> URL {
  URL(fileURLWithPath: "/tmp/devscope-fixtures/recovery")
    .appendingPathComponent("11111111-2222-3333-4444-555555555555.backup")
}

private func deterministicFirstManifestURL() -> URL {
  URL(fileURLWithPath: "/tmp/devscope-fixtures/recovery")
    .appendingPathComponent("11111111-2222-3333-4444-555555555555.manifest.plist")
}

private func classifiedAutomationProcess(
  pid: Int32,
  birth: ProcessBirthToken
) -> ClassifiedDevProcess {
  ClassifiedDevProcess(
    process: DevProcess(
      pid: pid,
      parentPID: 1,
      executable: "/bin/sleep",
      command: "/bin/sleep 14400",
      argumentVector: ["/bin/sleep", "14400"],
      birthToken: birth,
      launchLabel: Fixtures.userAgent.label
    ),
    classification: DevProcessClassification(
      kind: .backgroundAgent,
      displayName: "Automation",
      projectHint: nil
    )
  )
}

private func cronRecord(entry: CronEntry, checksum: String) -> AutomationRecord {
  AutomationRecord(
    id: CronParser.recordID(for: entry, ownerUID: 501),
    kind: .cron,
    sourceKind: .crontab,
    label: "Cron entry 1",
    displayName: "Cron entry 1",
    providerBundleIdentifier: nil,
    ownerUID: 501,
    ownership: .user,
    executable: nil,
    arguments: [],
    commandSignature: entry.command,
    environment: entry.environment,
    workingDirectory: nil,
    schedule: entry.schedule,
    sourceURL: nil,
    sourceChecksum: checksum,
    enabledState: .enabled,
    loadState: .unknown,
    approvalState: .notApplicable,
    state: .idle,
    evidence: [],
    capabilities: [],
    validationFindings: []
  )
}

private func realCronRecords(_ data: Data) async -> [AutomationRecord] {
  await CronAutomationSource(
    commandRunner: RecordingAutomationCommandRunner(result: .success(AutomationCommandResult(
      status: 0,
      standardOutput: data,
      standardError: Data()
    ))),
    currentUID: 501,
    currentUsername: "test-user"
  ).snapshot().records
}

private func realLegacyLoginItemRecords(
  _ items: [LegacyLoginItemDescriptor]
) async -> [AutomationRecord] {
  await LegacyLoginItemAutomationSource(
    adapter: StaticManagerLegacyLoginItemListing(items: items),
    currentUID: 501
  ).snapshot().records
}

private func managerCronProcessFixture() -> (
  classified: ClassifiedDevProcess,
  processes: [DevProcess]
) {
  let carrier = DevProcess(
    pid: 66_101,
    parentPID: 66_100,
    executable: "/bin/sh",
    command: "/bin/sh -c /usr/bin/true",
    argumentVector: ["/bin/sh", "-c", "/usr/bin/true"],
    resourceUsage: DevProcessResourceUsage(
      cpuPercent: 0,
      residentMemoryBytes: 1,
      elapsedTime: "00:00:00"
    ),
    birthToken: ProcessBirthToken(seconds: 3_600, microseconds: 1)
  )
  let daemon = DevProcess(
    pid: 66_100,
    parentPID: 1,
    executable: "/usr/sbin/cron",
    command: "/usr/sbin/cron",
    argumentVector: ["/usr/sbin/cron"],
    birthToken: ProcessBirthToken(seconds: 1, microseconds: 0)
  )
  return (
    ClassifiedDevProcess(
      process: carrier,
      classification: DevProcessClassification(kind: .shell, displayName: "cron", projectHint: nil)
    ),
    [daemon, carrier]
  )
}

private func legacyRecoveryDescriptorData(
  record: AutomationRecord,
  isHidden: Bool
) -> Data {
  try! LegacyLoginItemRecoveryDocument.encode(
    selectedRecord: record,
    descriptor: LegacyLoginItemDescriptor(
      name: record.label,
      path: record.executable!,
      isHidden: isHidden
    ),
    currentUID: 501
  )
}

private struct StaticManagerLegacyLoginItemListing: LegacyLoginItemListing {
  let items: [LegacyLoginItemDescriptor]

  func currentUserLoginItems() async throws -> [LegacyLoginItemDescriptor] { items }
}

private func recoverableCronSource(
  _ transactionURL: URL,
  fileSystem: InMemoryAutomationFileSystem
) -> @Sendable (AutomationRecord) async throws -> AutomationRecoverableSource {
  { _ in
    let data = try fileSystem.read(transactionURL)
    return AutomationRecoverableSource(
      transactionURL: transactionURL,
      data: data,
      checksum: sha256(data),
      metadata: try fileSystem.metadata(for: transactionURL)
    )
  }
}

private func recoverableLegacySource(
  _ transactionURL: URL,
  fileSystem: InMemoryAutomationFileSystem
) -> @Sendable (AutomationRecord) async throws -> AutomationRecoverableSource {
  { _ in
    let data = try fileSystem.read(transactionURL)
    return AutomationRecoverableSource(
      transactionURL: transactionURL,
      data: data,
      checksum: sha256(data),
      metadata: try fileSystem.metadata(for: transactionURL)
    )
  }
}
