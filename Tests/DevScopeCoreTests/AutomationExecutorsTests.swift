import CryptoKit
import Darwin
import XCTest
@testable import DevScopeCore

final class AutomationExecutorsTests: XCTestCase {
  func testCronPublicCompositionInitializerAcceptsFreshProcessSnapshotProvider() async throws {
    let runner = RecordingAutomationCommandRunner()
    let record = cronRecord(command: "/usr/bin/true", scheduleExpression: "* * * * *")
    let executor = CronAutomationExecutor(
      runner: runner,
      fileSystem: InMemoryAutomationFileSystem(),
      currentUID: 501,
      processSnapshot: { [] }
    )

    let confirmation = AutomationRunToCompletionConfirmation(
      recordID: record.id,
      sourceChecksum: record.sourceChecksum,
      exactCommand: "/usr/bin/true"
    )
    let result = try await executor.apply(.confirmedRunToCompletion(confirmation), to: record)

    XCTAssertEqual(result.postconditions, [.targetResolved, .runCompleted])
  }

  func testCronChecksumNormalizesLineEndingsAndExactlyOneTerminalNewline() throws {
    let zero = Data("0 * * * * /usr/bin/true".utf8)
    let one = Data("0 * * * * /usr/bin/true\n".utf8)
    let multiple = Data("0 * * * * /usr/bin/true\n\n\n".utf8)
    let crlf = Data("0 * * * * /usr/bin/true\r\n".utf8)

    XCTAssertEqual(CronDocumentChecksum.checksum(zero), CronDocumentChecksum.checksum(one))
    XCTAssertEqual(CronDocumentChecksum.checksum(one), CronDocumentChecksum.checksum(multiple))
    XCTAssertEqual(CronDocumentChecksum.checksum(one), CronDocumentChecksum.checksum(crlf))
    XCTAssertNotEqual(
      CronDocumentChecksum.checksum(Data("# interior\n\n0 * * * * /usr/bin/true\n".utf8)),
      CronDocumentChecksum.checksum(Data("# interior\n0 * * * * /usr/bin/true\n".utf8))
    )
  }

  func testLaunchdStartUsesKickstartWithAnArgumentArray() async throws {
    let runner = RecordingAutomationCommandRunner()
    let executor = LaunchdAutomationExecutor(runner: runner, guiUID: 501)

    _ = try await executor.apply(.startNow, to: Fixtures.runningUserAgent)

    XCTAssertEqual(runner.invocations, [
      AutomationCommand(
        executable: "/bin/launchctl",
        arguments: ["kickstart", "gui/501/com.example.backup"]
      ),
    ])
  }

  func testLaunchdStartBootstrapsCanonicalSourceBeforeKickstartingAnUnloadedService() async throws {
    let runner = RecordingAutomationCommandRunner()
    let executor = LaunchdAutomationExecutor(runner: runner, guiUID: 501)

    _ = try await executor.apply(.startNow, to: Fixtures.userAgent)

    XCTAssertEqual(runner.invocations.map(\.arguments), [
      ["bootstrap", "gui/501", Fixtures.userAgent.sourceURL!.path],
      ["kickstart", "gui/501/com.example.backup"],
    ])
  }

  func testLaunchdDisablePreventsFutureLaunchesWithoutClaimingTheProcessStopped() async throws {
    let runner = RecordingAutomationCommandRunner()
    let executor = LaunchdAutomationExecutor(runner: runner, guiUID: 501)

    let result = try await executor.apply(.disable, to: Fixtures.runningUserAgent)

    XCTAssertEqual(runner.invocations, [
      AutomationCommand(
        executable: "/bin/launchctl",
        arguments: ["disable", "gui/501/com.example.backup"]
      ),
    ])
    XCTAssertEqual(result.postconditions, [.futureLaunchesDisabled])
    XCTAssertFalse(result.postconditions.contains(.noLinkedProcess))
  }

  func testLaunchdDisableAndStopDisablesThenBootsOutTheExactService() async throws {
    let birth = ProcessBirthToken(seconds: 9_000, microseconds: 7)
    let process = classifiedProcess(pid: 44_001, birth: birth)
    let runner = RecordingAutomationCommandRunner()
    let executor = LaunchdAutomationExecutor(runner: runner, guiUID: 501)

    let result = try await executor.apply(
      .disableAndStop,
      to: Fixtures.runningUserAgent,
      linkedProcesses: [process],
      proposedSourceURL: nil
    )

    XCTAssertEqual(runner.invocations.map(\.arguments), [
      ["disable", "gui/501/com.example.backup"],
      ["bootout", "gui/501/com.example.backup"],
    ])
    XCTAssertEqual(result.postconditions, [.futureLaunchesDisabled, .noLinkedProcess])
  }

  func testLaunchdEnableBootstrapsCanonicalPlistOnlyWhenTargetIsNotLoaded() async throws {
    let runner = ScriptedAutomationCommandRunner(results: [
      missingLaunchctlServiceResult(),
      successfulCommandResult(),
      successfulCommandResult(),
    ])
    let executor = LaunchdAutomationExecutor(runner: runner, guiUID: 501)

    let result = try await executor.apply(.enable, to: Fixtures.userAgent)

    XCTAssertEqual(runner.invocations.map(\.arguments), [
      ["print", "gui/501/com.example.backup"],
      ["enable", "gui/501/com.example.backup"],
      ["bootstrap", "gui/501", Fixtures.userAgent.sourceURL!.path],
    ])
    XCTAssertEqual(result.postconditions, [.futureLaunchesEnabled, .targetResolved])
    XCTAssertFalse(result.postconditions.contains(.currentRunStarted))
  }

  func testLaunchdEnableFailsClosedWhenPrintIsPermissionDenied() async {
    let runner = ScriptedAutomationCommandRunner(results: [
      AutomationCommandResult(
        status: 113,
        standardOutput: Data(),
        standardError: Data("Operation not permitted\n".utf8)
      ),
    ])
    let executor = LaunchdAutomationExecutor(runner: runner, guiUID: 501)

    await XCTAssertThrowsErrorAsync {
      _ = try await executor.apply(.enable, to: Fixtures.userAgent)
    }

    XCTAssertEqual(runner.invocations.map(\.arguments), [
      ["print", "gui/501/com.example.backup"],
    ])
    XCTAssertEqual(runner.invocations.first?.environment, ["LC_ALL": "C"])
  }

  func testLaunchctlMissingServiceClassifierRejectsUnexpectedStatusOrDiagnostic() {
    let unexpectedDiagnostic = AutomationCommandResult(
      status: 113,
      standardOutput: Data(),
      standardError: Data("Operation not permitted\n".utf8)
    )
    let unexpectedStatus = AutomationCommandResult(
      status: 5,
      standardOutput: Data(),
      standardError: missingLaunchctlServiceResult().standardError
    )

    XCTAssertEqual(
      LaunchctlServiceTargetClassifier.classify(
        unexpectedDiagnostic,
        label: "com.example.backup",
        guiUID: 501
      ),
      .unknown
    )
    XCTAssertEqual(
      LaunchctlServiceTargetClassifier.classify(
        unexpectedStatus,
        label: "com.example.backup",
        guiUID: 501
      ),
      .unknown
    )
  }

  func testLaunchdDuplicateExplicitlyDisablesTheDistinctCopyWithoutLoadingIt() async throws {
    let label = "com.example.backup.copy"
    let destination = URL(fileURLWithPath: "/tmp/devscope-fixtures/\(label).plist")
    let data = try PropertyListSerialization.data(
      fromPropertyList: [
        "Label": label,
        "ProgramArguments": ["/bin/sleep", "14400"],
      ],
      format: .xml,
      options: 0
    )
    let fileSystem = InMemoryAutomationFileSystem(files: [destination: data])
    let runner = RecordingAutomationCommandRunner()
    let executor = LaunchdAutomationExecutor(
      runner: runner,
      guiUID: 501,
      fileSystem: fileSystem
    )
    let payload = AutomationEditPayload(
      label: label,
      executable: "/bin/sleep",
      arguments: ["14400"],
      environment: [:],
      workingDirectory: nil,
      schedule: Fixtures.userAgent.schedule,
      rawRepresentation: data,
      destination: destination
    )

    let result = try await executor.apply(
      .duplicate(payload),
      to: Fixtures.userAgent,
      linkedProcesses: [],
      proposedSourceURL: destination
    )

    XCTAssertEqual(runner.invocations.map(\.arguments), [
      ["disable", "gui/501/\(label)"],
    ])
    XCTAssertTrue(result.postconditions.contains(.futureLaunchesDisabled))
    XCTAssertFalse(result.postconditions.contains(.targetResolved))
  }

  func testLaunchdStopBootsOutTheExactServiceInsteadOfSignallingItsKeepAliveProcess() async throws {
    let birth = ProcessBirthToken(seconds: 9_000, microseconds: 7)
    let process = classifiedProcess(pid: 44_001, birth: birth)
    let runner = RecordingAutomationCommandRunner()
    let executor = LaunchdAutomationExecutor(runner: runner, guiUID: 501)

    let result = try await executor.apply(
      .stopCurrentRun,
      to: Fixtures.runningUserAgent,
      linkedProcesses: [process],
      proposedSourceURL: nil
    )

    XCTAssertEqual(runner.invocations.map(\.arguments), [
      ["bootout", "gui/501/com.example.backup"],
    ])
    XCTAssertEqual(result.postconditions, [.noLinkedProcess])
  }

  func testLaunchdStopFailsClosedWhenBootoutFails() async {
    let birth = ProcessBirthToken(seconds: 9_000, microseconds: 7)
    let process = classifiedProcess(pid: 44_002, birth: birth)
    let runner = ScriptedAutomationCommandRunner(statuses: [5])
    let executor = LaunchdAutomationExecutor(runner: runner, guiUID: 501)

    do {
      _ = try await executor.apply(
        .stopCurrentRun,
        to: Fixtures.runningUserAgent,
        linkedProcesses: [process],
        proposedSourceURL: nil
      )
      XCTFail("Expected failed bootout to fail closed")
    } catch {
      XCTAssertEqual(
        error as? AutomationExecutorError,
        .commandFailed(executable: "/bin/launchctl", status: 5)
      )
    }
    XCTAssertEqual(runner.invocations.map(\.arguments), [
      ["bootout", "gui/501/com.example.backup"],
    ])
  }

  func testLaunchdRollbackRestoresDisabledButLoadedStateExactly() async throws {
    let runner = ScriptedAutomationCommandRunner(results: [
      successfulCommandResult(),
      missingLaunchctlServiceResult(),
      successfulCommandResult(),
    ])
    let executor = LaunchdAutomationExecutor(runner: runner, guiUID: 501)
    let state = AutomationPreTransactionState(
      enabledState: .disabled,
      loadState: .loaded,
      linkedProcesses: []
    )

    let result = try await executor.restorePreTransactionState(
      state,
      for: Fixtures.runningUserAgent,
      recovery: verifiedRecoveryInput(
        data: Data(),
        url: URL(fileURLWithPath: "/tmp/recovery.backup")
      ),
      linkedProcesses: [],
      expectedAppliedState: nil
    )

    XCTAssertEqual(runner.invocations.map(\.arguments), [
      ["disable", "gui/501/com.example.backup"],
      ["print", "gui/501/com.example.backup"],
      ["bootstrap", "gui/501", Fixtures.runningUserAgent.sourceURL!.path],
    ])
    XCTAssertEqual(result.postconditions, [.preTransactionStateRestored(state)])
  }

  func testLaunchdRollbackFailsClosedWhenPrintStateIsUnknown() async {
    let runner = ScriptedAutomationCommandRunner(results: [
      successfulCommandResult(),
      AutomationCommandResult(
        status: 113,
        standardOutput: Data(),
        standardError: Data("Operation not permitted\n".utf8)
      ),
    ])
    let executor = LaunchdAutomationExecutor(runner: runner, guiUID: 501)
    let state = AutomationPreTransactionState(
      enabledState: .disabled,
      loadState: .loaded,
      linkedProcesses: []
    )

    await XCTAssertThrowsErrorAsync {
      _ = try await executor.restorePreTransactionState(
        state,
        for: Fixtures.runningUserAgent,
        recovery: verifiedRecoveryInput(
          data: Data(),
          url: URL(fileURLWithPath: "/tmp/recovery.backup")
        ),
        linkedProcesses: [],
        expectedAppliedState: nil
      )
    }

    XCTAssertEqual(runner.invocations.map(\.arguments), [
      ["disable", "gui/501/com.example.backup"],
      ["print", "gui/501/com.example.backup"],
    ])
  }

  func testLaunchdRemoveUsesStillExistingTrashPathAndProvesTargetUnresolved() async throws {
    let runner = ScriptedAutomationCommandRunner(results: [
      missingLaunchctlServiceResult(),
      successfulCommandResult(),
      missingLaunchctlServiceResult(),
    ])
    let executor = LaunchdAutomationExecutor(runner: runner, guiUID: 501)
    let trashURL = URL(fileURLWithPath: "/Users/test/.Trash/backup.plist")

    let result = try await executor.apply(
      .remove,
      to: Fixtures.userAgent,
      linkedProcesses: [],
      proposedSourceURL: trashURL
    )

    XCTAssertEqual(runner.invocations.map(\.arguments), [
      ["print", "gui/501/com.example.backup"],
      ["bootout", "gui/501", trashURL.path],
      ["print", "gui/501/com.example.backup"],
    ])
    XCTAssertEqual(result.postconditions, [.sourceRemoved, .targetUnresolved])
  }

  func testLaunchdRemoveNeverClaimsSuccessWhenFallbackFailsOrTargetStillResolves() async {
    let trashURL = URL(fileURLWithPath: "/Users/test/.Trash/backup.plist")
    for statuses in [[113, 5], [0, 0, 0]] as [[Int32]] {
      let runner = ScriptedAutomationCommandRunner(statuses: statuses)
      let executor = LaunchdAutomationExecutor(runner: runner, guiUID: 501)
      await XCTAssertThrowsErrorAsync {
        _ = try await executor.apply(
          .remove,
          to: Fixtures.userAgent,
          linkedProcesses: [],
          proposedSourceURL: trashURL
        )
      }
    }
  }

  func testLaunchdRemoveDoesNotClaimUnresolvedForUnexpectedFinalPrintFailure() async {
    let trashURL = URL(fileURLWithPath: "/Users/test/.Trash/backup.plist")
    let runner = ScriptedAutomationCommandRunner(results: [
      missingLaunchctlServiceResult(),
      successfulCommandResult(),
      AutomationCommandResult(
        status: 113,
        standardOutput: Data(),
        standardError: Data("Operation not permitted\n".utf8)
      ),
    ])
    let executor = LaunchdAutomationExecutor(runner: runner, guiUID: 501)

    await XCTAssertThrowsErrorAsync {
      _ = try await executor.apply(
        .remove,
        to: Fixtures.userAgent,
        linkedProcesses: [],
        proposedSourceURL: trashURL
      )
    }

    XCTAssertEqual(runner.invocations.map(\.arguments), [
      ["print", "gui/501/com.example.backup"],
      ["bootout", "gui/501", trashURL.path],
      ["print", "gui/501/com.example.backup"],
    ])
  }

  func testCommandFailureReportsOnlyExecutableAndStatus() async {
    let secret = "TOKEN=do-not-log"
    let runner = ScriptedAutomationCommandRunner(results: [
      AutomationCommandResult(
        status: 78,
        standardOutput: Data(secret.utf8),
        standardError: Data(secret.utf8)
      ),
    ])
    let executor = LaunchdAutomationExecutor(runner: runner, guiUID: 501)

    do {
      _ = try await executor.apply(.startNow, to: Fixtures.userAgent)
      XCTFail("Expected the nonzero command to fail")
    } catch {
      XCTAssertEqual(
        error as? AutomationExecutorError,
        .commandFailed(executable: "/bin/launchctl", status: 78)
      )
      XCTAssertFalse(String(describing: error).contains(secret))
    }
  }

  func testCronRunNowRequiresTypedConfirmationAndPassesOneExactCommandArgument() async throws {
    let runner = RecordingAutomationCommandRunner()
    let record = cronRecord(
      command: "printf '%s' \"$TOKEN\" | /usr/bin/logger",
      environment: ["SHELL": "/bin/zsh"]
    )
    let executor = CronAutomationExecutor(runner: runner, fileSystem: InMemoryAutomationFileSystem(), currentUID: 501)
    let confirmation = AutomationRunToCompletionConfirmation(
      recordID: record.id,
      sourceChecksum: record.sourceChecksum,
      exactCommand: record.commandSignature!
    )

    let result = try await executor.apply(.confirmedRunToCompletion(confirmation), to: record)

    XCTAssertEqual(runner.invocations, [
      AutomationCommand(
        executable: "/bin/zsh",
        arguments: ["-c", "printf '%s' \"$TOKEN\" | /usr/bin/logger"],
        environment: record.environment
      ),
    ])
    XCTAssertEqual(result.postconditions, [.targetResolved, .runCompleted])
  }

  func testCronUnconfirmedStartNowFailsBeforeCommandInvocation() async {
    let runner = RecordingAutomationCommandRunner()
    let executor = CronAutomationExecutor(runner: runner, fileSystem: InMemoryAutomationFileSystem(), currentUID: 501)

    await XCTAssertThrowsErrorAsync {
      _ = try await executor.apply(.startNow, to: cronRecord(command: "/usr/bin/true"))
    }

    XCTAssertTrue(runner.invocations.isEmpty)
  }

  func testCronEditInstallsAndVerifiesTheCompleteLosslessDocumentThroughA0600File() async throws {
    let sourceURL = URL(fileURLWithPath: "/tmp/devscope-fixtures/current-user.crontab")
    let document = "SHELL=/bin/zsh\n# keep this comment\n0 * * * * /usr/bin/true\n"
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: Data(document.utf8)])
    let runner = ScriptedAutomationCommandRunner(results: [
      AutomationCommandResult(status: 0, standardOutput: Data(), standardError: Data()),
      AutomationCommandResult(status: 0, standardOutput: Data(document.utf8), standardError: Data()),
    ])
    let executor = CronAutomationExecutor(runner: runner, fileSystem: fileSystem, currentUID: 501)

    let result = try await executor.apply(
      .edit(AutomationEditPayload(
        label: "Cron entry 1",
        executable: "/usr/bin/true",
        arguments: [],
        environment: ["SHELL": "/bin/zsh"],
        workingDirectory: nil,
        schedule: AutomationSchedule(triggers: [.cron("0 * * * *")], summary: "Hourly"),
        rawRepresentation: Data(document.utf8)
      )),
      to: cronRecord(command: "/usr/bin/true"),
      linkedProcesses: [],
      proposedSourceURL: sourceURL
    )

    guard case .writeTemporary(let temporaryURL, permissions: 0o600) = fileSystem.recordedOperations.first else {
      return XCTFail("Expected an owner-only complete-document staging file")
    }
    XCTAssertEqual(runner.invocations, [
      AutomationCommand(executable: "/usr/bin/crontab", arguments: [temporaryURL.path]),
      AutomationCommand(executable: "/usr/bin/crontab", arguments: ["-l"], environment: ["LC_ALL": "C"]),
    ])
    let checksum = SHA256.hash(data: Data(document.utf8)).map { String(format: "%02x", $0) }.joined()
    XCTAssertTrue(result.postconditions.contains(.sourceInstalled))
    XCTAssertTrue(result.postconditions.contains(.sourceChecksum(checksum)))
  }

  func testCronInstallDoesNotClaimPostconditionsWhenRelistedDocumentDiffers() async {
    let sourceURL = URL(fileURLWithPath: "/tmp/devscope-fixtures/current-user.crontab")
    let intended = Data("0 * * * * /usr/bin/true\n".utf8)
    let stale = Data("0 * * * * /usr/bin/false\n".utf8)
    let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: intended])
    let runner = ScriptedAutomationCommandRunner(results: [
      AutomationCommandResult(status: 0, standardOutput: Data(), standardError: Data()),
      AutomationCommandResult(status: 0, standardOutput: stale, standardError: Data()),
    ])
    let executor = CronAutomationExecutor(runner: runner, fileSystem: fileSystem, currentUID: 501)

    do {
      _ = try await executor.apply(
        .edit(AutomationEditPayload(
          label: "Cron entry 1",
          executable: "/usr/bin/true",
          arguments: [],
          environment: [:],
          workingDirectory: nil,
          schedule: AutomationSchedule(triggers: [.cron("0 * * * *")], summary: "Hourly"),
          rawRepresentation: intended
        )),
        to: cronRecord(command: "/usr/bin/true"),
        linkedProcesses: [],
        proposedSourceURL: sourceURL
      )
      XCTFail("Expected live generation mismatch")
    } catch let failure as AutomationExecutorMutationFailure {
      XCTAssertEqual(
        failure.appliedState,
        .cronLiveDocument(normalizedChecksum: CronDocumentChecksum.checksum(intended)!)
      )
    } catch {
      XCTFail("Expected typed applied-state failure, got \(error)")
    }
  }

  func testCronRollbackRefusesToOverwriteExternallyEditedLiveDocument() async {
    let backupURL = URL(fileURLWithPath: "/tmp/devscope-fixtures/cron.backup")
    let backup = Data("0 * * * * /usr/bin/original\n".utf8)
    let owned = Data("0 * * * * /usr/bin/devscope-change\n".utf8)
    let external = Data("0 * * * * /usr/bin/external-edit\n".utf8)
    let fileSystem = InMemoryAutomationFileSystem(files: [backupURL: backup])
    let runner = InspectingAutomationCommandRunner { command in
      XCTAssertEqual(command.arguments, ["-l"])
      XCTAssertTrue(fileSystem.recordedOperations.contains {
        if case .writeTemporary = $0 { return true }
        return false
      }, "The authenticated backup must be staged before the final live-generation proof.")
      return AutomationCommandResult(status: 0, standardOutput: external, standardError: Data())
    }
    let executor = CronAutomationExecutor(runner: runner, fileSystem: fileSystem, currentUID: 501)
    let state = AutomationPreTransactionState(
      enabledState: .enabled,
      loadState: .unknown,
      linkedProcesses: []
    )
    let backupEntry = try! XCTUnwrap(
      CronParser.parse(String(decoding: backup, as: UTF8.self)).entries.first
    )
    let record = cronRecord(
      command: "/usr/bin/original",
      recordID: CronParser.recordID(for: backupEntry, ownerUID: 501)
    )

    await XCTAssertThrowsErrorAsync {
      _ = try await executor.restorePreTransactionState(
        state,
        for: record,
        recovery: verifiedRecoveryInput(data: backup, url: backupURL),
        linkedProcesses: [],
        expectedAppliedState: .cronLiveDocument(
          normalizedChecksum: CronDocumentChecksum.checksum(owned)!
        )
      )
    }

    XCTAssertEqual(runner.invocations, [
      AutomationCommand(executable: "/usr/bin/crontab", arguments: ["-l"], environment: ["LC_ALL": "C"]),
    ])
    XCTAssertFalse(runner.invocations.contains { $0.arguments != ["-l"] })
  }

  func testCronRecoveryConsumesVerifiedBytesWhenBackupPathChangesAfterAuthentication() async throws {
    let backupURL = URL(fileURLWithPath: "/tmp/devscope-fixtures/cron.backup")
    let verified = Data("0 * * * * /usr/bin/true\n5 * * * * /usr/bin/keep\n".utf8)
    let altered = Data("0 * * * * /usr/bin/true\n10 * * * * /usr/bin/unrelated-change\n".utf8)
    let owned = Data("# devscope-disabled: 0 * * * * /usr/bin/true\n5 * * * * /usr/bin/keep\n".utf8)
    let fileSystem = InMemoryAutomationFileSystem(files: [backupURL: verified])
    let recovery = verifiedRecoveryInput(data: verified, url: backupURL)
    fileSystem.setStoredData(altered, at: backupURL)
    let callIndex = LockedInvocationIndex()
    let runner = InspectingAutomationCommandRunner { command in
      switch callIndex.next() {
      case 1:
        return AutomationCommandResult(status: 0, standardOutput: owned, standardError: Data())
      case 2:
        XCTAssertEqual(fileSystem.storedData(at: URL(fileURLWithPath: command.arguments[0])), verified)
        return AutomationCommandResult(status: 0, standardOutput: Data(), standardError: Data())
      default:
        return AutomationCommandResult(status: 0, standardOutput: verified, standardError: Data())
      }
    }
    let entry = try XCTUnwrap(CronParser.parse(String(decoding: verified, as: UTF8.self)).entries.first)
    let record = cronRecord(
      command: entry.command,
      recordID: CronParser.recordID(for: entry, ownerUID: 501)
    )
    let state = AutomationPreTransactionState(
      enabledState: .enabled,
      loadState: .unknown,
      linkedProcesses: []
    )
    let executor = CronAutomationExecutor(runner: runner, fileSystem: fileSystem, currentUID: 501)

    let result = try await executor.restorePreTransactionState(
      state,
      for: record,
      recovery: recovery,
      linkedProcesses: [],
      expectedAppliedState: .cronLiveDocument(
        normalizedChecksum: try XCTUnwrap(CronDocumentChecksum.checksum(owned))
      )
    )

    XCTAssertTrue(result.postconditions.contains(.preTransactionStateRestored(state)))
    XCTAssertEqual(fileSystem.storedData(at: backupURL), altered)
  }

  func testCronDisableAndStopPreservesOwnedGenerationForEveryPostInstallFailure() async {
    let sourceURL = URL(fileURLWithPath: "/tmp/devscope-fixtures/current-user.crontab")
    let intended = Data("# devscope-disabled: * * * * * /usr/bin/true\n".utf8)
    let checksum = try! XCTUnwrap(CronDocumentChecksum.checksum(intended))
    let (record, classified, snapshot) = cronProcessFixture()

    let scenarios: [(String, CronAutomationExecutor.ProcessSnapshot, ProcessKiller.IdentityResolver)] = [
      ("snapshot", { throw AutomationExecutorError.processControlUnavailable }, { _ in .notRunning }),
      ("poll", { snapshot }, { _ in .identity(ProcessIdentity(process: classified.process)) }),
    ]

    for (name, processSnapshot, resolver) in scenarios {
      let fileSystem = InMemoryAutomationFileSystem(files: [sourceURL: intended])
      let runner = ScriptedAutomationCommandRunner(results: [
        AutomationCommandResult(status: 0, standardOutput: Data(), standardError: Data()),
        AutomationCommandResult(status: 0, standardOutput: intended, standardError: Data()),
      ])
      let executor = CronAutomationExecutor(
        runner: runner,
        fileSystem: fileSystem,
        currentUID: 501,
        processKiller: ProcessKiller(
          identityResolver: resolver,
          signalSender: { _, _ in }
        ),
        currentProcessID: 99_999,
        processIdentityResolver: resolver,
        processSnapshot: processSnapshot,
        now: { Date(timeIntervalSince1970: 3_600) },
        terminationVerificationPolicy: .init(maximumAttempts: 1, interval: .zero),
        verificationSleep: { _ in }
      )

      do {
        _ = try await executor.apply(
          .disableAndStop,
          to: record,
          linkedProcesses: [classified],
          proposedSourceURL: sourceURL
        )
        XCTFail("Expected \(name) failure")
      } catch let failure as AutomationExecutorMutationFailure {
        XCTAssertEqual(
          failure.appliedState,
          .cronLiveDocument(normalizedChecksum: checksum),
          name
        )
      } catch {
        XCTFail("Expected owned-generation mutation failure for \(name), got \(error)")
      }
    }
  }

  func testCronStopRejectsWrongAncestryAndWrongScheduleMinuteBeforeSignal() async {
    let birth = ProcessBirthToken(seconds: 3_600, microseconds: 0)
    let carrier = DevProcess(
      pid: 55_001,
      parentPID: 55_000,
      executable: "/bin/sh",
      command: "/bin/sh -c /usr/bin/true",
      argumentVector: ["/bin/sh", "-c", "/usr/bin/true"],
      resourceUsage: DevProcessResourceUsage(
        cpuPercent: 0,
        residentMemoryBytes: 1,
        elapsedTime: "00:00:00"
      ),
      birthToken: birth
    )
    let classified = ClassifiedDevProcess(
      process: carrier,
      classification: DevProcessClassification(kind: .shell, displayName: "cron", projectHint: nil)
    )
    let cronDaemon = DevProcess(
      pid: 55_000,
      parentPID: 1,
      executable: "/usr/sbin/cron",
      command: "/usr/sbin/cron",
      argumentVector: ["/usr/sbin/cron"],
      birthToken: ProcessBirthToken(seconds: 1, microseconds: 0)
    )
    let signals = RecordedSignals()
    let killer = ProcessKiller(
      identityResolver: { _ in .identity(ProcessIdentity(process: carrier)) },
      signalSender: signals.send
    )
    let cases: [(AutomationRecord, [DevProcess])] = [
      (cronRecord(command: "/usr/bin/true", scheduleExpression: "* * * * *"), [carrier]),
      (cronRecord(command: "/usr/bin/true", scheduleExpression: "30 * * * *"), [cronDaemon, carrier]),
    ]

    for (record, snapshot) in cases {
      let executor = CronAutomationExecutor(
        runner: RecordingAutomationCommandRunner(),
        fileSystem: InMemoryAutomationFileSystem(),
        currentUID: 501,
        processKiller: killer,
        currentProcessID: 99_999,
        processIdentityResolver: { _ in .notRunning },
        processSnapshot: { snapshot },
        now: { Date(timeIntervalSince1970: 3_600) }
      )
      await XCTAssertThrowsErrorAsync {
        _ = try await executor.apply(
          .stopCurrentRun,
          to: record,
          linkedProcesses: [classified],
          proposedSourceURL: nil
        )
      }
    }

    XCTAssertTrue(signals.values.isEmpty)
  }

  func testLegacyLoginItemEnableUsesAFixedProgramAndPassesThePathAsAnArgument() async throws {
    let runner = RecordingAutomationCommandRunner()
    let record = legacyLoginItemRecord()
    let listing = StaticLegacyLoginItemListing(items: [
      LegacyLoginItemDescriptor(name: record.label, path: record.executable!, isHidden: false),
    ])
    let executor = LegacyLoginItemAutomationExecutor(
      runner: runner,
      listing: listing,
      currentUID: 501
    )

    let result = try await executor.apply(.enable, to: record)

    let invocation = try XCTUnwrap(runner.invocations.first)
    XCTAssertEqual(invocation.executable, "/usr/bin/osascript")
    XCTAssertEqual(
      Array(invocation.arguments.suffix(4)),
      ["--", "add", "/Applications/Backup.app", "false"]
    )
    XCTAssertFalse(invocation.arguments[1].contains("/Applications/Backup.app"))
    XCTAssertEqual(result.postconditions, [.futureLaunchesEnabled, .sourceInstalled])
  }

  func testLegacyExecutorRejectsModernBackgroundItemsBeforeAnyCommand() async {
    let runner = RecordingAutomationCommandRunner()
    let executor = LegacyLoginItemAutomationExecutor(
      runner: runner,
      listing: StaticLegacyLoginItemListing(items: []),
      currentUID: 501
    )

    await XCTAssertThrowsErrorAsync {
      _ = try await executor.apply(.disable, to: Fixtures.backgroundCopyOfUserAgent)
    }

    XCTAssertTrue(runner.invocations.isEmpty)
  }

  func testLegacyRollbackRestoresTypedHiddenStateForTrueAndFalse() async throws {
    let backupURL = URL(fileURLWithPath: "/tmp/devscope-fixtures/legacy.backup")
    let record = legacyLoginItemRecord()
    let state = AutomationPreTransactionState(
      enabledState: .enabled,
      loadState: .unknown,
      linkedProcesses: []
    )

    for isHidden in [true, false] {
      let descriptor = LegacyLoginItemDescriptor(
        name: record.label,
        path: record.executable!,
        isHidden: isHidden
      )
      let descriptorData = try LegacyLoginItemRecoveryDocument.encode(
        selectedRecord: record,
        descriptor: descriptor,
        currentUID: 501
      )
      let fileSystem = InMemoryAutomationFileSystem(files: [backupURL: descriptorData])
      let runner = RecordingAutomationCommandRunner()
      let executor = LegacyLoginItemAutomationExecutor(
        runner: runner,
        listing: StaticLegacyLoginItemListing(items: [
          LegacyLoginItemDescriptor(
            name: record.label,
            path: record.executable!,
            isHidden: isHidden
          ),
        ]),
        currentUID: 501
      )
      let recovery = verifiedRecoveryInput(data: descriptorData, url: backupURL)
      fileSystem.setStoredData(
        legacyRecoveryDescriptorData(record: record, isHidden: !isHidden),
        at: backupURL
      )

      let result = try await executor.restorePreTransactionState(
        state,
        for: record,
        recovery: recovery,
        linkedProcesses: [],
        expectedAppliedState: nil
      )

      let invocation = try XCTUnwrap(runner.invocations.first)
      XCTAssertEqual(
        Array(invocation.arguments.suffix(4)),
        ["--", "add", record.executable!, isHidden ? "true" : "false"]
      )
      XCTAssertEqual(result.postconditions, [.preTransactionStateRestored(state)])
    }
  }

  func testLegacyRecoveryDocumentFactoryRejectsUIDAndPathMismatch() throws {
    let record = legacyLoginItemRecord()
    let matching = LegacyLoginItemDescriptor(
      name: record.label,
      path: record.executable!,
      isHidden: true
    )
    XCTAssertThrowsError(try LegacyLoginItemRecoveryDocument.encode(
      selectedRecord: record,
      descriptor: matching,
      currentUID: 502
    ))
    XCTAssertThrowsError(try LegacyLoginItemRecoveryDocument.encode(
      selectedRecord: record,
      descriptor: LegacyLoginItemDescriptor(
        name: record.label,
        path: "/Applications/Other.app",
        isHidden: true
      ),
      currentUID: 501
    ))
  }

  func testLegacyRollbackRejectsMalformedOrMismatchedRecoveryDescriptorBeforeCommand() async {
    let backupURL = URL(fileURLWithPath: "/tmp/devscope-fixtures/legacy.backup")
    let record = legacyLoginItemRecord()
    let state = AutomationPreTransactionState(
      enabledState: .enabled,
      loadState: .unknown,
      linkedProcesses: []
    )
    let invalidDescriptors = [
      Data("{".utf8),
      legacyRecoveryDescriptorData(record: record, isHidden: true, ownerUID: 502),
      legacyRecoveryDescriptorData(record: record, isHidden: true, recordID: "other-record"),
      legacyRecoveryDescriptorData(
        record: record,
        isHidden: true,
        path: "/Applications/Other.app"
      ),
    ]

    for data in invalidDescriptors {
      let runner = RecordingAutomationCommandRunner()
      let executor = LegacyLoginItemAutomationExecutor(
        runner: runner,
        listing: StaticLegacyLoginItemListing(items: []),
        currentUID: 501
      )
      await XCTAssertThrowsErrorAsync {
        _ = try await executor.restorePreTransactionState(
          state,
          for: record,
          recovery: verifiedRecoveryInput(data: data, url: backupURL),
          linkedProcesses: [],
          expectedAppliedState: nil
        )
      }
      XCTAssertTrue(runner.invocations.isEmpty)
    }
  }
}

private final class ScriptedAutomationCommandRunner: AutomationCommandRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var statuses: [Int32]
  private var commands: [AutomationCommand] = []

  private var results: [AutomationCommandResult]?

  init(statuses: [Int32]) {
    self.statuses = statuses
    results = nil
  }

  init(results: [AutomationCommandResult]) {
    statuses = []
    self.results = results
  }

  var invocations: [AutomationCommand] {
    lock.withLock { commands }
  }

  func run(_ command: AutomationCommand) async throws -> AutomationCommandResult {
    lock.withLock {
      commands.append(command)
      if var results {
        let result = results.isEmpty
          ? AutomationCommandResult(status: 0, standardOutput: Data(), standardError: Data())
          : results.removeFirst()
        self.results = results
        return result
      }
      let status = statuses.isEmpty ? 0 : statuses.removeFirst()
      return AutomationCommandResult(
        status: status,
        standardOutput: Data("sensitive stdout".utf8),
        standardError: Data("sensitive stderr".utf8)
      )
    }
  }
}

private func successfulCommandResult() -> AutomationCommandResult {
  AutomationCommandResult(status: 0, standardOutput: Data(), standardError: Data())
}

private func missingLaunchctlServiceResult(
  label: String = "com.example.backup",
  guiUID: uid_t = 501
) -> AutomationCommandResult {
  AutomationCommandResult(
    status: 113,
    standardOutput: Data(),
    standardError: Data(
      "Bad request.\nCould not find service \"\(label)\" in domain for user gui: \(guiUID)\n".utf8
    )
  )
}

private final class InspectingAutomationCommandRunner: AutomationCommandRunning, @unchecked Sendable {
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

private final class LockedInvocationIndex: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func next() -> Int {
    lock.withLock {
      value += 1
      return value
    }
  }
}

private func cronRecord(
  command: String,
  environment: [String: String] = [:],
  enabledState: AutomationEnabledState = .enabled,
  sourceChecksum: String = "cron-checksum",
  scheduleExpression: String = "0 * * * *",
  recordID: AutomationRecord.ID = AutomationRecord.ID(rawValue: "cron-record")
) -> AutomationRecord {
  return AutomationRecord(
    id: recordID,
    kind: .cron,
    sourceKind: .crontab,
    label: "Cron entry 1",
    displayName: "Cron entry 1",
    providerBundleIdentifier: nil,
    ownerUID: 501,
    ownership: .user,
    executable: nil,
    arguments: [],
    commandSignature: command,
    environment: environment,
    workingDirectory: nil,
    schedule: AutomationSchedule(triggers: [.cron(scheduleExpression)], summary: "Cron"),
    sourceURL: nil,
    sourceChecksum: sourceChecksum,
    enabledState: enabledState,
    loadState: .unknown,
    approvalState: .notApplicable,
    state: enabledState == .enabled ? .idle : .disabled,
    evidence: [],
    capabilities: [.startNow],
    validationFindings: []
  )
}

private func classifiedProcess(pid: Int32, birth: ProcessBirthToken) -> ClassifiedDevProcess {
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
      displayName: "Backup",
      projectHint: nil
    )
  )
}

private func cronProcessFixture() -> (
  record: AutomationRecord,
  classified: ClassifiedDevProcess,
  snapshot: [DevProcess]
) {
  let carrier = DevProcess(
    pid: 55_101,
    parentPID: 55_100,
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
    pid: 55_100,
    parentPID: 1,
    executable: "/usr/sbin/cron",
    command: "/usr/sbin/cron",
    argumentVector: ["/usr/sbin/cron"],
    birthToken: ProcessBirthToken(seconds: 1, microseconds: 0)
  )
  return (
    cronRecord(command: "/usr/bin/true", scheduleExpression: "* * * * *"),
    ClassifiedDevProcess(
      process: carrier,
      classification: DevProcessClassification(kind: .shell, displayName: "cron", projectHint: nil)
    ),
    [daemon, carrier]
  )
}

private func legacyLoginItemRecord() -> AutomationRecord {
  let name = "Backup"
  let path = "/Applications/Backup.app"
  return AutomationRecord(
    id: AutomationRecord.ID(
      source: .legacyLoginItem,
      ownerUID: 501,
      label: name,
      sourcePath: path
    ),
    kind: .loginItem,
    sourceKind: .legacyLoginItem,
    label: name,
    displayName: name,
    providerBundleIdentifier: nil,
    ownerUID: 501,
    ownership: .user,
    executable: path,
    arguments: [],
    environment: [:],
    workingDirectory: nil,
    schedule: AutomationSchedule(triggers: [.atLogin], summary: "At login"),
    sourceURL: URL(fileURLWithPath: "/Applications/Backup.app"),
    sourceChecksum: nil,
    enabledState: .disabled,
    loadState: .unknown,
    approvalState: .notApplicable,
    state: .disabled,
    evidence: [],
    capabilities: [.enable, .disable],
    validationFindings: []
  )
}

private func legacyRecoveryDescriptorData(
  record: AutomationRecord,
  isHidden: Bool,
  ownerUID: uid_t = 501,
  path: String? = nil,
  recordID: String? = nil
) -> Data {
  try! JSONSerialization.data(withJSONObject: [
    "version": 1,
    "recordID": recordID ?? record.id.rawValue,
    "ownerUID": Int(ownerUID),
    "name": record.label,
    "path": path ?? record.executable!,
    "isHidden": isHidden,
  ], options: [.sortedKeys])
}

private func verifiedRecoveryInput(
  data: Data,
  url: URL
) -> AutomationVerifiedRecoveryInput {
  AutomationVerifiedRecoveryInput(
    backupID: AutomationBackup.ID(rawValue: UUID()),
    backupURL: url,
    data: data,
    checksum: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  )
}

private struct StaticLegacyLoginItemListing: LegacyLoginItemListing {
  let items: [LegacyLoginItemDescriptor]

  func currentUserLoginItems() async throws -> [LegacyLoginItemDescriptor] { items }
}

private final class SequencedLiveIdentityResolver: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [ProcessLiveIdentityResolution]

  init(values: [ProcessLiveIdentityResolution]) { self.values = values }

  func resolve(_ processID: Int32) -> ProcessLiveIdentityResolution {
    lock.withLock { values.isEmpty ? .notRunning : values.removeFirst() }
  }
}

private final class RecordedSignals: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [(Int32, Int32)] = []

  var values: [(Int32, Int32)] { lock.withLock { recorded } }

  func send(_ processID: Int32, _ signal: Int32) {
    lock.withLock { recorded.append((processID, signal)) }
  }
}

private func XCTAssertThrowsErrorAsync(
  _ expression: () async throws -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    try await expression()
    XCTFail("Expected an error", file: file, line: line)
  } catch {}
}
