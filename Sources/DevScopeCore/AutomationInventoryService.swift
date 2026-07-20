import Foundation

public struct AutomationInventorySnapshot: Equatable, Sendable {
  public let generation: UInt64
  public let records: [AutomationRecord]
  public let health: [AutomationSourceKind: AutomationSourceHealth]
  public let refreshedAt: Date

  public init(
    generation: UInt64,
    records: [AutomationRecord],
    health: [AutomationSourceKind: AutomationSourceHealth],
    refreshedAt: Date
  ) {
    self.generation = generation
    self.records = records
    self.health = health
    self.refreshedAt = refreshedAt
  }
}

public actor AutomationInventoryService {
  private struct InFlightRefresh: Sendable {
    let id: UInt64
    let task: Task<AutomationInventorySnapshot, Never>
  }

  private struct InFlightSourceRefresh: Sendable {
    let id: UInt64
    let task: Task<AutomationSourceSnapshot, Never>
  }

  private let sources: [any AutomationSource]
  private let minimumRefreshInterval: TimeInterval
  private let sourceTimeout: Duration
  private let now: @Sendable () -> Date
  private var cachedSnapshot: AutomationInventorySnapshot?
  private var inFlightRefresh: InFlightRefresh?
  private var inFlightSourceRefreshes: [Int: InFlightSourceRefresh] = [:]
  private var nextRefreshID: UInt64 = 0
  private var nextSourceRefreshID: UInt64 = 0

  public init(
    sources: [any AutomationSource],
    minimumRefreshInterval: TimeInterval = 60,
    sourceTimeout: Duration = .seconds(10),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.sources = sources
    self.minimumRefreshInterval = max(0, minimumRefreshInterval)
    self.sourceTimeout = max(.milliseconds(1), sourceTimeout)
    self.now = now
  }

  public func refresh(force: Bool = false) async -> AutomationInventorySnapshot {
    let refreshDate = now()
    if !force,
       let cachedSnapshot,
       refreshDate.timeIntervalSince(cachedSnapshot.refreshedAt) < minimumRefreshInterval
    {
      return cachedSnapshot
    }
    if let inFlightRefresh {
      return await complete(inFlightRefresh)
    }

    let generation = (cachedSnapshot?.generation ?? 0) + 1
    let sourceTimeout = self.sourceTimeout
    let task = Task {
      let sourceSnapshots = await refreshSources(
        timeout: sourceTimeout,
        refreshedAt: refreshDate
      )
      let health = Self.aggregatedHealth(sourceSnapshots)
      let records = Self.deduplicated(sourceSnapshots.flatMap(\.records))
      return AutomationInventorySnapshot(
        generation: generation,
        records: records,
        health: health,
        refreshedAt: refreshDate
      )
    }
    nextRefreshID &+= 1
    let inFlight = InFlightRefresh(id: nextRefreshID, task: task)
    inFlightRefresh = inFlight
    return await complete(inFlight)
  }

  public func refreshAfterCurrent() async -> AutomationInventorySnapshot {
    if let inFlightRefresh {
      _ = await complete(inFlightRefresh)
    }
    return await refresh(force: true)
  }

  private func complete(
    _ refresh: InFlightRefresh
  ) async -> AutomationInventorySnapshot {
    let snapshot = await refresh.task.value
    if inFlightRefresh?.id == refresh.id {
      cachedSnapshot = snapshot
      inFlightRefresh = nil
    }
    return snapshot
  }

  private func refreshSources(
    timeout: Duration,
    refreshedAt: Date
  ) async -> [AutomationSourceSnapshot] {
    let sources = self.sources
    return await withTaskGroup(
      of: (Int, AutomationSourceSnapshot).self,
      returning: [AutomationSourceSnapshot].self
    ) { group in
      for (index, source) in sources.enumerated() {
        group.addTask { [weak self] in
          guard let self else {
            return (
              index,
              .failed(
                kind: source.kind,
                message: "Automation inventory service became unavailable.",
                refreshedAt: refreshedAt
              )
            )
          }
          return (
            index,
            await self.refreshSource(
              at: index,
              source,
              timeout: timeout,
              refreshedAt: refreshedAt
            )
          )
        }
      }

      var indexed: [(Int, AutomationSourceSnapshot)] = []
      for await value in group {
        indexed.append(value)
      }
      return indexed.sorted { $0.0 < $1.0 }.map(\.1)
    }
  }

  private enum SourceRefreshOutcome: Sendable {
    case snapshot(AutomationSourceSnapshot)
    case timedOut
    case cancelled
  }

  private final class SourceRefreshResolution: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SourceRefreshOutcome, Never>?

    init(_ continuation: CheckedContinuation<SourceRefreshOutcome, Never>) {
      self.continuation = continuation
    }

    func resolve(_ outcome: SourceRefreshOutcome) {
      let continuation = lock.withLock {
        defer { self.continuation = nil }
        return self.continuation
      }
      continuation?.resume(returning: outcome)
    }
  }

  private func refreshSource(
    at index: Int,
    _ source: any AutomationSource,
    timeout: Duration,
    refreshedAt: Date
  ) async -> AutomationSourceSnapshot {
    if inFlightSourceRefreshes[index] != nil {
      return .failed(
        kind: source.kind,
        message: "A previous timed-out automation source refresh is still completing; a new call was not started.",
        refreshedAt: refreshedAt
      )
    }

    nextSourceRefreshID &+= 1
    let refreshID = nextSourceRefreshID
    let sourceTask = Task { await source.snapshot() }
    inFlightSourceRefreshes[index] = InFlightSourceRefresh(id: refreshID, task: sourceTask)
    Task { [weak self] in
      _ = await sourceTask.value
      await self?.sourceRefreshCompleted(at: index, id: refreshID)
    }

    let first = await Self.firstOutcome(of: sourceTask, timeout: timeout)
    switch first {
    case let .snapshot(snapshot):
      sourceRefreshCompleted(at: index, id: refreshID)
      return snapshot
    case .timedOut:
      return .failed(
        kind: source.kind,
        message: "Automation source refresh exceeded its configured time limit.",
        refreshedAt: refreshedAt
      )
    case .cancelled:
      return .failed(
        kind: source.kind,
        message: "Automation source refresh was cancelled.",
        refreshedAt: refreshedAt
      )
    }
  }

  private func sourceRefreshCompleted(at index: Int, id: UInt64) {
    guard inFlightSourceRefreshes[index]?.id == id else { return }
    inFlightSourceRefreshes[index] = nil
  }

  private static func firstOutcome(
    of sourceTask: Task<AutomationSourceSnapshot, Never>,
    timeout: Duration
  ) async -> SourceRefreshOutcome {
    await withCheckedContinuation {
      (continuation: CheckedContinuation<SourceRefreshOutcome, Never>) in
      let resolution = SourceRefreshResolution(continuation)
      Task {
        resolution.resolve(.snapshot(await sourceTask.value))
      }
      Task {
        do {
          try await Task.sleep(for: timeout)
          resolution.resolve(.timedOut)
        } catch is CancellationError {
          resolution.resolve(.cancelled)
        } catch {
          resolution.resolve(.cancelled)
        }
        sourceTask.cancel()
      }
    }
  }

  private static func aggregatedHealth(
    _ snapshots: [AutomationSourceSnapshot]
  ) -> [AutomationSourceKind: AutomationSourceHealth] {
    snapshots.reduce(into: [:]) { result, snapshot in
      let kind = snapshot.health.kind
      guard let existing = result[kind] else {
        result[kind] = snapshot.health
        return
      }
      result[kind] = worseHealth(existing, snapshot.health)
    }
  }

  private static func worseHealth(
    _ lhs: AutomationSourceHealth,
    _ rhs: AutomationSourceHealth
  ) -> AutomationSourceHealth {
    let lhsRank = healthRank(lhs.state)
    let rhsRank = healthRank(rhs.state)
    if lhsRank != rhsRank { return lhsRank > rhsRank ? lhs : rhs }
    if lhs.refreshedAt != rhs.refreshedAt { return lhs.refreshedAt > rhs.refreshedAt ? lhs : rhs }
    return (lhs.message ?? "") <= (rhs.message ?? "") ? lhs : rhs
  }

  private static func healthRank(_ state: AutomationSourceHealthState) -> Int {
    switch state {
    case .healthy: 0
    case .partial: 1
    case .permissionRequired: 2
    case .failed: 3
    }
  }

  private static func deduplicated(_ records: [AutomationRecord]) -> [AutomationRecord] {
    var groups: [[AutomationRecord]] = []

    for record in records.sorted(by: recordPrecedes) {
      let matchingIndexes = groups.indices.filter { groupIndex in
        groups[groupIndex].contains { exactIdentityMatches($0, record) }
      }
      var mergedGroup = [record]
      var mergedIndexes: [Int] = []
      for index in matchingIndexes where !strongIdentityConflicts(groups[index], mergedGroup) {
        mergedGroup.append(contentsOf: groups[index])
        mergedIndexes.append(index)
      }
      guard !mergedIndexes.isEmpty else {
        groups.append([record])
        continue
      }

      for index in mergedIndexes.reversed() {
        groups.remove(at: index)
      }
      groups.append(mergedGroup)
    }

    return groups
      .map(mergedRecord)
      .sorted(by: recordPrecedes)
  }

  private static func exactIdentityMatches(
    _ lhs: AutomationRecord,
    _ rhs: AutomationRecord
  ) -> Bool {
    if let lhsBundle = nonempty(lhs.providerBundleIdentifier),
       let rhsBundle = nonempty(rhs.providerBundleIdentifier),
       lhsBundle == rhsBundle
    {
      return true
    }

    if lhs.label == rhs.label,
       !lhs.label.isEmpty,
       let lhsExecutable = canonicalPath(lhs.executable),
       let rhsExecutable = canonicalPath(rhs.executable),
       lhsExecutable == rhsExecutable
    {
      return true
    }

    if let lhsSource = lhs.sourceURL?.standardizedFileURL,
       let rhsSource = rhs.sourceURL?.standardizedFileURL,
       lhsSource == rhsSource
    {
      return true
    }
    return false
  }

  private static func strongIdentityConflicts(
    _ lhs: [AutomationRecord],
    _ rhs: [AutomationRecord]
  ) -> Bool {
    valuesConflict(
      Set(lhs.compactMap { nonempty($0.providerBundleIdentifier) }),
      Set(rhs.compactMap { nonempty($0.providerBundleIdentifier) })
    ) || valuesConflict(
      Set(lhs.compactMap(labelExecutableIdentity)),
      Set(rhs.compactMap(labelExecutableIdentity))
    ) || valuesConflict(
      Set(lhs.compactMap(canonicalSourceReference)),
      Set(rhs.compactMap(canonicalSourceReference))
    )
  }

  private static func valuesConflict<Value: Hashable>(
    _ lhs: Set<Value>,
    _ rhs: Set<Value>
  ) -> Bool {
    !lhs.isEmpty && !rhs.isEmpty && lhs != rhs
  }

  private static func labelExecutableIdentity(_ record: AutomationRecord) -> String? {
    guard !record.label.isEmpty, let executable = canonicalPath(record.executable) else {
      return nil
    }
    return "\(record.label)\u{0}\(executable)"
  }

  private static func canonicalSourceReference(_ record: AutomationRecord) -> URL? {
    record.sourceURL?.standardizedFileURL
  }

  private static func mergedRecord(_ records: [AutomationRecord]) -> AutomationRecord {
    let primary = records.sorted(by: recordPrecedes).first!
    let evidence = Array(Set(records.flatMap(\.evidence))).sorted {
      if $0.strength != $1.strength { return $0.strength > $1.strength }
      if $0.source != $1.source { return $0.source < $1.source }
      return $0.detail < $1.detail
    }

    return AutomationRecord(
      id: primary.id,
      kind: primary.kind,
      sourceKind: primary.sourceKind,
      label: primary.label,
      displayName: primary.displayName,
      providerBundleIdentifier: primary.providerBundleIdentifier,
      ownerUID: primary.ownerUID,
      ownership: primary.ownership,
      executable: primary.executable,
      arguments: primary.arguments,
      commandSignature: primary.commandSignature,
      environment: primary.environment,
      workingDirectory: primary.workingDirectory,
      schedule: primary.schedule,
      sourceURL: primary.sourceURL,
      sourceChecksum: primary.sourceChecksum,
      enabledState: primary.enabledState,
      loadState: primary.loadState,
      approvalState: primary.approvalState,
      state: primary.state,
      evidence: evidence,
      capabilities: primary.capabilities,
      validationFindings: Array(Set(records.flatMap(\.validationFindings))).sorted()
    )
  }

  private static func recordPrecedes(_ lhs: AutomationRecord, _ rhs: AutomationRecord) -> Bool {
    let lhsRank = recordRank(lhs)
    let rhsRank = recordRank(rhs)
    if lhsRank != rhsRank { return lhsRank.lexicographicallyPrecedes(rhsRank) }
    let lhsCapabilities = lhs.capabilities.map(\.rawValue).sorted(by: utf8Precedes)
    let rhsCapabilities = rhs.capabilities.map(\.rawValue).sorted(by: utf8Precedes)
    if lhsCapabilities != rhsCapabilities {
      return utf8SequencePrecedes(lhsCapabilities, rhsCapabilities)
    }
    return recordOrderingKey(lhs).lexicographicallyPrecedes(recordOrderingKey(rhs))
  }

  private static func utf8SequencePrecedes(_ lhs: [String], _ rhs: [String]) -> Bool {
    for (lhsValue, rhsValue) in zip(lhs, rhs) where lhsValue != rhsValue {
      return utf8Precedes(lhsValue, rhsValue)
    }
    return lhs.count < rhs.count
  }

  private static func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
  }

  // This total key exists only for in-memory comparisons. It must never be persisted,
  // logged, or copied into diagnostics because it can contain commands and local paths.
  private static func recordOrderingKey(_ record: AutomationRecord) -> [UInt8] {
    var key = CanonicalOrderingKey()

    // Capability choice affects the surviving primary record, so compare the exact set
    // before any descriptive or identity fields once the policy rank is tied.
    key.append(record.capabilities.map(\.rawValue).sorted())
    key.append(record.sourceURL?.standardizedFileURL.path)
    key.append(record.sourceKind.rawValue)
    key.append(record.kind.rawValue)
    key.append(record.ownership.rawValue)
    key.append(record.state.rawValue)
    key.append(record.enabledState.rawValue)
    key.append(record.loadState.rawValue)
    key.append(record.approvalState.rawValue)
    key.append(canonicalPath(record.executable))
    key.append(record.arguments)
    key.append(record.commandSignature)
    key.append(record.providerBundleIdentifier)
    key.append(record.ownerUID.map(UInt64.init))
    appendSchedule(record.schedule, to: &key)
    appendCanonicalEvidence(record.evidence, to: &key)
    key.append(record.validationFindings.sorted(by: utf8Precedes))

    // Remaining exact value fields make the comparison total even when canonical forms
    // above intentionally normalize equivalent paths or collection ordering.
    key.append(record.label)
    key.append(record.id.rawValue)
    key.append(record.displayName)
    key.append(record.executable)
    appendEnvironment(record.environment, to: &key)
    key.append(canonicalPath(record.workingDirectory))
    key.append(record.workingDirectory)
    key.append(record.sourceURL?.absoluteString)
    key.append(record.sourceURL?.relativeString)
    key.append(record.sourceURL?.baseURL?.absoluteString)
    key.append(record.sourceChecksum)
    appendEvidenceInOriginalOrder(record.evidence, to: &key)
    key.append(record.validationFindings)
    return key.bytes
  }

  private static func appendEnvironment(
    _ environment: [String: String],
    to key: inout CanonicalOrderingKey
  ) {
    let entries = environment.sorted {
      if $0.key != $1.key { return $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
      return $0.value.utf8.lexicographicallyPrecedes($1.value.utf8)
    }
    key.appendCount(entries.count)
    for entry in entries {
      key.append(entry.key)
      key.append(entry.value)
    }
  }

  private static func appendSchedule(
    _ schedule: AutomationSchedule,
    to key: inout CanonicalOrderingKey
  ) {
    key.appendCount(schedule.triggers.count)
    for trigger in schedule.triggers {
      switch trigger {
      case .atLogin:
        key.append("atLogin")
      case .runAtLoad:
        key.append("runAtLoad")
      case let .interval(seconds):
        key.append("interval")
        key.append(Int64(seconds))
      case let .calendar(value):
        key.append("calendar")
        key.append(value)
      case .keepAlive:
        key.append("keepAlive")
      case let .cron(value):
        key.append("cron")
        key.append(value)
      case .demand:
        key.append("demand")
      }
    }
    key.append(schedule.summary)
  }

  private static func appendCanonicalEvidence(
    _ evidence: [AutomationEvidence],
    to key: inout CanonicalOrderingKey
  ) {
    let sorted = evidence.sorted {
      if $0.strength != $1.strength { return $0.strength.rawValue < $1.strength.rawValue }
      if $0.source != $1.source {
        return $0.source.utf8.lexicographicallyPrecedes($1.source.utf8)
      }
      return $0.detail.utf8.lexicographicallyPrecedes($1.detail.utf8)
    }
    appendEvidenceInOriginalOrder(sorted, to: &key)
  }

  private static func appendEvidenceInOriginalOrder(
    _ evidence: [AutomationEvidence],
    to key: inout CanonicalOrderingKey
  ) {
    key.appendCount(evidence.count)
    for item in evidence {
      key.append(Int64(item.strength.rawValue))
      key.append(item.source)
      key.append(item.detail)
    }
  }

  private static func recordRank(_ record: AutomationRecord) -> [Int] {
    [
      record.ownership == .user ? 0 : 1,
      -record.capabilities.count,
      sourceRank(record.sourceKind),
    ]
  }

  private static func sourceRank(_ kind: AutomationSourceKind) -> Int {
    switch kind {
    case .launchAgent: 0
    case .legacyLoginItem: 1
    case .crontab: 2
    case .launchDaemon: 3
    case .serviceManagement: 4
    }
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  private static func canonicalPath(_ value: String?) -> String? {
    guard let value = nonempty(value) else { return nil }
    return URL(fileURLWithPath: value).standardizedFileURL.path
  }
}

private struct CanonicalOrderingKey {
  private(set) var bytes: [UInt8] = []

  mutating func append(_ value: String) {
    let utf8 = Array(value.utf8)
    append(UInt64(utf8.count))
    bytes.append(contentsOf: utf8)
  }

  mutating func append(_ value: String?) {
    guard let value else {
      bytes.append(0)
      return
    }
    bytes.append(1)
    append(value)
  }

  mutating func append(_ values: [String]) {
    appendCount(values.count)
    for value in values {
      append(value)
    }
  }

  mutating func append(_ value: UInt64?) {
    guard let value else {
      bytes.append(0)
      return
    }
    bytes.append(1)
    append(value)
  }

  mutating func append(_ value: Int64) {
    append(UInt64(bitPattern: value) ^ (1 << 63))
  }

  mutating func appendCount(_ count: Int) {
    append(UInt64(count))
  }

  private mutating func append(_ value: UInt64) {
    for shift in stride(from: 56, through: 0, by: -8) {
      bytes.append(UInt8(truncatingIfNeeded: value >> shift))
    }
  }
}
