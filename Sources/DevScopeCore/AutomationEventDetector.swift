import Foundation

public enum AutomationEvent: Equatable, Sendable {
  case crossedLongRunningThreshold(
    process: ProcessIdentity,
    recordID: AutomationRecord.ID?
  )
  case unexpectedExit(recordID: AutomationRecord.ID, process: ProcessIdentity)
  case repeatedFailure(recordID: AutomationRecord.ID, observedExitCount: Int)
}

public enum AutomationNotificationPreference: CaseIterable, Hashable, Sendable {
  case crossedLongRunningThreshold
  case unexpectedExit
  case repeatedFailure
}

public struct AutomationNotificationPreferences: Equatable, Sendable {
  public var crossedLongRunningThreshold: Bool
  public var unexpectedExit: Bool
  public var repeatedFailure: Bool

  public init(
    crossedLongRunningThreshold: Bool = false,
    unexpectedExit: Bool = false,
    repeatedFailure: Bool = false
  ) {
    self.crossedLongRunningThreshold = crossedLongRunningThreshold
    self.unexpectedExit = unexpectedExit
    self.repeatedFailure = repeatedFailure
  }

  public subscript(preference: AutomationNotificationPreference) -> Bool {
    get {
      switch preference {
      case .crossedLongRunningThreshold: crossedLongRunningThreshold
      case .unexpectedExit: unexpectedExit
      case .repeatedFailure: repeatedFailure
      }
    }
    set {
      switch preference {
      case .crossedLongRunningThreshold: crossedLongRunningThreshold = newValue
      case .unexpectedExit: unexpectedExit = newValue
      case .repeatedFailure: repeatedFailure = newValue
      }
    }
  }
}

public enum AutomationNotificationAuthorizationAction: Equatable, Sendable {
  case none
  case requestAuthorization
}

public struct AutomationNotificationContent: Equatable, Sendable {
  public let title: String
  public let body: String

  public init(title: String, body: String) {
    self.title = title
    self.body = body
  }
}

public struct AutomationNotificationPolicy: Sendable {
  private enum AuthorizationState: Sendable {
    case unknown
    case requesting
    case granted
    case denied
  }

  private enum EventIdentity: Hashable, Sendable {
    case crossedThreshold(ProcessIdentity, AutomationRecord.ID?)
    case unexpectedExit(AutomationRecord.ID, ProcessIdentity)
    case repeatedFailure(AutomationRecord.ID, Int)
  }

  public private(set) var preferences = AutomationNotificationPreferences()
  private let maximumRetainedEventIdentities: Int
  private var authorizationState = AuthorizationState.unknown
  private var retainedEventIdentities: Set<EventIdentity> = []
  private var retainedEventOrder: [EventIdentity] = []

  public init(maximumRetainedEventIdentities: Int = 256) {
    self.maximumRetainedEventIdentities = max(1, maximumRetainedEventIdentities)
  }

  public mutating func setPreference(
    _ preference: AutomationNotificationPreference,
    isEnabled: Bool
  ) -> AutomationNotificationAuthorizationAction {
    let wasEnabled = preferences[preference]
    preferences[preference] = isEnabled
    guard !wasEnabled, isEnabled,
          authorizationState == .unknown || authorizationState == .denied else { return .none }
    authorizationState = .requesting
    return .requestAuthorization
  }

  public mutating func recordAuthorizationResult(granted: Bool) {
    authorizationState = granted ? .granted : .denied
  }

  public mutating func notification(
    for event: AutomationEvent
  ) -> AutomationNotificationContent? {
    guard authorizationState == .granted,
          preferences[preference(for: event)] else { return nil }
    let identity = identity(for: event)
    guard retainedEventIdentities.insert(identity).inserted else { return nil }
    retainedEventOrder.append(identity)
    while retainedEventOrder.count > maximumRetainedEventIdentities {
      retainedEventIdentities.remove(retainedEventOrder.removeFirst())
    }
    return safeContent(for: event)
  }

  public mutating func recordDeliveryFailure(for event: AutomationEvent) {
    let failedIdentity = identity(for: event)
    retainedEventIdentities.remove(failedIdentity)
    retainedEventOrder.removeAll { $0 == failedIdentity }
  }

  private func preference(
    for event: AutomationEvent
  ) -> AutomationNotificationPreference {
    switch event {
    case .crossedLongRunningThreshold: .crossedLongRunningThreshold
    case .unexpectedExit: .unexpectedExit
    case .repeatedFailure: .repeatedFailure
    }
  }

  private func identity(for event: AutomationEvent) -> EventIdentity {
    switch event {
    case let .crossedLongRunningThreshold(process, recordID):
      .crossedThreshold(safeIdentity(process), recordID)
    case let .unexpectedExit(recordID, process):
      .unexpectedExit(recordID, safeIdentity(process))
    case let .repeatedFailure(recordID, observedExitCount):
      .repeatedFailure(recordID, observedExitCount)
    }
  }

  private func safeIdentity(_ identity: ProcessIdentity) -> ProcessIdentity {
    ProcessIdentity(pid: identity.pid, birthToken: identity.birthToken)
  }

  private func safeContent(for event: AutomationEvent) -> AutomationNotificationContent {
    switch event {
    case .crossedLongRunningThreshold:
      AutomationNotificationContent(
        title: "Long-running process detected",
        body: "A verified process crossed your long-running threshold."
      )
    case .unexpectedExit:
      AutomationNotificationContent(
        title: "Automation stopped unexpectedly",
        body: "A verified user automation exited unexpectedly."
      )
    case .repeatedFailure:
      AutomationNotificationContent(
        title: "Automation is repeatedly stopping",
        body: "A verified user automation stopped repeatedly."
      )
    }
  }
}

public struct AutomationEventDetector: Sendable {
  private struct PendingExit: Sendable {
    let identity: ProcessIdentity
    var completeAbsenceCount: Int
  }

  private var pendingExits: [AutomationRecord.ID: PendingExit] = [:]
  private var verifiedExitHistory: [AutomationRecord.ID: [Date]] = [:]
  private var repeatedFailureActive: Set<AutomationRecord.ID> = []

  public init() {}

  public mutating func events(
    previous: AutomationPresentationSnapshot?,
    current: AutomationPresentationSnapshot,
    now: Date
  ) -> [AutomationEvent] {
    pruneFailureHistory(now: now)
    guard let previous else {
      pendingExits.removeAll()
      return []
    }
    guard previous.isProcessSnapshotComplete, current.isProcessSnapshotComplete else {
      pendingExits.removeAll()
      return []
    }

    let thresholdEvents = crossedThresholdEvents(previous: previous, current: current)
    let exitEvents = verifiedExitEvents(previous: previous, current: current)
    var repeatedEvents: [AutomationEvent] = []
    for event in exitEvents {
      guard case let .unexpectedExit(recordID, _) = event else { continue }
      if let repeated = recordVerifiedExit(recordID: recordID, now: now) {
        repeatedEvents.append(repeated)
      }
    }
    return thresholdEvents + exitEvents + repeatedEvents.sorted(by: eventPrecedes)
  }

  private func crossedThresholdEvents(
    previous: AutomationPresentationSnapshot,
    current: AutomationPresentationSnapshot
  ) -> [AutomationEvent] {
    current.longRunningProcessIdentities
      .subtracting(previous.longRunningProcessIdentities)
      .compactMap { identity -> AutomationEvent? in
        guard identity.birthToken != nil else { return nil }
        return .crossedLongRunningThreshold(
          process: safeEventIdentity(identity),
          recordID: uniqueStrongRecordID(for: identity, in: current)
        )
      }
      .sorted(by: eventPrecedes)
  }

  private mutating func verifiedExitEvents(
    previous: AutomationPresentationSnapshot,
    current: AutomationPresentationSnapshot
  ) -> [AutomationEvent] {
    let currentRecords = Dictionary(
      current.inventory.records.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let currentLinksByRecord = Dictionary(
      grouping: current.allLinksByProcessID.values.flatMap { $0 },
      by: \.recordID
    )
    var emitted: [AutomationEvent] = []

    for recordID in pendingExits.keys.sorted(by: idPrecedes) {
      guard var pending = pendingExits[recordID],
            previousSourceWasHealthy(recordID: recordID, snapshot: previous),
            canConfirmExit(
              recordID: recordID,
              identity: pending.identity,
              current: current,
              currentRecords: currentRecords,
              currentLinksByRecord: currentLinksByRecord
            ) else {
        pendingExits.removeValue(forKey: recordID)
        continue
      }
      pending.completeAbsenceCount += 1
      if pending.completeAbsenceCount >= 2 {
        emitted.append(.unexpectedExit(
          recordID: recordID,
          process: safeEventIdentity(pending.identity)
        ))
        pendingExits.removeValue(forKey: recordID)
      } else {
        pendingExits[recordID] = pending
      }
    }

    let priorLinks = previous.allLinksByProcessID.values.flatMap { $0 }.sorted { lhs, rhs in
      if lhs.recordID != rhs.recordID { return idPrecedes(lhs.recordID, rhs.recordID) }
      return lhs.processIdentity.pid < rhs.processIdentity.pid
    }
    for link in priorLinks {
      guard pendingExits[link.recordID] == nil,
            !emitted.contains(where: { eventRecordID($0) == link.recordID }),
            link.strength == .strong,
            link.processIdentity.birthToken != nil,
            uniqueStrongRecordID(for: link.processIdentity, in: previous) == link.recordID,
            previousSourceWasHealthy(recordID: link.recordID, snapshot: previous),
            canConfirmExit(
              recordID: link.recordID,
              identity: link.processIdentity,
              current: current,
              currentRecords: currentRecords,
              currentLinksByRecord: currentLinksByRecord
            ) else { continue }
      pendingExits[link.recordID] = PendingExit(
        identity: link.processIdentity,
        completeAbsenceCount: 1
      )
    }
    return emitted.sorted(by: eventPrecedes)
  }

  private func uniqueStrongRecordID(
    for identity: ProcessIdentity,
    in snapshot: AutomationPresentationSnapshot
  ) -> AutomationRecord.ID? {
    let recordIDs = Set(
      (snapshot.allLinksByProcessID[identity.pid] ?? [])
        .filter { $0.strength == .strong && $0.processIdentity == identity }
        .map(\.recordID)
    )
    return recordIDs.count == 1 ? recordIDs.first : nil
  }

  private func previousSourceWasHealthy(
    recordID: AutomationRecord.ID,
    snapshot: AutomationPresentationSnapshot
  ) -> Bool {
    guard let record = snapshot.inventory.records.first(where: { $0.id == recordID }) else {
      return false
    }
    return snapshot.inventory.health[record.sourceKind]?.state == .healthy
  }

  private func canConfirmExit(
    recordID: AutomationRecord.ID,
    identity: ProcessIdentity,
    current: AutomationPresentationSnapshot,
    currentRecords: [AutomationRecord.ID: AutomationRecord],
    currentLinksByRecord: [AutomationRecord.ID: [AutomationProcessLink]]
  ) -> Bool {
    guard let record = currentRecords[recordID],
          record.ownership == .user,
          record.enabledState == .enabled,
          record.schedule.triggers.contains(.keepAlive),
          current.inventory.health[record.sourceKind]?.state == .healthy,
          currentLinksByRecord[recordID]?.isEmpty != false else { return false }
    return current.processIdentitiesByID[identity.pid] == nil
  }

  private mutating func recordVerifiedExit(
    recordID: AutomationRecord.ID,
    now: Date
  ) -> AutomationEvent? {
    var history = verifiedExitHistory[recordID] ?? []
    history.append(now)
    history.sort()
    verifiedExitHistory[recordID] = history
    guard history.count >= 3, !repeatedFailureActive.contains(recordID) else { return nil }
    repeatedFailureActive.insert(recordID)
    return .repeatedFailure(recordID: recordID, observedExitCount: history.count)
  }

  private mutating func pruneFailureHistory(now: Date) {
    for recordID in verifiedExitHistory.keys {
      let retained = (verifiedExitHistory[recordID] ?? []).filter { timestamp in
        let age = now.timeIntervalSince(timestamp)
        return age >= 0 && age <= 600
      }
      if retained.isEmpty {
        verifiedExitHistory.removeValue(forKey: recordID)
      } else {
        verifiedExitHistory[recordID] = retained
      }
      if retained.count < 3 { repeatedFailureActive.remove(recordID) }
    }
  }

  private func safeEventIdentity(_ identity: ProcessIdentity) -> ProcessIdentity {
    ProcessIdentity(pid: identity.pid, birthToken: identity.birthToken)
  }

  private func eventRecordID(_ event: AutomationEvent) -> AutomationRecord.ID? {
    switch event {
    case let .crossedLongRunningThreshold(_, recordID): recordID
    case let .unexpectedExit(recordID, _): recordID
    case let .repeatedFailure(recordID, _): recordID
    }
  }

  private func eventPrecedes(_ lhs: AutomationEvent, _ rhs: AutomationEvent) -> Bool {
    let lhsKey = eventKey(lhs)
    let rhsKey = eventKey(rhs)
    if lhsKey.rank != rhsKey.rank { return lhsKey.rank < rhsKey.rank }
    if lhsKey.recordID != rhsKey.recordID {
      return lhsKey.recordID.utf8.lexicographicallyPrecedes(rhsKey.recordID.utf8)
    }
    return lhsKey.pid < rhsKey.pid
  }

  private func eventKey(_ event: AutomationEvent) -> (rank: Int, recordID: String, pid: Int32) {
    switch event {
    case let .crossedLongRunningThreshold(process, recordID):
      (0, recordID?.rawValue ?? "", process.pid)
    case let .unexpectedExit(recordID, process):
      (1, recordID.rawValue, process.pid)
    case let .repeatedFailure(recordID, _):
      (2, recordID.rawValue, 0)
    }
  }

  private func idPrecedes(_ lhs: AutomationRecord.ID, _ rhs: AutomationRecord.ID) -> Bool {
    lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8)
  }
}
