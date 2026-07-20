import CryptoKit
import Darwin
import DevScopeCore
import Foundation

struct AutomationExecutorRouter: AutomationMutationApplying {
  let launchd: LaunchdAutomationExecutor
  let cron: CronAutomationExecutor
  let legacy: LegacyLoginItemAutomationExecutor

  func apply(
    _ operation: AutomationOperation,
    to record: AutomationRecord,
    linkedProcesses: [ClassifiedDevProcess],
    proposedSourceURL: URL?
  ) async throws -> AutomationExecutorResult {
    switch record.sourceKind {
    case .launchAgent:
      try await launchd.apply(
        operation,
        to: record,
        linkedProcesses: linkedProcesses,
        proposedSourceURL: proposedSourceURL
      )
    case .crontab:
      try await cron.apply(
        operation,
        to: record,
        linkedProcesses: linkedProcesses,
        proposedSourceURL: proposedSourceURL
      )
    case .legacyLoginItem:
      try await legacy.apply(
        operation,
        to: record,
        linkedProcesses: linkedProcesses,
        proposedSourceURL: proposedSourceURL
      )
    case .launchDaemon, .serviceManagement:
      throw AutomationExecutorError.unsupportedSource
    }
  }

  func restorePreTransactionState(
    _ state: AutomationPreTransactionState,
    for record: AutomationRecord,
    recovery: AutomationVerifiedRecoveryInput,
    linkedProcesses: [ClassifiedDevProcess],
    expectedAppliedState: AutomationExecutorAppliedState?
  ) async throws -> AutomationExecutorResult {
    switch record.sourceKind {
    case .launchAgent:
      try await launchd.restorePreTransactionState(
        state,
        for: record,
        recovery: recovery,
        linkedProcesses: linkedProcesses,
        expectedAppliedState: expectedAppliedState
      )
    case .crontab:
      try await cron.restorePreTransactionState(
        state,
        for: record,
        recovery: recovery,
        linkedProcesses: linkedProcesses,
        expectedAppliedState: expectedAppliedState
      )
    case .legacyLoginItem:
      try await legacy.restorePreTransactionState(
        state,
        for: record,
        recovery: recovery,
        linkedProcesses: linkedProcesses,
        expectedAppliedState: expectedAppliedState
      )
    case .launchDaemon, .serviceManagement:
      throw AutomationExecutorError.unsupportedSource
    }
  }
}

actor AutomationRecoverableSourceProvider {
  private let runner: any AutomationCommandRunning
  private let fileSystem: any AutomationFileSystem
  private let legacyListing: any LegacyLoginItemListing
  private let root: URL
  private let currentUID: uid_t

  init(
    runner: any AutomationCommandRunning,
    fileSystem: any AutomationFileSystem,
    legacyListing: any LegacyLoginItemListing,
    root: URL,
    currentUID: uid_t
  ) {
    self.runner = runner
    self.fileSystem = fileSystem
    self.legacyListing = legacyListing
    self.root = root.standardizedFileURL
    self.currentUID = currentUID
  }

  func capture(_ record: AutomationRecord) async throws -> AutomationRecoverableSource {
    guard record.ownership == .user, record.ownerUID == currentUID else {
      throw AutomationManagerConfigurationError.recoverableSourceUnavailable
    }
    switch record.sourceKind {
    case .crontab:
      return try await captureCron(record)
    case .legacyLoginItem:
      return try await captureLegacyLoginItem(record)
    default:
      throw AutomationManagerConfigurationError.recoverableSourceUnavailable
    }
  }

  private func captureCron(
    _ record: AutomationRecord
  ) async throws -> AutomationRecoverableSource {
    let listed = try await runner.run(AutomationCommand(
      executable: "/usr/bin/crontab",
      arguments: ["-l"],
      environment: ["LC_ALL": "C"]
    ))
    guard listed.status == 0,
          let checksum = CronDocumentChecksum.checksum(listed.standardOutput),
          checksum == record.sourceChecksum else {
      throw AutomationManagerConfigurationError.recoverableSourceUnavailable
    }
    return try materialize(
      data: listed.standardOutput,
      checksum: checksum,
      at: Self.transactionURL(for: record, root: root)
    )
  }

  private func captureLegacyLoginItem(
    _ record: AutomationRecord
  ) async throws -> AutomationRecoverableSource {
    guard let selectedPath = record.executable else {
      throw AutomationManagerConfigurationError.recoverableSourceUnavailable
    }
    let canonicalSelectedPath = URL(fileURLWithPath: selectedPath).standardizedFileURL.path
    let items = try await legacyListing.currentUserLoginItems()
    guard let descriptor = items.first(where: {
      $0.name == record.label
        && URL(fileURLWithPath: $0.path).standardizedFileURL.path == canonicalSelectedPath
    }) else {
      throw AutomationManagerConfigurationError.recoverableSourceUnavailable
    }
    let data = try LegacyLoginItemRecoveryDocument.encode(
      selectedRecord: record,
      descriptor: descriptor,
      currentUID: currentUID
    )
    let checksum = LegacyLoginItemRecoveryDocument.checksum(ofEncodedDocument: data)
    guard checksum == record.sourceChecksum else {
      throw AutomationManagerConfigurationError.recoverableSourceUnavailable
    }
    return try materialize(
      data: data,
      checksum: checksum,
      at: Self.transactionURL(for: record, root: root)
    )
  }

  private func materialize(
    data: Data,
    checksum: String,
    at url: URL
  ) throws -> AutomationRecoverableSource {
    try fileSystem.createDirectory(root, permissions: 0o700)
    let rootMetadata = try fileSystem.metadata(for: root)
    guard rootMetadata.canonicalURL.standardizedFileURL.path == root.path,
          rootMetadata.ownerUID == currentUID,
          !rootMetadata.isSymbolicLink,
          rootMetadata.permissions == 0o700 else {
      throw AutomationManagerConfigurationError.recoverableSourceUnavailable
    }
    guard let rootAuthorization = AutomationDirectoryAuthorization(
      directoryURL: root,
      resourceIdentifier: rootMetadata.resourceIdentifier
    ) else { throw AutomationManagerConfigurationError.recoverableSourceUnavailable }
    if fileSystem.itemExists(at: url) {
      let metadata = try fileSystem.metadata(for: url)
      guard metadata.canonicalURL.standardizedFileURL.path == url.path,
            metadata.ownerUID == currentUID,
            !metadata.isSymbolicLink,
            metadata.permissions == 0o600 else {
        throw AutomationManagerConfigurationError.recoverableSourceUnavailable
      }
      if try fileSystem.read(url) != data {
        let staged = try fileSystem.writeStagedFile(
          nextTo: url,
          data: data,
          permissions: 0o600,
          authorization: rootAuthorization
        )
        guard let destination = AutomationFileAuthorization(
          fileURL: url,
          directory: rootAuthorization,
          expectation: .existing(resourceIdentifier: metadata.resourceIdentifier ?? "")
        ) else { throw AutomationManagerConfigurationError.recoverableSourceUnavailable }
        try install(destination: destination, staged: staged)
      }
    } else {
      let staged = try fileSystem.writeStagedFile(
        nextTo: url,
        data: data,
        permissions: 0o600,
        authorization: rootAuthorization
      )
      guard let destination = AutomationFileAuthorization(
        fileURL: url,
        directory: rootAuthorization,
        expectation: .absent
      ) else { throw AutomationManagerConfigurationError.recoverableSourceUnavailable }
      try install(destination: destination, staged: staged)
    }
    let storedData = try fileSystem.read(url)
    let metadata = try fileSystem.metadata(for: url)
    guard storedData == data,
          metadata.canonicalURL.standardizedFileURL.path == url.path,
          metadata.ownerUID == currentUID,
          !metadata.isSymbolicLink,
          metadata.permissions == 0o600 else {
      throw AutomationManagerConfigurationError.recoverableSourceUnavailable
    }
    return AutomationRecoverableSource(
      transactionURL: url,
      data: data,
      checksum: checksum,
      metadata: metadata
    )
  }

  private func install(
    destination: AutomationFileAuthorization,
    staged: AutomationStagedFile
  ) throws {
    let outcome: AutomationFileMutationOutcome
    do {
      outcome = try fileSystem.replaceItem(at: destination, with: staged)
    } catch let partial as AutomationFilePartialMutation {
      throw partial
    } catch {
      try failAfterCleaningStaged(staged, originalError: error)
    }
    guard case .unchanged = outcome else {
      return
    }
    try failAfterCleaningStaged(
      staged,
      originalError: AutomationManagerConfigurationError.recoverableSourceUnavailable
    )
  }

  private func failAfterCleaningStaged(
    _ staged: AutomationStagedFile,
    originalError: Error
  ) throws -> Never {
    do {
      guard case .committed = try fileSystem.removeItem(staged.authorization) else {
        throw AutomationManagerConfigurationError.recoverableSourceUnavailable
      }
    } catch {
      let directoryMatches = (try? fileSystem.metadata(
        for: staged.authorization.directory.directoryURL
      ).resourceIdentifier) == staged.authorization.directory.resourceIdentifier
      let leafMatches: Bool
      if case .existing(let identity) = staged.authorization.expectation {
        leafMatches = (try? fileSystem.metadata(for: staged.url).resourceIdentifier) == identity
      } else {
        leafMatches = false
      }
      guard directoryMatches && leafMatches else { throw originalError }
      throw AutomationFilePartialMutation(
        kind: .remove,
        commitState: .unknown,
        observedFiles: [staged.authorization],
        recoveryHandle: staged.authorization,
        resultURL: staged.url
      )
    }
    throw originalError
  }

  nonisolated static func transactionURL(
    for record: AutomationRecord,
    root: URL
  ) -> URL {
    switch record.sourceKind {
    case .crontab:
      root.appending(path: "current-crontab", directoryHint: .notDirectory)
    case .legacyLoginItem:
      root.appending(
        path: "legacy-\(rawChecksum(Data(record.id.rawValue.utf8))).json",
        directoryHint: .notDirectory
      )
    default:
      root.appending(path: "unsupported", directoryHint: .notDirectory)
    }
  }

  nonisolated private static func rawChecksum(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

struct AutomationAuthorityContextBuilder: Sendable {
  private let fileSystem: any AutomationFileSystem
  private let currentUID: uid_t
  private let launchAgentsRoot: URL
  private let transactionRoot: URL

  init(
    fileSystem: any AutomationFileSystem,
    currentUID: uid_t,
    launchAgentsRoot: URL,
    transactionRoot: URL
  ) {
    self.fileSystem = fileSystem
    self.currentUID = currentUID
    self.launchAgentsRoot = launchAgentsRoot.standardizedFileURL
    self.transactionRoot = transactionRoot.standardizedFileURL
  }

  func context(for record: AutomationRecord) throws -> AutomationCapabilityContext {
    if record.ownership != .user
      || record.kind == .launchDaemon
      || record.kind == .backgroundItem
      || record.sourceKind == .launchDaemon
      || record.sourceKind == .serviceManagement
    {
      return AutomationCapabilityContext(
        currentUID: currentUID,
        canonicalPathIsApproved: false,
        sourceOwnerUID: record.ownerUID,
        isSymlink: false,
        isManaged: record.ownership == .managed,
        implementedCapabilities: [.exportRecord]
      )
    }
    let sourceURL: URL
    switch record.sourceKind {
    case .launchAgent:
      guard let directURL = record.sourceURL else {
        throw AutomationManagerConfigurationError.destinationAuthorizationUnavailable
      }
      sourceURL = directURL.standardizedFileURL
    case .crontab, .legacyLoginItem:
      sourceURL = AutomationRecoverableSourceProvider.transactionURL(
        for: record,
        root: transactionRoot
      )
    case .launchDaemon, .serviceManagement:
      throw AutomationManagerConfigurationError.destinationAuthorizationUnavailable
    }
    return try context(for: record, destination: sourceURL)
  }

  func context(
    for record: AutomationRecord,
    destination: URL
  ) throws -> AutomationCapabilityContext {
    let destination = destination.standardizedFileURL
    let approvedRoot: URL
    switch record.sourceKind {
    case .launchAgent:
      approvedRoot = launchAgentsRoot
    case .crontab, .legacyLoginItem:
      approvedRoot = transactionRoot
    case .launchDaemon, .serviceManagement:
      throw AutomationManagerConfigurationError.destinationAuthorizationUnavailable
    }
    let destinationExists = fileSystem.itemExists(at: destination)
    let metadataURL = destinationExists
      ? destination
      : destination.deletingLastPathComponent().standardizedFileURL
    let metadata = try fileSystem.metadata(for: metadataURL)
    let canonicalPathIsApproved = AutomationPathAuthorization.isApprovedDestination(
      destination,
      approvedRoot: approvedRoot,
      destinationExists: destinationExists,
      verifiedMetadataURL: metadata.canonicalURL,
      metadataIsSymbolicLink: metadata.isSymbolicLink
    )
    return AutomationCapabilityContext(
      currentUID: currentUID,
      canonicalPathIsApproved: canonicalPathIsApproved,
      sourceOwnerUID: metadata.ownerUID,
      isSymlink: destinationExists ? metadata.isSymbolicLink : false,
      isManaged: record.ownership == .managed,
      implementedCapabilities: Self.implementedCapabilities(for: record.sourceKind)
    )
  }

  private static func implementedCapabilities(
    for sourceKind: AutomationSourceKind
  ) -> Set<AutomationCapability> {
    switch sourceKind {
    case .launchAgent:
      [.startNow, .stopCurrentRun, .enable, .disable, .disableAndStop,
       .edit, .duplicate, .importRecord, .exportRecord, .remove, .restore]
    case .crontab:
      [.startNow, .stopCurrentRun, .enable, .disable, .disableAndStop,
       .edit, .duplicate, .importRecord, .exportRecord, .remove, .restore]
    case .legacyLoginItem:
      [.startNow, .enable, .disable, .exportRecord, .remove]
    case .launchDaemon, .serviceManagement:
      [.exportRecord]
    }
  }
}

struct AutomationAuthorityCapabilityDecisionProvider:
  AutomationCapabilityDecisionProviding, Sendable
{
  let authority: AutomationAuthorityContextBuilder

  func decisions(
    for records: [AutomationRecord]
  ) async -> [AutomationRecord.ID: AutomationCapabilityDecision] {
    await Task.detached(priority: .utility) {
      Dictionary(uniqueKeysWithValues: records.map { record in
        do {
          let context = try authority.context(for: record)
          return (record.id, AutomationCapabilityPolicy.decision(for: record, context: context))
        } catch {
          return (
            record.id,
            AutomationCapabilityDecision(
              capabilities: record.capabilities.intersection([.exportRecord]),
              reason: "DevScope could not verify source ownership and path safety for management."
            )
          )
        }
      })
    }.value
  }
}

struct AutomationManagementDestinationProvider:
  AutomationManagementDestinationProviding, Sendable
{
  let transactionRoot: URL

  func duplicateDestination(for record: AutomationRecord, label: String) -> URL? {
    switch record.sourceKind {
    case .launchAgent:
      guard let sourceURL = record.sourceURL,
            let filename = safeFilename(label, requiredExtension: "plist") else { return nil }
      return sourceURL.deletingLastPathComponent().appendingPathComponent(filename)
    case .crontab:
      return AutomationRecoverableSourceProvider.transactionURL(for: record, root: transactionRoot)
    case .legacyLoginItem, .launchDaemon, .serviceManagement:
      return nil
    }
  }

  func importDestination(for record: AutomationRecord, suggestedFilename: String) -> URL? {
    switch record.sourceKind {
    case .launchAgent:
      // Import replaces the selected, checksum-bound source. Creating a sibling
      // requires separately inspected destination authority that the inventory
      // does not publish.
      return record.sourceURL?.standardizedFileURL
    case .crontab:
      return AutomationRecoverableSourceProvider.transactionURL(for: record, root: transactionRoot)
    case .legacyLoginItem, .launchDaemon, .serviceManagement:
      return nil
    }
  }

  private func safeFilename(_ value: String, requiredExtension: String) -> String? {
    let component = URL(fileURLWithPath: value).lastPathComponent
    guard component == value,
          !component.isEmpty,
          component != ".",
          component != "..",
          component.unicodeScalars.allSatisfy({
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0)
          }) else { return nil }
    return component.hasSuffix(".\(requiredExtension)")
      ? component : "\(component).\(requiredExtension)"
  }
}
