import CryptoKit
import Darwin
import Foundation

public enum AutomationExecutorError: Error, Equatable, Sendable {
  case unsupportedSource
  case unsupportedOperation
  case missingSource
  case invalidSource
  case commandFailed(executable: String, status: Int32)
  case commandUnavailable(executable: String)
  case processControlUnavailable
  case postconditionNotVerified
}

public struct AutomationTerminationVerificationPolicy: Equatable, Sendable {
  public let maximumAttempts: Int
  public let interval: Duration

  public init(maximumAttempts: Int = 40, interval: Duration = .milliseconds(100)) {
    self.maximumAttempts = max(1, maximumAttempts)
    self.interval = max(.zero, interval)
  }
}

public typealias AutomationVerificationSleep = @Sendable (Duration) async throws -> Void

private func oldBirthExited(
  _ expected: ProcessIdentity,
  resolver: ProcessKiller.IdentityResolver,
  policy: AutomationTerminationVerificationPolicy,
  sleep: AutomationVerificationSleep
) async throws -> Bool {
  for attempt in 0..<policy.maximumAttempts {
    switch resolver(expected.pid) {
    case .notRunning:
      return true
    case .identity(let live) where !expected.hasSameBirthIdentity(as: live):
      return true
    case .identity, .unverifiable:
      if attempt + 1 < policy.maximumAttempts {
        try await sleep(policy.interval)
      }
    }
  }
  return false
}

public struct LaunchdAutomationExecutor: AutomationMutationApplying {
  private let runner: any AutomationCommandRunning
  private let guiUID: uid_t
  private let fileSystem: (any AutomationFileSystem)?

  public init(
    runner: any AutomationCommandRunning,
    guiUID: uid_t,
    fileSystem: (any AutomationFileSystem)? = nil
  ) {
    self.runner = runner
    self.guiUID = guiUID
    self.fileSystem = fileSystem
  }

  public func apply(
    _ operation: AutomationOperation,
    to record: AutomationRecord
  ) async throws -> AutomationExecutorResult {
    try await apply(operation, to: record, linkedProcesses: [], proposedSourceURL: nil)
  }

  public func apply(
    _ operation: AutomationOperation,
    to record: AutomationRecord,
    linkedProcesses: [ClassifiedDevProcess],
    proposedSourceURL: URL?
  ) async throws -> AutomationExecutorResult {
    guard record.kind == .launchAgent,
          record.sourceKind == .launchAgent,
          record.ownership == .user,
          record.ownerUID == guiUID,
          isValidLaunchdLabel(record.label)
    else { throw AutomationExecutorError.unsupportedSource }

    switch operation {
    case .startNow:
      let loaded: Bool
      switch record.loadState {
      case .loaded:
        loaded = true
      case .unloaded:
        loaded = false
      case .unknown:
        loaded = try await verifiedLoadedState(for: record)
      }
      if !loaded {
        guard let sourceURL = canonicalSourceURL(for: record) else {
          throw AutomationExecutorError.missingSource
        }
        try await requireLaunchctlSuccess(["bootstrap", domainTarget, sourceURL.path])
      }
      try await requireLaunchctlSuccess(["kickstart", serviceTarget(for: record)])
      let evidence = loaded
        ? "launchd accepted the typed kickstart request."
        : "launchd loaded the canonical source and accepted the typed kickstart request."
      return AutomationExecutorResult(
        postconditions: [.targetResolved, .currentRunStarted],
        evidence: [evidence]
      )
    case .disable:
      try await requireLaunchctlSuccess(["disable", serviceTarget(for: record)])
      return AutomationExecutorResult(
        postconditions: [.futureLaunchesDisabled],
        evidence: ["launchd accepted the typed disable request."]
      )
    case .enable:
      guard let sourceURL = canonicalSourceURL(for: record) else {
        throw AutomationExecutorError.missingSource
      }
      let loaded = try await verifiedLoadedState(for: record)
      try await requireLaunchctlSuccess(["enable", serviceTarget(for: record)])
      if !loaded {
        try await requireLaunchctlSuccess(["bootstrap", domainTarget, sourceURL.path])
      }
      return AutomationExecutorResult(
        postconditions: [.futureLaunchesEnabled, .targetResolved],
        evidence: [
          loaded
            ? "launchd accepted enable for the resolved service target."
            : "launchd accepted enable and bootstrap for the canonical source.",
        ]
      )
    case .stopCurrentRun:
      try await requireLaunchctlSuccess(["bootout", serviceTarget(for: record)])
      return AutomationExecutorResult(
        postconditions: [.noLinkedProcess],
        evidence: ["launchd unloaded the exact user service target."]
      )
    case .disableAndStop:
      try await requireLaunchctlSuccess(["disable", serviceTarget(for: record)])
      try await requireLaunchctlSuccess(["bootout", serviceTarget(for: record)])
      return AutomationExecutorResult(
        postconditions: [.futureLaunchesDisabled, .noLinkedProcess],
        evidence: ["launchd disabled and unloaded the exact user service target."]
      )
    case .edit:
      let proof = try sourceProof(at: proposedSourceURL)
      if record.loadState == .loaded {
        try await requireLaunchctlSuccess(["bootout", serviceTarget(for: record)])
        try await requireLaunchctlSuccess(["bootstrap", domainTarget, proof.url.path])
      }
      return AutomationExecutorResult(
        postconditions: [.sourceInstalled, .sourceChecksum(proof.checksum)],
        evidence: ["The validated LaunchAgent source was installed."]
      )
    case .duplicate(let payload):
      let proof = try sourceProof(at: proposedSourceURL)
      guard isValidLaunchdLabel(payload.label), payload.label != record.label else {
        throw AutomationExecutorError.invalidSource
      }
      try await requireLaunchctlSuccess(["disable", "gui/\(guiUID)/\(payload.label)"])
      return AutomationExecutorResult(
        postconditions: [
          .sourceInstalled,
          .sourceChecksum(proof.checksum),
          .futureLaunchesDisabled,
        ],
        evidence: ["The validated LaunchAgent copy was installed disabled and unloaded."]
      )
    case .importRecord:
      let proof = try sourceProof(at: proposedSourceURL)
      return AutomationExecutorResult(
        postconditions: [.sourceInstalled, .sourceChecksum(proof.checksum)],
        evidence: ["The validated LaunchAgent source was installed without loading it."]
      )
    case .restore:
      let proof = try sourceProof(at: proposedSourceURL)
      return AutomationExecutorResult(
        postconditions: [.sourceInstalled, .sourceChecksum(proof.checksum)],
        evidence: ["The validated LaunchAgent recovery source was installed."]
      )
    case .remove:
      let target = serviceTarget(for: record)
      let loaded = try await verifiedLoadedState(for: record)
      if loaded {
        try await requireLaunchctlSuccess(["bootout", target])
      } else {
        guard let stillExistingSourceURL = proposedSourceURL?.standardizedFileURL else {
          throw AutomationExecutorError.missingSource
        }
        try await requireLaunchctlSuccess([
          "bootout", domainTarget, stillExistingSourceURL.path,
        ])
      }
      let finalResolution = try await runLaunchctlPrint(target)
      guard LaunchctlServiceTargetClassifier.classify(
        finalResolution,
        label: record.label,
        guiUID: guiUID
      ) == .absent else {
        throw AutomationExecutorError.postconditionNotVerified
      }
      return AutomationExecutorResult(
        postconditions: [.sourceRemoved, .targetUnresolved],
        evidence: ["The LaunchAgent source was removed and its service target no longer resolves."]
      )
    default:
      throw AutomationExecutorError.unsupportedOperation
    }
  }

  public func restorePreTransactionState(
    _ state: AutomationPreTransactionState,
    for record: AutomationRecord,
    recovery: AutomationVerifiedRecoveryInput,
    linkedProcesses: [ClassifiedDevProcess],
    expectedAppliedState: AutomationExecutorAppliedState?
  ) async throws -> AutomationExecutorResult {
    guard record.kind == .launchAgent,
          record.sourceKind == .launchAgent,
          record.ownership == .user,
          record.ownerUID == guiUID,
          isValidLaunchdLabel(record.label),
          let sourceURL = canonicalSourceURL(for: record)
    else { throw AutomationExecutorError.unsupportedSource }
    switch state.enabledState {
    case .enabled:
      try await requireLaunchctlSuccess(["enable", serviceTarget(for: record)])
    case .disabled:
      try await requireLaunchctlSuccess(["disable", serviceTarget(for: record)])
    case .unknown:
      throw AutomationExecutorError.postconditionNotVerified
    }
    let isLoaded = try await verifiedLoadedState(for: record)
    switch state.loadState {
    case .loaded where !isLoaded:
      try await requireLaunchctlSuccess(["bootstrap", domainTarget, sourceURL.path])
    case .unloaded where isLoaded:
      try await requireLaunchctlSuccess(["bootout", serviceTarget(for: record)])
    case .unknown:
      throw AutomationExecutorError.postconditionNotVerified
    default:
      break
    }
    return AutomationExecutorResult(
      postconditions: [.preTransactionStateRestored(state)],
      evidence: ["launchd accepted the exact enabled and loaded recovery state."]
    )
  }

  private func serviceTarget(for record: AutomationRecord) -> String {
    "gui/\(guiUID)/\(record.label)"
  }

  private func isValidLaunchdLabel(_ label: String) -> Bool {
    !label.isEmpty && !label.contains("/") && !label.contains("\0")
  }

  private var domainTarget: String { "gui/\(guiUID)" }

  private func canonicalSourceURL(for record: AutomationRecord) -> URL? {
    guard let sourceURL = record.sourceURL, sourceURL.path.hasPrefix("/") else { return nil }
    return sourceURL.standardizedFileURL
  }

  private func runLaunchctl(_ arguments: [String]) async throws -> AutomationCommandResult {
    do {
      return try await runner.run(AutomationCommand(
        executable: "/bin/launchctl",
        arguments: arguments
      ))
    } catch {
      throw AutomationExecutorError.commandUnavailable(executable: "/bin/launchctl")
    }
  }

  private func verifiedLoadedState(for record: AutomationRecord) async throws -> Bool {
    let result = try await runLaunchctlPrint(serviceTarget(for: record))
    switch LaunchctlServiceTargetClassifier.classify(
      result,
      label: record.label,
      guiUID: guiUID
    ) {
    case .loaded:
      return true
    case .absent:
      return false
    case .unknown:
      throw AutomationExecutorError.commandFailed(
        executable: "/bin/launchctl",
        status: result.status
      )
    }
  }

  private func runLaunchctlPrint(_ target: String) async throws -> AutomationCommandResult {
    do {
      return try await runner.run(AutomationCommand(
        executable: "/bin/launchctl",
        arguments: ["print", target],
        environment: ["LC_ALL": "C"]
      ))
    } catch {
      throw AutomationExecutorError.commandUnavailable(executable: "/bin/launchctl")
    }
  }

  private func requireLaunchctlSuccess(_ arguments: [String]) async throws {
    let result = try await runLaunchctl(arguments)
    guard result.status == 0 else {
      throw AutomationExecutorError.commandFailed(
        executable: "/bin/launchctl",
        status: result.status
      )
    }
  }

  private func sourceProof(at url: URL?) throws -> (url: URL, checksum: String) {
    guard let fileSystem, let url else { throw AutomationExecutorError.missingSource }
    let canonicalURL = url.standardizedFileURL
    let data: Data
    do {
      data = try fileSystem.read(canonicalURL)
    } catch {
      throw AutomationExecutorError.missingSource
    }
    guard (try? LaunchdPlistParser.parse(
      data: data,
      sourceURL: canonicalURL,
      ownerUID: guiUID,
      ownership: .user
    )) != nil else { throw AutomationExecutorError.invalidSource }
    return (canonicalURL, Self.checksum(data))
  }

  private static func checksum(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

public struct CronAutomationExecutor: AutomationMutationApplying {
  public typealias ProcessSnapshot = @Sendable () async throws -> [DevProcess]
  private let runner: any AutomationCommandRunning
  private let fileSystem: any AutomationFileSystem
  private let currentUID: uid_t
  private let processKiller: ProcessKiller
  private let currentProcessID: Int32
  private let processIdentityResolver: ProcessKiller.IdentityResolver
  private let processSnapshot: ProcessSnapshot
  private let now: @Sendable () -> Date
  private let terminationVerificationPolicy: AutomationTerminationVerificationPolicy
  private let verificationSleep: AutomationVerificationSleep

  public init(
    runner: any AutomationCommandRunning,
    fileSystem: any AutomationFileSystem,
    currentUID: uid_t
  ) {
    self.init(
      runner: runner,
      fileSystem: fileSystem,
      currentUID: currentUID,
      processKiller: ProcessKiller(),
      currentProcessID: getpid(),
      processIdentityResolver: ProcessKiller.resolveLiveIdentity,
      processSnapshot: { throw AutomationExecutorError.processControlUnavailable },
      now: Date.init,
      terminationVerificationPolicy: AutomationTerminationVerificationPolicy(),
      verificationSleep: { try await Task.sleep(for: $0) }
    )
  }

  public init(
    runner: any AutomationCommandRunning,
    fileSystem: any AutomationFileSystem,
    currentUID: uid_t,
    processSnapshot: @escaping ProcessSnapshot
  ) {
    self.init(
      runner: runner,
      fileSystem: fileSystem,
      currentUID: currentUID,
      processKiller: ProcessKiller(),
      currentProcessID: getpid(),
      processIdentityResolver: ProcessKiller.resolveLiveIdentity,
      processSnapshot: processSnapshot,
      now: Date.init,
      terminationVerificationPolicy: AutomationTerminationVerificationPolicy(),
      verificationSleep: { try await Task.sleep(for: $0) }
    )
  }

  init(
    runner: any AutomationCommandRunning,
    fileSystem: any AutomationFileSystem,
    currentUID: uid_t,
    processKiller: ProcessKiller,
    currentProcessID: Int32,
    processIdentityResolver: @escaping ProcessKiller.IdentityResolver,
    processSnapshot: @escaping ProcessSnapshot,
    now: @escaping @Sendable () -> Date,
    terminationVerificationPolicy: AutomationTerminationVerificationPolicy = .init(),
    verificationSleep: @escaping AutomationVerificationSleep = { try await Task.sleep(for: $0) }
  ) {
    self.runner = runner
    self.fileSystem = fileSystem
    self.currentUID = currentUID
    self.processKiller = processKiller
    self.currentProcessID = currentProcessID
    self.processIdentityResolver = processIdentityResolver
    self.processSnapshot = processSnapshot
    self.now = now
    self.terminationVerificationPolicy = terminationVerificationPolicy
    self.verificationSleep = verificationSleep
  }

  public func apply(
    _ operation: AutomationOperation,
    to record: AutomationRecord
  ) async throws -> AutomationExecutorResult {
    try await apply(operation, to: record, linkedProcesses: [], proposedSourceURL: nil)
  }

  public func apply(
    _ operation: AutomationOperation,
    to record: AutomationRecord,
    linkedProcesses: [ClassifiedDevProcess],
    proposedSourceURL: URL?
  ) async throws -> AutomationExecutorResult {
    guard record.kind == .cron,
          record.sourceKind == .crontab,
          record.ownership == .user,
          record.ownerUID == currentUID
    else { throw AutomationExecutorError.unsupportedSource }

    switch operation {
    case .startNow:
      throw AutomationExecutorError.unsupportedOperation
    case .confirmedRunToCompletion(let confirmation):
      guard confirmation.recordID == record.id,
            let sourceChecksum = record.sourceChecksum,
            confirmation.sourceChecksum == sourceChecksum,
            let command = record.commandSignature,
            !command.isEmpty,
            confirmation.exactCommand == command,
            !command.contains("\0")
      else { throw AutomationExecutorError.invalidSource }
      let shell = record.environment["SHELL"] ?? "/bin/sh"
      guard shell.hasPrefix("/"), !shell.contains("\0") else {
        throw AutomationExecutorError.invalidSource
      }
      let result = try await run(AutomationCommand(
        executable: shell,
        arguments: ["-c", command],
        environment: record.environment
      ))
      guard result.status == 0 else {
        throw AutomationExecutorError.commandFailed(executable: shell, status: result.status)
      }
      return AutomationExecutorResult(
        postconditions: [.targetResolved, .runCompleted],
        evidence: ["The confirmed cron command completed with exit status 0."]
      )
    case .edit, .duplicate, .importRecord, .restore:
      let checksum = try await installDocument(at: proposedSourceURL)
      return AutomationExecutorResult(
        postconditions: [.sourceInstalled, .sourceChecksum(checksum)],
        evidence: ["The complete current-user crontab document was installed and verified."],
        appliedState: .cronLiveDocument(normalizedChecksum: checksum)
      )
    case .enable:
      let checksum = try await installDocument(at: proposedSourceURL)
      return AutomationExecutorResult(
        postconditions: [
          .sourceInstalled,
          .sourceChecksum(checksum),
          .futureLaunchesEnabled,
        ],
        evidence: ["The complete current-user crontab document was installed and verified."],
        appliedState: .cronLiveDocument(normalizedChecksum: checksum)
      )
    case .disable:
      let checksum = try await installDocument(at: proposedSourceURL)
      return AutomationExecutorResult(
        postconditions: [
          .sourceInstalled,
          .sourceChecksum(checksum),
          .futureLaunchesDisabled,
        ],
        evidence: ["The complete current-user crontab document was installed and verified."],
        appliedState: .cronLiveDocument(normalizedChecksum: checksum)
      )
    case .stopCurrentRun:
      try await stopStronglyLinkedProcesses(linkedProcesses, for: record)
      return AutomationExecutorResult(
        postconditions: [.noLinkedProcess],
        evidence: ["Every exact cron carrier birth identity exited after SIGTERM."]
      )
    case .disableAndStop:
      let checksum = try await installDocument(at: proposedSourceURL)
      do {
        try await stopStronglyLinkedProcesses(linkedProcesses, for: record)
      } catch {
        throw AutomationExecutorMutationFailure(
          error: (error as? AutomationExecutorError) ?? .processControlUnavailable,
          appliedState: .cronLiveDocument(normalizedChecksum: checksum)
        )
      }
      return AutomationExecutorResult(
        postconditions: [
          .sourceInstalled,
          .sourceChecksum(checksum),
          .futureLaunchesDisabled,
          .noLinkedProcess,
        ],
        evidence: ["The complete crontab was installed and every controlled cron carrier exited."],
        appliedState: .cronLiveDocument(normalizedChecksum: checksum)
      )
    case .remove:
      let checksum = try await installDocument(at: proposedSourceURL)
      return AutomationExecutorResult(
        postconditions: [.sourceRemoved, .sourceChecksum(checksum)],
        evidence: ["The complete current-user crontab document without the selected entry was installed and verified."],
        appliedState: .cronLiveDocument(normalizedChecksum: checksum)
      )
    default:
      throw AutomationExecutorError.unsupportedOperation
    }
  }

  public func restorePreTransactionState(
    _ state: AutomationPreTransactionState,
    for record: AutomationRecord,
    recovery: AutomationVerifiedRecoveryInput,
    linkedProcesses: [ClassifiedDevProcess],
    expectedAppliedState: AutomationExecutorAppliedState?
  ) async throws -> AutomationExecutorResult {
    guard record.kind == .cron,
          record.sourceKind == .crontab,
          record.ownership == .user,
          record.ownerUID == currentUID,
          state.sourceExisted,
          state.loadState == .unknown
    else { throw AutomationExecutorError.postconditionNotVerified }
    guard case .cronLiveDocument(let ownedChecksum) = expectedAppliedState else {
      throw AutomationExecutorError.postconditionNotVerified
    }
    guard Self.rawChecksum(recovery.data) == recovery.checksum else {
      throw AutomationExecutorError.postconditionNotVerified
    }
    let prepared = try prepareDocument(
      data: recovery.data,
      nextTo: recovery.backupURL,
      expectedRawChecksum: recovery.checksum
    )
    let document = CronParser.parse(String(decoding: prepared.data, as: UTF8.self))
    let restoredEnabledState = document.entries.first(where: {
      CronParser.recordID(for: $0, ownerUID: currentUID) == record.id
    }).map { $0.isEnabled ? AutomationEnabledState.enabled : .disabled }
    guard restoredEnabledState == state.enabledState else {
      throw AutomationExecutorError.postconditionNotVerified
    }

    let live = try await run(AutomationCommand(
      executable: "/usr/bin/crontab",
      arguments: ["-l"],
      environment: ["LC_ALL": "C"]
    ))
    guard live.status == 0,
          CronDocumentChecksum.checksum(live.standardOutput) == ownedChecksum
    else { throw AutomationExecutorError.postconditionNotVerified }

    // crontab(1) exposes no atomic compare-and-swap. Keep this install as the immediately
    // following external operation after ownership proof; an unavoidable process-launch gap remains.
    let installResult = try await run(AutomationCommand(
      executable: "/usr/bin/crontab",
      arguments: [prepared.temporaryURL.path]
    ))
    guard installResult.status == 0 else {
      throw AutomationExecutorError.commandFailed(
        executable: "/usr/bin/crontab",
        status: installResult.status
      )
    }
    let listed = try await run(AutomationCommand(
      executable: "/usr/bin/crontab",
      arguments: ["-l"],
      environment: ["LC_ALL": "C"]
    ))
    guard listed.status == 0,
          CronDocumentChecksum.checksum(listed.standardOutput) == prepared.checksum
    else {
      throw AutomationExecutorError.postconditionNotVerified
    }
    var postconditions: Set<AutomationPostcondition> = [
      .sourceChecksum(prepared.checksum),
    ]
    if state.linkedProcesses.isEmpty {
      postconditions.insert(.preTransactionStateRestored(state))
    }
    let result = AutomationExecutorResult(
      postconditions: postconditions,
      evidence: [
        "The authenticated crontab backup was staged before the final ownership proof, then installed and verified; crontab provides no atomic compare-and-swap.",
      ]
    )
    try removeStagedFile(prepared.staged)
    return result
  }

  private func run(_ command: AutomationCommand) async throws -> AutomationCommandResult {
    do {
      return try await runner.run(command)
    } catch {
      throw AutomationExecutorError.commandUnavailable(executable: command.executable)
    }
  }

  private func installDocument(at sourceURL: URL?) async throws -> String {
    let prepared = try prepareDocument(at: sourceURL)
    let checksum = try await installPreparedDocument(prepared)
    try removeStagedFile(prepared.staged)
    return checksum
  }

  private struct PreparedCronDocument {
    let data: Data
    let staged: AutomationStagedFile
    let checksum: String

    var temporaryURL: URL { staged.url }
  }

  private func prepareDocument(at sourceURL: URL?) throws -> PreparedCronDocument {
    guard let sourceURL else { throw AutomationExecutorError.missingSource }
    let data: Data
    do {
      data = try fileSystem.read(sourceURL.standardizedFileURL)
    } catch {
      throw AutomationExecutorError.missingSource
    }
    return try prepareDocument(data: data, nextTo: sourceURL, expectedRawChecksum: nil)
  }

  private func prepareDocument(
    data: Data,
    nextTo sourceURL: URL,
    expectedRawChecksum: String?
  ) throws -> PreparedCronDocument {
    guard expectedRawChecksum == nil || Self.rawChecksum(data) == expectedRawChecksum,
          let text = String(data: data, encoding: .utf8),
          CronParser.parse(text).invalidLines.isEmpty
    else { throw AutomationExecutorError.invalidSource }

    let staged: AutomationStagedFile
    do {
      let parent = sourceURL.deletingLastPathComponent().standardizedFileURL
      let parentMetadata = try fileSystem.metadata(for: parent)
      guard let authorization = AutomationDirectoryAuthorization(
        directoryURL: parent,
        resourceIdentifier: parentMetadata.resourceIdentifier
      ) else { throw AutomationExecutorError.missingSource }
      staged = try fileSystem.writeStagedFile(
        nextTo: sourceURL.standardizedFileURL,
        data: data,
        permissions: 0o600,
        authorization: authorization
      )
    } catch {
      throw AutomationExecutorError.missingSource
    }
    let stagedData: Data
    do {
      stagedData = try fileSystem.read(staged.url)
    } catch {
      try removeStagedFile(staged)
      throw AutomationExecutorError.missingSource
    }
    guard stagedData == data,
          expectedRawChecksum == nil || Self.rawChecksum(stagedData) == expectedRawChecksum
    else {
      try removeStagedFile(staged)
      throw AutomationExecutorError.postconditionNotVerified
    }
    guard let intendedChecksum = CronDocumentChecksum.checksum(data) else {
      try removeStagedFile(staged)
      throw AutomationExecutorError.invalidSource
    }
    return PreparedCronDocument(
      data: data,
      staged: staged,
      checksum: intendedChecksum
    )
  }

  private func removeStagedFile(_ staged: AutomationStagedFile) throws {
    switch try fileSystem.removeItem(staged.authorization) {
    case .committed:
      return
    case .unchanged:
      throw AutomationFilePartialMutation(
        kind: .remove,
        commitState: .unknown,
        observedFiles: [staged.authorization],
        recoveryHandle: staged.authorization,
        resultURL: staged.url
      )
    }
  }

  private static func rawChecksum(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func installPreparedDocument(_ prepared: PreparedCronDocument) async throws -> String {
    let installResult = try await run(AutomationCommand(
      executable: "/usr/bin/crontab",
      arguments: [prepared.temporaryURL.path]
    ))
    guard installResult.status == 0 else {
      throw AutomationExecutorError.commandFailed(
        executable: "/usr/bin/crontab",
        status: installResult.status
      )
    }

    let appliedState = AutomationExecutorAppliedState.cronLiveDocument(
      normalizedChecksum: prepared.checksum
    )

    let listed: AutomationCommandResult
    do {
      listed = try await run(AutomationCommand(
        executable: "/usr/bin/crontab",
        arguments: ["-l"],
        environment: ["LC_ALL": "C"]
      ))
    } catch let error as AutomationExecutorError {
      throw AutomationExecutorMutationFailure(error: error, appliedState: appliedState)
    }
    guard listed.status == 0,
          CronDocumentChecksum.checksum(listed.standardOutput)
            == prepared.checksum
    else {
      throw AutomationExecutorMutationFailure(
        error: .postconditionNotVerified,
        appliedState: appliedState
      )
    }
    return prepared.checksum
  }

  private func stopStronglyLinkedProcesses(
    _ linkedProcesses: [ClassifiedDevProcess],
    for record: AutomationRecord
  ) async throws {
    guard !linkedProcesses.isEmpty,
          linkedProcesses.allSatisfy({ $0.process.birthToken != nil })
    else { throw AutomationExecutorError.processControlUnavailable }
    let freshProcesses: [DevProcess]
    do {
      freshProcesses = try await processSnapshot()
    } catch {
      throw AutomationExecutorError.processControlUnavailable
    }
    let expected = Set(linkedProcesses.map { ProcessIdentity(process: $0.process) })
    let proven = Set(AutomationProcessCorrelator.links(
      records: [record],
      processes: freshProcesses,
      now: now()
    ).filter { $0.strength == .strong }.map(\.processIdentity))
    guard expected.isSubset(of: proven) else {
      throw AutomationExecutorError.processControlUnavailable
    }
    for process in linkedProcesses.sorted(by: { $0.process.pid < $1.process.pid }) {
      _ = try processKiller.terminate(process, currentProcessID: currentProcessID)
    }
    for identity in expected {
      guard try await oldBirthExited(
        identity,
        resolver: processIdentityResolver,
        policy: terminationVerificationPolicy,
        sleep: verificationSleep
      ) else {
        throw AutomationExecutorError.postconditionNotVerified
      }
    }
  }
}

public struct LegacyLoginItemAutomationExecutor: AutomationMutationApplying {
  private static let fixedMutationProgram = """
    on run argv
      if (count of argv) is not 3 then error "invalid arguments"
      set requestedAction to item 1 of argv
      set targetPath to item 2 of argv
      set hiddenText to item 3 of argv
      if hiddenText is "true" then
        set hiddenAtLogin to true
      else if hiddenText is "false" then
        set hiddenAtLogin to false
      else
        error "invalid hidden state"
      end if
      tell application "System Events"
        if requestedAction is "add" then
          if not (exists login item 1 whose path is targetPath) then
            make new login item at end with properties {path:targetPath, hidden:hiddenAtLogin}
          end if
        else if requestedAction is "remove" then
          delete every login item whose path is targetPath
        else
          error "invalid action"
        end if
      end tell
    end run
    """

  private let runner: any AutomationCommandRunning
  private let listing: any LegacyLoginItemListing
  private let currentUID: uid_t

  public init(
    runner: any AutomationCommandRunning,
    listing: any LegacyLoginItemListing,
    currentUID: uid_t
  ) {
    self.runner = runner
    self.listing = listing
    self.currentUID = currentUID
  }

  public func apply(
    _ operation: AutomationOperation,
    to record: AutomationRecord
  ) async throws -> AutomationExecutorResult {
    try await apply(operation, to: record, linkedProcesses: [], proposedSourceURL: nil)
  }

  public func apply(
    _ operation: AutomationOperation,
    to record: AutomationRecord,
    linkedProcesses: [ClassifiedDevProcess],
    proposedSourceURL: URL?
  ) async throws -> AutomationExecutorResult {
    guard record.kind == .loginItem,
          record.sourceKind == .legacyLoginItem,
          record.ownership == .user,
          record.ownerUID == currentUID,
          let path = targetPath(for: record)
    else { throw AutomationExecutorError.unsupportedSource }

    switch operation {
    case .enable:
      try await mutate("add", path: path, isHidden: false)
      guard try await contains(path) else {
        throw AutomationExecutorError.postconditionNotVerified
      }
      return AutomationExecutorResult(
        postconditions: [.futureLaunchesEnabled, .sourceInstalled],
        evidence: ["The current-user legacy login item is present."]
      )
    case .disable:
      try await mutate("remove", path: path, isHidden: false)
      guard try await !contains(path) else {
        throw AutomationExecutorError.postconditionNotVerified
      }
      return AutomationExecutorResult(
        postconditions: [.futureLaunchesDisabled],
        evidence: ["The current-user legacy login item is absent without claiming its process stopped."]
      )
    case .remove:
      try await mutate("remove", path: path, isHidden: false)
      guard try await !contains(path) else {
        throw AutomationExecutorError.postconditionNotVerified
      }
      return AutomationExecutorResult(
        postconditions: [.sourceRemoved],
        evidence: ["The current-user legacy login item is absent."]
      )
    case .startNow:
      let result = try await run(AutomationCommand(
        executable: "/usr/bin/open",
        arguments: ["--", path]
      ))
      guard result.status == 0 else {
        throw AutomationExecutorError.commandFailed(executable: "/usr/bin/open", status: result.status)
      }
      return AutomationExecutorResult(
        postconditions: [.targetResolved, .currentRunStarted],
        evidence: ["macOS accepted the typed open request for the login-item path."]
      )
    default:
      throw AutomationExecutorError.unsupportedOperation
    }
  }

  public func restorePreTransactionState(
    _ state: AutomationPreTransactionState,
    for record: AutomationRecord,
    recovery: AutomationVerifiedRecoveryInput,
    linkedProcesses: [ClassifiedDevProcess],
    expectedAppliedState: AutomationExecutorAppliedState?
  ) async throws -> AutomationExecutorResult {
    guard record.kind == .loginItem,
          record.sourceKind == .legacyLoginItem,
          record.ownership == .user,
          record.ownerUID == currentUID,
          state.loadState == .unknown,
          state.linkedProcesses.isEmpty,
          let path = targetPath(for: record)
    else { throw AutomationExecutorError.postconditionNotVerified }
    guard Self.rawChecksum(recovery.data) == recovery.checksum else {
      throw AutomationExecutorError.postconditionNotVerified
    }
    let recoveryDescriptor = try recoveryDescriptor(
      recovery.data,
      for: record,
      path: path
    )
    switch state.enabledState {
    case .enabled:
      try await mutate("add", path: path, isHidden: recoveryDescriptor.isHidden)
      guard try await descriptor(for: path)?.isHidden == recoveryDescriptor.isHidden else {
        throw AutomationExecutorError.postconditionNotVerified
      }
    case .disabled:
      try await mutate("remove", path: path, isHidden: recoveryDescriptor.isHidden)
      guard try await !contains(path) else {
        throw AutomationExecutorError.postconditionNotVerified
      }
    case .unknown:
      throw AutomationExecutorError.postconditionNotVerified
    }
    return AutomationExecutorResult(
      postconditions: [.preTransactionStateRestored(state)],
      evidence: ["The exact current-user legacy login-item presence state was restored."]
    )
  }

  private func targetPath(for record: AutomationRecord) -> String? {
    guard let path = record.executable, path.hasPrefix("/"), !path.contains("\0") else {
      return nil
    }
    return URL(fileURLWithPath: path).standardizedFileURL.path
  }

  private func mutate(_ action: String, path: String, isHidden: Bool) async throws {
    let result = try await run(AutomationCommand(
      executable: "/usr/bin/osascript",
      arguments: ["-e", Self.fixedMutationProgram, "--", action, path, isHidden ? "true" : "false"]
    ))
    guard result.status == 0 else {
      throw AutomationExecutorError.commandFailed(executable: "/usr/bin/osascript", status: result.status)
    }
  }

  private func contains(_ path: String) async throws -> Bool {
    try await descriptor(for: path) != nil
  }

  private func descriptor(for path: String) async throws -> LegacyLoginItemDescriptor? {
    do {
      return try await listing.currentUserLoginItems().first {
        URL(fileURLWithPath: $0.path).standardizedFileURL.path == path
      }
    } catch {
      throw AutomationExecutorError.postconditionNotVerified
    }
  }

  private func recoveryDescriptor(
    _ data: Data,
    for record: AutomationRecord,
    path: String
  ) throws -> LegacyLoginItemRecoveryDescriptor {
    guard let descriptor = try? JSONDecoder().decode(
      LegacyLoginItemRecoveryDescriptor.self,
      from: data
    ), descriptor.version == 1,
       descriptor.recordID == record.id.rawValue,
       descriptor.ownerUID == currentUID,
       descriptor.name == record.label,
       descriptor.path.hasPrefix("/"),
       !descriptor.path.contains("\0"),
       URL(fileURLWithPath: descriptor.path).standardizedFileURL.path == path,
       record.id == AutomationRecord.ID(
         source: .legacyLoginItem,
         ownerUID: currentUID,
         label: descriptor.name,
         sourcePath: path
       )
    else { throw AutomationExecutorError.invalidSource }
    return descriptor
  }

  private func run(_ command: AutomationCommand) async throws -> AutomationCommandResult {
    do {
      return try await runner.run(command)
    } catch {
      throw AutomationExecutorError.commandUnavailable(executable: command.executable)
    }
  }

  private static func rawChecksum(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
