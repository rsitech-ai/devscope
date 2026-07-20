import CryptoKit
import Darwin
import Foundation

public enum AutomationManagerConfigurationError: Error, Equatable, Sendable {
  case destinationAuthorizationUnavailable
  case recoverableSourceUnavailable
  case exactStateRestorationUnavailable
  case runtimeProcessVerificationUnavailable
}

public struct AutomationRecoverableSource: Equatable, Sendable {
  public let transactionURL: URL
  public let data: Data
  public let checksum: String
  public let metadata: AutomationFileMetadata

  public init(
    transactionURL: URL,
    data: Data,
    checksum: String,
    metadata: AutomationFileMetadata
  ) {
    self.transactionURL = transactionURL
    self.data = data
    self.checksum = checksum
    self.metadata = metadata
  }
}

public enum AutomationOperation: Equatable, Sendable {
  case startNow
  case confirmedRunToCompletion(AutomationRunToCompletionConfirmation)
  case stopCurrentRun
  case enable
  case disable
  case disableAndStop
  case edit(AutomationEditPayload)
  case duplicate(AutomationEditPayload)
  case importRecord(AutomationImportPayload)
  case exportRecord(redacted: Bool)
  case remove
  case restore(AutomationBackup.ID)
}

public struct AutomationRunToCompletionConfirmation: Equatable, Sendable {
  public let recordID: AutomationRecord.ID
  public let sourceChecksum: String?
  public let exactCommand: String

  public init(
    recordID: AutomationRecord.ID,
    sourceChecksum: String?,
    exactCommand: String
  ) {
    self.recordID = recordID
    self.sourceChecksum = sourceChecksum
    self.exactCommand = exactCommand
  }
}

public struct AutomationEditPayload: Equatable, Sendable {
  public let label: String
  public let executable: String
  public let arguments: [String]
  public let environment: [String: String]
  public let workingDirectory: String?
  public let schedule: AutomationSchedule
  public let rawRepresentation: Data?
  public let destination: URL?
  public let expectedDestinationChecksum: String?

  public init(
    label: String,
    executable: String,
    arguments: [String],
    environment: [String: String],
    workingDirectory: String?,
    schedule: AutomationSchedule,
    rawRepresentation: Data?,
    destination: URL? = nil,
    expectedDestinationChecksum: String? = nil
  ) {
    self.label = label
    self.executable = executable
    self.arguments = arguments
    self.environment = environment
    self.workingDirectory = workingDirectory
    self.schedule = schedule
    self.rawRepresentation = rawRepresentation
    self.destination = destination
    self.expectedDestinationChecksum = expectedDestinationChecksum
  }
}

public struct AutomationImportPayload: Equatable, Sendable {
  public let destination: URL
  public let data: Data
  public let expectedKind: AutomationKind
  public let expectedDestinationChecksum: String?

  public init(
    destination: URL,
    data: Data,
    expectedKind: AutomationKind,
    expectedDestinationChecksum: String? = nil
  ) {
    self.destination = destination
    self.data = data
    self.expectedKind = expectedKind
    self.expectedDestinationChecksum = expectedDestinationChecksum
  }
}

public struct AutomationBackup: Identifiable, Equatable, Sendable {
  public struct ID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
      self.rawValue = rawValue
    }
  }

  public let id: ID
  public let recordID: AutomationRecord.ID
  public let sourceURL: URL
  public let backupURL: URL
  public let checksum: String
  public let createdAt: Date
  public let sourceExisted: Bool
  public let ownerUID: uid_t
  public let kind: AutomationKind
  public let sourceKind: AutomationSourceKind
  public let authorizedRecordIDs: Set<AutomationRecord.ID>
  public let parentResourceIdentifier: String?

  public init(
    id: ID,
    recordID: AutomationRecord.ID,
    sourceURL: URL,
    backupURL: URL,
    checksum: String,
    createdAt: Date,
    sourceExisted: Bool = true,
    ownerUID: uid_t = 0,
    kind: AutomationKind = .launchAgent,
    sourceKind: AutomationSourceKind = .launchAgent,
    authorizedRecordIDs: Set<AutomationRecord.ID>? = nil,
    parentResourceIdentifier: String? = nil
  ) {
    self.id = id
    self.recordID = recordID
    self.sourceURL = sourceURL
    self.backupURL = backupURL
    self.checksum = checksum
    self.createdAt = createdAt
    self.sourceExisted = sourceExisted
    self.ownerUID = ownerUID
    self.kind = kind
    self.sourceKind = sourceKind
    self.authorizedRecordIDs = authorizedRecordIDs ?? [recordID]
    self.parentResourceIdentifier = parentResourceIdentifier
  }
}

public enum AutomationRollbackOutcome: Equatable, Sendable {
  case notNeeded
  case restored(AutomationBackup.ID)
  case failed(String)
}

public enum AutomationOperationStatus: Equatable, Sendable {
  case succeeded
  case rejected(String)
  case failed(String)
  case partialFailure(String)
}

public struct AutomationExportArtifact: Equatable, Sendable {
  public let suggestedFilename: String
  public let mediaType: String
  public let format: String
  public let data: Data
  public let isRedacted: Bool

  public init(
    suggestedFilename: String,
    mediaType: String,
    format: String,
    data: Data,
    isRedacted: Bool
  ) {
    self.suggestedFilename = suggestedFilename
    self.mediaType = mediaType
    self.format = format
    self.data = data
    self.isRedacted = isRedacted
  }
}

public enum AutomationRecordExporter {
  public static func artifact(
    for record: AutomationRecord,
    verifiedSourceData: Data?,
    requestedRedaction: Bool
  ) throws -> AutomationExportArtifact {
    let protected = record.ownership != .user
      || record.kind == .launchDaemon
      || record.kind == .backgroundItem
      || record.sourceKind == .launchDaemon
      || record.sourceKind == .serviceManagement
    let redacted = requestedRedaction || protected || verifiedSourceData == nil
    if !redacted, let verifiedSourceData {
      let presentation: (extension: String, mediaType: String, format: String)
      switch record.kind {
      case .launchAgent, .launchDaemon:
        presentation = ("plist", "application/x-plist", "source.plist")
      case .cron:
        presentation = ("crontab", "text/plain", "source.crontab")
      case .loginItem:
        presentation = ("json", "application/json", "source.legacy-login-item")
      case .backgroundItem:
        presentation = ("json", "application/json", "inspection-manifest.v1")
      }
      return AutomationExportArtifact(
        suggestedFilename: "devscope-\(record.sourceKind.rawValue)-\(record.id.rawValue.prefix(12)).\(presentation.extension)",
        mediaType: presentation.mediaType,
        format: presentation.format,
        data: verifiedSourceData,
        isRedacted: false
      )
    }

    var payload: [String: Any] = [
      "schemaVersion": 1,
      "recordID": record.id.rawValue,
      "kind": record.kind.rawValue,
      "sourceKind": record.sourceKind.rawValue,
      "ownership": record.ownership.rawValue,
      "enabledState": record.enabledState.rawValue,
      "loadState": record.loadState.rawValue,
      "approvalState": record.approvalState.rawValue,
      "state": record.state.rawValue,
      "redacted": redacted,
      "importable": false,
      "scheduleSummary": record.schedule.summary,
    ]
    payload["providerBundleIdentifier"] = record.providerBundleIdentifier
    payload["sourceChecksum"] = record.sourceChecksum
    payload["label"] = "<redacted>"
    payload["displayName"] = "<redacted>"
    payload["argumentCount"] = record.arguments.count
    payload["environmentKeys"] = record.environment.keys.sorted()
    payload["validationFindingCount"] = record.validationFindings.count
    payload["evidenceCount"] = record.evidence.count
    let data = try JSONSerialization.data(
      withJSONObject: payload,
      options: [.prettyPrinted, .sortedKeys]
    )
    return AutomationExportArtifact(
      suggestedFilename: "devscope-\(record.sourceKind.rawValue)-\(record.id.rawValue.prefix(12)).json",
      mediaType: "application/json",
      format: "inspection-manifest.v1",
      data: data,
      isRedacted: redacted
    )
  }
}

public struct AutomationOperationResult: Equatable, Sendable {
  public let operation: AutomationOperation
  public let status: AutomationOperationStatus
  public let appliedSteps: [String]
  public let verificationEvidence: [String]
  public let rollback: AutomationRollbackOutcome
  public let manualRecovery: String?
  public let backup: AutomationBackup?
  public let exportArtifact: AutomationExportArtifact?
  public let fileMutationEvidence: AutomationFilePartialMutation?
  public let rollbackFileMutationEvidence: AutomationFilePartialMutation?

  public init(
    operation: AutomationOperation,
    status: AutomationOperationStatus,
    appliedSteps: [String],
    verificationEvidence: [String],
    rollback: AutomationRollbackOutcome,
    manualRecovery: String?,
    backup: AutomationBackup? = nil,
    exportArtifact: AutomationExportArtifact? = nil,
    fileMutationEvidence: AutomationFilePartialMutation? = nil,
    rollbackFileMutationEvidence: AutomationFilePartialMutation? = nil
  ) {
    self.operation = operation
    self.status = status
    self.appliedSteps = appliedSteps
    self.verificationEvidence = verificationEvidence
    self.rollback = rollback
    self.manualRecovery = manualRecovery
    self.backup = backup
    self.exportArtifact = exportArtifact
    self.fileMutationEvidence = fileMutationEvidence
    self.rollbackFileMutationEvidence = rollbackFileMutationEvidence
  }
}

public enum AutomationPostcondition: Equatable, Hashable, Sendable {
  case targetResolved
  case targetUnresolved
  case currentRunStarted
  case runCompleted
  case noLinkedProcess
  case futureLaunchesEnabled
  case futureLaunchesDisabled
  case sourceInstalled
  case sourceRemoved
  case sourceChecksum(String)
  case preTransactionStateRestored(AutomationPreTransactionState)
}

public struct AutomationExecutorResult: Equatable, Sendable {
  public let postconditions: Set<AutomationPostcondition>
  public let evidence: [String]
  public let appliedState: AutomationExecutorAppliedState?

  public init(
    postconditions: Set<AutomationPostcondition>,
    evidence: [String],
    appliedState: AutomationExecutorAppliedState? = nil
  ) {
    self.postconditions = postconditions
    self.evidence = evidence
    self.appliedState = appliedState
  }
}

public enum AutomationExecutorAppliedState: Equatable, Hashable, Sendable {
  case cronLiveDocument(normalizedChecksum: String)
}

public struct AutomationExecutorMutationFailure: Error, Equatable, Sendable {
  public let error: AutomationExecutorError
  public let appliedState: AutomationExecutorAppliedState

  public init(error: AutomationExecutorError, appliedState: AutomationExecutorAppliedState) {
    self.error = error
    self.appliedState = appliedState
  }
}

public struct AutomationVerifiedRecoveryInput: Equatable, Sendable {
  public let backupID: AutomationBackup.ID
  public let backupURL: URL
  public let data: Data
  public let checksum: String

  public init(
    backupID: AutomationBackup.ID,
    backupURL: URL,
    data: Data,
    checksum: String
  ) {
    self.backupID = backupID
    self.backupURL = backupURL
    self.data = data
    self.checksum = checksum
  }
}

public struct AutomationLinkedProcessIdentity: Equatable, Hashable, Sendable {
  public let processID: Int32
  public let birthToken: ProcessBirthToken

  public init(processID: Int32, birthToken: ProcessBirthToken) {
    self.processID = processID
    self.birthToken = birthToken
  }
}

public struct AutomationPreTransactionState: Equatable, Hashable, Sendable {
  public let sourceExisted: Bool
  public let enabledState: AutomationEnabledState
  public let loadState: AutomationLoadState
  public let linkedProcesses: Set<AutomationLinkedProcessIdentity>

  public init(
    sourceExisted: Bool = true,
    enabledState: AutomationEnabledState,
    loadState: AutomationLoadState,
    linkedProcesses: Set<AutomationLinkedProcessIdentity>
  ) {
    self.sourceExisted = sourceExisted
    self.enabledState = enabledState
    self.loadState = loadState
    self.linkedProcesses = linkedProcesses
  }
}

public protocol AutomationMutationApplying: Sendable {
  func apply(
    _ operation: AutomationOperation,
    to record: AutomationRecord,
    linkedProcesses: [ClassifiedDevProcess],
    proposedSourceURL: URL?
  ) async throws -> AutomationExecutorResult

  func restorePreTransactionState(
    _ state: AutomationPreTransactionState,
    for record: AutomationRecord,
    recovery: AutomationVerifiedRecoveryInput,
    linkedProcesses: [ClassifiedDevProcess],
    expectedAppliedState: AutomationExecutorAppliedState?
  ) async throws -> AutomationExecutorResult
}

public extension AutomationMutationApplying {
  func restorePreTransactionState(
    _ state: AutomationPreTransactionState,
    for record: AutomationRecord,
    recovery: AutomationVerifiedRecoveryInput,
    linkedProcesses: [ClassifiedDevProcess],
    expectedAppliedState: AutomationExecutorAppliedState?
  ) async throws -> AutomationExecutorResult {
    throw AutomationManagerConfigurationError.exactStateRestorationUnavailable
  }
}

public actor AutomationManager {
  private let fileSystem: any AutomationFileSystem
  private let executor: any AutomationMutationApplying
  private let capabilityContext: @Sendable (AutomationRecord) throws -> AutomationCapabilityContext
  private let destinationContext: @Sendable (
    AutomationRecord,
    URL
  ) throws -> AutomationCapabilityContext
  private let recoverableSource: @Sendable (
    AutomationRecord
  ) async throws -> AutomationRecoverableSource
  private let refresh: @Sendable () async -> AutomationInventorySnapshot
  private let refreshProcesses: @Sendable () async throws -> [DevProcess]
  private let backupDirectory: URL
  private let currentUID: uid_t
  private let now: @Sendable () -> Date
  private let makeUUID: @Sendable () -> UUID
  private let evidenceRedactor: @Sendable (String) -> String
  private var backupsByID: [AutomationBackup.ID: AutomationBackup] = [:]
  private var manifestURLsByID: [AutomationBackup.ID: URL] = [:]
  private var backupAuthorizationsByID: [AutomationBackup.ID: AutomationFileAuthorization] = [:]
  private var manifestAuthorizationsByID: [AutomationBackup.ID: AutomationFileAuthorization] = [:]
  private var manifestDataByID: [AutomationBackup.ID: Data] = [:]
  private var recoveryRootResourceIdentifier: String?
  private var transactionIsActive = false
  private var transactionWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    fileSystem: any AutomationFileSystem,
    executor: any AutomationMutationApplying,
    capabilityContext: @escaping @Sendable (AutomationRecord) throws -> AutomationCapabilityContext,
    destinationContext: @escaping @Sendable (
      AutomationRecord,
      URL
    ) throws -> AutomationCapabilityContext = { _, _ in
      throw AutomationManagerConfigurationError.destinationAuthorizationUnavailable
    },
    recoverableSource: @escaping @Sendable (
      AutomationRecord
    ) async throws -> AutomationRecoverableSource = { _ in
      throw AutomationManagerConfigurationError.recoverableSourceUnavailable
    },
    refresh: @escaping @Sendable () async -> AutomationInventorySnapshot,
    refreshProcesses: @escaping @Sendable () async throws -> [DevProcess] = {
      throw AutomationManagerConfigurationError.runtimeProcessVerificationUnavailable
    },
    backupDirectory: URL,
    currentUID: uid_t = getuid(),
    now: @escaping @Sendable () -> Date = Date.init,
    makeUUID: @escaping @Sendable () -> UUID = UUID.init,
    evidenceRedactor: @escaping @Sendable (String) -> String = { _ in
      "Executor evidence redacted."
    }
  ) {
    self.fileSystem = fileSystem
    self.executor = executor
    self.capabilityContext = capabilityContext
    self.destinationContext = destinationContext
    self.recoverableSource = recoverableSource
    self.refresh = refresh
    self.refreshProcesses = refreshProcesses
    self.backupDirectory = backupDirectory
    self.currentUID = currentUID
    self.now = now
    self.makeUUID = makeUUID
    self.evidenceRedactor = evidenceRedactor
    recoveryRootResourceIdentifier = try? fileSystem.metadata(for: backupDirectory)
      .resourceIdentifier
    let loaded = Self.loadManifests(
      fileSystem: fileSystem,
      backupDirectory: backupDirectory,
      currentUID: currentUID
    )
    backupsByID = loaded.backups
    manifestURLsByID = loaded.manifestURLs
    backupAuthorizationsByID = loaded.backupAuthorizations
    manifestAuthorizationsByID = loaded.manifestAuthorizations
    manifestDataByID = loaded.manifestData
  }

  public func perform(
    _ operation: AutomationOperation,
    record: AutomationRecord,
    expectedChecksum: String?,
    linkedProcesses: [ClassifiedDevProcess]
  ) async -> AutomationOperationResult {
    await acquireTransaction()
    defer { releaseTransaction() }

    if case let .exportRecord(requestedRedaction) = operation,
       record.ownership != .user
         || record.kind == .launchDaemon
         || record.kind == .backgroundItem
         || record.sourceKind == .launchDaemon
         || record.sourceKind == .serviceManagement
    {
      guard expectedChecksum == record.sourceChecksum else {
        return rejected(operation, "The automation record changed since it was inspected.")
      }
      let context: AutomationCapabilityContext
      do {
        context = try capabilityContext(record)
      } catch {
        return rejected(operation, "DevScope could not verify the automation record identity.")
      }
      let decision = AutomationCapabilityPolicy.decision(for: record, context: context)
      guard decision.capabilities.contains(.exportRecord) else {
        return rejected(operation, decision.reason ?? "Export is not available for this source.")
      }
      do {
        let artifact = try AutomationRecordExporter.artifact(
          for: record,
          verifiedSourceData: nil,
          requestedRedaction: requestedRedaction
        )
        return AutomationOperationResult(
          operation: operation.redactedForResult,
          status: .succeeded,
          appliedSteps: ["Prepared an automation export without mutating its source."],
          verificationEvidence: ["The export artifact is bound to the inspected record generation."],
          rollback: .notNeeded,
          manualRecovery: nil,
          exportArtifact: artifact
        )
      } catch {
        return failed(operation, "DevScope could not prepare the automation export.")
      }
    }

    let restorationBackup: AutomationBackup?
    if case .restore(let id) = operation {
      guard let backup = backupsByID[id],
            backup.authorizedRecordIDs.contains(record.id),
            backup.ownerUID == record.ownerUID,
            backup.kind == record.kind,
            backup.sourceKind == record.sourceKind
      else {
        return rejected(operation, "The selected recovery backup does not belong to this automation.")
      }
      restorationBackup = backup
    } else {
      restorationBackup = nil
    }

    let sourceURL: URL
    let sourceData: Data
    let metadata: AutomationFileMetadata
    let sourceExistedAtPreflight: Bool
    do {
      if let restorationBackup {
        sourceURL = restorationBackup.sourceURL.standardizedFileURL
        sourceExistedAtPreflight = fileSystem.itemExists(at: sourceURL)
        if sourceExistedAtPreflight {
          sourceData = try fileSystem.read(sourceURL)
          metadata = try fileSystem.metadata(for: sourceURL)
        } else {
          sourceData = Data()
          metadata = try fileSystem.metadata(for: sourceURL.deletingLastPathComponent())
        }
      } else if !record.sourceKind.requiresRecoverableSource, let directURL = record.sourceURL {
        sourceURL = directURL.standardizedFileURL
        sourceData = try fileSystem.read(sourceURL)
        metadata = try fileSystem.metadata(for: sourceURL)
        sourceExistedAtPreflight = true
      } else {
        let captured = try await recoverableSource(record)
        sourceURL = captured.transactionURL.standardizedFileURL
        sourceData = captured.data
        metadata = captured.metadata
        guard captured.checksum == Self.sourceChecksum(captured.data, kind: record.kind),
              try fileSystem.read(sourceURL) == captured.data,
              try fileSystem.metadata(for: sourceURL) == captured.metadata
        else {
          return rejected(operation, "The recoverable source identity could not be established.")
        }
        sourceExistedAtPreflight = true
      }
    } catch let partial as AutomationFilePartialMutation {
      _ = await refresh()
      return AutomationOperationResult(
        operation: operation.redactedForResult,
        status: .partialFailure(
          "HIGH SEVERITY: recoverable source materialization reached a partial filesystem state."
        ),
        appliedSteps: ["Recoverable source materialization reached a partial filesystem state."],
        verificationEvidence: ["Refreshed automation truth before returning."],
        rollback: .notNeeded,
        manualRecovery: "Preserve and inspect the authorized recovery handle before retrying.",
        fileMutationEvidence: partial
      )
    } catch {
      let reason: String
      switch record.sourceKind {
      case .crontab:
        reason = "Current-user crontab management is unavailable until recoverable source access is installed."
      case .legacyLoginItem:
        reason = "Legacy login-item management is unavailable until recoverable source access is installed."
      default:
        reason = "DevScope could not re-read the automation source."
      }
      return rejected(operation, reason)
    }

    let observedChecksum = Self.sourceChecksum(sourceData, kind: record.kind)
    if restorationBackup != nil {
      guard sourceExistedAtPreflight ? expectedChecksum == observedChecksum : expectedChecksum == nil else {
        return rejected(operation, "The restore destination changed since it was inspected.")
      }
    } else if expectedChecksum != observedChecksum {
      return rejected(operation, "The automation source changed since it was inspected.")
    }
    if case .confirmedRunToCompletion(let confirmation) = operation {
      guard confirmation.recordID == record.id,
            let confirmationChecksum = confirmation.sourceChecksum,
            confirmationChecksum == record.sourceChecksum,
            confirmationChecksum == observedChecksum
      else {
        return rejected(operation, "The confirmed cron command belongs to a stale source generation.")
      }
    }

    let context: AutomationCapabilityContext
    do {
      context = try restorationBackup == nil
        ? capabilityContext(record)
        : destinationContext(record, sourceURL)
    } catch {
      return rejected(operation, "DevScope could not verify the automation source identity.")
    }
    let authorizedMetadataURL = sourceExistedAtPreflight
      ? sourceURL
      : sourceURL.deletingLastPathComponent().standardizedFileURL
    guard metadata.resourceIdentifier?.isEmpty == false,
          metadata.ownerUID == context.sourceOwnerUID,
          metadata.isSymbolicLink == context.isSymlink,
          metadata.canonicalURL.standardizedFileURL.path == authorizedMetadataURL.path
    else {
      return rejected(operation, "The automation source identity changed during verification.")
    }
    let decision = AutomationCapabilityPolicy.decision(for: record, context: context)
    guard decision.capabilities.contains(operation.requiredCapability) else {
      return rejected(operation, decision.reason ?? "This operation is not available for the source.")
    }

    if case let .exportRecord(requestedRedaction) = operation {
      do {
        let artifact = try AutomationRecordExporter.artifact(
          for: record,
          verifiedSourceData: sourceData,
          requestedRedaction: requestedRedaction
        )
        return AutomationOperationResult(
          operation: operation.redactedForResult,
          status: .succeeded,
          appliedSteps: ["Prepared an automation export without mutating its source."],
          verificationEvidence: ["The export uses the checksum-verified source generation."],
          rollback: .notNeeded,
          manualRecovery: nil,
          exportArtifact: artifact
        )
      } catch {
        return failed(operation, "DevScope could not prepare the automation export.")
      }
    }

    let proposal: SourceProposal?
    do {
      proposal = try makeProposal(
        for: operation,
        record: record,
        sourceURL: sourceURL,
        selectedSourceData: sourceData
      )
    } catch let error as ProposalError {
      return rejected(operation, error.message)
    } catch {
      return rejected(operation, "The proposed automation source could not be prepared.")
    }

    if let proposal, proposal.restoresSourcePresence,
       !Self.isValidSource(
         proposal.data,
         kind: record.kind,
         expectedLabel: proposal.intendedLabel,
         sourceURL: proposal.destination,
         ownerUID: context.currentUID
       )
    {
      return rejected(operation, "The proposed automation source is not valid.")
    }

    let destinationSnapshot: DestinationSnapshot?
    do {
      destinationSnapshot = try proposal.map {
        try verifyDestination(
          $0,
          record: record,
          selectedSourceURL: sourceURL,
          selectedSourceData: sourceData,
          selectedMetadata: metadata
        )
      }
    } catch let error as ProposalError {
      return rejected(operation, error.message)
    } catch {
      return rejected(operation, "DevScope could not authorize the intended destination.")
    }

    let linkedIdentities = linkedProcesses.compactMap { classified -> AutomationLinkedProcessIdentity? in
      guard let birthToken = classified.process.birthToken else { return nil }
      return AutomationLinkedProcessIdentity(
        processID: classified.process.pid,
        birthToken: birthToken
      )
    }
    if operation.controlsLinkedProcesses, linkedIdentities.count != linkedProcesses.count {
      return rejected(operation, "Every controlled process requires an exact birth identity.")
    }
    let preTransactionState = AutomationPreTransactionState(
      sourceExisted: destinationSnapshot?.existed ?? sourceExistedAtPreflight,
      enabledState: record.enabledState,
      loadState: record.loadState,
      linkedProcesses: Set(linkedIdentities)
    )

    let backup: AutomationBackup
    do {
      let recoveryData = destinationSnapshot?.data ?? (proposal == nil ? sourceData : Data())
      let recoveryURL = proposal?.destination ?? sourceURL
      backup = try createBackup(
        sourceData: recoveryData,
        checksum: Self.checksum(recoveryData),
        sourceURL: recoveryURL,
        sourceExisted: destinationSnapshot?.existed ?? true,
        record: record
      )
    } catch let partial as AutomationFilePartialMutation {
      _ = await refresh()
      return AutomationOperationResult(
        operation: operation.redactedForResult,
        status: .partialFailure(
          "HIGH SEVERITY: recovery evidence installation was only partially completed."
        ),
        appliedSteps: ["Recovery evidence installation reached a partial filesystem state."],
        verificationEvidence: ["Refreshed automation truth before returning."],
        rollback: .notNeeded,
        manualRecovery: "Preserve and inspect the authorized recovery handle before retrying.",
        fileMutationEvidence: partial
      )
    } catch {
      return failed(
        operation,
        "DevScope could not create owner-only recovery evidence.",
        manualRecovery: "No changes were applied. Verify that the recovery folder is writable."
      )
    }

    if restorationBackup == nil {
      do {
        if let revalidationFailure = try await revalidationFailure(
          operation: operation,
          record: record,
          sourceURL: sourceURL,
          expectedChecksum: observedChecksum,
          initialMetadata: metadata
        ) {
          return failed(
            operation,
            revalidationFailure,
            appliedSteps: ["Created owner-only recovery backup."],
            manualRecovery: "No mutation was applied; inspect the source again before retrying.",
            backup: backup
          )
        }
      } catch let partial as AutomationFilePartialMutation {
        _ = await refresh()
        return AutomationOperationResult(
          operation: operation.redactedForResult,
          status: .partialFailure(
            "HIGH SEVERITY: recoverable source materialization reached a partial filesystem state."
          ),
          appliedSteps: [
            "Created owner-only recovery backup.",
            "Recoverable source materialization reached a partial filesystem state.",
          ],
          verificationEvidence: ["Refreshed automation truth before returning."],
          rollback: .notNeeded,
          manualRecovery: "Preserve and inspect the authorized recovery handle before retrying.",
          backup: backup,
          fileMutationEvidence: partial
        )
      } catch {
        return failed(
          operation,
          "DevScope could not revalidate the automation source immediately before mutation.",
          appliedSteps: ["Created owner-only recovery backup."],
          manualRecovery: "No mutation was applied; inspect the source again before retrying.",
          backup: backup
        )
      }
    }
    if let proposal, let destinationSnapshot,
       let failure = destinationRevalidationFailure(
         proposal,
         snapshot: destinationSnapshot,
         record: record
       )
    {
      return failed(
        operation,
        failure,
        appliedSteps: ["Created owner-only recovery backup."],
        manualRecovery: "No mutation was applied; inspect the destination again before retrying.",
        backup: backup
      )
    }

    var proposedSourceURL: URL?
    var sourceMutationStep: String?
    var postMutationResourceIdentifier: String?
    if let proposal, proposal.restoresSourcePresence {
      do {
        guard let destinationSnapshot else {
          throw AutomationManagerConfigurationError.destinationAuthorizationUnavailable
        }
        let parentAuthorization = try Self.directoryAuthorization(
          for: proposal.destination.deletingLastPathComponent(),
          resourceIdentifier: destinationSnapshot.parentMetadata.resourceIdentifier
        )
        let staged = try fileSystem.writeStagedFile(
          nextTo: proposal.destination,
          data: proposal.data,
          permissions: 0o600,
          authorization: parentAuthorization
        )
        let stagedData = try fileSystem.read(staged.url)
        guard Self.isValidSource(
          stagedData,
          kind: record.kind,
          expectedLabel: proposal.intendedLabel,
          sourceURL: proposal.destination,
          ownerUID: context.currentUID
        ), stagedData == proposal.data else {
          try removeCleanupArtifact(staged.authorization)
          return failed(
            operation,
            "The proposed automation source is not valid.",
            appliedSteps: ["Created owner-only recovery backup."],
            backup: backup
          )
        }
        if let failure = destinationRevalidationFailure(
             proposal,
             snapshot: destinationSnapshot,
             record: record
           ) {
          try removeCleanupArtifact(staged.authorization)
          return failed(
            operation,
            failure,
            appliedSteps: ["Created owner-only recovery backup."],
            backup: backup
          )
        }
        let destinationAuthorization = try Self.fileAuthorization(
          for: proposal.destination,
          directory: parentAuthorization,
          resourceIdentifier: destinationSnapshot.metadata.resourceIdentifier,
          existed: destinationSnapshot.existed
        )
        let replacementReceipt = try committedReplacement(
          at: destinationAuthorization,
          with: staged
        )
        guard replacementReceipt.bindingVerified else {
          throw AutomationManagerConfigurationError.recoverableSourceUnavailable
        }
        sourceMutationStep = "Installed validated source atomically."
        let installedMetadata = try fileSystem.metadata(for: proposal.destination)
        guard let installedIdentity = installedMetadata.resourceIdentifier,
              !installedIdentity.isEmpty
        else {
          throw AutomationManagerConfigurationError.recoverableSourceUnavailable
        }
        postMutationResourceIdentifier = installedIdentity
        let installedAuthorization = try Self.fileAuthorization(
          for: proposal.destination,
          directory: parentAuthorization,
          resourceIdentifier: installedIdentity,
          existed: true
        )
        guard try fileSystem.fileMatchesBinding(
          installedAuthorization,
          binding: staged.binding
        ) else {
          throw AutomationManagerConfigurationError.recoverableSourceUnavailable
        }
        proposedSourceURL = proposal.destination
      } catch let partial as AutomationFilePartialMutation {
        postMutationResourceIdentifier = try? fileSystem.metadata(for: proposal.destination)
          .resourceIdentifier
        return await failureAfterMutation(
          operation: operation,
          record: record,
          linkedProcesses: linkedProcesses,
          backup: backup,
          preTransactionState: preTransactionState,
          proposal: proposal,
          originalSourceMetadata: metadata,
          postMutationResourceIdentifier: postMutationResourceIdentifier,
          sourceMutationStep: "Filesystem reported a partial source replacement.",
          phase: .sourceMutationFailed,
          evidence: ["Filesystem mutation state was refreshed before executor use."],
          expectedAppliedState: nil,
          fileMutationEvidence: partial
        )
      } catch {
        if sourceMutationStep != nil {
          postMutationResourceIdentifier = try? fileSystem.metadata(for: proposal.destination)
            .resourceIdentifier
          return await failureAfterMutation(
            operation: operation,
            record: record,
            linkedProcesses: linkedProcesses,
            backup: backup,
            preTransactionState: preTransactionState,
            proposal: proposal,
            originalSourceMetadata: metadata,
            postMutationResourceIdentifier: postMutationResourceIdentifier,
            sourceMutationStep: sourceMutationStep,
            phase: .sourceMutationFailed,
            evidence: [],
            expectedAppliedState: nil
          )
        }
        return failed(
          operation,
          "DevScope could not stage the proposed automation source.",
          appliedSteps: ["Created owner-only recovery backup."],
          backup: backup
        )
      }
    } else if let proposal {
      do {
        if fileSystem.itemExists(at: proposal.destination) {
          guard try writeTargetIsAuthorized(
            record: record,
            url: proposal.destination,
            expectedResourceIdentifier: destinationSnapshot?.metadata.resourceIdentifier,
            expectedParentResourceIdentifier: destinationSnapshot?.parentMetadata.resourceIdentifier,
            requiredCapability: .restore
          ) else {
            throw AutomationManagerConfigurationError.destinationAuthorizationUnavailable
          }
          let parentAuthorization = try Self.directoryAuthorization(
            for: proposal.destination.deletingLastPathComponent(),
            resourceIdentifier: destinationSnapshot?.parentMetadata.resourceIdentifier
          )
          let destinationAuthorization = try Self.fileAuthorization(
            for: proposal.destination,
            directory: parentAuthorization,
            resourceIdentifier: destinationSnapshot?.metadata.resourceIdentifier,
            existed: true
          )
          _ = try Self.committedReceipt(fileSystem.removeItem(destinationAuthorization))
        }
        sourceMutationStep = "Restored the source's prior absence."
      } catch let partial as AutomationFilePartialMutation {
        return await failureAfterMutation(
          operation: operation,
          record: record,
          linkedProcesses: linkedProcesses,
          backup: backup,
          preTransactionState: preTransactionState,
          proposal: proposal,
          originalSourceMetadata: metadata,
          postMutationResourceIdentifier: nil,
          sourceMutationStep: "Filesystem reported a partial removal while restoring absence.",
          phase: .sourceMutationFailed,
          evidence: ["Filesystem mutation state was refreshed before executor use."],
          expectedAppliedState: nil,
          fileMutationEvidence: partial
        )
      } catch {
        return failed(
          operation,
          "DevScope could not restore the prior absent source state.",
          appliedSteps: ["Created owner-only recovery backup."],
          backup: backup
        )
      }
    }

    if case .remove = operation, !record.sourceKind.requiresRecoverableSource {
      do {
        guard try writeTargetIsAuthorized(
          record: record,
          url: sourceURL,
          expectedResourceIdentifier: metadata.resourceIdentifier,
          expectedParentResourceIdentifier: backup.parentResourceIdentifier,
          requiredCapability: .remove
        ) else {
          throw AutomationManagerConfigurationError.destinationAuthorizationUnavailable
        }
        let parentAuthorization = try Self.directoryAuthorization(
          for: sourceURL.deletingLastPathComponent(),
          resourceIdentifier: backup.parentResourceIdentifier
        )
        let sourceAuthorization = try Self.fileAuthorization(
          for: sourceURL,
          directory: parentAuthorization,
          resourceIdentifier: metadata.resourceIdentifier,
          existed: true
        )
        let trashReceipt = try Self.committedReceipt(
          fileSystem.moveToTrash(sourceAuthorization)
        )
        guard let trashURL = trashReceipt.resultURL else {
          throw AutomationManagerConfigurationError.recoverableSourceUnavailable
        }
        proposedSourceURL = trashURL
        sourceMutationStep = "Moved the source to Trash."
      } catch let partial as AutomationFilePartialMutation {
        proposedSourceURL = partial.resultURL
        return await failureAfterMutation(
          operation: operation,
          record: record,
          linkedProcesses: linkedProcesses,
          backup: backup,
          preTransactionState: preTransactionState,
          proposal: proposal,
          originalSourceMetadata: metadata,
          postMutationResourceIdentifier: nil,
          sourceMutationStep: "Filesystem reported a partial Trash move.",
          phase: .sourceMutationFailed,
          evidence: ["Filesystem mutation state was refreshed before executor use."],
          expectedAppliedState: nil,
          fileMutationEvidence: partial
        )
      } catch {
        return failed(
          operation,
          "DevScope could not move the automation source to Trash.",
          appliedSteps: ["Created owner-only recovery backup."],
          backup: backup
        )
      }
    }

    let executorResult: AutomationExecutorResult
    do {
      executorResult = try await executor.apply(
        operation,
        to: record,
        linkedProcesses: linkedProcesses,
        proposedSourceURL: proposedSourceURL
      )
    } catch let partial as AutomationFilePartialMutation {
      return await failureAfterMutation(
        operation: operation,
        record: record,
        linkedProcesses: linkedProcesses,
        backup: backup,
        preTransactionState: preTransactionState,
        proposal: proposal,
        originalSourceMetadata: metadata,
        postMutationResourceIdentifier: postMutationResourceIdentifier,
        sourceMutationStep: sourceMutationStep,
        phase: .executorAttempted,
        evidence: ["Executor filesystem cleanup reached a partial state."],
        expectedAppliedState: nil,
        fileMutationEvidence: partial
      )
    } catch {
      let expectedAppliedState = (error as? AutomationExecutorMutationFailure)?.appliedState
      return await failureAfterMutation(
        operation: operation,
        record: record,
        linkedProcesses: linkedProcesses,
        backup: backup,
        preTransactionState: preTransactionState,
        proposal: proposal,
        originalSourceMetadata: metadata,
        postMutationResourceIdentifier: postMutationResourceIdentifier,
        sourceMutationStep: sourceMutationStep,
        phase: .executorAttempted,
        evidence: [],
        expectedAppliedState: expectedAppliedState
      )
    }

    let refreshed = await refresh()
    let refreshedProcesses: [DevProcess]
    if operation.requiresFreshProcessSnapshot {
      do {
        refreshedProcesses = try await refreshProcesses()
      } catch {
        return await failureAfterMutation(
          operation: operation,
          record: record,
          linkedProcesses: linkedProcesses,
          backup: backup,
          preTransactionState: preTransactionState,
          proposal: proposal,
          originalSourceMetadata: metadata,
          postMutationResourceIdentifier: postMutationResourceIdentifier,
          sourceMutationStep: sourceMutationStep,
          phase: .verificationFailed,
          evidence: ["Live process verification was unavailable after the operation."],
          expectedAppliedState: executorResult.appliedState
        )
      }
    } else {
      refreshedProcesses = []
    }
    let verification = verify(
      operation,
      record: record,
      executorResult: executorResult,
      snapshot: refreshed,
      proposal: proposal,
      transactionSourceURL: sourceURL,
      controlledIdentities: preTransactionState.linkedProcesses,
      liveProcesses: refreshedProcesses
    )
    guard verification.satisfied else {
      return await failureAfterMutation(
        operation: operation,
        record: record,
        linkedProcesses: linkedProcesses,
        backup: backup,
        preTransactionState: preTransactionState,
        proposal: proposal,
        originalSourceMetadata: metadata,
        postMutationResourceIdentifier: postMutationResourceIdentifier,
        sourceMutationStep: sourceMutationStep,
        phase: .verificationFailed,
        evidence: executorResult.evidence.map(evidenceRedactor) + verification.evidence,
        expectedAppliedState: executorResult.appliedState
      )
    }

    if let verifiedRecordID = verification.verifiedRecordID,
       !backup.authorizedRecordIDs.contains(verifiedRecordID) {
      do {
        try authorizeRecoverySuccessor(verifiedRecordID, for: backup.id)
      } catch let partial as AutomationFilePartialMutation {
        return await failureAfterMutation(
          operation: operation,
          record: record,
          linkedProcesses: linkedProcesses,
          backup: backup,
          preTransactionState: preTransactionState,
          proposal: proposal,
          originalSourceMetadata: metadata,
          postMutationResourceIdentifier: postMutationResourceIdentifier,
          sourceMutationStep: sourceMutationStep,
          phase: .verificationFailed,
          evidence: verification.evidence + ["Recovery identity persistence reached a partial filesystem state."],
          expectedAppliedState: executorResult.appliedState,
          fileMutationEvidence: partial
        )
      } catch {
        return await failureAfterMutation(
          operation: operation,
          record: record,
          linkedProcesses: linkedProcesses,
          backup: backup,
          preTransactionState: preTransactionState,
          proposal: proposal,
          originalSourceMetadata: metadata,
          postMutationResourceIdentifier: postMutationResourceIdentifier,
          sourceMutationStep: sourceMutationStep,
          phase: .verificationFailed,
          evidence: verification.evidence + ["Recovery identity could not be persisted."],
          expectedAppliedState: executorResult.appliedState
        )
      }
    }

    return AutomationOperationResult(
      operation: operation.redactedForResult,
      status: .succeeded,
      appliedSteps: [
        "Created owner-only recovery backup.",
        sourceMutationStep,
        "Applied typed automation operation.",
        "Refreshed automation inventory.",
        "Verified operation postconditions.",
      ].compactMap { $0 },
      verificationEvidence: executorResult.evidence.map(evidenceRedactor) + verification.evidence,
      rollback: .notNeeded,
      manualRecovery: nil,
      backup: backup.redactedForResult
    )
  }

  public func restorationManifests() -> [AutomationBackup] {
    return backupsByID.values.sorted { lhs, rhs in
      if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
      return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
    }.map(\.redactedForResult)
  }

  private func acquireTransaction() async {
    guard transactionIsActive else {
      transactionIsActive = true
      return
    }
    await withCheckedContinuation { continuation in
      transactionWaiters.append(continuation)
    }
  }

  private func releaseTransaction() {
    guard !transactionWaiters.isEmpty else {
      transactionIsActive = false
      return
    }
    transactionWaiters.removeFirst().resume()
  }

  private func createBackup(
    sourceData: Data,
    checksum: String,
    sourceURL: URL,
    sourceExisted: Bool,
    record: AutomationRecord
  ) throws -> AutomationBackup {
    let id = AutomationBackup.ID(rawValue: makeUUID())
    let parentMetadata = try fileSystem.metadata(for: sourceURL.deletingLastPathComponent())
    guard parentMetadata.resourceIdentifier?.isEmpty == false else {
      throw AutomationManagerConfigurationError.recoverableSourceUnavailable
    }
    let backupURL = backupDirectory.appendingPathComponent(
      "\(id.rawValue.uuidString.lowercased()).backup",
      isDirectory: false
    )
    guard backupsByID[id] == nil, !fileSystem.itemExists(at: backupURL) else {
      throw AutomationManagerConfigurationError.recoverableSourceUnavailable
    }
    try fileSystem.createDirectory(backupDirectory, permissions: 0o700)
    let rootMetadata = try fileSystem.metadata(for: backupDirectory)
    guard rootMetadata.canonicalURL.standardizedFileURL.path == backupDirectory.standardizedFileURL.path,
          rootMetadata.ownerUID == currentUID,
          !rootMetadata.isSymbolicLink,
          rootMetadata.resourceIdentifier?.isEmpty == false,
          rootMetadata.permissions == 0o700
    else { throw AutomationManagerConfigurationError.recoverableSourceUnavailable }
    if let expectedRootIdentity = recoveryRootResourceIdentifier,
       rootMetadata.resourceIdentifier != expectedRootIdentity {
      throw AutomationManagerConfigurationError.recoverableSourceUnavailable
    }
    recoveryRootResourceIdentifier = rootMetadata.resourceIdentifier
    let rootAuthorization = try Self.directoryAuthorization(
      for: backupDirectory,
      resourceIdentifier: rootMetadata.resourceIdentifier
    )
    let stagedBackup = try fileSystem.writeStagedFile(
      nextTo: backupURL,
      data: sourceData,
      permissions: 0o600,
      authorization: rootAuthorization
    )
    guard recoveryRootIsAuthorized() else {
      try removeCleanupArtifact(stagedBackup.authorization)
      throw AutomationManagerConfigurationError.recoverableSourceUnavailable
    }
    let absentBackup = try Self.fileAuthorization(
      for: backupURL,
      directory: rootAuthorization,
      resourceIdentifier: nil,
      existed: false
    )
    _ = try committedReplacement(at: absentBackup, with: stagedBackup)
    let backupResourceIdentifier: String
    guard case .existing(let stagedBackupIdentity) = stagedBackup.authorization.expectation else {
      throw AutomationManagerConfigurationError.recoverableSourceUnavailable
    }
    backupResourceIdentifier = stagedBackupIdentity
    let backupAuthorization = try Self.fileAuthorization(
      for: backupURL,
      directory: rootAuthorization,
      resourceIdentifier: backupResourceIdentifier,
      existed: true
    )
    guard recoveryArtifactIsVerified(
      at: backupURL,
      expectedData: sourceData,
      expectedChecksum: checksum,
      requiresPropertyList: false
    ) else {
      try removeCleanupArtifact(backupAuthorization)
      throw AutomationManagerConfigurationError.recoverableSourceUnavailable
    }
    let backup = AutomationBackup(
      id: id,
      recordID: record.id,
      sourceURL: sourceURL,
      backupURL: backupURL,
      checksum: checksum,
      createdAt: now(),
      sourceExisted: sourceExisted,
      ownerUID: record.ownerUID ?? 0,
      kind: record.kind,
      sourceKind: record.sourceKind,
      parentResourceIdentifier: parentMetadata.resourceIdentifier
    )
    let manifestURL = backupDirectory.appendingPathComponent(
      "\(id.rawValue.uuidString.lowercased()).manifest.plist",
      isDirectory: false
    )
    var installedManifestAuthorization: AutomationFileAuthorization?
    var installedManifestData: Data?
    do {
      let manifestData = try Self.manifestData(
        for: backup,
        ownerUID: record.ownerUID ?? 0
      )
      let stagedManifest = try fileSystem.writeStagedFile(
        nextTo: manifestURL,
        data: manifestData,
        permissions: 0o600,
        authorization: rootAuthorization
      )
      guard recoveryRootIsAuthorized() else {
        try removeCleanupArtifact(stagedManifest.authorization)
        throw AutomationManagerConfigurationError.recoverableSourceUnavailable
      }
      let absentManifest = try Self.fileAuthorization(
        for: manifestURL,
        directory: rootAuthorization,
        resourceIdentifier: nil,
        existed: false
      )
      let manifestReceipt = try committedReplacement(at: absentManifest, with: stagedManifest)
      installedManifestAuthorization = manifestReceipt.primaryFile
      installedManifestData = manifestData
      guard recoveryArtifactIsVerified(
        at: manifestURL,
        expectedData: manifestData,
        expectedChecksum: Self.checksum(manifestData),
        requiresPropertyList: true
      ) else { throw AutomationManagerConfigurationError.recoverableSourceUnavailable }
    } catch {
      let originalPartial = error as? AutomationFilePartialMutation
      var cleanupCandidates = [installedManifestAuthorization, backupAuthorization].compactMap {
        $0
      }
      if let originalPartial {
        for candidate in originalPartial.recoveryHandles
          where candidate.directory.directoryURL.standardizedFileURL
            == backupDirectory.standardizedFileURL
            && !cleanupCandidates.contains(candidate) {
          cleanupCandidates.append(candidate)
        }
      }
      do {
        try cleanupRecoveryArtifacts(cleanupCandidates)
      } catch let cleanupPartial as AutomationFilePartialMutation {
        let observedSurvivors = currentAuthorizedSurvivors(
          cleanupCandidates + (originalPartial?.observedFiles ?? [])
            + cleanupPartial.observedFiles + cleanupPartial.recoveryHandles
        )
        let recoverySurvivors = currentAuthorizedSurvivors(
          cleanupCandidates + (originalPartial?.recoveryHandles ?? [])
            + cleanupPartial.recoveryHandles
        )
        throw AutomationFilePartialMutation(
          kind: originalPartial?.kind ?? .remove,
          commitState: .unknown,
          observedFiles: observedSurvivors,
          recoveryHandle: recoverySurvivors.first,
          recoveryHandles: recoverySurvivors,
          resultURL: originalPartial?.resultURL ?? manifestURL
        )
      }
      if let originalPartial {
        let observedSurvivors = currentAuthorizedSurvivors(
          cleanupCandidates + originalPartial.observedFiles
        )
        let recoverySurvivors = currentAuthorizedSurvivors(
          cleanupCandidates + originalPartial.recoveryHandles
        )
        throw AutomationFilePartialMutation(
          kind: originalPartial.kind,
          commitState: originalPartial.commitState,
          observedFiles: observedSurvivors,
          recoveryHandle: recoverySurvivors.first,
          recoveryHandles: recoverySurvivors,
          resultURL: originalPartial.resultURL
        )
      }
      throw error
    }
    guard let installedManifestAuthorization, let installedManifestData else {
      throw AutomationManagerConfigurationError.recoverableSourceUnavailable
    }
    backupsByID[id] = backup
    manifestURLsByID[id] = manifestURL
    backupAuthorizationsByID[id] = backupAuthorization
    manifestAuthorizationsByID[id] = installedManifestAuthorization
    manifestDataByID[id] = installedManifestData
    try pruneRecoveryEvidence(preserving: id)
    return backup
  }

  private static func manifestData(
    for backup: AutomationBackup,
    ownerUID: uid_t
  ) throws -> Data {
    try PropertyListSerialization.data(
      fromPropertyList: [
        "version": 2,
        "id": backup.id.rawValue.uuidString.lowercased(),
        "recordID": backup.recordID.rawValue,
        "sourcePath": backup.sourceURL.path,
        "backupPath": backup.backupURL.path,
        "checksum": backup.checksum,
        "createdAt": backup.createdAt.timeIntervalSince1970,
        "sourceExisted": backup.sourceExisted,
        "ownerUID": Int(ownerUID),
        "kind": backup.kind.rawValue,
        "sourceKind": backup.sourceKind.rawValue,
        "authorizedRecordIDs": backup.authorizedRecordIDs.map(\.rawValue).sorted(),
        "parentResourceIdentifier": backup.parentResourceIdentifier ?? "",
      ],
      format: .binary,
      options: 0
    )
  }

  private static func loadManifests(
    fileSystem: any AutomationFileSystem,
    backupDirectory: URL,
    currentUID: uid_t
  ) -> (
    backups: [AutomationBackup.ID: AutomationBackup],
    manifestURLs: [AutomationBackup.ID: URL],
    backupAuthorizations: [AutomationBackup.ID: AutomationFileAuthorization],
    manifestAuthorizations: [AutomationBackup.ID: AutomationFileAuthorization],
    manifestData: [AutomationBackup.ID: Data]
  ) {
    let recoveryRoot = backupDirectory.standardizedFileURL
    guard let rootMetadata = try? fileSystem.metadata(for: recoveryRoot),
          rootMetadata.canonicalURL.standardizedFileURL.path == recoveryRoot.path,
          rootMetadata.ownerUID == currentUID,
          !rootMetadata.isSymbolicLink,
          let rootResourceIdentifier = rootMetadata.resourceIdentifier,
          !rootResourceIdentifier.isEmpty,
          let rootAuthorization = AutomationDirectoryAuthorization(
            directoryURL: recoveryRoot,
            resourceIdentifier: rootResourceIdentifier
          ),
          rootMetadata.permissions == 0o700,
          let urls = try? fileSystem.plistURLs(in: recoveryRoot)
    else { return ([:], [:], [:], [:], [:]) }
    var backups: [AutomationBackup.ID: AutomationBackup] = [:]
    var manifestURLs: [AutomationBackup.ID: URL] = [:]
    var backupAuthorizations: [AutomationBackup.ID: AutomationFileAuthorization] = [:]
    var manifestAuthorizations: [AutomationBackup.ID: AutomationFileAuthorization] = [:]
    var manifestData: [AutomationBackup.ID: Data] = [:]
    for manifestURL in urls where manifestURL.lastPathComponent.hasSuffix(".manifest.plist") {
      guard let data = try? fileSystem.read(manifestURL),
            let value = try? PropertyListSerialization.propertyList(
              from: data,
              options: [],
              format: nil
            ),
            let dictionary = value as? [String: Any],
            Set(dictionary.keys) == Set([
              "version", "id", "recordID", "sourcePath", "backupPath", "checksum",
              "createdAt", "sourceExisted", "ownerUID", "kind", "sourceKind",
              "authorizedRecordIDs", "parentResourceIdentifier",
            ]),
            dictionary["version"] as? Int == 2,
            let rawID = dictionary["id"] as? String,
            let uuid = UUID(uuidString: rawID),
            manifestURL.standardizedFileURL == recoveryRoot.appendingPathComponent(
              "\(uuid.uuidString.lowercased()).manifest.plist"
            ).standardizedFileURL,
            let recordID = dictionary["recordID"] as? String,
            let sourcePath = dictionary["sourcePath"] as? String,
            let backupPath = dictionary["backupPath"] as? String,
            let checksum = dictionary["checksum"] as? String,
            let createdAt = dictionary["createdAt"] as? TimeInterval,
            let sourceExisted = dictionary["sourceExisted"] as? Bool,
            let ownerNumber = dictionary["ownerUID"] as? Int,
            let kindRaw = dictionary["kind"] as? String,
            let kind = AutomationKind(rawValue: kindRaw),
            let sourceKindRaw = dictionary["sourceKind"] as? String,
            let sourceKind = AutomationSourceKind(rawValue: sourceKindRaw),
            let authorizedRawIDs = dictionary["authorizedRecordIDs"] as? [String],
            let parentResourceIdentifier = dictionary["parentResourceIdentifier"] as? String,
            ownerNumber == Int(currentUID),
            let derivedBackupURL = Optional(recoveryRoot.appendingPathComponent(
              "\(uuid.uuidString.lowercased()).backup"
            ).standardizedFileURL),
            URL(fileURLWithPath: backupPath).standardizedFileURL == derivedBackupURL,
            fileSystem.itemExists(at: derivedBackupURL),
            let manifestMetadata = try? fileSystem.metadata(for: manifestURL),
            let backupMetadata = try? fileSystem.metadata(for: derivedBackupURL),
            manifestMetadata.canonicalURL.standardizedFileURL == manifestURL.standardizedFileURL,
            backupMetadata.canonicalURL.standardizedFileURL == derivedBackupURL,
            !manifestMetadata.isSymbolicLink,
            !backupMetadata.isSymbolicLink,
            manifestMetadata.ownerUID == currentUID,
            backupMetadata.ownerUID == currentUID,
            let manifestIdentity = manifestMetadata.resourceIdentifier,
            !manifestIdentity.isEmpty,
            let backupIdentity = backupMetadata.resourceIdentifier,
            !backupIdentity.isEmpty,
            manifestMetadata.permissions == 0o600,
            backupMetadata.permissions == 0o600,
            let backupData = try? fileSystem.read(derivedBackupURL),
            checksum == Self.checksum(backupData),
            let manifestAuthorization = AutomationFileAuthorization(
              fileURL: manifestURL,
              directory: rootAuthorization,
              expectation: .existing(resourceIdentifier: manifestIdentity)
            ),
            let backupAuthorization = AutomationFileAuthorization(
              fileURL: derivedBackupURL,
              directory: rootAuthorization,
              expectation: .existing(resourceIdentifier: backupIdentity)
            )
      else { continue }
      let id = AutomationBackup.ID(rawValue: uuid)
      let backup = AutomationBackup(
        id: id,
        recordID: AutomationRecord.ID(rawValue: recordID),
        sourceURL: URL(fileURLWithPath: sourcePath),
        backupURL: derivedBackupURL,
        checksum: checksum,
        createdAt: Date(timeIntervalSince1970: createdAt),
        sourceExisted: sourceExisted,
        ownerUID: uid_t(ownerNumber),
        kind: kind,
        sourceKind: sourceKind,
        authorizedRecordIDs: Set(authorizedRawIDs.map(AutomationRecord.ID.init(rawValue:))),
        parentResourceIdentifier: parentResourceIdentifier.isEmpty ? nil : parentResourceIdentifier
      )
      backups[id] = backup
      manifestURLs[id] = manifestURL
      manifestAuthorizations[id] = manifestAuthorization
      backupAuthorizations[id] = backupAuthorization
      manifestData[id] = data
    }
    return (backups, manifestURLs, backupAuthorizations, manifestAuthorizations, manifestData)
  }

  private func authorizeRecoverySuccessor(
    _ recordID: AutomationRecord.ID,
    for backupID: AutomationBackup.ID
  ) throws {
    guard let backup = backupsByID[backupID],
          let manifestURL = manifestURLsByID[backupID],
          let manifestAuthorization = manifestAuthorizationsByID[backupID],
          let backupAuthorization = backupAuthorizationsByID[backupID],
          let previousManifestData = manifestDataByID[backupID]
    else { throw AutomationManagerConfigurationError.recoverableSourceUnavailable }
    let updated = AutomationBackup(
      id: backup.id,
      recordID: backup.recordID,
      sourceURL: backup.sourceURL,
      backupURL: backup.backupURL,
      checksum: backup.checksum,
      createdAt: backup.createdAt,
      sourceExisted: backup.sourceExisted,
      ownerUID: backup.ownerUID,
      kind: backup.kind,
      sourceKind: backup.sourceKind,
      authorizedRecordIDs: backup.authorizedRecordIDs.union([recordID]),
      parentResourceIdentifier: backup.parentResourceIdentifier
    )
    let manifestData = try Self.manifestData(for: updated, ownerUID: backup.ownerUID)
    let rootAuthorization = manifestAuthorization.directory
    let artifactsRemainExact = rootAuthorization == backupAuthorization.directory
      && recoveryRootIsAuthorized()
      && authorizationIsCurrent(manifestAuthorization)
      && authorizationIsCurrent(backupAuthorization)
      && recoveryArtifactIsVerified(
            at: manifestURL,
            expectedData: previousManifestData,
            expectedChecksum: Self.checksum(previousManifestData),
            requiresPropertyList: true
          )
      && ((try? fileSystem.read(backup.backupURL)).map {
          recoveryArtifactIsVerified(
            at: backup.backupURL,
            expectedData: $0,
            expectedChecksum: backup.checksum,
            requiresPropertyList: false
          )
        } ?? false)
    guard artifactsRemainExact else {
      let observed = [manifestURL, backup.backupURL].compactMap {
        try? currentRecoveryAuthorization(at: $0, authorization: rootAuthorization)
      }
      reconcileRecoveryMapsFromRetainedAuthority()
      throw AutomationFilePartialMutation(
        kind: .replace,
        commitState: .unknown,
        observedFiles: observed,
        recoveryHandle: nil,
        resultURL: manifestURL
      )
    }
    let staged = try fileSystem.writeStagedFile(
      nextTo: manifestURL,
      data: manifestData,
      permissions: 0o600,
      authorization: rootAuthorization
    )
    guard recoveryRootIsAuthorized() else {
      try removeCleanupArtifact(staged.authorization)
      throw AutomationManagerConfigurationError.recoverableSourceUnavailable
    }
    let installedAuthorization = try Self.fileAuthorization(
      for: manifestURL,
      directory: rootAuthorization,
      resourceIdentifier: staged.binding.resourceIdentifier,
      existed: true
    )
    let replacementReceipt: AutomationFileMutationReceipt
    do {
      replacementReceipt = try committedReplacement(at: manifestAuthorization, with: staged)
    } catch let partial as AutomationFilePartialMutation {
      let restored: AutomationFileAuthorization
      do {
        guard let compensationDestination = currentAuthorizedSurvivors(
          [manifestAuthorization, installedAuthorization]
        ).first else {
          throw AutomationManagerConfigurationError.recoverableSourceUnavailable
        }
        restored = try compensateRecoveryArtifact(
          previousManifestData,
          at: manifestURL,
          authorization: rootAuthorization,
          destination: compensationDestination
        )
        retainRestoredManifest(
          for: backupID,
          authorization: restored,
          data: previousManifestData
        )
        try cleanupRecoveryArtifacts(partial.recoveryHandles.filter {
          $0.fileURL.standardizedFileURL == staged.url.standardizedFileURL
            && $0.directory == rootAuthorization
            && $0.expectation == staged.authorization.expectation
        })
      } catch let compensation as AutomationFilePartialMutation {
        throw aggregatePartialMutations(
          partial,
          compensation,
          at: manifestURL,
          authorization: rootAuthorization
        )
      } catch {
        throw aggregatePartialMutations(
          partial,
          nil,
          at: manifestURL,
          authorization: rootAuthorization
        )
      }
      let observedSurvivors = currentAuthorizedSurvivors(
        [restored] + partial.observedFiles
      )
      let recoverySurvivors = currentAuthorizedSurvivors(
        [restored] + partial.recoveryHandles
      )
      throw AutomationFilePartialMutation(
        kind: .replace,
        commitState: partial.commitState,
        observedFiles: observedSurvivors,
        recoveryHandle: recoverySurvivors.first,
        recoveryHandles: recoverySurvivors,
        resultURL: manifestURL
      )
    }
    guard let exactInstalled = replacementReceipt.primaryFile,
          exactInstalled == installedAuthorization,
          authorizationIsCurrent(exactInstalled),
          recoveryRootIsAuthorized(),
          authorizationIsCurrent(backupAuthorization),
          let finalBackupData = try? fileSystem.read(backup.backupURL),
          recoveryArtifactIsVerified(
            at: backup.backupURL,
            expectedData: finalBackupData,
            expectedChecksum: backup.checksum,
            requiresPropertyList: false
          ),
          authorizationIsCurrent(backupAuthorization),
          recoveryArtifactIsVerified(
            at: manifestURL,
            expectedData: manifestData,
            expectedChecksum: Self.checksum(manifestData),
            requiresPropertyList: true
          ),
          authorizationIsCurrent(exactInstalled)
    else {
      let knownInstalled = currentAuthorizedSurvivors([installedAuthorization])
      let committed = AutomationFilePartialMutation(
        kind: .replace,
        commitState: .committed,
        observedFiles: knownInstalled,
        recoveryHandle: knownInstalled.first,
        resultURL: manifestURL
      )
      let restored: AutomationFileAuthorization
      do {
        guard authorizationIsCurrent(installedAuthorization) else {
          throw AutomationManagerConfigurationError.recoverableSourceUnavailable
        }
        restored = try compensateRecoveryArtifact(
          previousManifestData,
          at: manifestURL,
          authorization: rootAuthorization,
          destination: installedAuthorization
        )
        retainRestoredManifest(
          for: backupID,
          authorization: restored,
          data: previousManifestData
        )
      } catch let compensation as AutomationFilePartialMutation {
        let aggregate = aggregatePartialMutations(
          committed,
          compensation,
          at: manifestURL,
          authorization: rootAuthorization
        )
        reconcileRecoveryMapsFromRetainedAuthority()
        throw aggregate
      } catch {
        let aggregate = aggregatePartialMutations(
          committed,
          nil,
          at: manifestURL,
          authorization: rootAuthorization
        )
        reconcileRecoveryMapsFromRetainedAuthority()
        throw aggregate
      }
      let ambientBackup = try? currentRecoveryAuthorization(
        at: backup.backupURL,
        authorization: rootAuthorization
      )
      reconcileRecoveryMapsFromRetainedAuthority()
      throw AutomationFilePartialMutation(
        kind: .replace,
        commitState: .committed,
        observedFiles: [restored] + [ambientBackup].compactMap { $0 },
        recoveryHandle: restored,
        resultURL: manifestURL
      )
    }
    backupsByID[backupID] = updated
    manifestAuthorizationsByID[backupID] = exactInstalled
    manifestDataByID[backupID] = manifestData
  }

  private func retainRestoredManifest(
    for backupID: AutomationBackup.ID,
    authorization: AutomationFileAuthorization,
    data: Data
  ) {
    manifestAuthorizationsByID[backupID] = authorization
    manifestDataByID[backupID] = data
  }

  private func compensateRecoveryArtifact(
    _ data: Data,
    at url: URL,
    authorization rootAuthorization: AutomationDirectoryAuthorization,
    destination: AutomationFileAuthorization
  ) throws -> AutomationFileAuthorization {
    let staged = try fileSystem.writeStagedFile(
      nextTo: url,
      data: data,
      permissions: 0o600,
      authorization: rootAuthorization
    )
    let receipt = try committedReplacement(at: destination, with: staged)
    guard let installed = receipt.primaryFile,
          installed.expectation == staged.authorization.expectation,
          authorizationIsCurrent(installed),
          recoveryArtifactIsVerified(
      at: url,
      expectedData: data,
      expectedChecksum: Self.checksum(data),
      requiresPropertyList: true
    ) else { throw AutomationManagerConfigurationError.recoverableSourceUnavailable }
    return installed
  }

  private func currentRecoveryAuthorization(
    at url: URL,
    authorization rootAuthorization: AutomationDirectoryAuthorization
  ) throws -> AutomationFileAuthorization {
    let metadata = try fileSystem.metadata(for: url)
    return try Self.fileAuthorization(
      for: url,
      directory: rootAuthorization,
      resourceIdentifier: metadata.resourceIdentifier,
      existed: true
    )
  }

  private func aggregatePartialMutations(
    _ primary: AutomationFilePartialMutation,
    _ secondary: AutomationFilePartialMutation?,
    at url: URL,
    authorization rootAuthorization: AutomationDirectoryAuthorization
  ) -> AutomationFilePartialMutation {
    var observed: [AutomationFileAuthorization] = []
    for candidate in primary.observedFiles + (secondary?.observedFiles ?? [])
      where authorizationIsCurrent(candidate) && !observed.contains(candidate) {
      observed.append(candidate)
    }
    var handles: [AutomationFileAuthorization] = []
    for candidate in primary.recoveryHandles + (secondary?.recoveryHandles ?? [])
      where authorizationIsCurrent(candidate) && !handles.contains(candidate) {
      handles.append(candidate)
    }
    if let current = try? currentRecoveryAuthorization(
      at: url,
      authorization: rootAuthorization
    ) {
      if !observed.contains(current) { observed.append(current) }
    }
    return AutomationFilePartialMutation(
      kind: .replace,
      commitState: .unknown,
      observedFiles: observed,
      recoveryHandle: handles.first,
      recoveryHandles: handles,
      resultURL: url
    )
  }

  private func recoveryArtifactIsVerified(
    at url: URL,
    expectedData: Data,
    expectedChecksum: String,
    requiresPropertyList: Bool
  ) -> Bool {
    let artifact = url.standardizedFileURL
    let root = backupDirectory.standardizedFileURL
    guard recoveryRootIsAuthorized(),
          artifact.deletingLastPathComponent().standardizedFileURL.path == root.path,
          let metadata = try? fileSystem.metadata(for: artifact),
          metadata.canonicalURL.standardizedFileURL.path == artifact.path,
          metadata.ownerUID == currentUID,
          !metadata.isSymbolicLink,
          metadata.resourceIdentifier?.isEmpty == false,
          metadata.permissions == 0o600,
          let actualData = try? fileSystem.read(artifact),
          actualData == expectedData,
          Self.checksum(actualData) == expectedChecksum
    else { return false }
    if requiresPropertyList {
      return (try? PropertyListSerialization.propertyList(
        from: actualData,
        options: [],
        format: nil
      )) != nil
    }
    return true
  }

  private func pruneRecoveryEvidence(preserving currentID: AutomationBackup.ID?) throws {
    guard recoveryRootIsAuthorized() else { return }
    let rootMetadata = try fileSystem.metadata(for: backupDirectory)
    let rootAuthorization = try Self.directoryAuthorization(
      for: backupDirectory,
      resourceIdentifier: rootMetadata.resourceIdentifier
    )
    let cutoff = now().addingTimeInterval(-30 * 24 * 60 * 60)
    let ordered = backupsByID.values.sorted { lhs, rhs in
      if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
      return lhs.id.rawValue.uuidString > rhs.id.rawValue.uuidString
    }
    var retained = Set(ordered.prefix(20).map(\.id))
    if let currentID { retained.insert(currentID) }
    for backup in ordered where backup.createdAt < cutoff || !retained.contains(backup.id) {
      guard backup.id != currentID else { continue }
      guard let manifestURL = manifestURLsByID[backup.id],
            let manifestAuthorization = manifestAuthorizationsByID[backup.id],
            let backupAuthorization = backupAuthorizationsByID[backup.id],
            let manifestData = manifestDataByID[backup.id]
      else {
        reconcileRecoveryMapsFromRetainedAuthority()
        continue
      }
      let backupData = try? fileSystem.read(backup.backupURL)
      guard manifestAuthorization.directory == rootAuthorization,
            backupAuthorization.directory == rootAuthorization,
            authorizationIsCurrent(manifestAuthorization),
            authorizationIsCurrent(backupAuthorization),
            recoveryArtifactIsVerified(
              at: manifestURL,
              expectedData: manifestData,
              expectedChecksum: Self.checksum(manifestData),
              requiresPropertyList: true
            ),
            let backupData,
            recoveryArtifactIsVerified(
              at: backup.backupURL,
              expectedData: backupData,
              expectedChecksum: backup.checksum,
              requiresPropertyList: false
            )
      else {
        // A fresh occupant is evidence only. Retained-authority reconciliation drops
        // the invalid pair; no destructive authority comes from the ambient namespace.
        reconcileRecoveryMapsFromRetainedAuthority()
        continue
      }
      var manifestDeletionCommitted = false
      do {
        try removeCleanupArtifact(manifestAuthorization)
        manifestDeletionCommitted = true
        try removeCleanupArtifact(backupAuthorization)
      } catch {
        let primaryPartial = error as? AutomationFilePartialMutation
        if !manifestDeletionCommitted {
          reconcileRecoveryMapsFromRetainedAuthority()
          if let primaryPartial { throw primaryPartial }
          throw error
        }
        var compensationPartial: AutomationFilePartialMutation?
        var restoredManifest: AutomationFileAuthorization?
        if !fileSystem.itemExists(at: manifestURL),
           authorizationIsCurrent(backupAuthorization) {
          do {
            let absentManifest = try Self.fileAuthorization(
              for: manifestURL,
              directory: rootAuthorization,
              resourceIdentifier: nil,
              existed: false
            )
            restoredManifest = try compensateRecoveryArtifact(
              manifestData,
              at: manifestURL,
              authorization: rootAuthorization,
              destination: absentManifest
            )
            if let restoredManifest {
              retainRestoredManifest(
                for: backup.id,
                authorization: restoredManifest,
                data: manifestData
              )
            }
            if let primaryPartial {
              try cleanupRecoveryArtifacts(primaryPartial.recoveryHandles.filter {
                $0.fileURL.standardizedFileURL != manifestURL.standardizedFileURL
                  && $0.expectation == backupAuthorization.expectation
                  && $0.directory == rootAuthorization
              })
            }
          } catch let partial as AutomationFilePartialMutation {
            compensationPartial = partial
          } catch {
            compensationPartial = AutomationFilePartialMutation(
              kind: .replace,
              commitState: .unknown,
              observedFiles: [],
              recoveryHandle: nil,
              resultURL: manifestURL
            )
          }
        }
        let currentArtifacts = [
          try? currentRecoveryAuthorization(
            at: manifestURL,
            authorization: rootAuthorization
          ),
          try? currentRecoveryAuthorization(
            at: backup.backupURL,
            authorization: rootAuthorization
          ),
        ].compactMap { $0 }
        let knownRecoveryCandidates = [
          restoredManifest,
          authorizationIsCurrent(manifestAuthorization) ? manifestAuthorization : nil,
          authorizationIsCurrent(backupAuthorization) ? backupAuthorization : nil,
        ].compactMap { $0 }
        let observedSurvivors = currentAuthorizedSurvivors(
          currentArtifacts
            + knownRecoveryCandidates
            + (primaryPartial?.observedFiles ?? [])
            + (primaryPartial?.recoveryHandles ?? [])
            + (compensationPartial?.observedFiles ?? [])
            + (compensationPartial?.recoveryHandles ?? [])
        )
        let recoverySurvivors = currentAuthorizedSurvivors(
          knownRecoveryCandidates
            + (primaryPartial?.recoveryHandles ?? [])
            + (compensationPartial?.recoveryHandles ?? [])
        )
        reconcileRecoveryMapsFromRetainedAuthority()
        throw AutomationFilePartialMutation(
          kind: .remove,
          commitState: .unknown,
          observedFiles: observedSurvivors,
          recoveryHandle: recoverySurvivors.first,
          recoveryHandles: recoverySurvivors,
          resultURL: manifestURL
        )
      }
      if !fileSystem.itemExists(at: backup.backupURL),
         !fileSystem.itemExists(at: manifestURL)
      {
        backupsByID.removeValue(forKey: backup.id)
        manifestURLsByID.removeValue(forKey: backup.id)
        backupAuthorizationsByID.removeValue(forKey: backup.id)
        manifestAuthorizationsByID.removeValue(forKey: backup.id)
        manifestDataByID.removeValue(forKey: backup.id)
      } else {
        let observedSurvivors = currentAuthorizedSurvivors([
          try? currentRecoveryAuthorization(at: manifestURL, authorization: rootAuthorization),
          try? currentRecoveryAuthorization(at: backup.backupURL, authorization: rootAuthorization),
        ].compactMap { $0 })
        let recoverySurvivors = currentAuthorizedSurvivors([
          manifestAuthorization,
          backupAuthorization,
        ])
        reconcileRecoveryMapsFromRetainedAuthority()
        throw AutomationFilePartialMutation(
          kind: .remove,
          commitState: .unknown,
          observedFiles: observedSurvivors,
          recoveryHandle: recoverySurvivors.first,
          recoveryHandles: recoverySurvivors,
          resultURL: manifestURL
        )
      }
    }
  }

  private func reconcileRecoveryMapsFromRetainedAuthority() {
    guard recoveryRootIsAuthorized() else {
      backupsByID.removeAll()
      manifestURLsByID.removeAll()
      backupAuthorizationsByID.removeAll()
      manifestAuthorizationsByID.removeAll()
      manifestDataByID.removeAll()
      return
    }
    var retainedBackups: [AutomationBackup.ID: AutomationBackup] = [:]
    var retainedManifestURLs: [AutomationBackup.ID: URL] = [:]
    var retainedBackupAuthorizations: [
      AutomationBackup.ID: AutomationFileAuthorization
    ] = [:]
    var retainedManifestAuthorizations: [
      AutomationBackup.ID: AutomationFileAuthorization
    ] = [:]
    var retainedManifestData: [AutomationBackup.ID: Data] = [:]
    for (id, backup) in backupsByID {
      guard let manifestURL = manifestURLsByID[id],
            let backupAuthorization = backupAuthorizationsByID[id],
            let manifestAuthorization = manifestAuthorizationsByID[id],
            let manifestData = manifestDataByID[id],
            authorizationIsCurrent(backupAuthorization),
            authorizationIsCurrent(manifestAuthorization),
            let backupData = try? fileSystem.read(backup.backupURL),
            recoveryArtifactIsVerified(
              at: backup.backupURL,
              expectedData: backupData,
              expectedChecksum: backup.checksum,
              requiresPropertyList: false
            ),
            recoveryArtifactIsVerified(
              at: manifestURL,
              expectedData: manifestData,
              expectedChecksum: Self.checksum(manifestData),
              requiresPropertyList: true
            )
      else { continue }
      retainedBackups[id] = backup
      retainedManifestURLs[id] = manifestURL
      retainedBackupAuthorizations[id] = backupAuthorization
      retainedManifestAuthorizations[id] = manifestAuthorization
      retainedManifestData[id] = manifestData
    }
    backupsByID = retainedBackups
    manifestURLsByID = retainedManifestURLs
    backupAuthorizationsByID = retainedBackupAuthorizations
    manifestAuthorizationsByID = retainedManifestAuthorizations
    manifestDataByID = retainedManifestData
  }

  private func recoveryRootIsAuthorized() -> Bool {
    guard let expectedIdentity = recoveryRootResourceIdentifier,
          let metadata = try? fileSystem.metadata(for: backupDirectory),
          metadata.canonicalURL.standardizedFileURL.path == backupDirectory.standardizedFileURL.path,
          metadata.ownerUID == currentUID,
          !metadata.isSymbolicLink,
          metadata.resourceIdentifier == expectedIdentity,
          metadata.permissions == 0o700
    else { return false }
    return true
  }

  private func removeCleanupArtifact(_ authorization: AutomationFileAuthorization) throws {
    let outcome: AutomationFileMutationOutcome
    do {
      outcome = try fileSystem.removeItem(authorization)
    } catch let partial as AutomationFilePartialMutation {
      throw partial
    } catch {
      throw error
    }
    switch outcome {
    case .committed:
      return
    case .unchanged:
      throw AutomationManagerConfigurationError.recoverableSourceUnavailable
    }
  }

  private func cleanupRecoveryArtifacts(
    _ authorizations: [AutomationFileAuthorization]
  ) throws {
    var committedDeletion = false
    var partials: [AutomationFilePartialMutation] = []
    var firstRawError: Error?
    for authorization in authorizations where fileSystem.itemExists(at: authorization.fileURL) {
      do {
        switch try fileSystem.removeItem(authorization) {
        case .committed:
          committedDeletion = true
        case .unchanged:
          firstRawError = firstRawError
            ?? AutomationManagerConfigurationError.recoverableSourceUnavailable
        }
      } catch let partial as AutomationFilePartialMutation {
        partials.append(partial)
      } catch {
        firstRawError = firstRawError ?? error
      }
    }
    if !partials.isEmpty || committedDeletion && firstRawError != nil {
      var observed = partials.flatMap(\.observedFiles)
      var handles = partials.flatMap(\.recoveryHandles)
      for authorization in authorizations {
        guard authorizationIsCurrent(authorization) else { continue }
        if !observed.contains(authorization) { observed.append(authorization) }
        if !handles.contains(authorization) { handles.append(authorization) }
      }
      throw AutomationFilePartialMutation(
        kind: .remove,
        commitState: .unknown,
        observedFiles: observed,
        recoveryHandle: handles.first,
        recoveryHandles: handles,
        resultURL: nil
      )
    }
    if let firstRawError { throw firstRawError }
  }

  private func currentAuthorizedSurvivors(
    _ candidates: [AutomationFileAuthorization]
  ) -> [AutomationFileAuthorization] {
    var survivors: [AutomationFileAuthorization] = []
    for candidate in candidates {
      guard authorizationIsCurrent(candidate), !survivors.contains(candidate)
      else { continue }
      survivors.append(candidate)
    }
    return survivors
  }

  private func authorizationIsCurrent(_ authorization: AutomationFileAuthorization) -> Bool {
    guard case .existing(let expectedIdentity) = authorization.expectation,
          let directoryMetadata = try? fileSystem.metadata(
            for: authorization.directory.directoryURL
          ),
          directoryMetadata.resourceIdentifier == authorization.directory.resourceIdentifier,
          let metadata = try? fileSystem.metadata(for: authorization.fileURL),
          metadata.resourceIdentifier == expectedIdentity
    else { return false }
    return true
  }

  private func revalidationFailure(
    operation: AutomationOperation,
    record: AutomationRecord,
    sourceURL: URL,
    expectedChecksum: String,
    initialMetadata: AutomationFileMetadata
  ) async throws -> String? {
    do {
      let sourceData: Data
      let metadata: AutomationFileMetadata
      if record.sourceKind.requiresRecoverableSource {
        let captured = try await recoverableSource(record)
        guard captured.transactionURL.standardizedFileURL.path == sourceURL.standardizedFileURL.path,
              captured.checksum == Self.sourceChecksum(captured.data, kind: record.kind),
              try fileSystem.read(sourceURL) == captured.data,
              try fileSystem.metadata(for: sourceURL) == captured.metadata
        else {
          return "The recoverable source identity changed immediately before mutation."
        }
        sourceData = captured.data
        metadata = captured.metadata
      } else {
        sourceData = try fileSystem.read(sourceURL)
        metadata = try fileSystem.metadata(for: sourceURL)
      }
      guard Self.sourceChecksum(sourceData, kind: record.kind) == expectedChecksum else {
        return "The automation source changed immediately before mutation."
      }
      let context = try capabilityContext(record)
      guard let resourceIdentifier = metadata.resourceIdentifier,
            !resourceIdentifier.isEmpty,
            metadata.canonicalURL.standardizedFileURL.path == sourceURL.standardizedFileURL.path,
            metadata.ownerUID == context.sourceOwnerUID,
            metadata.isSymbolicLink == context.isSymlink,
            resourceIdentifier == initialMetadata.resourceIdentifier
      else {
        return "The automation source identity changed immediately before mutation."
      }
      let decision = AutomationCapabilityPolicy.decision(for: record, context: context)
      guard decision.capabilities.contains(operation.requiredCapability) else {
        return decision.reason ?? "This operation is no longer available for the source."
      }
      return nil
    } catch let partial as AutomationFilePartialMutation {
      throw partial
    } catch {
      return "DevScope could not revalidate the automation source immediately before mutation."
    }
  }

  private func verifyDestination(
    _ proposal: SourceProposal,
    record: AutomationRecord,
    selectedSourceURL: URL,
    selectedSourceData: Data,
    selectedMetadata: AutomationFileMetadata
  ) throws -> DestinationSnapshot {
    let destination = proposal.destination.standardizedFileURL
    let parent = destination.deletingLastPathComponent().standardizedFileURL
    let parentMetadata = try fileSystem.metadata(for: parent)
    let context = try destinationContext(record, destination)
    guard context.canonicalPathIsApproved else {
      throw ProposalError("The intended destination resolves outside the approved automation folder.")
    }
    guard !context.isManaged else {
      throw ProposalError("The intended destination is managed by your organization.")
    }
    guard !context.isSymlink else {
      throw ProposalError("The intended destination is a symbolic link.")
    }
    guard context.sourceOwnerUID == context.currentUID else {
      throw ProposalError("The intended destination is not owned by the current user.")
    }
    guard parentMetadata.canonicalURL.standardizedFileURL.path == parent.path,
          parentMetadata.ownerUID == context.currentUID,
          !parentMetadata.isSymbolicLink,
          parentMetadata.resourceIdentifier?.isEmpty == false
    else {
      throw ProposalError("The intended destination parent identity could not be established.")
    }

    if destination == selectedSourceURL.standardizedFileURL,
       fileSystem.itemExists(at: destination) {
      guard selectedMetadata.ownerUID == context.currentUID,
            selectedMetadata.resourceIdentifier != nil
      else {
        throw ProposalError("The intended destination identity could not be established.")
      }
      return DestinationSnapshot(
        existed: true,
        data: selectedSourceData,
        metadata: selectedMetadata,
        parentMetadata: parentMetadata
      )
    }

    if fileSystem.itemExists(at: destination) {
      let data = try fileSystem.read(destination)
      let metadata = try fileSystem.metadata(for: destination)
      guard metadata.canonicalURL.standardizedFileURL.path == destination.path,
            metadata.ownerUID == context.currentUID,
            !metadata.isSymbolicLink,
            let resourceIdentifier = metadata.resourceIdentifier,
            !resourceIdentifier.isEmpty
      else {
        throw ProposalError("The intended destination identity could not be established.")
      }
      guard let expected = proposal.expectedDestinationChecksum,
            expected == Self.checksum(data)
      else {
        throw ProposalError("The intended destination changed since it was inspected.")
      }
      return DestinationSnapshot(
        existed: true,
        data: data,
        metadata: metadata,
        parentMetadata: parentMetadata
      )
    }

    return DestinationSnapshot(
      existed: false,
      data: nil,
      metadata: parentMetadata,
      parentMetadata: parentMetadata
    )
  }

  private func destinationRevalidationFailure(
    _ proposal: SourceProposal,
    snapshot: DestinationSnapshot,
    record: AutomationRecord
  ) -> String? {
    do {
      let destination = proposal.destination.standardizedFileURL
      let context = try destinationContext(record, destination)
      guard context.canonicalPathIsApproved,
            context.sourceOwnerUID == context.currentUID,
            !context.isSymlink,
            !context.isManaged
      else {
        return "The intended destination authorization changed immediately before mutation."
      }
      let parent = destination.deletingLastPathComponent().standardizedFileURL
      let currentParentMetadata = try fileSystem.metadata(for: parent)
      guard currentParentMetadata.canonicalURL.standardizedFileURL.path == parent.path,
            currentParentMetadata.ownerUID == snapshot.parentMetadata.ownerUID,
            !currentParentMetadata.isSymbolicLink,
            currentParentMetadata.resourceIdentifier == snapshot.parentMetadata.resourceIdentifier
      else {
        return "The intended destination parent changed immediately before mutation."
      }
      if snapshot.existed {
        guard fileSystem.itemExists(at: destination),
              let previousData = snapshot.data
        else {
          return "The intended destination changed immediately before mutation."
        }
        let data = try fileSystem.read(destination)
        let metadata = try fileSystem.metadata(for: destination)
        guard data == previousData,
              metadata.canonicalURL.standardizedFileURL.path == destination.path,
              metadata.ownerUID == snapshot.metadata.ownerUID,
              metadata.isSymbolicLink == snapshot.metadata.isSymbolicLink,
              metadata.resourceIdentifier != nil,
              metadata.resourceIdentifier == snapshot.metadata.resourceIdentifier
        else {
          return "The intended destination identity changed immediately before mutation."
        }
      } else {
        guard !fileSystem.itemExists(at: destination) else {
          return "The intended destination appeared immediately before mutation."
        }
        let metadata = currentParentMetadata
        guard metadata.canonicalURL.standardizedFileURL.path == parent.path,
              metadata.ownerUID == snapshot.metadata.ownerUID,
              !metadata.isSymbolicLink,
              metadata.resourceIdentifier != nil,
              metadata.resourceIdentifier == snapshot.metadata.resourceIdentifier
        else {
          return "The intended destination parent changed immediately before mutation."
        }
      }
      return nil
    } catch {
      return "DevScope could not revalidate the intended destination immediately before mutation."
    }
  }

  private func makeProposal(
    for operation: AutomationOperation,
    record: AutomationRecord,
    sourceURL: URL,
    selectedSourceData: Data
  ) throws -> SourceProposal? {
    switch operation {
    case .edit(let payload):
      try Self.validate(payload)
      let data = try Self.sourceData(for: payload, kind: record.kind)
      try Self.validate(
        data: data,
        against: payload,
        kind: record.kind,
        sourceURL: sourceURL,
        ownerUID: record.ownerUID ?? 0
      )
      let cronBinding = record.kind == .cron
        ? try Self.cronProposalBinding(
          originalData: selectedSourceData,
          intendedData: data,
          record: record,
          payload: payload
        )
        : nil
      return SourceProposal(
        data: data,
        destination: sourceURL,
        intendedLabel: payload.label,
        intendedRecordID: cronBinding?.intendedRecordID,
        cronBinding: cronBinding,
        intendedChecksum: Self.sourceChecksum(data, kind: record.kind),
        expectedDestinationChecksum: payload.expectedDestinationChecksum
      )
    case .duplicate(let payload):
      try Self.validate(payload)
      guard let destination = payload.destination else {
        throw ProposalError("A distinct duplicate destination is required.")
      }
      let data = try Self.sourceData(for: payload, kind: record.kind)
      try Self.validate(
        data: data,
        against: payload,
        kind: record.kind,
        sourceURL: destination,
        ownerUID: record.ownerUID ?? 0
      )
      let cronBinding = record.kind == .cron
        ? try Self.cronDuplicateBinding(
          originalData: selectedSourceData,
          intendedData: data,
          record: record,
          payload: payload
        )
        : nil
      return SourceProposal(
        data: data,
        destination: destination,
        intendedLabel: payload.label,
        intendedRecordID: cronBinding?.intendedRecordID,
        cronBinding: cronBinding,
        intendedChecksum: Self.sourceChecksum(data, kind: record.kind),
        expectedDestinationChecksum: payload.expectedDestinationChecksum
      )
    case .importRecord(let payload):
      guard payload.expectedKind == record.kind else {
        throw ProposalError("The imported source kind does not match the selected automation.")
      }
      let sourceParent = sourceURL.deletingLastPathComponent().standardizedFileURL
      let destinationParent = payload.destination.deletingLastPathComponent().standardizedFileURL
      guard sourceParent == destinationParent else {
        throw ProposalError("The import destination is outside the approved automation folder.")
      }
      if record.kind == .cron {
        try Self.validateCronDocument(payload.data, against: record)
      }
      return SourceProposal(
        data: payload.data,
        destination: payload.destination,
        intendedLabel: Self.parsedLabel(
          data: payload.data,
          kind: payload.expectedKind,
          sourceURL: payload.destination,
          ownerUID: record.ownerUID ?? 0
        ),
        intendedRecordID: record.kind == .cron ? record.id : nil,
        cronBinding: record.kind == .cron
          ? try Self.cronImportBinding(data: payload.data, record: record)
          : nil,
        intendedChecksum: Self.sourceChecksum(payload.data, kind: record.kind),
        expectedDestinationChecksum: payload.expectedDestinationChecksum
      )
    case .restore(let id):
      guard let backup = backupsByID[id], backup.authorizedRecordIDs.contains(record.id) else {
        throw ProposalError("The selected recovery backup does not belong to this automation.")
      }
      let data = try fileSystem.read(backup.backupURL)
      guard Self.checksum(data) == backup.checksum else {
        throw ProposalError("The recovery backup failed its integrity check.")
      }
      let cronBinding = backup.kind == .cron && backup.sourceExisted
        ? try Self.cronRestoreBinding(data: data, backup: backup, selectedRecord: record)
        : nil
      return SourceProposal(
        data: data,
        destination: sourceURL,
        intendedLabel: Self.parsedLabel(
          data: data,
          kind: backup.kind,
          sourceURL: sourceURL,
          ownerUID: backup.ownerUID
        ),
        intendedRecordID: cronBinding?.intendedRecordID,
        cronBinding: cronBinding,
        intendedChecksum: Self.sourceChecksum(data, kind: backup.kind),
        expectedDestinationChecksum: nil,
        restoresSourcePresence: backup.sourceExisted
      )
    case .enable where record.kind == .cron:
      return try Self.cronEnabledStateProposal(
        selectedSourceData,
        sourceURL: sourceURL,
        record: record,
        isEnabled: true
      )
    case .disable where record.kind == .cron,
         .disableAndStop where record.kind == .cron:
      return try Self.cronEnabledStateProposal(
        selectedSourceData,
        sourceURL: sourceURL,
        record: record,
        isEnabled: false
      )
    case .remove where record.kind == .cron:
      return try Self.cronRemovalProposal(
        selectedSourceData,
        sourceURL: sourceURL,
        record: record
      )
    case .startNow, .confirmedRunToCompletion, .stopCurrentRun, .enable, .disable, .disableAndStop,
         .exportRecord, .remove:
      return nil
    }
  }

  private static func cronEnabledStateProposal(
    _ data: Data,
    sourceURL: URL,
    record: AutomationRecord,
    isEnabled: Bool
  ) throws -> SourceProposal {
    guard let text = String(data: data, encoding: .utf8) else {
      throw ProposalError("The complete current-user crontab is not valid UTF-8.")
    }
    let document = CronParser.parse(text)
    let matches = document.entries.filter { cronEntry($0, matches: record) }
    guard matches.count == 1, let selected = matches.first,
          selected.lineNumber > 0,
          selected.lineNumber <= document.originalLines.count
    else {
      throw ProposalError("The selected cron entry is missing or ambiguous in the displayed document generation.")
    }
    var lines = document.originalLines
    let disabledPrefix = "# devscope-disabled: "
    let trimmed = lines[selected.lineNumber - 1].trimmingCharacters(in: .whitespaces)
    if isEnabled {
      guard !selected.isEnabled, trimmed.hasPrefix(disabledPrefix) else {
        throw ProposalError("The selected cron entry is already enabled or changed externally.")
      }
      lines[selected.lineNumber - 1] = String(trimmed.dropFirst(disabledPrefix.count))
    } else {
      guard selected.isEnabled else {
        throw ProposalError("The selected cron entry is already disabled or changed externally.")
      }
      lines[selected.lineNumber - 1] = disabledPrefix + trimmed
    }
    let intendedData = Data(lines.joined(separator: "\n").utf8)
    let intended = CronParser.parse(String(decoding: intendedData, as: UTF8.self))
    let intendedMatches = intended.entries.filter {
      CronParser.recordID(for: $0, ownerUID: record.ownerUID ?? 0) == record.id
        && $0.command == selected.command
        && $0.schedule.triggers == selected.schedule.triggers
        && $0.environment == selected.environment
        && $0.isEnabled == isEnabled
    }
    guard intended.invalidLines.isEmpty,
          intendedMatches.count == 1,
          let intendedEntry = intendedMatches.first
    else { throw ProposalError("The rendered current-user crontab is not valid.") }
    let binding = CronProposalBinding(
      selectedRecordID: record.id,
      intendedRecordID: CronParser.recordID(for: intendedEntry, ownerUID: record.ownerUID ?? 0),
      command: intendedEntry.command,
      schedule: intendedEntry.schedule,
      environment: intendedEntry.environment,
      enabledState: isEnabled ? .enabled : .disabled
    )
    return SourceProposal(
      data: intendedData,
      destination: sourceURL,
      intendedLabel: nil,
      intendedRecordID: binding.intendedRecordID,
      cronBinding: binding,
      cronRemovalBinding: nil,
      intendedChecksum: sourceChecksum(intendedData, kind: .cron),
      expectedDestinationChecksum: nil
    )
  }

  private static func cronRemovalProposal(
    _ data: Data,
    sourceURL: URL,
    record: AutomationRecord
  ) throws -> SourceProposal {
    guard let text = String(data: data, encoding: .utf8) else {
      throw ProposalError("The complete current-user crontab is not valid UTF-8.")
    }
    let document = CronParser.parse(text)
    let indexedMatches = document.entries.enumerated().filter { cronEntry($0.element, matches: record) }
    guard indexedMatches.count == 1, let selected = indexedMatches.first,
          selected.element.lineNumber > 0,
          selected.element.lineNumber <= document.originalLines.count
    else {
      throw ProposalError("The selected cron entry is missing or ambiguous in the displayed document generation.")
    }
    let fingerprint = cronFingerprint(selected.element)
    var lines = document.originalLines
    lines.remove(at: selected.element.lineNumber - 1)
    let intendedData = Data(lines.joined(separator: "\n").utf8)
    let intended = CronParser.parse(String(decoding: intendedData, as: UTF8.self))
    guard intended.invalidLines.isEmpty else {
      throw ProposalError("The rendered current-user crontab is not valid.")
    }
    let binding = CronRemovalBinding(
      command: fingerprint.command,
      schedule: selected.element.schedule,
      environment: selected.element.environment,
      enabledState: selected.element.isEnabled ? .enabled : .disabled,
      remainingMatchingCount: intended.entries.filter { cronFingerprint($0) == fingerprint }.count
    )
    return SourceProposal(
      data: intendedData,
      destination: sourceURL,
      intendedLabel: nil,
      intendedRecordID: nil,
      cronBinding: nil,
      cronRemovalBinding: binding,
      intendedChecksum: sourceChecksum(intendedData, kind: .cron),
      expectedDestinationChecksum: nil
    )
  }

  private static func cronEntry(_ entry: CronEntry, matches record: AutomationRecord) -> Bool {
    CronParser.recordID(for: entry, ownerUID: record.ownerUID ?? 0) == record.id
      && entry.command == record.commandSignature
      && entry.schedule.triggers == record.schedule.triggers
      && entry.environment == record.environment
      && (entry.isEnabled ? AutomationEnabledState.enabled : .disabled) == record.enabledState
  }

  private static func validate(_ payload: AutomationEditPayload) throws {
    guard !payload.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ProposalError("An automation label is required.")
    }
    guard payload.executable.hasPrefix("/"), !payload.executable.contains("\0") else {
      throw ProposalError("The automation executable must be an absolute path.")
    }
    guard payload.arguments.allSatisfy({ !$0.contains("\0") }),
          payload.environment.allSatisfy({ key, value in
            !key.isEmpty && !key.contains("=") && !key.contains("\0") && !value.contains("\0")
          })
    else {
      throw ProposalError("The automation arguments or environment contain invalid values.")
    }
  }

  private static func sourceData(
    for payload: AutomationEditPayload,
    kind: AutomationKind
  ) throws -> Data {
    if let rawRepresentation = payload.rawRepresentation {
      return rawRepresentation
    }
    guard kind != .cron else {
      throw ProposalError("Cron edits require a complete rendered crontab document.")
    }
    var propertyList: [String: Any] = [
      "Label": payload.label,
      "ProgramArguments": [payload.executable] + payload.arguments,
    ]
    for trigger in payload.schedule.triggers {
      switch trigger {
      case .atLogin, .runAtLoad:
        propertyList["RunAtLoad"] = true
      case .interval(let seconds):
        guard propertyList["StartInterval"] == nil, seconds > 0 else {
          throw ProposalError("Generated launchd sources support one positive interval.")
        }
        propertyList["StartInterval"] = seconds
      case .keepAlive:
        propertyList["KeepAlive"] = true
      case .demand:
        break
      case .calendar, .cron:
        throw ProposalError("This schedule requires a validated raw source representation.")
      }
    }
    if !payload.environment.isEmpty {
      propertyList["EnvironmentVariables"] = payload.environment
    }
    if let workingDirectory = payload.workingDirectory {
      propertyList["WorkingDirectory"] = workingDirectory
    }
    return try PropertyListSerialization.data(
      fromPropertyList: propertyList,
      format: .xml,
      options: 0
    )
  }

  private static func validate(
    data: Data,
    against payload: AutomationEditPayload,
    kind: AutomationKind,
    sourceURL: URL,
    ownerUID: uid_t
  ) throws {
    guard kind != .cron else {
      let document = CronParser.parse(String(decoding: data, as: UTF8.self))
      guard document.invalidLines.isEmpty else {
        throw ProposalError("The rendered crontab contains invalid lines.")
      }
      let reviewedCommand = ([payload.executable] + payload.arguments).joined(separator: " ")
      guard document.entries.contains(where: {
        $0.command == reviewedCommand
          && $0.schedule.triggers == payload.schedule.triggers
          && $0.environment == payload.environment
      }) else {
        throw ProposalError("The rendered crontab does not match the reviewed command, schedule, and environment.")
      }
      return
    }
    let parsed: AutomationRecord
    do {
      parsed = try LaunchdPlistParser.parse(
        data: data,
        sourceURL: sourceURL,
        ownerUID: ownerUID,
        ownership: .user
      )
    } catch {
      throw ProposalError("The launchd property list is not semantically valid.")
    }
    guard parsed.label == payload.label,
          parsed.executable == payload.executable,
          parsed.arguments == payload.arguments,
          parsed.schedule.triggers == payload.schedule.triggers
    else {
      throw ProposalError("The raw source does not match the reviewed automation fields.")
    }
    guard let propertyList = try? PropertyListSerialization.propertyList(
      from: data,
      options: [],
      format: nil
    ) as? [String: Any]
    else {
      throw ProposalError("The launchd property list is not semantically valid.")
    }
    let environment = propertyList["EnvironmentVariables"] as? [String: String] ?? [:]
    let workingDirectory = propertyList["WorkingDirectory"] as? String
    guard environment == payload.environment,
          workingDirectory == payload.workingDirectory
    else {
      throw ProposalError("The raw source does not match the reviewed environment or directory.")
    }
  }

  private static func validateCronDocument(
    _ data: Data,
    against record: AutomationRecord
  ) throws {
    let document = CronParser.parse(String(decoding: data, as: UTF8.self))
    guard document.invalidLines.isEmpty,
          document.entries.contains(where: {
            CronParser.recordID(for: $0, ownerUID: record.ownerUID ?? 0) == record.id
              && $0.command == record.commandSignature
              && $0.schedule.triggers == record.schedule.triggers
              && $0.environment == record.environment
          })
    else {
      throw ProposalError("The imported crontab does not contain the reviewed target entry.")
    }
  }

  private static func cronProposalBinding(
    originalData: Data,
    intendedData: Data,
    record: AutomationRecord,
    payload: AutomationEditPayload
  ) throws -> CronProposalBinding {
    let ownerUID = record.ownerUID ?? 0
    let original = CronParser.parse(String(decoding: originalData, as: UTF8.self))
    let selected = original.entries.enumerated().filter {
      CronParser.recordID(for: $0.element, ownerUID: ownerUID) == record.id
        && $0.element.command == record.commandSignature
        && $0.element.schedule.triggers == record.schedule.triggers
        && $0.element.environment == record.environment
        && ($0.element.isEnabled ? AutomationEnabledState.enabled : .disabled) == record.enabledState
    }
    guard selected.count == 1, let selectedMatch = selected.first else {
      throw ProposalError("The selected cron entry is missing or ambiguous in the displayed document generation.")
    }

    let command = ([payload.executable] + payload.arguments).joined(separator: " ")
    let intendedDocument = CronParser.parse(String(decoding: intendedData, as: UTF8.self))
    let intended = intendedDocument.entries.enumerated().filter {
      $0.element.command == command
        && $0.element.schedule.triggers == payload.schedule.triggers
        && $0.element.environment == payload.environment
    }
    guard intended.count == 1, let intendedMatch = intended.first else {
      throw ProposalError("The intended cron entry is missing or ambiguous in the rendered document.")
    }
    var originalCounts = cronEntryCounts(original.entries)
    var intendedCounts = cronEntryCounts(intendedDocument.entries)
    guard removeOne(cronFingerprint(selectedMatch.element), from: &originalCounts),
          removeOne(cronFingerprint(intendedMatch.element), from: &intendedCounts),
          originalCounts == intendedCounts
    else {
      throw ProposalError(
        "A cron edit must replace exactly the selected entry and preserve unrelated entries."
      )
    }
    guard selectedMatch.offset == intendedMatch.offset else {
      throw ProposalError("The intended cron entry does not replace the selected occurrence.")
    }
    var originalRemainder = original.entries.map(cronFingerprint)
    var intendedRemainder = intendedDocument.entries.map(cronFingerprint)
    originalRemainder.remove(at: selectedMatch.offset)
    intendedRemainder.remove(at: intendedMatch.offset)
    guard originalRemainder == intendedRemainder
    else {
      throw ProposalError(
        "A cron edit must replace exactly the selected entry and preserve unrelated entries."
      )
    }
    let entry = intendedMatch.element
    return CronProposalBinding(
      selectedRecordID: record.id,
      intendedRecordID: CronParser.recordID(for: entry, ownerUID: ownerUID),
      command: entry.command,
      schedule: entry.schedule,
      environment: entry.environment,
      enabledState: entry.isEnabled ? .enabled : .disabled
    )
  }

  private static func cronDuplicateBinding(
    originalData: Data,
    intendedData: Data,
    record: AutomationRecord,
    payload: AutomationEditPayload
  ) throws -> CronProposalBinding {
    let ownerUID = record.ownerUID ?? 0
    let original = CronParser.parse(String(decoding: originalData, as: UTF8.self))
    let intended = CronParser.parse(String(decoding: intendedData, as: UTF8.self))
    let selected = original.entries.filter {
      CronParser.recordID(for: $0, ownerUID: ownerUID) == record.id
        && $0.command == record.commandSignature
        && $0.schedule.triggers == record.schedule.triggers
        && $0.environment == record.environment
        && ($0.isEnabled ? AutomationEnabledState.enabled : .disabled) == record.enabledState
    }
    guard selected.count == 1 else {
      throw ProposalError("The selected cron entry is missing or ambiguous in the displayed document generation.")
    }

    let before = cronEntryCounts(original.entries)
    let after = cronEntryCounts(intended.entries)
    let removedCount = before.reduce(into: 0) { total, pair in
      total += max(0, pair.value - after[pair.key, default: 0])
    }
    let added = after.flatMap { pair in
      Array(repeating: pair.key, count: max(0, pair.value - before[pair.key, default: 0]))
    }
    let reviewedCommand = ([payload.executable] + payload.arguments).joined(separator: " ")
    guard removedCount == 0,
          added.count == 1,
          let addedFingerprint = added.first,
          addedFingerprint.command == reviewedCommand,
          addedFingerprint.scheduleExpression == cronExpression(from: payload.schedule),
          addedFingerprint.environment == cronEnvironmentFingerprint(payload.environment)
    else {
      throw ProposalError("A cron duplicate must add exactly one reviewed entry and preserve the document.")
    }

    let originalIDs = Set(original.entries.map {
      CronParser.recordID(for: $0, ownerUID: ownerUID)
    })
    let candidates = intended.entries.filter {
      cronFingerprint($0) == addedFingerprint
        && !originalIDs.contains(CronParser.recordID(for: $0, ownerUID: ownerUID))
    }
    guard candidates.count == 1,
          let entry = candidates.first,
          CronParser.recordID(for: entry, ownerUID: ownerUID) != record.id
    else {
      throw ProposalError("The added cron entry identity is not distinct.")
    }
    return CronProposalBinding(
      selectedRecordID: record.id,
      intendedRecordID: CronParser.recordID(for: entry, ownerUID: ownerUID),
      command: entry.command,
      schedule: entry.schedule,
      environment: entry.environment,
      enabledState: entry.isEnabled ? .enabled : .disabled
    )
  }

  private static func cronRestoreBinding(
    data: Data,
    backup: AutomationBackup,
    selectedRecord: AutomationRecord
  ) throws -> CronProposalBinding {
    let matches = CronParser.parse(String(decoding: data, as: UTF8.self)).entries.filter {
      CronParser.recordID(for: $0, ownerUID: backup.ownerUID) == backup.recordID
    }
    guard matches.count == 1, let entry = matches.first else {
      throw ProposalError("The recovery crontab does not contain one exact recovery-lineage entry.")
    }
    return CronProposalBinding(
      selectedRecordID: selectedRecord.id,
      intendedRecordID: backup.recordID,
      command: entry.command,
      schedule: entry.schedule,
      environment: entry.environment,
      enabledState: entry.isEnabled ? .enabled : .disabled
    )
  }

  private static func cronEntryCounts(
    _ entries: [CronEntry]
  ) -> [CronEntryFingerprint: Int] {
    entries.reduce(into: [:]) { counts, entry in
      counts[cronFingerprint(entry), default: 0] += 1
    }
  }

  private static func removeOne(
    _ fingerprint: CronEntryFingerprint,
    from counts: inout [CronEntryFingerprint: Int]
  ) -> Bool {
    guard let count = counts[fingerprint], count > 0 else { return false }
    if count == 1 {
      counts.removeValue(forKey: fingerprint)
    } else {
      counts[fingerprint] = count - 1
    }
    return true
  }

  private static func cronFingerprint(_ entry: CronEntry) -> CronEntryFingerprint {
    CronEntryFingerprint(
      scheduleExpression: entry.scheduleExpression,
      command: entry.command,
      environment: cronEnvironmentFingerprint(entry.environment),
      isEnabled: entry.isEnabled
    )
  }

  private static func cronEnvironmentFingerprint(
    _ environment: [String: String]
  ) -> [String] {
    environment.keys.sorted().map { key in
      key + "\u{0}" + (environment[key] ?? "")
    }
  }

  private static func cronExpression(from schedule: AutomationSchedule) -> String? {
    guard schedule.triggers.count == 1,
          case .cron(let expression) = schedule.triggers[0]
    else { return nil }
    return expression
  }

  private static func cronImportBinding(
    data: Data,
    record: AutomationRecord
  ) throws -> CronProposalBinding {
    let ownerUID = record.ownerUID ?? 0
    let matches = CronParser.parse(String(decoding: data, as: UTF8.self)).entries.filter {
      CronParser.recordID(for: $0, ownerUID: ownerUID) == record.id
        && $0.command == record.commandSignature
        && $0.schedule.triggers == record.schedule.triggers
        && $0.environment == record.environment
        && ($0.isEnabled ? AutomationEnabledState.enabled : .disabled) == record.enabledState
    }
    guard matches.count == 1, let entry = matches.first else {
      throw ProposalError("The imported crontab does not contain one exact reviewed target entry.")
    }
    return CronProposalBinding(
      selectedRecordID: record.id,
      intendedRecordID: record.id,
      command: entry.command,
      schedule: entry.schedule,
      environment: entry.environment,
      enabledState: entry.isEnabled ? .enabled : .disabled
    )
  }

  private static func parsedLabel(
    data: Data,
    kind: AutomationKind,
    sourceURL: URL,
    ownerUID: uid_t
  ) -> String? {
    guard kind != .cron else { return nil }
    return try? LaunchdPlistParser.parse(
      data: data,
      sourceURL: sourceURL,
      ownerUID: ownerUID,
      ownership: .user
    ).label
  }

  private static func isValidSource(
    _ data: Data,
    kind: AutomationKind,
    expectedLabel: String?,
    sourceURL: URL,
    ownerUID: uid_t
  ) -> Bool {
    if kind == .cron {
      guard let text = String(data: data, encoding: .utf8) else { return false }
      return CronParser.parse(text).invalidLines.isEmpty
    }
    guard let parsed = try? LaunchdPlistParser.parse(
      data: data,
      sourceURL: sourceURL,
      ownerUID: ownerUID,
      ownership: .user
    ) else { return false }
    return expectedLabel == nil || parsed.label == expectedLabel
  }

  private func verify(
    _ operation: AutomationOperation,
    record: AutomationRecord,
    executorResult: AutomationExecutorResult,
    snapshot: AutomationInventorySnapshot,
    proposal: SourceProposal?,
    transactionSourceURL: URL,
    controlledIdentities: Set<AutomationLinkedProcessIdentity>,
    liveProcesses: [DevProcess]
  ) -> (satisfied: Bool, evidence: [String], verifiedRecordID: AutomationRecord.ID?) {
    let requiredPostconditions: Set<AutomationPostcondition>
    if case .restore = operation, proposal?.restoresSourcePresence == false {
      requiredPostconditions = [.sourceRemoved]
    } else {
      requiredPostconditions = operation.requiredPostconditions
    }
    guard executorResult.postconditions.isSuperset(of: requiredPostconditions) else {
      return (false, ["The executor did not prove every required postcondition."], nil)
    }
    let refreshedRecord = snapshot.records.first { $0.id == record.id }
    switch operation {
    case .disable, .disableAndStop:
      if record.sourceKind == .legacyLoginItem {
        guard snapshot.health[.legacyLoginItem]?.state == .healthy else {
          return (false, ["Authoritative legacy login-item health is not healthy."], nil)
        }
        guard !snapshot.records.contains(where: { Self.sameLegacyLoginItem($0, record) }) else {
          return (false, ["The selected legacy login item is still present."], nil)
        }
        return (true, ["Refreshed login items confirm the selected path is absent."], nil)
      }
      guard refreshedRecord?.enabledState == .disabled else {
        return (false, ["Refreshed inventory still reports future launches as enabled or unknown."], nil)
      }
      if case .disableAndStop = operation,
         !runtimeStopIsVerified(
           record: record,
           snapshot: snapshot,
           controlledIdentities: controlledIdentities,
           liveProcesses: liveProcesses
         ) {
        return (false, ["Refreshed process truth still contains a controlled or relaunched process."], nil)
      }
      if record.kind == .cron {
        guard let proposal,
              executorResult.postconditions.contains(.sourceChecksum(proposal.intendedChecksum)),
              refreshedRecord?.sourceChecksum == proposal.intendedChecksum,
              fileSystem.itemExists(at: transactionSourceURL),
              (try? Self.sourceChecksum(fileSystem.read(transactionSourceURL), kind: record.kind)) == proposal.intendedChecksum
        else {
          return (false, ["The refreshed current-user crontab does not match the complete disabled document."], nil)
        }
      }
      return (true, ["Refreshed inventory confirms future launches are disabled."], nil)
    case .enable:
      guard refreshedRecord?.enabledState == .enabled else {
        return (false, ["Refreshed inventory does not report future launches as enabled."], nil)
      }
      if record.kind == .cron {
        guard let proposal,
              executorResult.postconditions.contains(.sourceChecksum(proposal.intendedChecksum)),
              refreshedRecord?.sourceChecksum == proposal.intendedChecksum,
              fileSystem.itemExists(at: transactionSourceURL),
              (try? Self.sourceChecksum(fileSystem.read(transactionSourceURL), kind: record.kind)) == proposal.intendedChecksum
        else {
          return (false, ["The refreshed current-user crontab does not match the complete enabled document."], nil)
        }
      }
      return (true, ["Refreshed inventory confirms future launches are enabled."], nil)
    case .confirmedRunToCompletion:
      guard record.kind == .cron else {
        return (false, ["Run-to-completion confirmation is only supported for cron records."], nil)
      }
      return (true, ["The explicitly confirmed cron command completed successfully."], nil)
    case .startNow:
      guard let refreshedRecord else {
        return (false, ["Refreshed inventory no longer contains the requested automation."], nil)
      }
      let hasStrongFreshLink = AutomationProcessCorrelator.links(
        records: [refreshedRecord],
        processes: liveProcesses,
        now: now()
      ).contains { link in
        link.recordID == refreshedRecord.id
          && link.strength == .strong
          && link.processIdentity.birthToken != nil
      }
      guard hasStrongFreshLink else {
        return (false, ["Fresh process truth does not contain a strong birth-identified automation link."], nil)
      }
      return (
        true,
        ["Fresh process truth confirms a strong link to the requested automation."],
        refreshedRecord.id
      )
    case .remove:
      if record.kind == .cron {
        guard let proposal,
              let binding = proposal.cronRemovalBinding,
              executorResult.postconditions.contains(.sourceChecksum(proposal.intendedChecksum)),
              fileSystem.itemExists(at: transactionSourceURL),
              (try? Self.sourceChecksum(fileSystem.read(transactionSourceURL), kind: record.kind)) == proposal.intendedChecksum
        else {
          return (false, ["The remaining current-user crontab document could not be verified."], nil)
        }
        let matchingRecords = snapshot.records.filter {
          $0.kind == .cron
            && $0.sourceKind == .crontab
            && $0.ownerUID == record.ownerUID
            && $0.commandSignature == binding.command
            && $0.schedule.triggers == binding.schedule.triggers
            && $0.environment == binding.environment
            && $0.enabledState == binding.enabledState
            && $0.sourceChecksum == proposal.intendedChecksum
        }
        guard matchingRecords.count == binding.remainingMatchingCount,
              snapshot.records.filter({
                $0.kind == .cron && $0.sourceKind == .crontab && $0.ownerUID == record.ownerUID
              }).allSatisfy({ $0.sourceChecksum == proposal.intendedChecksum })
        else {
          return (false, ["The selected cron occurrence is still present or the remaining document changed."], nil)
        }
        return (true, ["Refreshed current-user crontab confirms the selected occurrence was removed."], nil)
      }
      if record.sourceKind == .legacyLoginItem {
        guard snapshot.health[.legacyLoginItem]?.state == .healthy else {
          return (false, ["Authoritative legacy login-item health is not healthy."], nil)
        }
        guard !snapshot.records.contains(where: { Self.sameLegacyLoginItem($0, record) }),
              fileSystem.itemExists(at: transactionSourceURL)
        else {
          return (false, ["The selected legacy login item is still present or recovery evidence disappeared."], nil)
        }
        return (true, ["Refreshed login items confirm only the selected path was removed."], nil)
      }
      if record.sourceKind == .launchAgent,
         !executorResult.postconditions.contains(.targetUnresolved) {
        return (false, ["launchd still resolves the removed service target."], nil)
      }
      let canonicalTransactionPath = transactionSourceURL.standardizedFileURL.path
      let recreatedAtTransactionIdentity = snapshot.records.contains { candidate in
        if let candidateURL = candidate.sourceURL {
          return candidateURL.standardizedFileURL.path == canonicalTransactionPath
        }
        return record.sourceKind.requiresRecoverableSource
          && candidate.sourceKind == record.sourceKind
          && candidate.ownerUID == record.ownerUID
      }
      guard refreshedRecord == nil,
            !fileSystem.itemExists(at: transactionSourceURL),
            !recreatedAtTransactionIdentity
      else {
        return (false, ["The removed source or transaction identity still exists."], nil)
      }
      return (true, ["Refreshed inventory confirms the source was removed."], nil)
    case .edit, .duplicate, .importRecord, .restore:
      if case .restore = operation, proposal?.restoresSourcePresence == false {
        let stillPresent = fileSystem.itemExists(at: transactionSourceURL)
          || snapshot.records.contains { candidate in
            candidate.sourceURL?.standardizedFileURL.path == transactionSourceURL.standardizedFileURL.path
          }
        return stillPresent
          ? (false, ["Refreshed inventory still contains the source restored to absence."], nil)
          : (true, ["Refreshed inventory confirms the prior absent source state."], nil)
      }
      guard let proposal,
            executorResult.postconditions.contains(.sourceChecksum(proposal.intendedChecksum))
      else {
        return (false, ["The executor did not prove the intended source checksum."], nil)
      }
      let installed = snapshot.records.first { candidate in
        if record.kind == .cron {
          guard let binding = proposal.cronBinding else { return false }
          return binding.selectedRecordID == record.id
            && candidate.id == binding.intendedRecordID
            && candidate.kind == .cron
            && candidate.sourceKind == .crontab
            && candidate.ownerUID == record.ownerUID
            && candidate.commandSignature == binding.command
            && candidate.schedule.triggers == binding.schedule.triggers
            && candidate.environment == binding.environment
            && candidate.enabledState == binding.enabledState
            && candidate.sourceChecksum == proposal.intendedChecksum
        }
        let destinationMatches = record.sourceKind.requiresRecoverableSource
          ? candidate.sourceKind == record.sourceKind
          : candidate.sourceURL?.standardizedFileURL.path == proposal.destination.standardizedFileURL.path
        return destinationMatches
          && candidate.label == proposal.intendedLabel
          && candidate.sourceChecksum == proposal.intendedChecksum
      }
      guard let installed else {
        return (false, ["Refreshed inventory does not contain the intended destination, label, and checksum."], nil)
      }
      if case .duplicate = operation, record.sourceKind == .launchAgent {
        guard executorResult.postconditions.contains(.futureLaunchesDisabled),
              installed.enabledState == .disabled,
              installed.loadState == .unloaded
        else {
          return (
            false,
            ["The duplicated LaunchAgent is not verified disabled and unloaded."],
            nil
          )
        }
      }
      return (true, ["Refreshed inventory confirms the intended destination, label, and checksum."], installed.id)
    case .stopCurrentRun:
      guard runtimeStopIsVerified(
        record: record,
        snapshot: snapshot,
        controlledIdentities: controlledIdentities,
        liveProcesses: liveProcesses
      ) else {
        return (false, ["Refreshed process truth still contains a controlled or relaunched process."], nil)
      }
      return (true, ["Refreshed process truth confirms no controlled process remains."], nil)
    case .exportRecord:
      return (true, ["The executor resolved the export target."], nil)
    }
  }

  private func runtimeStopIsVerified(
    record: AutomationRecord,
    snapshot: AutomationInventorySnapshot,
    controlledIdentities: Set<AutomationLinkedProcessIdentity>,
    liveProcesses: [DevProcess]
  ) -> Bool {
    guard !liveProcesses.contains(where: {
      $0.birthToken == nil && Self.isStrongBirthlessCandidate($0, for: record)
    }) else { return false }
    let liveIdentities = Set(liveProcesses.compactMap { process -> AutomationLinkedProcessIdentity? in
      guard let birth = process.birthToken else { return nil }
      return AutomationLinkedProcessIdentity(processID: process.pid, birthToken: birth)
    })
    guard controlledIdentities.isDisjoint(with: liveIdentities) else { return false }
    let candidateIDs = Set(snapshot.records.filter {
      $0.id == record.id
        || ($0.sourceKind == record.sourceKind && $0.ownerUID == record.ownerUID && $0.label == record.label)
    }.map(\.id))
    return AutomationProcessCorrelator.links(
      records: snapshot.records,
      processes: liveProcesses,
      now: now()
    ).allSatisfy { !candidateIDs.contains($0.recordID) }
  }

  private static func isStrongBirthlessCandidate(
    _ process: DevProcess,
    for record: AutomationRecord
  ) -> Bool {
    if record.kind == .cron {
      guard let signature = record.commandSignature,
            let argv = process.argumentVector,
            argv.count == 3,
            argv[1] == "-c"
      else { return false }
      return argv[2] == signature
    }
    let exactLabel = process.launchLabel == record.label
    let exactExecutableAndArguments = record.executable.map {
      URL(fileURLWithPath: process.executable).standardizedFileURL.path
        == URL(fileURLWithPath: $0).standardizedFileURL.path
        && process.argumentVector == [$0] + record.arguments
    } ?? false
    return exactLabel || exactExecutableAndArguments
  }

  private func failureAfterMutation(
    operation: AutomationOperation,
    record: AutomationRecord,
    linkedProcesses: [ClassifiedDevProcess],
    backup: AutomationBackup,
    preTransactionState: AutomationPreTransactionState,
    proposal: SourceProposal?,
    originalSourceMetadata: AutomationFileMetadata,
    postMutationResourceIdentifier: String?,
    sourceMutationStep: String?,
    phase: TransactionFailurePhase,
    evidence: [String],
    expectedAppliedState: AutomationExecutorAppliedState?,
    fileMutationEvidence: AutomationFilePartialMutation? = nil
  ) async -> AutomationOperationResult {
    var appliedSteps = ["Created owner-only recovery backup."]
    if let sourceMutationStep {
      appliedSteps.append(sourceMutationStep)
    }
    if phase == .verificationFailed {
      appliedSteps.append("Applied typed automation operation.")
    }

    do {
      guard try rollbackTargetIsUnchanged(
        operation: operation,
        proposal: proposal,
        backup: backup,
        sourceMutationStep: sourceMutationStep,
        originalSourceMetadata: originalSourceMetadata,
        postMutationResourceIdentifier: postMutationResourceIdentifier
      ) else {
        throw RollbackError.sourceChangedExternally
      }
      guard try writeTargetIsAuthorized(
        record: record,
        url: backup.sourceURL,
        expectedResourceIdentifier: postMutationResourceIdentifier,
        expectedParentResourceIdentifier: backup.parentResourceIdentifier,
        requiredCapability: .restore
      ) else {
        throw RollbackError.sourceChangedExternally
      }
      let backupData = try fileSystem.read(backup.backupURL)
      guard Self.checksum(backupData) == backup.checksum else {
        throw RollbackError.integrityMismatch
      }
      let verifiedRecovery = AutomationVerifiedRecoveryInput(
        backupID: backup.id,
        backupURL: backup.backupURL,
        data: backupData,
        checksum: backup.checksum
      )
      if backup.sourceExisted {
        let parentAuthorization = try Self.directoryAuthorization(
          for: backup.sourceURL.deletingLastPathComponent(),
          resourceIdentifier: backup.parentResourceIdentifier
        )
        let staged = try fileSystem.writeStagedFile(
          nextTo: backup.sourceURL,
          data: verifiedRecovery.data,
          permissions: 0o600,
          authorization: parentAuthorization
        )
        guard try writeTargetIsAuthorized(
          record: record,
          url: backup.sourceURL,
          expectedResourceIdentifier: postMutationResourceIdentifier,
          expectedParentResourceIdentifier: backup.parentResourceIdentifier,
          requiredCapability: .restore
        ) else {
          try removeCleanupArtifact(staged.authorization)
          throw RollbackError.sourceChangedExternally
        }
        let destinationExists = fileSystem.itemExists(at: backup.sourceURL)
        let destinationResourceIdentifier = destinationExists
          ? (postMutationResourceIdentifier ?? originalSourceMetadata.resourceIdentifier)
          : nil
        let destinationAuthorization = try Self.fileAuthorization(
          for: backup.sourceURL,
          directory: parentAuthorization,
          resourceIdentifier: destinationResourceIdentifier,
          existed: destinationExists
        )
        _ = try committedReplacement(at: destinationAuthorization, with: staged)
      } else if fileSystem.itemExists(at: backup.sourceURL) {
        guard try writeTargetIsAuthorized(
          record: record,
          url: backup.sourceURL,
          expectedResourceIdentifier: postMutationResourceIdentifier,
          expectedParentResourceIdentifier: backup.parentResourceIdentifier,
          requiredCapability: .restore
        ) else {
          throw RollbackError.sourceChangedExternally
        }
        let parentAuthorization = try Self.directoryAuthorization(
          for: backup.sourceURL.deletingLastPathComponent(),
          resourceIdentifier: backup.parentResourceIdentifier
        )
        let sourceAuthorization = try Self.fileAuthorization(
          for: backup.sourceURL,
          directory: parentAuthorization,
          resourceIdentifier: postMutationResourceIdentifier,
          existed: true
        )
        _ = try Self.committedReceipt(fileSystem.removeItem(sourceAuthorization))
      }
      appliedSteps.append("Restored source from recovery backup.")

      if !preTransactionState.sourceExisted {
        let recoveredSnapshot = await refresh()
        let sourcePath = backup.sourceURL.standardizedFileURL.path
        guard !fileSystem.itemExists(at: backup.sourceURL),
              !recoveredSnapshot.records.contains(where: {
                $0.sourceURL?.standardizedFileURL.path == sourcePath
              })
        else {
          throw RollbackError.priorStateUnverified
        }
        appliedSteps.append("Refreshed and verified the prior absent source state.")
        return AutomationOperationResult(
          operation: operation.redactedForResult,
          status: Self.statusAfterRecoveredMutation(
            fileMutationEvidence,
            otherwise: "The automation operation failed; the prior absent source state was restored."
          ),
          appliedSteps: appliedSteps,
          verificationEvidence: evidence,
          rollback: .restored(backup.id),
          manualRecovery: nil,
          backup: backup.redactedForResult,
          fileMutationEvidence: fileMutationEvidence
        )
      }

      if phase == .sourceMutationFailed {
        let recoveredSnapshot = await refresh()
        guard let recoveredRecord = recoveredSnapshot.records.first(where: { $0.id == record.id }),
              recoveredRecord.enabledState == preTransactionState.enabledState,
              recoveredRecord.loadState == preTransactionState.loadState,
              fileSystem.itemExists(at: backup.sourceURL),
              Self.checksum(try fileSystem.read(backup.sourceURL)) == backup.checksum
        else { throw RollbackError.priorStateUnverified }
        appliedSteps.append(
          record.kind == .cron
            ? "Verified live cron state was never mutated."
            : "Verified the prior source and loaded state remain intact."
        )
        return AutomationOperationResult(
          operation: operation.redactedForResult,
          status: Self.statusAfterRecoveredMutation(
            fileMutationEvidence,
            otherwise: record.kind == .cron
              ? "The automation operation failed before the live crontab was changed."
              : "The automation operation failed; the prior source and loaded state were restored."
          ),
          appliedSteps: appliedSteps,
          verificationEvidence: evidence,
          rollback: .restored(backup.id),
          manualRecovery: nil,
          backup: backup.redactedForResult,
          fileMutationEvidence: fileMutationEvidence
        )
      }

      let priorStateResult = try await executor.restorePreTransactionState(
        preTransactionState,
        for: record,
        recovery: verifiedRecovery,
        linkedProcesses: linkedProcesses,
        expectedAppliedState: expectedAppliedState
      )
      guard priorStateResult.postconditions.contains(
        .preTransactionStateRestored(preTransactionState)
      ) else {
        throw RollbackError.priorStateUnverified
      }
      appliedSteps.append("Re-applied the exact pre-transaction state.")

      let recoveredSnapshot = await refresh()
      let recoveredProcesses = preTransactionState.linkedProcesses.isEmpty
        ? []
        : try await refreshProcesses()
      guard let recoveredRecord = recoveredSnapshot.records.first(where: { $0.id == record.id }),
            recoveredRecord.enabledState == preTransactionState.enabledState,
            recoveredRecord.loadState == preTransactionState.loadState
      else {
        throw RollbackError.priorStateUnverified
      }
      if !preTransactionState.linkedProcesses.isEmpty {
        let links = AutomationProcessCorrelator.links(
          records: recoveredSnapshot.records,
          processes: recoveredProcesses,
          now: now()
        ).filter { $0.recordID == recoveredRecord.id }
        let restoredIdentities = Set(links.compactMap { link -> AutomationLinkedProcessIdentity? in
          guard let birth = link.processIdentity.birthToken else { return nil }
          return AutomationLinkedProcessIdentity(
            processID: link.processIdentity.pid,
            birthToken: birth
          )
        })
        guard restoredIdentities.count >= preTransactionState.linkedProcesses.count else {
          throw RollbackError.priorStateUnverified
        }
      }
      if backup.sourceExisted {
        guard fileSystem.itemExists(at: backup.sourceURL),
              Self.checksum(try fileSystem.read(backup.sourceURL)) == backup.checksum
        else {
          throw RollbackError.priorStateUnverified
        }
      } else {
        guard !fileSystem.itemExists(at: backup.sourceURL) else {
          throw RollbackError.priorStateUnverified
        }
      }
      appliedSteps.append("Refreshed and verified exact recovery state.")

      return AutomationOperationResult(
        operation: operation.redactedForResult,
        status: Self.statusAfterRecoveredMutation(
          fileMutationEvidence,
          otherwise: "The automation operation failed; the prior source and loaded state were restored."
        ),
        appliedSteps: appliedSteps,
        verificationEvidence: evidence,
        rollback: .restored(backup.id),
        manualRecovery: nil,
        backup: backup.redactedForResult,
        fileMutationEvidence: fileMutationEvidence
      )
    } catch let rollbackPartial as AutomationFilePartialMutation {
      _ = await refresh()
      return AutomationOperationResult(
        operation: operation.redactedForResult,
        status: .partialFailure(
          "HIGH SEVERITY: the operation failed and automatic rollback reached a partial filesystem state."
        ),
        appliedSteps: appliedSteps,
        verificationEvidence: evidence,
        rollback: .failed("Automatic rollback did not complete."),
        manualRecovery: "Preserve the authorized filesystem recovery handles and use DevScope Restore before retrying.",
        backup: backup.redactedForResult,
        fileMutationEvidence: fileMutationEvidence ?? rollbackPartial,
        rollbackFileMutationEvidence: fileMutationEvidence == nil ? nil : rollbackPartial
      )
    } catch {
      _ = await refresh()
      return AutomationOperationResult(
        operation: operation.redactedForResult,
        status: .partialFailure(
          "HIGH SEVERITY: the operation failed and automatic rollback did not complete."
        ),
        appliedSteps: appliedSteps,
        verificationEvidence: evidence,
        rollback: .failed("Automatic rollback did not complete."),
        manualRecovery: "Use DevScope Restore with the recorded recovery identifier before retrying.",
        backup: backup.redactedForResult,
        fileMutationEvidence: fileMutationEvidence
      )
    }
  }

  private static func statusAfterRecoveredMutation(
    _ partial: AutomationFilePartialMutation?,
    otherwise message: String
  ) -> AutomationOperationStatus {
    if partial != nil {
      return .partialFailure(
        "HIGH SEVERITY: the filesystem reported a partial mutation; automatic rollback restored the prior state."
      )
    }
    return .failed(message)
  }

  private func rollbackTargetIsUnchanged(
    operation: AutomationOperation,
    proposal: SourceProposal?,
    backup: AutomationBackup,
    sourceMutationStep: String?,
    originalSourceMetadata: AutomationFileMetadata,
    postMutationResourceIdentifier: String?
  ) throws -> Bool {
    if case .remove = operation, backup.sourceKind == .legacyLoginItem {
      guard fileSystem.itemExists(at: backup.sourceURL) else { return false }
      let data = try fileSystem.read(backup.sourceURL)
      let metadata = try fileSystem.metadata(for: backup.sourceURL)
      return Self.checksum(data) == backup.checksum
        && metadata.resourceIdentifier == originalSourceMetadata.resourceIdentifier
    }
    if case .remove = operation {
      return !fileSystem.itemExists(at: backup.sourceURL)
    }
    if proposal?.restoresSourcePresence == false, sourceMutationStep != nil {
      return !fileSystem.itemExists(at: backup.sourceURL)
    }
    guard fileSystem.itemExists(at: backup.sourceURL) else { return false }
    let data = try fileSystem.read(backup.sourceURL)
    let metadata = try fileSystem.metadata(for: backup.sourceURL)
    guard let resourceIdentifier = metadata.resourceIdentifier else { return false }
    if sourceMutationStep != nil, let proposal {
      return Self.sourceChecksum(data, kind: backup.kind) == proposal.intendedChecksum
        && resourceIdentifier == postMutationResourceIdentifier
    }
    return Self.checksum(data) == backup.checksum
      && resourceIdentifier == originalSourceMetadata.resourceIdentifier
  }

  private func writeTargetIsAuthorized(
    record: AutomationRecord,
    url: URL,
    expectedResourceIdentifier: String?,
    expectedParentResourceIdentifier: String?,
    requiredCapability: AutomationCapability
  ) throws -> Bool {
    let destination = url.standardizedFileURL
    let context = try destinationContext(record, destination)
    let decision = AutomationCapabilityPolicy.decision(for: record, context: context)
    guard decision.capabilities.contains(requiredCapability),
          context.canonicalPathIsApproved,
          context.sourceOwnerUID == context.currentUID,
          !context.isManaged,
          !context.isSymlink
    else { return false }
    let parent = destination.deletingLastPathComponent().standardizedFileURL
    let parentMetadata = try fileSystem.metadata(for: parent)
    guard parentMetadata.canonicalURL.standardizedFileURL.path == parent.path,
          parentMetadata.ownerUID == context.currentUID,
          !parentMetadata.isSymbolicLink,
          parentMetadata.resourceIdentifier?.isEmpty == false,
          expectedParentResourceIdentifier == nil
            || parentMetadata.resourceIdentifier == expectedParentResourceIdentifier
    else { return false }
    if fileSystem.itemExists(at: destination) {
      let metadata = try fileSystem.metadata(for: destination)
      guard metadata.canonicalURL.standardizedFileURL.path == destination.path,
            metadata.ownerUID == context.currentUID,
            !metadata.isSymbolicLink,
            let identity = metadata.resourceIdentifier,
            !identity.isEmpty
      else { return false }
      return expectedResourceIdentifier == nil || identity == expectedResourceIdentifier
    }
    return expectedResourceIdentifier == nil
  }

  private func rejected(
    _ operation: AutomationOperation,
    _ message: String
  ) -> AutomationOperationResult {
    AutomationOperationResult(
      operation: operation.redactedForResult,
      status: .rejected(message),
      appliedSteps: [],
      verificationEvidence: [],
      rollback: .notNeeded,
      manualRecovery: nil
    )
  }

  private func failed(
    _ operation: AutomationOperation,
    _ message: String,
    appliedSteps: [String] = [],
    evidence: [String] = [],
    manualRecovery: String? = nil,
    backup: AutomationBackup? = nil
  ) -> AutomationOperationResult {
    AutomationOperationResult(
      operation: operation.redactedForResult,
      status: .failed(message),
      appliedSteps: appliedSteps,
      verificationEvidence: evidence,
      rollback: .notNeeded,
      manualRecovery: manualRecovery,
      backup: backup?.redactedForResult
    )
  }

  private static func checksum(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func sameLegacyLoginItem(
    _ candidate: AutomationRecord,
    _ selected: AutomationRecord
  ) -> Bool {
    guard candidate.sourceKind == .legacyLoginItem else { return false }
    if candidate.id == selected.id { return true }
    guard let candidatePath = candidate.executable, let selectedPath = selected.executable else {
      return false
    }
    return URL(fileURLWithPath: candidatePath).standardizedFileURL.path
      == URL(fileURLWithPath: selectedPath).standardizedFileURL.path
  }

  private static func sourceChecksum(_ data: Data, kind: AutomationKind) -> String {
    if kind == .cron, let normalized = CronDocumentChecksum.checksum(data) {
      return normalized
    }
    return checksum(data)
  }

  private static func directoryAuthorization(
    for directory: URL,
    resourceIdentifier: String?
  ) throws -> AutomationDirectoryAuthorization {
    guard let authorization = AutomationDirectoryAuthorization(
      directoryURL: directory,
      resourceIdentifier: resourceIdentifier
    ) else { throw AutomationManagerConfigurationError.destinationAuthorizationUnavailable }
    return authorization
  }

  private static func committedReceipt(
    _ outcome: AutomationFileMutationOutcome
  ) throws -> AutomationFileMutationReceipt {
    guard case .committed(let receipt) = outcome else {
      throw AutomationManagerConfigurationError.recoverableSourceUnavailable
    }
    return receipt
  }

  private func committedReplacement(
    at destination: AutomationFileAuthorization,
    with staged: AutomationStagedFile
  ) throws -> AutomationFileMutationReceipt {
    let outcome: AutomationFileMutationOutcome
    do {
      outcome = try fileSystem.replaceItem(at: destination, with: staged)
    } catch let partial as AutomationFilePartialMutation {
      throw partial
    } catch {
      try failAfterCleaningStaged(staged, originalError: error)
    }
    switch outcome {
    case .committed(let receipt):
      return receipt
    case .unchanged:
      try failAfterCleaningStaged(
        staged,
        originalError: AutomationManagerConfigurationError.recoverableSourceUnavailable
      )
    }
  }

  private func failAfterCleaningStaged(
    _ staged: AutomationStagedFile,
    originalError: Error
  ) throws -> Never {
    do {
      try removeCleanupArtifact(staged.authorization)
    } catch {
      let survivors = currentAuthorizedSurvivors([staged.authorization])
      guard !survivors.isEmpty else { throw originalError }
      throw AutomationFilePartialMutation(
        kind: .remove,
        commitState: .unknown,
        observedFiles: survivors,
        recoveryHandle: survivors.first,
        recoveryHandles: survivors,
        resultURL: staged.url
      )
    }
    throw originalError
  }

  private static func fileAuthorization(
    for file: URL,
    directory: AutomationDirectoryAuthorization,
    resourceIdentifier: String?,
    existed: Bool
  ) throws -> AutomationFileAuthorization {
    let expectation: AutomationFileExpectation
    if existed {
      guard let resourceIdentifier, !resourceIdentifier.isEmpty else {
        throw AutomationManagerConfigurationError.destinationAuthorizationUnavailable
      }
      expectation = .existing(resourceIdentifier: resourceIdentifier)
    } else {
      expectation = .absent
    }
    guard let authorization = AutomationFileAuthorization(
      fileURL: file,
      directory: directory,
      expectation: expectation
    ) else { throw AutomationManagerConfigurationError.destinationAuthorizationUnavailable }
    return authorization
  }
}

private extension AutomationOperation {
  var redactedForResult: AutomationOperation {
    switch self {
    case .confirmedRunToCompletion(let confirmation):
      .confirmedRunToCompletion(AutomationRunToCompletionConfirmation(
        recordID: confirmation.recordID,
        sourceChecksum: confirmation.sourceChecksum,
        exactCommand: "<redacted>"
      ))
    case .edit(let payload):
      .edit(payload.redactedForResult)
    case .duplicate(let payload):
      .duplicate(payload.redactedForResult)
    case .importRecord(let payload):
      .importRecord(AutomationImportPayload(
        destination: URL(fileURLWithPath: "/redacted"),
        data: Data(),
        expectedKind: payload.expectedKind,
        expectedDestinationChecksum: payload.expectedDestinationChecksum
      ))
    default:
      self
    }
  }

  var requiredCapability: AutomationCapability {
    switch self {
    case .startNow, .confirmedRunToCompletion: .startNow
    case .stopCurrentRun: .stopCurrentRun
    case .enable: .enable
    case .disable: .disable
    case .disableAndStop: .disableAndStop
    case .edit: .edit
    case .duplicate: .duplicate
    case .importRecord: .importRecord
    case .exportRecord: .exportRecord
    case .remove: .remove
    case .restore: .restore
    }
  }

  var controlsLinkedProcesses: Bool {
    switch self {
    case .stopCurrentRun, .disableAndStop:
      true
    default:
      false
    }
  }

  var requiresFreshProcessSnapshot: Bool {
    if controlsLinkedProcesses { return true }
    if case .startNow = self { return true }
    return false
  }

  var requiredPostconditions: Set<AutomationPostcondition> {
    switch self {
    case .startNow: [.targetResolved, .currentRunStarted]
    case .confirmedRunToCompletion: [.targetResolved, .runCompleted]
    case .stopCurrentRun: [.noLinkedProcess]
    case .enable: [.futureLaunchesEnabled]
    case .disable: [.futureLaunchesDisabled]
    case .disableAndStop: [.futureLaunchesDisabled, .noLinkedProcess]
    case .edit, .duplicate, .importRecord, .restore: [.sourceInstalled]
    case .exportRecord: [.targetResolved]
    case .remove: [.sourceRemoved]
    }
  }
}

private extension AutomationEditPayload {
  var redactedForResult: AutomationEditPayload {
    AutomationEditPayload(
      label: "<redacted>",
      executable: "/redacted",
      arguments: arguments.map { _ in "<redacted>" },
      environment: environment.mapValues { _ in "<redacted>" },
      workingDirectory: workingDirectory == nil ? nil : "/redacted",
      schedule: schedule,
      rawRepresentation: nil,
      destination: destination == nil ? nil : URL(fileURLWithPath: "/redacted"),
      expectedDestinationChecksum: expectedDestinationChecksum
    )
  }
}

private extension AutomationBackup {
  var redactedForResult: AutomationBackup {
    AutomationBackup(
      id: id,
      recordID: recordID,
      sourceURL: URL(fileURLWithPath: "/redacted"),
      backupURL: URL(fileURLWithPath: "/redacted"),
      checksum: checksum,
      createdAt: createdAt,
      sourceExisted: sourceExisted,
      ownerUID: ownerUID,
      kind: kind,
      sourceKind: sourceKind,
      authorizedRecordIDs: authorizedRecordIDs,
      parentResourceIdentifier: nil
    )
  }
}

private struct SourceProposal {
  let data: Data
  let destination: URL
  let intendedLabel: String?
  let intendedRecordID: AutomationRecord.ID?
  let cronBinding: CronProposalBinding?
  let cronRemovalBinding: CronRemovalBinding?
  let intendedChecksum: String
  let expectedDestinationChecksum: String?
  var restoresSourcePresence: Bool

  init(
    data: Data,
    destination: URL,
    intendedLabel: String?,
    intendedRecordID: AutomationRecord.ID?,
    cronBinding: CronProposalBinding?,
    cronRemovalBinding: CronRemovalBinding? = nil,
    intendedChecksum: String,
    expectedDestinationChecksum: String?,
    restoresSourcePresence: Bool = true
  ) {
    self.data = data
    self.destination = destination
    self.intendedLabel = intendedLabel
    self.intendedRecordID = intendedRecordID
    self.cronBinding = cronBinding
    self.cronRemovalBinding = cronRemovalBinding
    self.intendedChecksum = intendedChecksum
    self.expectedDestinationChecksum = expectedDestinationChecksum
    self.restoresSourcePresence = restoresSourcePresence
  }
}

private struct CronProposalBinding {
  let selectedRecordID: AutomationRecord.ID
  let intendedRecordID: AutomationRecord.ID
  let command: String
  let schedule: AutomationSchedule
  let environment: [String: String]
  let enabledState: AutomationEnabledState
}

private struct CronRemovalBinding {
  let command: String
  let schedule: AutomationSchedule
  let environment: [String: String]
  let enabledState: AutomationEnabledState
  let remainingMatchingCount: Int
}

private struct CronEntryFingerprint: Hashable {
  let scheduleExpression: String
  let command: String
  let environment: [String]
  let isEnabled: Bool
}

private struct DestinationSnapshot {
  let existed: Bool
  let data: Data?
  let metadata: AutomationFileMetadata
  let parentMetadata: AutomationFileMetadata
}

private struct ProposalError: Error {
  let message: String

  init(_ message: String) {
    self.message = message
  }
}

private extension AutomationSourceKind {
  var requiresRecoverableSource: Bool {
    self == .crontab || self == .legacyLoginItem
  }
}

private enum RollbackError: Error {
  case integrityMismatch
  case priorStateUnverified
  case sourceChangedExternally
}

private enum TransactionFailurePhase: Equatable {
  case sourceMutationFailed
  case executorAttempted
  case verificationFailed
}
