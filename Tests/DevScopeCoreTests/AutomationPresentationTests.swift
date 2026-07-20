import XCTest
@testable import DevScopeCore

final class AutomationPresentationTests: XCTestCase {
  func testNewestContextProjectsOneCoherentInventoryAndThresholdGeneration() {
    let firstContext = AutomationPresentationContext(
      inventory: Fixtures.inventoryGeneration7,
      longRunningThreshold: 14_400
    )
    let nextInventory = AutomationInventorySnapshot(
      generation: 8,
      records: [],
      health: [:],
      refreshedAt: Date(timeIntervalSince1970: 20_000)
    )
    let newestContext = AutomationPresentationContext(
      inventory: nextInventory,
      longRunningThreshold: 18_000
    )

    let first = firstContext.build(
      processes: [Fixtures.runningBackup],
      now: Date(timeIntervalSince1970: 10_000)
    )
    let newest = newestContext.build(
      processes: [Fixtures.runningBackup],
      now: Date(timeIntervalSince1970: 10_002)
    )

    XCTAssertEqual(first.inventory.generation, 7)
    XCTAssertEqual(first.longRunningProcessIDs, [Fixtures.runningBackup.pid])
    XCTAssertEqual(newest.inventory.generation, 8)
    XCTAssertTrue(newest.linksByProcessID.isEmpty)
    XCTAssertTrue(newest.longRunningProcessIDs.isEmpty)
  }

  func testPresentationContextSanitizesInvalidThresholdsAtTheBoundary() {
    XCTAssertEqual(
      AutomationPresentationContext(
        inventory: Fixtures.inventoryGeneration7,
        longRunningThreshold: -.infinity
      ).longRunningThreshold,
      AutomationPresentationContext.defaultLongRunningThreshold
    )
    XCTAssertEqual(
      AutomationPresentationContext(
        inventory: Fixtures.inventoryGeneration7,
        longRunningThreshold: -1
      ).longRunningThreshold,
      0
    )
  }


  func testBuildKeepsInventoryLinksAndIndependentLongRunningStateCoherent() {
    let unautomated = DevProcess(
      pid: 77, parentPID: 1, executable: "/bin/other", command: "/bin/other",
      resourceUsage: DevProcessResourceUsage(
        cpuPercent: 0, residentMemoryBytes: 0, elapsedTime: "04:00:00"
      )
    )

    let snapshot = AutomationPresentationSnapshot.build(
      inventory: Fixtures.inventoryGeneration7,
      processes: [Fixtures.runningBackup, unautomated],
      longRunningThreshold: 14_400,
      now: Date(timeIntervalSince1970: 10_000)
    )

    XCTAssertEqual(snapshot.inventory.generation, 7)
    XCTAssertEqual(snapshot.inventory.records.first?.state, .running)
    XCTAssertEqual(snapshot.linksByProcessID[Fixtures.runningBackup.pid]?.recordID, Fixtures.userAgent.id)
    XCTAssertEqual(
      AutomationPresentation.uniquelyStrongLinkedProcessIdentities(
        for: Fixtures.userAgent.id,
        linksByProcessID: snapshot.allLinksByProcessID
      ),
      [ProcessIdentity(process: Fixtures.runningBackup)]
    )
    XCTAssertEqual(snapshot.longRunningProcessIDs, [Fixtures.runningBackup.pid, unautomated.pid])
    XCTAssertNil(snapshot.processIdentitiesByID[unautomated.pid]?.birthToken)
    XCTAssertTrue(snapshot.isProcessSnapshotComplete)
  }

  func testPresentationPreservesEveryStrongRecordLinkForOneProcess() {
    let launchAgent = copiedRecord(
      Fixtures.userAgent,
      label: Fixtures.userAgent.label,
      ownership: .user,
      state: .idle,
      sourceKind: .launchAgent
    )
    let launchDaemon = copiedRecord(
      Fixtures.userAgent,
      label: Fixtures.userAgent.label,
      ownership: .user,
      state: .idle,
      sourceKind: .launchDaemon
    )
    let snapshot = AutomationPresentationSnapshot.build(
      inventory: AutomationInventorySnapshot(
        generation: 9,
        records: [launchAgent, launchDaemon],
        health: [:],
        refreshedAt: Date(timeIntervalSince1970: 9)
      ),
      processes: [Fixtures.runningBackup],
      longRunningThreshold: 14_400,
      now: Date(timeIntervalSince1970: 10_000)
    )

    XCTAssertEqual(
      Set(snapshot.allLinksByProcessID[Fixtures.runningBackup.pid]?.map(\.recordID) ?? []),
      [launchAgent.id, launchDaemon.id]
    )
    XCTAssertNotNil(snapshot.linksByProcessID[Fixtures.runningBackup.pid])
    XCTAssertEqual(
      AutomationPresentation.uniquelyStrongLinkedProcessIdentities(
        for: launchAgent.id,
        linksByProcessID: snapshot.allLinksByProcessID
      ),
      Set<ProcessIdentity>()
    )
  }

  func testAmbiguousNilLabelProvenancePublishesNoControllablePresentationLink() {
    let first = copiedRecord(
      Fixtures.userAgent,
      label: "com.example.first",
      ownership: .user,
      state: .idle,
      sourceKind: .launchAgent
    )
    let second = copiedRecord(
      Fixtures.userAgent,
      label: "com.example.second",
      ownership: .user,
      state: .idle,
      sourceKind: .launchAgent
    )
    let inventory = AutomationInventorySnapshot(
      generation: 1,
      records: [first, second],
      health: [:],
      refreshedAt: Date(timeIntervalSince1970: 10_000)
    )

    let snapshot = AutomationPresentationSnapshot.build(
      inventory: inventory,
      processes: [Fixtures.runningBackup],
      longRunningThreshold: 14_400,
      now: Date(timeIntervalSince1970: 10_000)
    )

    XCTAssertTrue(snapshot.linksByProcessID.isEmpty)
    XCTAssertEqual(snapshot.inventory.records.map(\.state), [.idle, .idle])
  }

  func testThresholdOnlyChangeRecomputesDurationWithoutChangingLinksOrInventory() {
    let first = AutomationPresentationSnapshot.build(
      inventory: Fixtures.inventoryGeneration7, processes: [Fixtures.runningBackup],
      longRunningThreshold: 14_400, now: Date(timeIntervalSince1970: 10_000)
    )
    let second = AutomationPresentationSnapshot.build(
      inventory: Fixtures.inventoryGeneration7, processes: [Fixtures.runningBackup],
      longRunningThreshold: 18_000, now: Date(timeIntervalSince1970: 10_000)
    )

    XCTAssertEqual(first.inventory, second.inventory)
    XCTAssertEqual(first.linksByProcessID, second.linksByProcessID)
    XCTAssertEqual(first.longRunningProcessIDs, [Fixtures.runningBackup.pid])
    XCTAssertTrue(second.longRunningProcessIDs.isEmpty)
  }

  func testRecycledPIDCannotRetainOldPresentationLinkIdentity() {
    let old = AutomationPresentationSnapshot.build(
      inventory: Fixtures.inventoryGeneration7, processes: [Fixtures.runningBackup],
      longRunningThreshold: 14_400, now: Date(timeIntervalSince1970: 10_000)
    )
    let replacement = DevProcess(
      pid: Fixtures.runningBackup.pid, parentPID: 1, executable: "/bin/other",
      command: "/bin/other", birthToken: ProcessBirthToken(seconds: 20_000, microseconds: 9)
    )
    let current = AutomationPresentationSnapshot.build(
      inventory: Fixtures.inventoryGeneration7, processes: [replacement],
      longRunningThreshold: 14_400, now: Date(timeIntervalSince1970: 20_001)
    )

    XCTAssertNotNil(old.linksByProcessID[replacement.pid])
    XCTAssertNil(current.linksByProcessID[replacement.pid])
    XCTAssertEqual(current.processIdentitiesByID[replacement.pid]?.birthToken, replacement.birthToken)
  }

  func testDuplicatePIDRowsAlwaysChooseNewestBirthRegardlessOfInputOrder() {
    let old = Fixtures.runningBackup
    let newest = DevProcess(
      pid: old.pid, parentPID: 1, executable: "/bin/other", command: "/bin/other",
      argumentVector: ["/bin/other"],
      resourceUsage: DevProcessResourceUsage(
        cpuPercent: 0, residentMemoryBytes: 0, elapsedTime: "04:00:01"
      ),
      birthToken: ProcessBirthToken(seconds: 40_000, microseconds: 1)
    )

    for processes in [[old, newest], [newest, old]] {
      let snapshot = AutomationPresentationSnapshot.build(
        inventory: Fixtures.inventoryGeneration7, processes: processes,
        longRunningThreshold: 14_400, now: Date(timeIntervalSince1970: 40_001)
      )
      XCTAssertNil(snapshot.linksByProcessID[old.pid])
      XCTAssertEqual(snapshot.processIdentitiesByID[old.pid]?.birthToken, newest.birthToken)
      XCTAssertEqual(snapshot.longRunningProcessIdentities, [ProcessIdentity(process: newest)])
    }
  }

  func testDuplicatePIDRowsWithSameBirthButConflictingMetadataFailClosed() {
    let first = Fixtures.runningBackup
    let conflicting = DevProcess(
      pid: first.pid, parentPID: first.parentPID, executable: first.executable,
      command: first.command, argumentVector: [first.executable, "different"],
      resourceUsage: first.resourceUsage, birthToken: first.birthToken
    )

    let snapshot = AutomationPresentationSnapshot.build(
      inventory: Fixtures.inventoryGeneration7, processes: [first, conflicting],
      longRunningThreshold: 14_400, now: Date(timeIntervalSince1970: 10_001)
    )

    XCTAssertTrue(snapshot.linksByProcessID.isEmpty)
    XCTAssertTrue(snapshot.processIdentitiesByID.isEmpty)
    XCTAssertTrue(snapshot.longRunningProcessIDs.isEmpty)
  }

  func testFiltersExcludeAppleByDefaultAndCombineExactFacetsDeterministically() {
    let apple = copiedRecord(
      Fixtures.userAgent, label: "com.apple.synthetic", ownership: .appleSystem,
      state: .idle, sourceKind: .launchDaemon
    )
    let user = copiedRecord(
      Fixtures.userAgent, label: "com.example.weekly-report", ownership: .user,
      state: .idle, sourceKind: .launchAgent
    )

    XCTAssertEqual(AutomationPresentation.filtered(
      [apple, user], source: .launchd, state: .idle, ownership: .all,
      searchText: "weekly", includeAppleSystemServices: false
    ).map(\.label), ["com.example.weekly-report"])
    XCTAssertEqual(AutomationPresentation.filtered(
      [apple, user], source: .launchd, state: .idle, ownership: .all,
      searchText: "", includeAppleSystemServices: true
    ).map(\.label), ["com.apple.synthetic", "com.example.weekly-report"])
  }

  func testInventoryCountExplainsAppleServicesHiddenByPolicy() {
    let count = AutomationPresentation.inventoryCount(
      visibleCount: 69,
      eligibleCount: 69,
      totalCount: 983
    )

    XCTAssertEqual(count.primaryText, "69 automations")
    XCTAssertEqual(count.contextText, "914 Apple system services hidden")
    XCTAssertEqual(
      count.accessibilityLabel,
      "69 automations. 914 Apple system services hidden. "
        + "In Settings, open Automations and enable Include Apple System Services to review them."
    )
  }

  func testInventoryCountSeparatesActiveFiltersFromPolicyHiddenServices() {
    let count = AutomationPresentation.inventoryCount(
      visibleCount: 5,
      eligibleCount: 69,
      totalCount: 983
    )

    XCTAssertEqual(count.primaryText, "5 of 69 automations")
    XCTAssertEqual(count.contextText, "914 Apple system services hidden")
  }

  func testInventoryCountOmitsHiddenContextWhenAppleServicesAreIncluded() {
    let count = AutomationPresentation.inventoryCount(
      visibleCount: 983,
      eligibleCount: 983,
      totalCount: 983
    )

    XCTAssertEqual(count.primaryText, "983 automations")
    XCTAssertNil(count.contextText)
    XCTAssertEqual(count.accessibilityLabel, "983 automations")
  }

  func testInventoryCountUsesSingularGrammarAndClampsInconsistentInputs() {
    XCTAssertEqual(
      AutomationPresentation.inventoryCount(
        visibleCount: 1,
        eligibleCount: 1,
        totalCount: 1
      ).primaryText,
      "1 automation"
    )
    XCTAssertEqual(
      AutomationPresentation.inventoryCount(
        visibleCount: 20,
        eligibleCount: 10,
        totalCount: 5
      ).primaryText,
      "5 automations"
    )
    XCTAssertEqual(
      AutomationPresentation.inventoryCount(
        visibleCount: 1,
        eligibleCount: 1,
        totalCount: 2
      ).contextText,
      "1 Apple system service hidden"
    )
  }

  func testThirdPartyOwnershipFilterIncludesManagedInspectionOnlyDefinitions() {
    let thirdParty = copiedRecord(
      Fixtures.userAgent, label: "third", ownership: .thirdPartySystem,
      state: .idle, sourceKind: .launchAgent
    )
    let managed = copiedRecord(
      Fixtures.userAgent, label: "managed", ownership: .managed,
      state: .idle, sourceKind: .launchAgent
    )
    let user = copiedRecord(
      Fixtures.userAgent, label: "user", ownership: .user,
      state: .idle, sourceKind: .launchAgent
    )

    XCTAssertEqual(
      AutomationPresentation.filtered(
        [thirdParty, managed, user], source: .all, state: nil, ownership: .thirdParty,
        searchText: "", includeAppleSystemServices: false
      ).map(\.label),
      ["managed", "third"]
    )
  }

  func testAutomatedAndLongRunningBadgesRemainIndependent() {
    XCTAssertEqual(
      AutomationPresentation.badges(isAutomated: true, isLongRunning: false, elapsed: "00:20:00"),
      [.automated]
    )
    XCTAssertEqual(
      AutomationPresentation.badges(isAutomated: false, isLongRunning: true, elapsed: "05:00:00"),
      [.longRunning("5h")]
    )
    XCTAssertEqual(
      AutomationPresentation.badges(isAutomated: true, isLongRunning: true, elapsed: "04:00:00"),
      [.automated, .longRunning("4h")]
    )
  }

  func testActivityTypeFiltersKeepAutomatedAndLongRunningIndependentAndCombinable() {
    XCTAssertTrue(AutomationActivityTypeFilter.all.matches(isAutomated: false, isLongRunning: false))
    XCTAssertTrue(AutomationActivityTypeFilter.automated.matches(isAutomated: true, isLongRunning: false))
    XCTAssertFalse(AutomationActivityTypeFilter.automated.matches(isAutomated: false, isLongRunning: true))
    XCTAssertTrue(AutomationActivityTypeFilter.longRunning.matches(isAutomated: false, isLongRunning: true))
    XCTAssertFalse(AutomationActivityTypeFilter.both.matches(isAutomated: true, isLongRunning: false))
    XCTAssertTrue(AutomationActivityTypeFilter.both.matches(isAutomated: true, isLongRunning: true))
  }

  func testAutomationSearchCoversArgumentsSourceScheduleAndOwningApplication() {
    let record = copiedRecord(
      Fixtures.userAgent,
      label: "com.example.report",
      ownership: .user,
      state: .idle,
      sourceKind: .launchAgent,
      displayName: "Weekly Report",
      providerBundleIdentifier: "com.example.owner",
      arguments: ["--workspace", "North Star"],
      sourceURL: URL(fileURLWithPath: "/Users/test/Library/LaunchAgents/report.plist"),
      schedule: AutomationSchedule(triggers: [.calendar("Monday")], summary: "Every Monday")
    )

    for query in ["weekly", "north star", "report.plist", "every monday", "example.owner"] {
      XCTAssertEqual(
        AutomationPresentation.filtered(
          [record], source: .all, state: nil, ownership: .all,
          searchText: query, includeAppleSystemServices: false
        ).map(\.id),
        [record.id],
        "Expected \(query) to match the complete automation search surface."
      )
    }
  }

  func testManagementActionsFollowExactCapabilityDecisionAndConcreteBackups() {
    let backup = AutomationBackup(
      id: .init(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!),
      recordID: Fixtures.userAgent.id,
      sourceURL: URL(fileURLWithPath: "/redacted"),
      backupURL: URL(fileURLWithPath: "/redacted"),
      checksum: "checksum",
      createdAt: Date(timeIntervalSince1970: 1)
    )
    let decision = AutomationCapabilityDecision(
      capabilities: [.startNow, .disable, .exportRecord, .remove, .restore],
      reason: nil
    )

    XCTAssertEqual(
      AutomationManagementPresentation.actions(
        decision: decision,
        backups: [backup],
        record: Fixtures.userAgent
      ),
      [.startNow, .disable, .exportRedacted, .exportUnredacted, .remove, .restore(backup.id)]
    )
    XCTAssertEqual(
      AutomationManagementPresentation.actions(
        decision: AutomationCapabilityDecision(
          capabilities: [.exportRecord],
          reason: "Modern background items must be managed in System Settings."
        ),
        backups: [backup],
        record: Fixtures.userAgent
      ),
      [.exportRedacted, .exportUnredacted]
    )

    let protected = copiedRecord(
      Fixtures.userAgent,
      label: "background",
      ownership: .thirdPartySystem,
      state: .idle,
      sourceKind: .serviceManagement,
      kind: .backgroundItem
    )
    XCTAssertEqual(
      AutomationManagementPresentation.actions(
        decision: AutomationCapabilityDecision(capabilities: [.exportRecord], reason: "Inspection only."),
        backups: [],
        record: protected
      ),
      [.exportRedacted]
    )
  }

  func testManagementActionChromeKeepsLifecycleActionsPinnedWithRedundantSemanticCues() {
    let expectations: [(
      action: AutomationManagementAction,
      placement: AutomationManagementActionPlacement,
      emphasis: AutomationManagementActionEmphasis,
      symbol: String
    )] = [
      (.startNow, .pinned, .positive, "play.fill"),
      (.stopCurrentRun, .pinned, .destructive, "stop.fill"),
      (.enable, .pinned, .positive, "checkmark.circle"),
      (.disable, .pinned, .caution, "pause.circle"),
      (.disableAndStop, .pinned, .destructive, "stop.circle.fill"),
      (.edit, .overflow, .neutral, "square.and.pencil"),
      (.duplicate, .overflow, .neutral, "plus.square.on.square"),
      (.importRecord, .overflow, .neutral, "square.and.arrow.down"),
      (.exportRedacted, .overflow, .neutral, "square.and.arrow.up"),
      (.exportUnredacted, .overflow, .caution, "lock.open.fill"),
      (.remove, .overflow, .destructive, "trash"),
      (.restore(.init(rawValue: UUID())), .history, .neutral, "clock.arrow.circlepath"),
    ]

    for expectation in expectations {
      XCTAssertEqual(expectation.action.placement, expectation.placement)
      XCTAssertEqual(expectation.action.emphasis, expectation.emphasis)
      XCTAssertEqual(expectation.action.systemImage, expectation.symbol)
    }
  }

  func testConfirmationPoliciesStateExactLifecycleConsequences() throws {
    let stop = try XCTUnwrap(AutomationManagementPresentation.confirmation(
      for: .stopCurrentRun,
      record: Fixtures.userAgent
    ))
    XCTAssertTrue(stop.consequence.contains("exact launchd service"))
    XCTAssertTrue(stop.consequence.contains("does not disable"))
    XCTAssertFalse(stop.consequence.contains("KeepAlive"))

    let cron = copiedRecord(
      Fixtures.userAgent,
      label: "nightly",
      ownership: .user,
      state: .running,
      sourceKind: .crontab,
      kind: .cron
    )
    XCTAssertTrue(try XCTUnwrap(AutomationManagementPresentation.confirmation(
      for: .stopCurrentRun,
      record: cron
    )).consequence.contains("strongly linked"))

    let start = try XCTUnwrap(AutomationManagementPresentation.confirmation(
      for: .startNow,
      record: Fixtures.userAgent
    ))
    XCTAssertTrue(start.consequence.contains("immediate launch"))

    XCTAssertTrue(try XCTUnwrap(AutomationManagementPresentation.confirmation(
      for: .enable,
      record: Fixtures.userAgent
    )).consequence.contains("does not start"))
    XCTAssertTrue(try XCTUnwrap(AutomationManagementPresentation.confirmation(
      for: .disable,
      record: Fixtures.userAgent
    )).consequence.contains("does not stop"))
    XCTAssertTrue(try XCTUnwrap(AutomationManagementPresentation.confirmation(
      for: .disableAndStop,
      record: Fixtures.userAgent
    )).consequence.contains("exact launchd service"))
    XCTAssertTrue(
      AutomationManagementPresentation.helpText(
        for: .stopCurrentRun,
        record: Fixtures.userAgent
      ).contains("exact launchd service")
    )
    XCTAssertTrue(
      AutomationManagementPresentation.helpText(
        for: .disableAndStop,
        record: Fixtures.userAgent
      ).contains("exact launchd service")
    )
    XCTAssertTrue(
      AutomationManagementPresentation.helpText(
        for: .stopCurrentRun,
        record: cron
      ).contains("strongly linked")
    )

    let remove = try XCTUnwrap(AutomationManagementPresentation.confirmation(
      for: .remove,
      record: Fixtures.userAgent
    ))
    XCTAssertEqual(remove.requiredLabel, Fixtures.userAgent.label)
    XCTAssertTrue(remove.consequence.contains("restoration manifest"))
    XCTAssertFalse(remove.isSatisfiedByLabel("\(Fixtures.userAgent.label) "))
    XCTAssertTrue(remove.isSatisfiedByLabel(Fixtures.userAgent.label))
  }

  func testUnredactedExportAndConcreteRestoreRequireExplicitConfirmation() throws {
    let backup = AutomationBackup(
      id: .init(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!),
      recordID: Fixtures.userAgent.id,
      sourceURL: URL(fileURLWithPath: "/redacted"),
      backupURL: URL(fileURLWithPath: "/redacted"),
      checksum: "checksum",
      createdAt: Date(timeIntervalSince1970: 10)
    )
    let export = try XCTUnwrap(AutomationManagementPresentation.confirmation(
      for: .exportUnredacted,
      record: Fixtures.userAgent
    ))
    XCTAssertTrue(export.consequence.contains("secrets"))

    let restore = try XCTUnwrap(AutomationManagementPresentation.confirmation(
      for: .restore(backup.id),
      record: Fixtures.userAgent,
      backups: [backup]
    ))
    XCTAssertTrue(restore.consequence.contains("verified backup"))
    XCTAssertTrue(restore.consequence.contains(backup.createdAt.formatted(date: .abbreviated, time: .shortened)))
  }

  func testOperationResultPresentationRedactsSecretsAndKeepsPartialRecoveryVisible() {
    let result = AutomationOperationResult(
      operation: .disable,
      status: .partialFailure("launchctl failed --token=super-secret"),
      appliedSteps: ["raw output --password=hunter2"],
      verificationEvidence: ["API_KEY=hidden"],
      rollback: .failed("rollback --secret=also-hidden"),
      manualRecovery: "Retry with --access-token=last-secret"
    )

    let presentation = AutomationManagementPresentation.result(result)
    XCTAssertEqual(presentation.title, "Partially completed")
    XCTAssertTrue(presentation.detail.contains("<redacted>"))
    XCTAssertFalse(presentation.detail.contains("super-secret"))
    XCTAssertFalse(presentation.recoveryGuidance?.contains("last-secret") ?? true)
    XCTAssertFalse(presentation.detail.contains("hunter2"))
    XCTAssertFalse(presentation.detail.contains("hidden"))
    let completePresentation = String(describing: presentation)
    for secret in ["super-secret", "hunter2", "hidden", "also-hidden", "last-secret"] {
      XCTAssertFalse(completePresentation.contains(secret))
    }
  }

  func testOperationResultPresentationKeepsRedactedAppliedVerificationAndRecoveryEvidence() {
    let backup = AutomationBackup(
      id: AutomationBackup.ID(rawValue: UUID(uuidString: "AAAA0000-0000-0000-0000-000000000001")!),
      recordID: Fixtures.userAgent.id,
      sourceURL: URL(fileURLWithPath: "/private/source.plist"),
      backupURL: URL(fileURLWithPath: "/private/backup.plist"),
      checksum: String(repeating: "a", count: 64),
      createdAt: Date(timeIntervalSince1970: 20_000)
    )
    let result = AutomationOperationResult(
      operation: .edit(AutomationEditPayload(
        label: "fixture", executable: "/bin/true", arguments: [], environment: [:],
        workingDirectory: nil, schedule: Fixtures.userAgent.schedule,
        rawRepresentation: nil
      )),
      status: .succeeded,
      appliedSteps: ["Applied --token=private-value"],
      verificationEvidence: ["Verified API_KEY=private-value"],
      rollback: .restored(backup.id),
      manualRecovery: nil,
      backup: backup,
      fileMutationEvidence: AutomationFilePartialMutation(
        kind: .replace,
        commitState: .unknown,
        observedFiles: [],
        recoveryHandle: nil,
        recoveryHandles: [],
        resultURL: nil
      )
    )

    let presentation = AutomationManagementPresentation.result(result)
    XCTAssertEqual(presentation.appliedEvidence, ["Applied --token=<redacted>"])
    XCTAssertEqual(presentation.verificationEvidence, ["Verified API_KEY=<redacted>"])
    XCTAssertTrue(presentation.rollbackEvidence.contains("restored"))
    XCTAssertTrue(presentation.rollbackEvidence.contains("AAAA0000"))
    XCTAssertTrue(presentation.backupEvidence?.contains(String(repeating: "a", count: 12)) == true)
    XCTAssertEqual(
      presentation.mutationEvidence,
      ["Source replacement outcome is unknown; 0 observed files and 0 recovery handles were retained."]
    )
    XCTAssertFalse(String(describing: presentation).contains("private-value"))
    XCTAssertFalse(String(describing: presentation).contains("/private/"))
  }

  func testOperationResultPresentationExposesEveryExactRecoveryLocation() throws {
    let directoryURL = URL(fileURLWithPath: "/tmp/devscope-recovery", isDirectory: true)
    let directory = try XCTUnwrap(AutomationDirectoryAuthorization(
      directoryURL: directoryURL,
      resourceIdentifier: "directory-id"
    ))
    let firstURL = directoryURL.appendingPathComponent(".devscope-recovery-first")
    let secondURL = directoryURL.appendingPathComponent(".devscope-recovery-second")
    let first = try XCTUnwrap(AutomationFileAuthorization(
      fileURL: firstURL,
      directory: directory,
      expectation: .existing(resourceIdentifier: "first-id")
    ))
    let second = try XCTUnwrap(AutomationFileAuthorization(
      fileURL: secondURL,
      directory: directory,
      expectation: .existing(resourceIdentifier: "second-id")
    ))
    let result = AutomationOperationResult(
      operation: .remove,
      status: .partialFailure("Automatic recovery did not complete."),
      appliedSteps: [],
      verificationEvidence: [],
      rollback: .notNeeded,
      manualRecovery: nil,
      fileMutationEvidence: AutomationFilePartialMutation(
        kind: .remove,
        commitState: .unknown,
        observedFiles: [],
        recoveryHandle: first,
        recoveryHandles: [second],
        resultURL: nil
      )
    )

    let guidance = try XCTUnwrap(AutomationManagementPresentation.result(result).recoveryGuidance)

    XCTAssertTrue(guidance.contains(firstURL.path), guidance)
    XCTAssertTrue(guidance.contains(secondURL.path), guidance)
  }

  func testCronConfirmationDisplaysRedactedCommandButBuildsExactTypedOperation() throws {
    let cron = copiedRecord(
      Fixtures.userAgent,
      label: "nightly",
      ownership: .user,
      state: .idle,
      sourceKind: .crontab,
      kind: .cron,
      commandSignature: "/usr/bin/curl --token=super-secret https://example.test"
    )

    let policy = try XCTUnwrap(AutomationManagementPresentation.confirmation(
      for: .startNow,
      record: cron
    ))
    XCTAssertEqual(
      policy.displayedCommand,
      "/usr/bin/curl --token=<redacted> https://example.test"
    )
    XCTAssertEqual(
      AutomationManagementPresentation.confirmedOperation(for: .startNow, record: cron),
      .confirmedRunToCompletion(AutomationRunToCompletionConfirmation(
        recordID: cron.id,
        sourceChecksum: cron.sourceChecksum,
        exactCommand: "/usr/bin/curl --token=super-secret https://example.test"
      ))
    )
  }

  func testEditorValidationRequiresApprovedDuplicateDestinationAndValidRawPlist() {
    XCTAssertEqual(
      AutomationEditorPresentation.validationMessage(
        record: Fixtures.userAgent,
        purposeIsDuplicate: true,
        label: "copy",
        executable: "/bin/true",
        arguments: [],
        environment: [:],
        schedule: Fixtures.userAgent.schedule,
        usesRawRepresentation: false,
        rawData: nil,
        duplicateDestination: nil
      ),
      "Choose a label that resolves to a distinct approved destination."
    )
    XCTAssertEqual(
      AutomationEditorPresentation.validationMessage(
        record: Fixtures.userAgent,
        purposeIsDuplicate: false,
        label: "valid",
        executable: "/bin/true",
        arguments: [],
        environment: [:],
        schedule: Fixtures.userAgent.schedule,
        usesRawRepresentation: true,
        rawData: Data("not a plist".utf8),
        duplicateDestination: nil
      ),
      "The raw property list is not valid."
    )
  }

  func testEditorRawLaunchdValidationRejectsMismatchedLabelAndCommand() throws {
    let destination = URL(fileURLWithPath: "/Users/test/Library/LaunchAgents/copy.plist")
    func plist(_ label: String, _ program: String) throws -> Data {
      try PropertyListSerialization.data(
        fromPropertyList: ["Label": label, "Program": program],
        format: .xml,
        options: 0
      )
    }

    XCTAssertEqual(
      AutomationEditorPresentation.validationMessage(
        record: Fixtures.userAgent, purposeIsDuplicate: true,
        label: "expected", executable: "/bin/true", arguments: [], environment: [:],
        schedule: Fixtures.userAgent.schedule, usesRawRepresentation: true,
        rawData: try plist("different", "/bin/true"), duplicateDestination: destination
      ),
      "The raw property-list label does not match the reviewed label."
    )
    XCTAssertEqual(
      AutomationEditorPresentation.validationMessage(
        record: Fixtures.userAgent, purposeIsDuplicate: true,
        label: "expected", executable: "/bin/true", arguments: [], environment: [:],
        schedule: Fixtures.userAgent.schedule, usesRawRepresentation: true,
        rawData: try plist("expected", "/bin/false"), duplicateDestination: destination
      ),
      "The raw property-list command does not match the reviewed executable and arguments."
    )
  }

  func testEditorRawCronValidationRequiresReviewedEntryAndRetainedOriginalForDuplicate() {
    let schedule = AutomationSchedule(triggers: [.cron("* * * * *")], summary: "Every minute")
    let cron = copiedRecord(
      Fixtures.userAgent, label: "cron", ownership: .user, state: .idle,
      sourceKind: .crontab, kind: .cron, schedule: schedule,
      commandSignature: "/bin/true --old"
    )
    let destination = URL(fileURLWithPath: "/tmp/cron-source")

    XCTAssertEqual(
      AutomationEditorPresentation.validationMessage(
        record: cron, purposeIsDuplicate: true, label: "cron-copy",
        executable: "/bin/true", arguments: ["--new"], environment: cron.environment, schedule: schedule,
        usesRawRepresentation: true,
        rawData: Data("DEVSCOPE_FIXTURE=synthetic\n* * * * * /bin/true --new\n".utf8),
        duplicateDestination: destination
      ),
      "The duplicate crontab must retain the selected entry and add one reviewed entry."
    )
    XCTAssertNil(AutomationEditorPresentation.validationMessage(
      record: cron, purposeIsDuplicate: true, label: "cron-copy",
      executable: "/bin/true", arguments: ["--new"], environment: cron.environment, schedule: schedule,
      usesRawRepresentation: true,
      rawData: Data("DEVSCOPE_FIXTURE=synthetic\n* * * * * /bin/true --old\n* * * * * /bin/true --new\n".utf8),
      duplicateDestination: destination
    ))
  }

  func testEditorParsesEditableEnvironmentAndEverySupportedScheduleToken() throws {
    let environment = try XCTUnwrap(AutomationEditorPresentation.environment(
      from: "API_URL=https://example.test?a=b\nTOKEN=value\n"
    ))
    XCTAssertEqual(environment, ["API_URL": "https://example.test?a=b", "TOKEN": "value"])
    XCTAssertEqual(
      AutomationEditorPresentation.environmentText(for: environment),
      "API_URL=https://example.test?a=b\nTOKEN=value"
    )

    let schedule = try XCTUnwrap(AutomationEditorPresentation.schedule(
      from: "run-at-load\ninterval 900\nkeep-alive\ncalendar Mondays at 08:30"
    ))
    XCTAssertEqual(schedule.triggers, [
      .runAtLoad,
      .keepAlive,
      .interval(seconds: 900),
      .calendar("Mondays at 08:30"),
    ])
    XCTAssertEqual(
      AutomationEditorPresentation.scheduleText(for: schedule),
      "run-at-load\nkeep-alive\ninterval 900\ncalendar Mondays at 08:30"
    )
    XCTAssertNil(AutomationEditorPresentation.environment(from: "INVALID"))
    XCTAssertNil(AutomationEditorPresentation.schedule(from: "interval 0"))
    XCTAssertNil(AutomationEditorPresentation.schedule(from: "unknown trigger"))
  }

  func testEditorScheduleNormalizesManagerRoundTripAndRejectsContradictoryCombinations() throws {
    XCTAssertEqual(
      try XCTUnwrap(AutomationEditorPresentation.schedule(from: "keep-alive")).triggers,
      [.runAtLoad, .keepAlive]
    )
    XCTAssertEqual(
      try XCTUnwrap(AutomationEditorPresentation.schedule(from: "at-login")).triggers,
      [.runAtLoad]
    )
    XCTAssertNil(AutomationEditorPresentation.schedule(from: "on-demand\ninterval 60"))
    XCTAssertNil(AutomationEditorPresentation.schedule(from: "interval 60\ninterval 120"))
    XCTAssertNil(AutomationEditorPresentation.schedule(from: "cron * * * * *\nrun-at-load"))
    XCTAssertEqual(
      try XCTUnwrap(AutomationEditorPresentation.schedule(
        from: "calendar First\ninterval 60\ncalendar Second"
      )).triggers,
      [.interval(seconds: 60), .calendar("First"), .calendar("Second")]
    )
    XCTAssertEqual(
      AutomationEditorPresentation.scheduleText(for: AutomationSchedule(
        triggers: [.atLogin],
        summary: "At login"
      )),
      "run-at-load"
    )
  }

  func testRawLaunchdValidationAcceptsChangedReviewedEnvironmentAndSchedule() throws {
    let changedSchedule = AutomationSchedule(
      triggers: [.runAtLoad, .interval(seconds: 900)],
      summary: "At load, every 15 minutes"
    )
    let changedEnvironment = ["MODE": "audit"]
    let raw = try PropertyListSerialization.data(
      fromPropertyList: [
        "Label": "edited",
        "ProgramArguments": ["/bin/true", "--edited"],
        "EnvironmentVariables": changedEnvironment,
        "RunAtLoad": true,
        "StartInterval": 900,
      ],
      format: .xml,
      options: 0
    )

    XCTAssertNil(AutomationEditorPresentation.validationMessage(
      record: Fixtures.userAgent,
      purposeIsDuplicate: false,
      label: "edited",
      executable: "/bin/true",
      arguments: ["--edited"],
      environment: changedEnvironment,
      schedule: changedSchedule,
      usesRawRepresentation: true,
      rawData: raw,
      duplicateDestination: Fixtures.userAgent.sourceURL
    ))
    XCTAssertNotNil(AutomationEditorPresentation.validationMessage(
      record: Fixtures.userAgent,
      purposeIsDuplicate: false,
      label: "edited",
      executable: "/bin/true",
      arguments: ["--edited"],
      environment: [:],
      schedule: changedSchedule,
      usesRawRepresentation: true,
      rawData: raw,
      duplicateDestination: Fixtures.userAgent.sourceURL
    ))
  }

  func testImportPreviewValidatesKindAndExactDestinationBeforeApply() throws {
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["Label": "com.example.imported", "Program": "/bin/true"],
      format: .xml,
      options: 0
    )
    let destination = URL(fileURLWithPath: "/Users/test/Library/LaunchAgents/imported.plist")
    let valid = AutomationImportPresentation(
      data: data,
      expectedRecord: Fixtures.userAgent,
      destination: destination
    )
    XCTAssertTrue(valid.canApply)
    XCTAssertEqual(valid.destination, destination)
    XCTAssertTrue(valid.summary.contains("com.example.imported"))

    let invalid = AutomationImportPresentation(
      data: Data("* * * * * /bin/true".utf8),
      expectedRecord: Fixtures.userAgent,
      destination: destination
    )
    XCTAssertFalse(invalid.canApply)
    XCTAssertEqual(invalid.validationMessage, "The selected file is not a labeled launchd property list.")
  }

  func testImportPreviewNamesReplacementTargetOwnershipAndConsequence() throws {
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["Label": "com.example.imported", "Program": "/bin/true"],
      format: .xml,
      options: 0
    )
    let presentation = AutomationImportPresentation(
      data: data,
      expectedRecord: Fixtures.userAgent,
      destination: URL(fileURLWithPath: "/Users/test/Library/LaunchAgents/imported.plist")
    )

    XCTAssertEqual(presentation.targetLabel, Fixtures.userAgent.label)
    XCTAssertEqual(presentation.targetOwnership, "User owned")
    XCTAssertTrue(presentation.consequence.contains("replace"))
    XCTAssertTrue(presentation.consequence.contains(Fixtures.userAgent.label))
    XCTAssertTrue(presentation.consequence.contains("checksum"))
  }

  func testVisibleSelectionDropsARecordExcludedByFilters() {
    let visible = [Fixtures.userAgent.id]
    XCTAssertEqual(
      AutomationPresentation.resolvedSelection(current: nil, visibleIDs: visible),
      Fixtures.userAgent.id
    )
    XCTAssertEqual(
      AutomationPresentation.resolvedSelection(
        current: AutomationRecord.ID(rawValue: "hidden"),
        visibleIDs: visible
      ),
      Fixtures.userAgent.id
    )
    XCTAssertEqual(
      AutomationPresentation.resolvedSelection(current: Fixtures.userAgent.id, visibleIDs: visible),
      Fixtures.userAgent.id
    )
    XCTAssertNil(AutomationPresentation.resolvedSelection(
      current: Fixtures.userAgent.id,
      visibleIDs: []
    ))
  }
}

private func copiedRecord(
  _ source: AutomationRecord,
  label: String,
  ownership: AutomationOwnership,
  state: AutomationState,
  sourceKind: AutomationSourceKind,
  kind: AutomationKind? = nil,
  displayName: String? = nil,
  providerBundleIdentifier: String? = nil,
  arguments: [String]? = nil,
  sourceURL: URL? = nil,
  schedule: AutomationSchedule? = nil,
  commandSignature: String? = nil
) -> AutomationRecord {
  AutomationRecord(
    id: AutomationRecord.ID(source: sourceKind, ownerUID: 501, label: label, sourcePath: "/\(label)"),
    kind: kind ?? source.kind, sourceKind: sourceKind, label: label, displayName: displayName ?? label,
    providerBundleIdentifier: providerBundleIdentifier ?? source.providerBundleIdentifier, ownerUID: source.ownerUID,
    ownership: ownership, executable: source.executable, arguments: arguments ?? source.arguments,
    commandSignature: commandSignature ?? source.commandSignature, environment: source.environment,
    workingDirectory: source.workingDirectory, schedule: schedule ?? source.schedule,
    sourceURL: sourceURL ?? source.sourceURL, sourceChecksum: source.sourceChecksum,
    enabledState: source.enabledState, loadState: source.loadState,
    approvalState: source.approvalState, state: state, evidence: source.evidence,
    capabilities: source.capabilities, validationFindings: source.validationFindings
  )
}
