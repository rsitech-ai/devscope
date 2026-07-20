import Foundation

public struct AutomationPresentationContext: Equatable, Sendable {
  public static let defaultLongRunningThreshold: TimeInterval = 14_400

  public let inventory: AutomationInventorySnapshot
  public let longRunningThreshold: TimeInterval

  public init(
    inventory: AutomationInventorySnapshot,
    longRunningThreshold: TimeInterval
  ) {
    self.inventory = inventory
    if longRunningThreshold.isFinite {
      self.longRunningThreshold = max(0, longRunningThreshold)
    } else {
      self.longRunningThreshold = Self.defaultLongRunningThreshold
    }
  }

  public func build(
    processes: [DevProcess],
    now: Date,
    calendar: Calendar = .current,
    isProcessSnapshotComplete: Bool = true
  ) -> AutomationPresentationSnapshot {
    AutomationPresentationSnapshot.build(
      inventory: inventory,
      processes: processes,
      longRunningThreshold: longRunningThreshold,
      now: now,
      calendar: calendar,
      isProcessSnapshotComplete: isProcessSnapshotComplete
    )
  }
}

public struct AutomationPresentationSnapshot: Equatable, Sendable {
  public let inventory: AutomationInventorySnapshot
  public let linksByProcessID: [Int32: AutomationProcessLink]
  public let allLinksByProcessID: [Int32: [AutomationProcessLink]]
  public let longRunningProcessIDs: Set<Int32>
  public let longRunningProcessIdentities: Set<ProcessIdentity>
  public let processIdentitiesByID: [Int32: ProcessIdentity]
  public let isProcessSnapshotComplete: Bool

  public init(
    inventory: AutomationInventorySnapshot,
    linksByProcessID: [Int32: AutomationProcessLink],
    allLinksByProcessID: [Int32: [AutomationProcessLink]]? = nil,
    longRunningProcessIDs: Set<Int32>,
    longRunningProcessIdentities: Set<ProcessIdentity>,
    processIdentitiesByID: [Int32: ProcessIdentity],
    isProcessSnapshotComplete: Bool = true
  ) {
    self.inventory = inventory
    self.linksByProcessID = linksByProcessID
    self.allLinksByProcessID = allLinksByProcessID ?? linksByProcessID.mapValues { [$0] }
    self.longRunningProcessIDs = longRunningProcessIDs
    self.longRunningProcessIdentities = longRunningProcessIdentities
    self.processIdentitiesByID = processIdentitiesByID
    self.isProcessSnapshotComplete = isProcessSnapshotComplete
  }

  public static func build(
    inventory: AutomationInventorySnapshot,
    processes: [DevProcess],
    longRunningThreshold: TimeInterval,
    now: Date,
    calendar: Calendar = .current,
    isProcessSnapshotComplete: Bool = true
  ) -> Self {
    let processes = ProcessSnapshotNormalization.newestUnambiguous(processes)
    let links = AutomationProcessCorrelator.links(
      records: inventory.records,
      processes: processes,
      now: now,
      calendar: calendar
    )
    let allLinksByProcessID = Dictionary(grouping: links, by: \.processIdentity.pid)
    let linksByProcessID = allLinksByProcessID.compactMapValues(\.first)
    let stronglyRunningRecordIDs = Set(
      links.filter { $0.strength == .strong }.map(\.recordID)
    )
    let projectedInventory = AutomationInventorySnapshot(
      generation: inventory.generation,
      records: inventory.records.map { record in
        stronglyRunningRecordIDs.contains(record.id)
          ? record.withRuntimeState(.running)
          : record
      },
      health: inventory.health,
      refreshedAt: inventory.refreshedAt
    )
    let longRunningIdentities = Set(processes.compactMap { process in
      LongRunningAssessment.isLongRunning(process.resourceUsage, threshold: longRunningThreshold)
        ? ProcessIdentity(process: process) : nil
    })
    let longRunning = Set(longRunningIdentities.map(\.pid))
    let identities = Dictionary(uniqueKeysWithValues:
      processes.map { ($0.pid, ProcessIdentity(process: $0)) }
    )
    return Self(
      inventory: projectedInventory,
      linksByProcessID: linksByProcessID,
      allLinksByProcessID: allLinksByProcessID,
      longRunningProcessIDs: longRunning,
      longRunningProcessIdentities: longRunningIdentities,
      processIdentitiesByID: identities,
      isProcessSnapshotComplete: isProcessSnapshotComplete
    )
  }

}

private extension AutomationRecord {
  func withRuntimeState(_ state: AutomationState) -> AutomationRecord {
    AutomationRecord(
      id: id,
      kind: kind,
      sourceKind: sourceKind,
      label: label,
      displayName: displayName,
      providerBundleIdentifier: providerBundleIdentifier,
      ownerUID: ownerUID,
      ownership: ownership,
      executable: executable,
      arguments: arguments,
      commandSignature: commandSignature,
      environment: environment,
      workingDirectory: workingDirectory,
      schedule: schedule,
      sourceURL: sourceURL,
      sourceChecksum: sourceChecksum,
      enabledState: enabledState,
      loadState: loadState,
      approvalState: approvalState,
      state: state,
      evidence: evidence,
      capabilities: capabilities,
      validationFindings: validationFindings
    )
  }
}

public enum AutomationProcessBadge: Equatable, Sendable {
  case automated
  case longRunning(String)
}

public enum AutomationSourceFilter: String, CaseIterable, Hashable, Sendable {
  case all, launchd, loginItems, scheduled
}

public enum AutomationOwnershipFilter: String, CaseIterable, Hashable, Sendable {
  case all, user, thirdParty, appleSystem

  public func matches(_ ownership: AutomationOwnership) -> Bool {
    switch self {
    case .all: true
    case .user: ownership == .user
    case .thirdParty: ownership == .thirdPartySystem || ownership == .managed
    case .appleSystem: ownership == .appleSystem
    }
  }
}

public enum AutomationActivityTypeFilter: String, CaseIterable, Hashable, Sendable {
  case all, automated, longRunning, both

  public func matches(isAutomated: Bool, isLongRunning: Bool) -> Bool {
    switch self {
    case .all:
      true
    case .automated:
      isAutomated
    case .longRunning:
      isLongRunning
    case .both:
      isAutomated && isLongRunning
    }
  }
}

public struct AutomationInventoryCountPresentation: Equatable, Sendable {
  public let primaryText: String
  public let contextText: String?
  public let accessibilityLabel: String
}

public enum AutomationPresentation {
  public static func inventoryCount(
    visibleCount: Int,
    eligibleCount: Int,
    totalCount: Int
  ) -> AutomationInventoryCountPresentation {
    let totalCount = max(0, totalCount)
    let eligibleCount = min(max(0, eligibleCount), totalCount)
    let visibleCount = min(max(0, visibleCount), eligibleCount)
    let automationNoun = eligibleCount == 1 ? "automation" : "automations"
    let primaryText = visibleCount == eligibleCount
      ? "\(eligibleCount) \(automationNoun)"
      : "\(visibleCount) of \(eligibleCount) \(automationNoun)"
    let hiddenCount = totalCount - eligibleCount
    let contextText = hiddenCount > 0
      ? "\(hiddenCount) Apple system service\(hiddenCount == 1 ? "" : "s") hidden"
      : nil
    let accessibilityLabel = if let contextText {
      "\(primaryText). \(contextText). "
        + "In Settings, open Automations and enable Include Apple System Services to review them."
    } else {
      primaryText
    }
    return AutomationInventoryCountPresentation(
      primaryText: primaryText,
      contextText: contextText,
      accessibilityLabel: accessibilityLabel
    )
  }

  public static func uniquelyStrongLinkedProcessIdentities(
    for recordID: AutomationRecord.ID,
    linksByProcessID: [Int32: [AutomationProcessLink]]
  ) -> Set<ProcessIdentity> {
    Set(linksByProcessID.values.compactMap { links in
      let strongLinks = links.filter { $0.strength == .strong }
      let strongRecordIDs = Set(strongLinks.map(\.recordID))
      let identities = Set(strongLinks.map(\.processIdentity))
      guard strongRecordIDs == [recordID], identities.count == 1 else { return nil }
      return identities.first
    })
  }

  public static func resolvedSelection(
    current: AutomationRecord.ID?,
    visibleIDs: [AutomationRecord.ID]
  ) -> AutomationRecord.ID? {
    guard let current, visibleIDs.contains(current) else { return visibleIDs.first }
    return current
  }

  public static func filtered(
    _ records: [AutomationRecord],
    source: AutomationSourceFilter,
    state: AutomationState?,
    ownership: AutomationOwnershipFilter,
    searchText: String,
    includeAppleSystemServices: Bool
  ) -> [AutomationRecord] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return records.filter { record in
      guard includeAppleSystemServices || record.ownership != .appleSystem,
            state == nil || record.state == state,
            ownership.matches(record.ownership),
            sourceMatches(record.sourceKind, filter: source) else { return false }
      guard !query.isEmpty else { return true }
      return [
        record.label, record.displayName, record.executable ?? "",
        record.arguments.joined(separator: " "), record.sourceURL?.path ?? "",
        record.providerBundleIdentifier ?? "", record.schedule.summary,
      ].contains { $0.lowercased().contains(query) }
    }.sorted(by: recordPrecedes)
  }

  public static func badges(
    isAutomated: Bool,
    isLongRunning: Bool,
    elapsed: String
  ) -> [AutomationProcessBadge] {
    var result: [AutomationProcessBadge] = []
    if isAutomated { result.append(.automated) }
    if isLongRunning { result.append(.longRunning(compactElapsed(elapsed))) }
    return result
  }

  private static func sourceMatches(
    _ kind: AutomationSourceKind,
    filter: AutomationSourceFilter
  ) -> Bool {
    switch filter {
    case .all: true
    case .launchd: kind == .launchAgent || kind == .launchDaemon
    case .loginItems: kind == .serviceManagement || kind == .legacyLoginItem
    case .scheduled: kind == .crontab
    }
  }

  private static func recordPrecedes(_ lhs: AutomationRecord, _ rhs: AutomationRecord) -> Bool {
    if lhs.label != rhs.label {
      return lhs.label.utf8.lexicographicallyPrecedes(rhs.label.utf8)
    }
    return lhs.id.rawValue.utf8.lexicographicallyPrecedes(rhs.id.rawValue.utf8)
  }

  private static func compactElapsed(_ elapsed: String) -> String {
    let seconds = ProcessPresentation.elapsedSeconds(elapsed)
    guard seconds >= 0 else { return elapsed }
    if seconds >= 86_400 { return "\(seconds / 86_400)d" }
    if seconds >= 3_600 { return "\(seconds / 3_600)h" }
    if seconds >= 60 { return "\(seconds / 60)m" }
    return "\(seconds)s"
  }
}

public enum AutomationManagementAction: Equatable, Hashable, Sendable {
  case startNow
  case stopCurrentRun
  case enable
  case disable
  case disableAndStop
  case edit
  case duplicate
  case importRecord
  case exportRedacted
  case exportUnredacted
  case remove
  case restore(AutomationBackup.ID)

  public var title: String {
    switch self {
    case .startNow: "Start Now"
    case .stopCurrentRun: "Stop Current Run"
    case .enable: "Enable"
    case .disable: "Disable"
    case .disableAndStop: "Disable and Stop"
    case .edit: "Edit"
    case .duplicate: "Duplicate"
    case .importRecord: "Import"
    case .exportRedacted: "Export Redacted"
    case .exportUnredacted: "Export Unredacted"
    case .remove: "Remove"
    case .restore: "Restore"
    }
  }

  public var isDestructive: Bool {
    switch self {
    case .stopCurrentRun, .disableAndStop, .remove:
      true
    default:
      false
    }
  }

  public var placement: AutomationManagementActionPlacement {
    switch self {
    case .startNow, .stopCurrentRun, .enable, .disable, .disableAndStop:
      .pinned
    case .restore:
      .history
    case .edit, .duplicate, .importRecord, .exportRedacted, .exportUnredacted, .remove:
      .overflow
    }
  }

  public var emphasis: AutomationManagementActionEmphasis {
    switch self {
    case .startNow, .enable:
      .positive
    case .disable, .exportUnredacted:
      .caution
    case .stopCurrentRun, .disableAndStop, .remove:
      .destructive
    case .edit, .duplicate, .importRecord, .exportRedacted, .restore:
      .neutral
    }
  }

  public var systemImage: String {
    switch self {
    case .startNow: "play.fill"
    case .stopCurrentRun: "stop.fill"
    case .enable: "checkmark.circle"
    case .disable: "pause.circle"
    case .disableAndStop: "stop.circle.fill"
    case .edit: "square.and.pencil"
    case .duplicate: "plus.square.on.square"
    case .importRecord: "square.and.arrow.down"
    case .exportRedacted: "square.and.arrow.up"
    case .exportUnredacted: "lock.open.fill"
    case .remove: "trash"
    case .restore: "clock.arrow.circlepath"
    }
  }
}

public enum AutomationManagementActionPlacement: Equatable, Sendable {
  case pinned
  case overflow
  case history
}

public enum AutomationManagementActionEmphasis: Equatable, Sendable {
  case neutral
  case positive
  case caution
  case destructive
}

public struct AutomationConfirmationPolicy: Equatable, Sendable {
  public let title: String
  public let consequence: String
  public let requiredLabel: String?
  public let displayedCommand: String?

  public init(
    title: String,
    consequence: String,
    requiredLabel: String? = nil,
    displayedCommand: String? = nil
  ) {
    self.title = title
    self.consequence = consequence
    self.requiredLabel = requiredLabel
    self.displayedCommand = displayedCommand
  }

  public func isSatisfiedByLabel(_ candidate: String) -> Bool {
    guard let requiredLabel else { return true }
    return candidate == requiredLabel
  }
}

public struct AutomationOperationResultPresentation: Equatable, Sendable {
  public let title: String
  public let detail: String
  public let appliedEvidence: [String]
  public let verificationEvidence: [String]
  public let rollbackEvidence: String
  public let backupEvidence: String?
  public let mutationEvidence: [String]
  public let recoveryGuidance: String?
  public let isFailure: Bool

  public init(
    title: String,
    detail: String,
    appliedEvidence: [String],
    verificationEvidence: [String],
    rollbackEvidence: String,
    backupEvidence: String?,
    mutationEvidence: [String],
    recoveryGuidance: String?,
    isFailure: Bool
  ) {
    self.title = title
    self.detail = detail
    self.appliedEvidence = appliedEvidence
    self.verificationEvidence = verificationEvidence
    self.rollbackEvidence = rollbackEvidence
    self.backupEvidence = backupEvidence
    self.mutationEvidence = mutationEvidence
    self.recoveryGuidance = recoveryGuidance
    self.isFailure = isFailure
  }
}

public enum AutomationManagementPresentation {
  public static func actions(
    decision: AutomationCapabilityDecision,
    backups: [AutomationBackup],
    record: AutomationRecord
  ) -> [AutomationManagementAction] {
    let capabilities = decision.capabilities
    var result: [AutomationManagementAction] = []
    if capabilities.contains(.startNow) { result.append(.startNow) }
    if capabilities.contains(.stopCurrentRun) { result.append(.stopCurrentRun) }
    if capabilities.contains(.enable) { result.append(.enable) }
    if capabilities.contains(.disable) { result.append(.disable) }
    if capabilities.contains(.disableAndStop) { result.append(.disableAndStop) }
    if capabilities.contains(.edit) { result.append(.edit) }
    if capabilities.contains(.duplicate) { result.append(.duplicate) }
    if capabilities.contains(.importRecord) { result.append(.importRecord) }
    if capabilities.contains(.exportRecord) {
      result.append(.exportRedacted)
      if record.ownership == .user,
         record.kind != .launchDaemon,
         record.kind != .backgroundItem,
         record.sourceKind != .launchDaemon,
         record.sourceKind != .serviceManagement {
        result.append(.exportUnredacted)
      }
    }
    if capabilities.contains(.remove) { result.append(.remove) }
    if capabilities.contains(.restore) {
      result.append(contentsOf: backups
        .filter { $0.recordID == record.id }
        .sorted { $0.createdAt > $1.createdAt }
        .map { .restore($0.id) })
    }
    return result
  }

  public static func helpText(
    for action: AutomationManagementAction,
    record: AutomationRecord
  ) -> String {
    switch action {
    case .startNow:
      "Request this automation to run now"
    case .stopCurrentRun where isLaunchAgent(record):
      "Unload the exact launchd service after confirmation"
    case .stopCurrentRun:
      "Stop strongly linked current processes after confirmation"
    case .enable:
      "Allow future launches after confirmation"
    case .disable:
      "Prevent future launches after confirmation"
    case .disableAndStop where isLaunchAgent(record):
      "Prevent future launches and unload the exact launchd service"
    case .disableAndStop:
      "Prevent future launches and stop strongly linked current processes"
    case .edit:
      "Edit this user-owned automation through validated fields"
    case .duplicate:
      "Create a disabled copy with a distinct label"
    case .importRecord:
      "Validate and preview an automation file before importing"
    case .exportRedacted:
      "Export a secret-redacted inspection artifact"
    case .exportUnredacted:
      "Explicitly request an unredacted export when policy allows"
    case .remove:
      "Remove through a recoverable transaction after exact-label confirmation"
    case .restore:
      "Restore this concrete verified backup"
    }
  }

  public static func confirmation(
    for action: AutomationManagementAction,
    record: AutomationRecord,
    backups: [AutomationBackup] = []
  ) -> AutomationConfirmationPolicy? {
    switch action {
    case .startNow where record.kind == .cron:
      return AutomationConfirmationPolicy(
        title: "Run this scheduled command now?",
        consequence: "Runs this cron command to completion outside its normal schedule.",
        displayedCommand: record.commandSignature.map(ProcessPresentation.redactedCommand)
      )
    case .startNow:
      return AutomationConfirmationPolicy(
        title: "Start this automation now?",
        consequence: "Requests an immediate launch. This does not change whether future launches are enabled."
      )
    case .stopCurrentRun:
      if record.kind == .launchAgent, record.sourceKind == .launchAgent {
        return AutomationConfirmationPolicy(
          title: "Stop the current run?",
          consequence: "Unloads the exact launchd service. "
            + "This does not disable future launches; Start Now or Enable can load it again."
        )
      }
      return AutomationConfirmationPolicy(
        title: "Stop the current run?",
        consequence: "Stops only strongly linked, birth-validated processes. "
          + "A scheduled or supervising automation may launch again."
      )
    case .enable:
      return AutomationConfirmationPolicy(
        title: "Enable future launches?",
        consequence: "Allows future launches. This does not start a run now."
      )
    case .disable:
      return AutomationConfirmationPolicy(
        title: "Disable future launches?",
        consequence: "Prevents future launches. This does not stop a process that is already running."
      )
    case .disableAndStop where isLaunchAgent(record):
      return AutomationConfirmationPolicy(
        title: "Disable and stop this automation?",
        consequence: "Prevents future launches and unloads the exact launchd service."
      )
    case .disableAndStop:
      return AutomationConfirmationPolicy(
        title: "Disable and stop this automation?",
        consequence: "Prevents future launches and stops only strongly linked current processes."
      )
    case .remove:
      return AutomationConfirmationPolicy(
        title: "Remove this automation?",
        consequence: "Unloads it where applicable, removes its source through a recoverable transaction, and writes a restoration manifest.",
        requiredLabel: record.label
      )
    case .exportUnredacted:
      return AutomationConfirmationPolicy(
        title: "Export unredacted source?",
        consequence: "The exported file may contain commands, paths, environment values, credentials, or other secrets. DevScope will not log its contents."
      )
    case .restore(let backupID):
      guard let backup = backups.first(where: { $0.id == backupID && $0.recordID == record.id }) else {
        return nil
      }
      return AutomationConfirmationPolicy(
        title: "Restore this verified backup?",
        consequence: "Replaces the current definition with the verified backup from \(backup.createdAt.formatted(date: .abbreviated, time: .shortened)) after conflict and integrity checks."
      )
    default:
      return nil
    }
  }

  private static func isLaunchAgent(_ record: AutomationRecord) -> Bool {
    record.kind == .launchAgent && record.sourceKind == .launchAgent
  }

  public static func confirmedOperation(
    for action: AutomationManagementAction,
    record: AutomationRecord
  ) -> AutomationOperation? {
    switch action {
    case .startNow where record.kind == .cron:
      guard let exactCommand = record.commandSignature else { return nil }
      return .confirmedRunToCompletion(AutomationRunToCompletionConfirmation(
        recordID: record.id,
        sourceChecksum: record.sourceChecksum,
        exactCommand: exactCommand
      ))
    case .startNow: return AutomationOperation.startNow
    case .stopCurrentRun: return AutomationOperation.stopCurrentRun
    case .enable: return AutomationOperation.enable
    case .disable: return AutomationOperation.disable
    case .disableAndStop: return AutomationOperation.disableAndStop
    case .exportRedacted: return AutomationOperation.exportRecord(redacted: true)
    case .exportUnredacted: return AutomationOperation.exportRecord(redacted: false)
    case .remove: return AutomationOperation.remove
    case .restore(let backupID): return AutomationOperation.restore(backupID)
    case .edit, .duplicate, .importRecord: return nil
    }
  }

  public static func result(
    _ result: AutomationOperationResult
  ) -> AutomationOperationResultPresentation {
    let title: String
    let detail: String
    let isFailure: Bool
    switch result.status {
    case .succeeded:
      title = "Completed"
      detail = "The operation completed and DevScope refreshed the automation inventory."
      isFailure = false
    case .rejected(let reason):
      title = "Not performed"
      detail = ProcessPresentation.redactedCommand(reason)
      isFailure = true
    case .failed(let reason):
      title = "Operation failed"
      detail = ProcessPresentation.redactedCommand(reason)
      isFailure = true
    case .partialFailure(let reason):
      title = "Partially completed"
      detail = ProcessPresentation.redactedCommand(reason)
      isFailure = true
    }

    var recovery: [String] = []
    if let manualRecovery = result.manualRecovery {
      recovery.append(ProcessPresentation.redactedCommand(manualRecovery))
    }
    if case .failed(let reason) = result.rollback {
      recovery.append("Rollback failed: \(ProcessPresentation.redactedCommand(reason))")
    }
    var recoveryPaths: Set<String> = []
    for evidence in [result.fileMutationEvidence, result.rollbackFileMutationEvidence].compactMap({ $0 }) {
      for handle in evidence.recoveryHandles {
        let path = handle.fileURL.standardizedFileURL.path
        if recoveryPaths.insert(path).inserted {
          recovery.append("Recovery location: \(path)")
        }
      }
    }
    let rollbackEvidence: String
    switch result.rollback {
    case .notNeeded:
      rollbackEvidence = "Rollback was not required."
    case .restored(let backupID):
      rollbackEvidence = "Rollback restored verified backup \(backupID.rawValue.uuidString.prefix(8))."
    case .failed(let reason):
      rollbackEvidence = "Rollback failed: \(ProcessPresentation.redactedCommand(reason))"
    }
    let backupEvidence = result.backup.map {
      "Recovery backup verified · \($0.checksum.prefix(12)) · \($0.createdAt.formatted(date: .abbreviated, time: .shortened))"
    }
    var mutationEvidence: [String] = []
    if let evidence = result.fileMutationEvidence {
      mutationEvidence.append(mutationSummary(evidence, subject: "Source"))
    }
    if let evidence = result.rollbackFileMutationEvidence {
      mutationEvidence.append(mutationSummary(evidence, subject: "Rollback"))
    }
    return AutomationOperationResultPresentation(
      title: title,
      detail: detail,
      appliedEvidence: result.appliedSteps.map(ProcessPresentation.redactedCommand),
      verificationEvidence: result.verificationEvidence.map(ProcessPresentation.redactedCommand),
      rollbackEvidence: rollbackEvidence,
      backupEvidence: backupEvidence,
      mutationEvidence: mutationEvidence,
      recoveryGuidance: recovery.isEmpty ? nil : recovery.joined(separator: "\n"),
      isFailure: isFailure
    )
  }

  private static func mutationSummary(
    _ evidence: AutomationFilePartialMutation,
    subject: String
  ) -> String {
    let mutation: String
    switch evidence.kind {
    case .replace: mutation = "replacement"
    case .remove: mutation = "removal"
    case .trash: mutation = "trash move"
    }
    let state = evidence.commitState == .committed ? "committed" : "outcome is unknown"
    return "\(subject) \(mutation) \(state); \(evidence.observedFiles.count) observed files and \(evidence.recoveryHandles.count) recovery handles were retained."
  }
}

public enum AutomationEditorPresentation {
  public static func environmentText(for environment: [String: String]) -> String {
    environment.keys.sorted().compactMap { key in
      environment[key].map { "\(key)=\($0)" }
    }.joined(separator: "\n")
  }

  public static func environment(from text: String) -> [String: String]? {
    var environment: [String: String] = [:]
    for rawLine in text.split(whereSeparator: \.isNewline) {
      let line = String(rawLine)
      guard let separator = line.firstIndex(of: "=") else { return nil }
      let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
      let value = String(line[line.index(after: separator)...])
      guard !key.isEmpty,
            !key.contains("="),
            !key.contains("\0"),
            !value.contains("\0"),
            environment[key] == nil else { return nil }
      environment[key] = value
    }
    return environment
  }

  public static func scheduleText(for schedule: AutomationSchedule) -> String {
    schedule.triggers.map { trigger in
      switch trigger {
      case .atLogin: "run-at-load"
      case .runAtLoad: "run-at-load"
      case .interval(let seconds): "interval \(seconds)"
      case .calendar(let summary): "calendar \(summary)"
      case .keepAlive: "keep-alive"
      case .cron(let expression): "cron \(expression)"
      case .demand: "on-demand"
      }
    }.joined(separator: "\n")
  }

  public static func schedule(from text: String) -> AutomationSchedule? {
    let lines = text.split(whereSeparator: \.isNewline).map {
      String($0).trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }
    guard !lines.isEmpty else { return nil }
    var triggers: [AutomationSchedule.Trigger] = []
    for line in lines {
      switch line {
      case "at-login":
        triggers.append(.runAtLoad)
      case "run-at-load":
        triggers.append(.runAtLoad)
      case "keep-alive":
        triggers.append(.keepAlive)
      case "on-demand":
        triggers.append(.demand)
      default:
        if line.hasPrefix("interval "),
           let seconds = Int(line.dropFirst("interval ".count)),
           seconds > 0 {
          triggers.append(.interval(seconds: seconds))
        } else if line.hasPrefix("calendar ") {
          let summary = String(line.dropFirst("calendar ".count))
          guard !summary.isEmpty else { return nil }
          triggers.append(.calendar(summary))
        } else if line.hasPrefix("cron ") {
          let expression = String(line.dropFirst("cron ".count))
          guard !expression.isEmpty else { return nil }
          triggers.append(.cron(expression))
        } else {
          return nil
        }
      }
    }
    guard Set(triggers).count == triggers.count else { return nil }
    if triggers.contains(.demand) {
      guard triggers == [.demand] else { return nil }
      return AutomationSchedule(triggers: triggers, summary: "On demand")
    }
    if triggers.contains(where: {
      if case .cron = $0 { return true }
      return false
    }) {
      guard triggers.count == 1,
            case .cron(let expression) = triggers[0] else { return nil }
      return AutomationSchedule(triggers: triggers, summary: expression)
    }
    guard triggers.filter({
      if case .interval = $0 { return true }
      return false
    }).count <= 1 else { return nil }

    if triggers.contains(.keepAlive), !triggers.contains(.runAtLoad) {
      triggers.append(.runAtLoad)
    }
    var canonical: [AutomationSchedule.Trigger] = []
    if triggers.contains(.runAtLoad) { canonical.append(.runAtLoad) }
    if triggers.contains(.keepAlive) { canonical.append(.keepAlive) }
    canonical.append(contentsOf: triggers.filter {
      if case .interval = $0 { return true }
      return false
    })
    canonical.append(contentsOf: triggers.filter {
      if case .calendar = $0 { return true }
      return false
    })
    guard canonical.count == triggers.count else { return nil }
    let summaries = canonical.map { triggerSummary($0) }
    return AutomationSchedule(triggers: canonical, summary: summaries.joined(separator: ", "))
  }

  private static func triggerSummary(_ trigger: AutomationSchedule.Trigger) -> String {
    switch trigger {
    case .atLogin, .runAtLoad: "At load"
    case .keepAlive: "Keep alive"
    case .interval(let seconds): "Every \(seconds) seconds"
    case .calendar(let summary): summary
    case .cron(let expression): expression
    case .demand: "On demand"
    }
  }

  public static func validationMessage(
    record: AutomationRecord,
    purposeIsDuplicate: Bool,
    label: String,
    executable: String,
    arguments: [String],
    environment: [String: String],
    schedule: AutomationSchedule,
    usesRawRepresentation: Bool,
    rawData: Data?,
    duplicateDestination: URL?,
    workingDirectory: String? = nil
  ) -> String? {
    guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return "A label is required."
    }
    guard !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return "An executable is required."
    }
    guard executable.hasPrefix("/"), !executable.contains("\0") else {
      return "The executable must be an absolute path without null characters."
    }
    if usesRawRepresentation {
      guard let rawData, !rawData.isEmpty else {
        return "Paste a raw representation before applying."
      }
      if record.kind == .launchAgent || record.kind == .launchDaemon {
        guard let plist = try? PropertyListSerialization.propertyList(from: rawData, format: nil) as? [String: Any] else {
          return "The raw property list is not valid."
        }
        guard plist["Label"] as? String == label else {
          return "The raw property-list label does not match the reviewed label."
        }
        let rawExecutable: String?
        let rawArguments: [String]
        if let program = plist["Program"] as? String {
          rawExecutable = program
          rawArguments = plist["ProgramArguments"] as? [String] ?? []
        } else if let programArguments = plist["ProgramArguments"] as? [String],
                  let first = programArguments.first {
          rawExecutable = first
          rawArguments = Array(programArguments.dropFirst())
        } else {
          rawExecutable = nil
          rawArguments = []
        }
        guard rawExecutable == executable, rawArguments == arguments else {
          return "The raw property-list command does not match the reviewed executable and arguments."
        }
        guard let parsed = try? LaunchdPlistParser.parse(
          data: rawData,
          sourceURL: record.sourceURL ?? URL(fileURLWithPath: "/tmp/devscope-editor.plist"),
          ownerUID: record.ownerUID ?? 0,
          ownership: record.ownership
        ),
          (plist["EnvironmentVariables"] as? [String: String] ?? [:]) == environment,
          parsed.schedule.triggers == schedule.triggers,
          plist["WorkingDirectory"] as? String == workingDirectory
        else {
          return "The raw property-list environment, schedule, or working directory does not match the reviewed fields."
        }
      } else if record.kind == .cron {
        let document = CronParser.parse(String(decoding: rawData, as: UTF8.self))
        guard document.invalidLines.isEmpty else {
          return "The raw crontab contains invalid lines."
        }
        let reviewedCommand = ([executable] + arguments).joined(separator: " ")
        let matchingReviewedEntries = document.entries.filter {
          $0.command == reviewedCommand
            && $0.schedule.triggers == schedule.triggers
            && $0.environment == environment
        }
        guard !matchingReviewedEntries.isEmpty else {
          return "The raw crontab does not contain the reviewed command, schedule, and environment."
        }
        if purposeIsDuplicate {
          let originalCount = document.entries.filter {
            $0.command == record.commandSignature
              && $0.schedule.triggers == record.schedule.triggers
              && $0.environment == record.environment
          }.count
          let requiredCount = record.commandSignature == reviewedCommand
            && record.schedule.triggers == schedule.triggers
            && record.environment == environment ? 2 : 1
          guard originalCount >= 1, matchingReviewedEntries.count >= requiredCount else {
            return "The duplicate crontab must retain the selected entry and add one reviewed entry."
          }
        }
      }
    }
    if purposeIsDuplicate && record.kind == .cron && !usesRawRepresentation {
      return "Cron duplication requires an advanced raw crontab containing the existing entries and one reviewed new entry."
    }
    if record.kind == .cron && !usesRawRepresentation {
      return "Cron edits require an advanced raw crontab containing the complete current-user document."
    }
    if !usesRawRepresentation,
       schedule.triggers.contains(where: {
         if case .calendar = $0 { return true }
         if case .cron = $0 { return true }
         return false
       }) {
      return "Calendar and cron schedules require an advanced raw source representation."
    }
    if purposeIsDuplicate && duplicateDestination == nil {
      return "Choose a label that resolves to a distinct approved destination."
    }
    return nil
  }
}

public struct AutomationImportPresentation: Equatable, Sendable {
  public let expectedKind: AutomationKind
  public let destination: URL
  public let targetLabel: String
  public let targetOwnership: String
  public let consequence: String
  public let summary: String
  public let validationMessage: String?

  public init(
    data: Data,
    expectedRecord: AutomationRecord,
    destination: URL
  ) {
    expectedKind = expectedRecord.kind
    self.destination = destination
    targetLabel = expectedRecord.label
    switch expectedRecord.ownership {
    case .user: targetOwnership = "User owned"
    case .thirdPartySystem: targetOwnership = "Third party"
    case .appleSystem: targetOwnership = "Apple system"
    case .managed: targetOwnership = "Managed"
    }
    consequence = "This import will replace \(expectedRecord.label) at its checksum-verified destination after ownership and kind are revalidated."
    switch expectedRecord.kind {
    case .launchAgent, .launchDaemon:
      if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
         let label = plist["Label"] as? String,
         !label.isEmpty {
        summary = "\(expectedRecord.kind.rawValue): \(label)"
        validationMessage = nil
      } else {
        summary = expectedRecord.kind.rawValue
        validationMessage = "The selected file is not a labeled launchd property list."
      }
    case .cron:
      let document = CronParser.parse(String(decoding: data, as: UTF8.self))
      summary = "Current-user crontab · \(document.entries.count) entries"
      if !document.invalidLines.isEmpty {
        validationMessage = "The selected crontab contains invalid lines."
      } else if !document.entries.contains(where: { $0.command == expectedRecord.commandSignature }) {
        validationMessage = "The selected crontab does not contain the reviewed automation command."
      } else {
        validationMessage = nil
      }
    case .loginItem, .backgroundItem:
      summary = expectedRecord.kind.rawValue
      validationMessage = "This automation kind does not support file import."
    }
  }

  public var canApply: Bool { validationMessage == nil }
}
