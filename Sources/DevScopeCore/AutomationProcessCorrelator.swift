import Foundation

public struct AutomationProcessLink: Equatable, Sendable {
  public let recordID: AutomationRecord.ID
  public let processIdentity: ProcessIdentity
  public let strength: AutomationEvidence.Strength
  public let evidence: [AutomationEvidence]

  public init(
    recordID: AutomationRecord.ID,
    processIdentity: ProcessIdentity,
    strength: AutomationEvidence.Strength,
    evidence: [AutomationEvidence]
  ) {
    self.recordID = recordID
    self.processIdentity = processIdentity
    self.strength = strength
    self.evidence = evidence
  }
}

struct AutomationCorrelationWork: Equatable {
  var indexedProcesses = 0
  var ancestrySteps = 0
  var cronRecordLookups = 0
  var cronCandidateEvaluations = 0
  var nonCronRecordLookups = 0
  var nonCronCandidateEvaluations = 0
}

public enum AutomationProcessCorrelator {
  public static func links(
    records: [AutomationRecord],
    processes: [DevProcess],
    now: Date,
    calendar: Calendar = .current
  ) -> [AutomationProcessLink] {
    var work = AutomationCorrelationWork()
    return links(records: records, processes: processes, now: now, calendar: calendar, work: &work)
  }

  static func links(
    records: [AutomationRecord],
    processes: [DevProcess],
    now: Date,
    calendar: Calendar = .current,
    work: inout AutomationCorrelationWork
  ) -> [AutomationProcessLink] {
    let bornProcesses = ProcessSnapshotNormalization.newestUnambiguous(processes)
      .filter { $0.birthToken != nil }
    work.indexedProcesses += bornProcesses.count
    let nonCronProcesses = nonCronIndex(processes: bornProcesses)
    let ambiguousNilLabelProvenance = ambiguousNilLabelProvenance(in: records)
    let processesByPID = Dictionary(uniqueKeysWithValues: bornProcesses.map { ($0.pid, $0) })
    let cronLineage = cronLineageByPID(processesByPID: processesByPID, work: &work)
    let cronCarriers = Dictionary(grouping: bornProcesses.compactMap { process -> (CronKey, DevProcess)? in
      guard let argv = process.argumentVector, argv.count == 3, argv[1] == "-c",
            canonicalPath(argv[0]) == canonicalPath(process.executable) else { return nil }
      return (CronKey(shell: argv[0], signature: argv[2]), process)
    }, by: \.0).mapValues { $0.map(\.1) }
    var result: [AutomationProcessLink] = []

    for record in records {
      var matchedByPID: [Int32: (DevProcess, String)] = [:]

      if record.kind == .cron {
        guard let signature = nonempty(record.commandSignature),
              record.enabledState == .enabled else { continue }
        let shell = nonempty(record.environment["SHELL"]) ?? "/bin/sh"
        work.cronRecordLookups += 1
        for process in cronCarriers[CronKey(shell: shell, signature: signature)] ?? [] {
          work.cronCandidateEvaluations += 1
          guard process.argumentVector == [shell, "-c", signature],
                cronLineage[process.parentPID] == true,
                startMatchesSchedule(process, schedule: record.schedule, now: now, calendar: calendar)
          else { continue }
          matchedByPID[process.pid] = (process, "Exact cron carrier argv, schedule minute, and ancestry")
        }
      } else {
        let allowsNilLaunchLabel = nilLabelProvenanceKey(for: record).map {
          !ambiguousNilLabelProvenance.contains($0)
        } ?? true
        if let executable = canonicalPath(record.executable) {
          work.nonCronRecordLookups += 1
          appendNonCronMatches(
            identity: .executable(executable), record: record,
            index: nonCronProcesses, allowsNilLaunchLabel: allowsNilLaunchLabel,
            work: &work, matches: &matchedByPID
          )
        }
        if let bundleIdentifier = nonempty(record.providerBundleIdentifier) {
          work.nonCronRecordLookups += 1
          appendNonCronMatches(
            identity: .bundle(bundleIdentifier), record: record,
            index: nonCronProcesses, allowsNilLaunchLabel: allowsNilLaunchLabel,
            work: &work, matches: &matchedByPID
          )
        }
      }

      for (_, match) in matchedByPID.sorted(by: { $0.key < $1.key }) {
        result.append(AutomationProcessLink(
          recordID: record.id,
          processIdentity: ProcessIdentity(process: match.0),
          strength: .strong,
          evidence: [AutomationEvidence(
            strength: .strong,
            source: "process snapshot",
            detail: match.1
          )]
        ))
      }
    }

    return result.sorted(by: linkPrecedes)
  }

  private enum NonCronIdentity: Hashable {
    case executable(String)
    case bundle(String)

    var evidenceName: String {
      switch self {
      case .executable: "executable"
      case .bundle: "bundle identity"
      }
    }
  }

  private struct NonCronKey: Hashable {
    let identity: NonCronIdentity
    let arguments: [String]
    let launchLabel: String?
  }

  private struct NilLabelProvenanceKey: Hashable {
    let executable: String
    let arguments: [String]
  }

  private static func ambiguousNilLabelProvenance(
    in records: [AutomationRecord]
  ) -> Set<NilLabelProvenanceKey> {
    var labelsByKey: [NilLabelProvenanceKey: Set<String>] = [:]
    for record in records where record.kind != .cron {
      guard let key = nilLabelProvenanceKey(for: record) else { continue }
      labelsByKey[key, default: []].insert(record.label)
    }
    return Set(labelsByKey.compactMap { key, labels in labels.count > 1 ? key : nil })
  }

  private static func nilLabelProvenanceKey(
    for record: AutomationRecord
  ) -> NilLabelProvenanceKey? {
    guard let executable = canonicalPath(record.executable) else { return nil }
    return NilLabelProvenanceKey(executable: executable, arguments: record.arguments)
  }

  private static func nonCronIndex(processes: [DevProcess]) -> [NonCronKey: [DevProcess]] {
    var result: [NonCronKey: [DevProcess]] = [:]
    for process in processes {
      guard let argumentVector = process.argumentVector,
            let executable = canonicalPath(process.executable),
            argumentVector.first.flatMap(canonicalPath) == executable else { continue }
      let arguments = Array(argumentVector.dropFirst())
      var identities: [NonCronIdentity] = [.executable(executable)]
      if let bundleIdentifier = nonempty(process.bundleIdentifier) {
        identities.append(.bundle(bundleIdentifier))
      }
      for identity in identities {
        let key = NonCronKey(
          identity: identity,
          arguments: arguments,
          launchLabel: process.launchLabel
        )
        result[key, default: []].append(process)
      }
    }
    return result
  }

  private static func appendNonCronMatches(
    identity: NonCronIdentity,
    record: AutomationRecord,
    index: [NonCronKey: [DevProcess]],
    allowsNilLaunchLabel: Bool,
    work: inout AutomationCorrelationWork,
    matches: inout [Int32: (DevProcess, String)]
  ) {
    let launchLabels: [String?] = allowsNilLaunchLabel ? [record.label, nil] : [record.label]
    for launchLabel in launchLabels {
      let key = NonCronKey(
        identity: identity,
        arguments: record.arguments,
        launchLabel: launchLabel
      )
      for process in index[key] ?? [] {
        work.nonCronCandidateEvaluations += 1
        guard hasCompatibleLaunchProvenance(process, record: record) else { continue }
        matches[process.pid] = (
          process, nonCronEvidenceDetail(identity: identity.evidenceName, process: process)
        )
      }
    }
  }

  private struct CronKey: Hashable {
    let shell: String
    let signature: String
  }

  private static func cronLineageByPID(
    processesByPID: [Int32: DevProcess],
    work: inout AutomationCorrelationWork
  ) -> [Int32: Bool] {
    var result: [Int32: Bool] = [:]
    for startPID in processesByPID.keys.sorted() where result[startPID] == nil {
      var path: [Int32] = []
      var pathSet = Set<Int32>()
      var cursor = startPID
      var resolved = false
      while let process = processesByPID[cursor] {
        work.ancestrySteps += 1
        if let cached = result[cursor] {
          resolved = cached
          break
        }
        guard pathSet.insert(cursor).inserted else {
          resolved = false
          break
        }
        path.append(cursor)
        if canonicalPath(process.executable) == "/usr/sbin/cron" {
          resolved = true
          break
        }
        cursor = process.parentPID
      }
      for processID in path.reversed() { result[processID] = resolved }
    }
    return result
  }

  private static func linkPrecedes(_ lhs: AutomationProcessLink, _ rhs: AutomationProcessLink) -> Bool {
    if lhs.processIdentity.pid != rhs.processIdentity.pid {
      return lhs.processIdentity.pid < rhs.processIdentity.pid
    }
    let lhsBirth = lhs.processIdentity.birthToken.map { ($0.seconds, $0.microseconds) } ?? (0, 0)
    let rhsBirth = rhs.processIdentity.birthToken.map { ($0.seconds, $0.microseconds) } ?? (0, 0)
    if lhsBirth != rhsBirth { return lhsBirth < rhsBirth }
    return lhs.recordID.rawValue.utf8.lexicographicallyPrecedes(rhs.recordID.rawValue.utf8)
  }

  private static func hasCompatibleLaunchProvenance(
    _ process: DevProcess,
    record: AutomationRecord
  ) -> Bool {
    if let launchLabel = process.launchLabel {
      return launchLabel == record.label
    }
    // Direct PID 1 parentage is conservative launchd-compatibility evidence only.
    // It is not a claim that the process was launched under record.label.
    return process.parentPID == 1
  }

  private static func nonCronEvidenceDetail(identity: String, process: DevProcess) -> String {
    if process.launchLabel != nil {
      return "Exact \(identity), arguments, and launch label"
    }
    return "Exact \(identity) and arguments with direct PID 1 compatibility"
  }

  private static func startMatchesSchedule(
    _ process: DevProcess,
    schedule: AutomationSchedule,
    now: Date,
    calendar: Calendar
  ) -> Bool {
    guard let elapsed = process.resourceUsage.map({ ProcessPresentation.elapsedSeconds($0.elapsedTime) }),
          elapsed >= 0 else { return false }
    let start = now.addingTimeInterval(-TimeInterval(elapsed))
    return schedule.triggers.contains { trigger in
      guard case let .cron(expression) = trigger else { return false }
      return cronExpression(expression, matches: start, calendar: calendar)
    }
  }

  private static func cronExpression(
    _ expression: String,
    matches date: Date,
    calendar: Calendar
  ) -> Bool {
    let expanded: String
    switch expression {
    case "@hourly": expanded = "0 * * * *"
    case "@daily": expanded = "0 0 * * *"
    case "@weekly": expanded = "0 0 * * 0"
    case "@monthly": expanded = "0 0 1 * *"
    case "@yearly": expanded = "0 0 1 1 *"
    case "@reboot": return false
    default: expanded = expression
    }
    let fields = expanded.split(whereSeparator: \.isWhitespace).map(String.init)
    guard fields.count == 5 else { return false }
    let components = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
    guard let minute = components.minute, let hour = components.hour, let day = components.day,
          let month = components.month, let weekday = components.weekday else { return false }
    let cronWeekday = weekday - 1
    guard let minuteField = parsedField(fields[0], range: 0...59, names: [:]),
          let hourField = parsedField(fields[1], range: 0...23, names: [:]),
          let dayField = parsedField(fields[2], range: 1...31, names: [:]),
          let monthField = parsedField(fields[3], range: 1...12, names: monthNames),
          let weekdayField = parsedField(fields[4], range: 0...7, names: weekdayNames)
    else { return false }
    let dayMatch = dayField.values.contains(day)
    let weekdayMatch = weekdayField.values.contains(cronWeekday)
      || (cronWeekday == 0 && weekdayField.values.contains(7))
    let dayConstraint = dayField.wildcardOrigin || weekdayField.wildcardOrigin
      ? dayMatch && weekdayMatch
      : dayMatch || weekdayMatch
    return minuteField.values.contains(minute)
      && hourField.values.contains(hour)
      && monthField.values.contains(month)
      && dayConstraint
  }

  private struct ParsedCronField {
    let values: Set<Int>
    let wildcardOrigin: Bool
  }

  private static func parsedField(
    _ expression: String,
    range: ClosedRange<Int>,
    names: [String: Int]
  ) -> ParsedCronField? {
    let items = expression.lowercased().split(separator: ",", omittingEmptySubsequences: false)
    guard !items.isEmpty else { return nil }
    var values = Set<Int>()
    var wildcardOrigin = false
    for item in items {
      let stepParts = item.split(separator: "/", omittingEmptySubsequences: false)
      guard stepParts.count == 1 || stepParts.count == 2 else { return nil }
      let step = stepParts.count == 2 ? Int(stepParts[1]) : 1
      guard let step, step > 0 else { return nil }
      let base = String(stepParts[0])
      let bounds: ClosedRange<Int>
      if base == "*" {
        bounds = range
        wildcardOrigin = true
      } else {
        let parts = base.split(separator: "-", omittingEmptySubsequences: false)
        // macOS crontab(5) permits steps only after `*` or an explicit range.
        guard stepParts.count == 1 || parts.count == 2 else { return nil }
        let lower = valueOf(parts.first.map(String.init) ?? "", names: names)
        let upper = parts.count == 2 ? valueOf(String(parts[1]), names: names) : lower
        guard parts.count <= 2, let lower, let upper,
              range.contains(lower), range.contains(upper), lower <= upper else { return nil }
        bounds = lower...upper
      }
      for value in bounds where (value - bounds.lowerBound).isMultiple(of: step) {
        values.insert(value)
      }
    }
    return ParsedCronField(values: values, wildcardOrigin: wildcardOrigin)
  }

  private static func valueOf(_ value: String, names: [String: Int]) -> Int? {
    names[value.lowercased()] ?? Int(value)
  }

  private static let monthNames = Dictionary(uniqueKeysWithValues:
    zip(["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"], 1...12)
  )
  private static let weekdayNames = [
    "sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6,
  ]

  private static func canonicalPath(_ value: String?) -> String? {
    guard let value = nonempty(value), value.hasPrefix("/") else { return nil }
    return URL(fileURLWithPath: value).resolvingSymlinksInPath().standardizedFileURL.path
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }
}
