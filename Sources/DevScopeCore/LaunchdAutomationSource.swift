import Darwin
import CoreFoundation
import CryptoKit
import Foundation

public struct LaunchdScanRoot: Equatable, Sendable {
  public let url: URL
  public let kind: AutomationKind
  public let ownership: AutomationOwnership
  public let isMutable: Bool

  public init(
    url: URL,
    kind: AutomationKind,
    ownership: AutomationOwnership,
    isMutable: Bool
  ) {
    self.url = url
    self.kind = kind
    self.ownership = ownership
    self.isMutable = isMutable
  }
}

public struct LaunchdRuntimeState: Equatable, Sendable {
  public let enabledState: AutomationEnabledState
  public let loadState: AutomationLoadState

  public init(
    enabledState: AutomationEnabledState,
    loadState: AutomationLoadState
  ) {
    self.enabledState = enabledState
    self.loadState = loadState
  }
}

public protocol LaunchdRuntimeStateProviding: Sendable {
  func states(
    for labels: [String],
    guiUID: uid_t
  ) async -> [String: LaunchdRuntimeState]
}

typealias LaunchdRecordParser = @Sendable (
  Data,
  URL,
  uid_t,
  AutomationOwnership,
  AutomationKind,
  Bool
) throws -> AutomationRecord

public actor LaunchdAutomationSource: AutomationSource {
  private struct CacheIdentity: Hashable, Sendable {
    let canonicalURL: URL
    let resourceIdentifier: String?
    let modificationDate: Date
    let checksum: String
    let ownerUID: uid_t
    let ownership: AutomationOwnership
    let kind: AutomationKind
    let isMutable: Bool
  }

  private struct CacheEntry: Sendable {
    let identity: CacheIdentity
    let record: AutomationRecord
  }

  public nonisolated let kind: AutomationSourceKind = .launchAgent

  private let fileSystem: any AutomationFileSystem
  private let currentUID: uid_t
  private let roots: [LaunchdScanRoot]
  private let runtimeStateProvider: (any LaunchdRuntimeStateProviding)?
  private let recordParser: LaunchdRecordParser
  private var cache: [URL: CacheEntry] = [:]

  public init(
    fileSystem: any AutomationFileSystem,
    currentUID: uid_t,
    roots: [LaunchdScanRoot],
    runtimeStateProvider: (any LaunchdRuntimeStateProviding)? = nil
  ) {
    self.fileSystem = fileSystem
    self.currentUID = currentUID
    self.roots = roots
    self.runtimeStateProvider = runtimeStateProvider
    recordParser = { data, sourceURL, ownerUID, ownership, kind, isMutable in
      try LaunchdPlistParser.parse(
        data: data,
        canonicalSourceURL: sourceURL,
        ownerUID: ownerUID,
        ownership: ownership,
        kind: kind,
        isMutable: isMutable
      )
    }
  }

  init(
    fileSystem: any AutomationFileSystem,
    currentUID: uid_t,
    roots: [LaunchdScanRoot],
    runtimeStateProvider: (any LaunchdRuntimeStateProviding)? = nil,
    recordParser: @escaping LaunchdRecordParser
  ) {
    self.fileSystem = fileSystem
    self.currentUID = currentUID
    self.roots = roots
    self.runtimeStateProvider = runtimeStateProvider
    self.recordParser = recordParser
  }

  public static func defaultRoots(homeDirectory: URL) -> [LaunchdScanRoot] {
    [
      LaunchdScanRoot(
        url: homeDirectory.appending(path: "Library/LaunchAgents"),
        kind: .launchAgent,
        ownership: .user,
        isMutable: true
      ),
      LaunchdScanRoot(
        url: URL(fileURLWithPath: "/Library/LaunchAgents"),
        kind: .launchAgent,
        ownership: .thirdPartySystem,
        isMutable: false
      ),
      LaunchdScanRoot(
        url: URL(fileURLWithPath: "/Library/LaunchDaemons"),
        kind: .launchDaemon,
        ownership: .thirdPartySystem,
        isMutable: false
      ),
      LaunchdScanRoot(
        url: URL(fileURLWithPath: "/System/Library/LaunchAgents"),
        kind: .launchAgent,
        ownership: .appleSystem,
        isMutable: false
      ),
      LaunchdScanRoot(
        url: URL(fileURLWithPath: "/System/Library/LaunchDaemons"),
        kind: .launchDaemon,
        ownership: .appleSystem,
        isMutable: false
      ),
    ]
  }

  public func snapshot() async -> AutomationSourceSnapshot {
    var records: [AutomationRecord] = []
    var errors: [String] = []
    var seenCanonicalURLs: Set<URL> = []

    for root in roots {
      let urls: [URL]
      do {
        urls = try fileSystem.plistURLs(in: root.url)
      } catch {
        errors.append("\(root.url.path): \(error)")
        continue
      }

      for url in urls {
        let metadata: AutomationFileMetadata
        do {
          metadata = try fileSystem.metadata(for: url)
        } catch {
          let finding = "Unable to inspect launchd definition: \(error)"
          errors.append("\(url.path): \(finding)")
          records.append(Self.invalidRecord(
            root: root,
            sourceURL: url.standardizedFileURL,
            ownerUID: root.ownership == .user ? currentUID : 0,
            checksum: nil,
            finding: finding
          ))
          continue
        }

        let canonicalURL = Self.canonical(metadata.canonicalURL)
        let ownerUID = metadata.ownerUID
        seenCanonicalURLs.insert(canonicalURL)
        let data: Data
        do {
          data = try fileSystem.read(url)
        } catch {
          cache.removeValue(forKey: canonicalURL)
          let finding = "Unable to read launchd definition: \(error)"
          errors.append("\(url.path): \(finding)")
          records.append(Self.invalidRecord(
            root: root,
            sourceURL: canonicalURL,
            ownerUID: ownerUID,
            checksum: nil,
            finding: finding
          ))
          continue
        }

        let isMutable = Self.isSafelyMutable(
          root: root,
          metadata: metadata,
          canonicalURL: canonicalURL,
          currentUID: currentUID
        )
        let checksum = Self.checksum(data)
        let identity = CacheIdentity(
          canonicalURL: canonicalURL,
          resourceIdentifier: metadata.resourceIdentifier,
          modificationDate: metadata.modificationDate,
          checksum: checksum,
          ownerUID: ownerUID,
          ownership: root.ownership,
          kind: root.kind,
          isMutable: isMutable
        )
        if let entry = cache[canonicalURL], entry.identity == identity {
          records.append(entry.record)
          continue
        }

        do {
          let record = try recordParser(
            data,
            canonicalURL,
            ownerUID,
            root.ownership,
            root.kind,
            isMutable
          )
          records.append(record)
          cache[canonicalURL] = CacheEntry(identity: identity, record: record)
        } catch {
          cache.removeValue(forKey: canonicalURL)
          let finding = Self.finding(for: error)
          errors.append("\(url.path): \(finding)")
          records.append(Self.invalidRecord(
            root: root,
            sourceURL: canonicalURL,
            ownerUID: ownerUID,
            checksum: checksum,
            finding: finding
          ))
        }
      }
    }

    cache = cache.filter { seenCanonicalURLs.contains($0.key) }

    if let runtimeStateProvider {
      let labels = records.compactMap { record -> String? in
        guard record.kind == .launchAgent,
              record.sourceKind == .launchAgent,
              record.ownership == .user,
              record.ownerUID == currentUID,
              !record.label.isEmpty,
              !record.label.contains("/"),
              !record.label.contains("\0")
        else { return nil }
        return record.label
      }.sorted()
      let runtimeStates = await runtimeStateProvider.states(
        for: labels,
        guiUID: currentUID
      )
      records = records.map { record in
        guard let runtimeState = runtimeStates[record.label],
              record.kind == .launchAgent,
              record.ownership == .user,
              record.ownerUID == currentUID
        else { return record }
        return Self.applying(runtimeState, to: record)
      }
    }

    if errors.isEmpty {
      return .healthy(kind: kind, records: records)
    }
    return AutomationSourceSnapshot(
      records: records,
      health: AutomationSourceHealth(
        kind: kind,
        state: records.isEmpty ? .failed : .partial,
        message: Self.healthMessage(for: errors),
        refreshedAt: Date()
      )
    )
  }

  private static func applying(
    _ runtimeState: LaunchdRuntimeState,
    to record: AutomationRecord
  ) -> AutomationRecord {
    let state: AutomationState
    switch runtimeState.enabledState {
    case .enabled:
      state = .idle
    case .disabled:
      state = .disabled
    case .unknown:
      state = .unresolved
    }
    return AutomationRecord(
      id: record.id,
      kind: record.kind,
      sourceKind: record.sourceKind,
      label: record.label,
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
      sourceURL: record.sourceURL,
      sourceChecksum: record.sourceChecksum,
      enabledState: runtimeState.enabledState,
      loadState: runtimeState.loadState,
      approvalState: record.approvalState,
      state: state,
      evidence: record.evidence,
      capabilities: record.capabilities,
      validationFindings: record.validationFindings
    )
  }

  static func healthMessage(for errors: [String]) -> String {
    precondition(!errors.isEmpty)
    let examples = errors.prefix(2).map { error in
      let compact = error.split(whereSeparator: \.isWhitespace).joined(separator: " ")
      guard compact.count > 120 else { return compact }
      return String(compact.prefix(119)) + "…"
    }
    let issueLabel = errors.count == 1 ? "issue" : "issues"
    let exampleLabel = examples.count == 1 ? "Example" : "Examples"
    return "Launchd inspection found \(errors.count) \(issueLabel). "
      + "\(exampleLabel): \(examples.joined(separator: "; ")). "
      + "Select an Invalid record for per-definition details."
  }

  private static func invalidRecord(
    root: LaunchdScanRoot,
    sourceURL: URL,
    ownerUID: uid_t,
    checksum: String?,
    finding: String
  ) -> AutomationRecord {
    let sourceURL = sourceURL.standardizedFileURL
    let label = sourceURL.deletingPathExtension().lastPathComponent
    let sourceKind: AutomationSourceKind = root.kind == .launchDaemon
      ? .launchDaemon : .launchAgent
    return AutomationRecord(
      id: AutomationRecord.ID(
        source: sourceKind,
        ownerUID: ownerUID,
        label: label,
        sourcePath: sourceURL.path
      ),
      kind: root.kind,
      sourceKind: sourceKind,
      label: label,
      displayName: label,
      providerBundleIdentifier: nil,
      ownerUID: ownerUID,
      ownership: root.ownership,
      executable: nil,
      arguments: [],
      environment: [:],
      workingDirectory: nil,
      schedule: AutomationSchedule(triggers: [.demand], summary: "Invalid definition"),
      sourceURL: sourceURL,
      sourceChecksum: checksum,
      enabledState: .unknown,
      loadState: .unknown,
      approvalState: .notApplicable,
      state: .invalid,
      evidence: [AutomationEvidence(
        strength: .weak,
        source: "launchd property list",
        detail: finding
      )],
      capabilities: [],
      validationFindings: [finding]
    )
  }

  private static func finding(for error: Error) -> String {
    switch error as? AutomationParseError {
    case .unreadablePropertyList:
      return "Unreadable property list"
    case .missingLabel:
      return "Missing required Label"
    case .missingProgram:
      return "Missing Program, BundleProgram, or ProgramArguments"
    case .invalidField(let field):
      return "Invalid \(field)"
    case nil:
      return "Unable to parse launchd definition: \(error)"
    }
  }

  private static func checksum(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func isSafelyMutable(
    root: LaunchdScanRoot,
    metadata: AutomationFileMetadata,
    canonicalURL: URL,
    currentUID: uid_t
  ) -> Bool {
    guard
      root.isMutable,
      root.kind == .launchAgent,
      root.ownership == .user,
      metadata.ownerUID == currentUID,
      !metadata.isSymbolicLink
    else {
      return false
    }

    let rootComponents = canonical(root.url).pathComponents
    let fileComponents = canonicalURL.pathComponents
    return fileComponents.count > rootComponents.count
      && fileComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
  }

  private static func canonical(_ url: URL) -> URL {
    URL(fileURLWithPath: url.standardizedFileURL.path)
  }
}

public enum LaunchdPlistParser {
  public static func parse(
    data: Data,
    sourceURL: URL,
    ownerUID: uid_t,
    ownership: AutomationOwnership
  ) throws -> AutomationRecord {
    let canonicalSourceURL = sourceURL.standardizedFileURL
    let kind: AutomationKind = canonicalSourceURL.deletingLastPathComponent().lastPathComponent
      == "LaunchDaemons" ? .launchDaemon : .launchAgent
    return try parse(
      data: data,
      canonicalSourceURL: canonicalSourceURL,
      ownerUID: ownerUID,
      ownership: ownership,
      kind: kind,
      isMutable: false
    )
  }

  static func parse(
    data: Data,
    canonicalSourceURL: URL,
    ownerUID: uid_t,
    ownership: AutomationOwnership,
    kind: AutomationKind,
    isMutable: Bool
  ) throws -> AutomationRecord {
    guard
      let plist = try? PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
      ) as? [String: Any]
    else {
      throw AutomationParseError.unreadablePropertyList
    }
    guard let labelValue = plist["Label"] else {
      throw AutomationParseError.missingLabel
    }
    guard let label = labelValue as? String, !label.isEmpty else {
      throw AutomationParseError.invalidField("Label")
    }

    let program = try optionalNonemptyString("Program", in: plist)
    let bundleProgram = try optionalNonemptyString("BundleProgram", in: plist)
    let programArguments = try optionalStringArray("ProgramArguments", in: plist)
    let environment = try optionalStringDictionary("EnvironmentVariables", in: plist) ?? [:]
    let workingDirectory = try optionalNonemptyString("WorkingDirectory", in: plist)
    let executable: String
    let arguments: [String]
    if let program {
      guard program.hasPrefix("/") else {
        throw AutomationParseError.invalidField("Program")
      }
      executable = program
      arguments = programArguments ?? []
    } else if let bundleProgram {
      guard !bundleProgram.hasPrefix("/") else {
        throw AutomationParseError.invalidField("BundleProgram")
      }
      executable = bundleProgram
      arguments = programArguments ?? []
    } else {
      guard
        let programArguments,
        let firstArgument = programArguments.first,
        !firstArgument.isEmpty
      else {
        throw AutomationParseError.missingProgram
      }
      executable = firstArgument
      arguments = Array(programArguments.dropFirst())
    }

    let schedule = try parseSchedule(plist)
    let sourceKind: AutomationSourceKind = kind == .launchDaemon ? .launchDaemon : .launchAgent
    let checksum = SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
    let capabilities: Set<AutomationCapability> = isMutable
      ? [.edit, .duplicate, .exportRecord, .remove]
      : [.exportRecord]

    return AutomationRecord(
      id: AutomationRecord.ID(
        source: sourceKind,
        ownerUID: ownerUID,
        label: label,
        sourcePath: canonicalSourceURL.path
      ),
      kind: kind,
      sourceKind: sourceKind,
      label: label,
      displayName: label,
      providerBundleIdentifier: nil,
      ownerUID: ownerUID,
      ownership: ownership,
      executable: executable,
      arguments: arguments,
      environment: environment,
      workingDirectory: workingDirectory,
      schedule: schedule,
      sourceURL: canonicalSourceURL,
      sourceChecksum: checksum,
      enabledState: .unknown,
      loadState: .unknown,
      approvalState: .notApplicable,
      state: .unresolved,
      evidence: [AutomationEvidence(
        strength: .strong,
        source: "launchd property list",
        detail: "Parsed \(canonicalSourceURL.lastPathComponent)"
      )],
      capabilities: capabilities,
      validationFindings: []
    )
  }

  private static func parseSchedule(_ plist: [String: Any]) throws -> AutomationSchedule {
    var triggers: [AutomationSchedule.Trigger] = []
    var summaries: [String] = []

    if let value = plist["RunAtLoad"] {
      guard let runAtLoad = strictBoolean(value) else {
        throw AutomationParseError.invalidField("RunAtLoad")
      }
      if runAtLoad {
        triggers.append(.runAtLoad)
        summaries.append("At load")
      }
    }

    if let value = plist["KeepAlive"] {
      if let keepAlive = strictBoolean(value) {
        if keepAlive {
          if !triggers.contains(.runAtLoad) {
            triggers.append(.runAtLoad)
            summaries.append("At load")
          }
          triggers.append(.keepAlive)
          summaries.append("kept alive")
        }
      } else if let conditions = value as? [String: Any] {
        try validateKeepAliveConditions(conditions)
        if !triggers.contains(.runAtLoad) {
          triggers.append(.runAtLoad)
          summaries.append("At load")
        }
        triggers.append(.keepAlive)
        summaries.append("kept alive conditionally")
      } else {
        throw AutomationParseError.invalidField("KeepAlive")
      }
    }

    if let value = plist["StartInterval"] {
      guard let seconds = strictInteger(value), seconds > 0 else {
        throw AutomationParseError.invalidField("StartInterval")
      }
      triggers.append(.interval(seconds: seconds))
      summaries.append(intervalSummary(seconds))
    }

    if let value = plist["StartCalendarInterval"] {
      let descriptions = try parseCalendarIntervals(value)
      triggers.append(contentsOf: descriptions.map(AutomationSchedule.Trigger.calendar))
      summaries.append(descriptions.joined(separator: "; "))
    }

    if triggers.isEmpty {
      return AutomationSchedule(triggers: [.demand], summary: "On demand")
    }
    return AutomationSchedule(triggers: triggers, summary: summaries.joined(separator: ", "))
  }

  private static func parseCalendarIntervals(_ value: Any) throws -> [String] {
    if let fields = value as? [String: Any] {
      return [try calendarSummary(fields)]
    }
    guard let intervals = value as? [[String: Any]], !intervals.isEmpty else {
      throw AutomationParseError.invalidField("StartCalendarInterval")
    }
    return try intervals.map(calendarSummary)
  }

  private static func validateKeepAliveConditions(_ conditions: [String: Any]) throws {
    let booleanKeys: Set<String> = ["SuccessfulExit", "NetworkState", "Crashed"]
    let dictionaryKeys: Set<String> = ["PathState", "OtherJobEnabled"]
    guard Set(conditions.keys).isSubset(of: booleanKeys.union(dictionaryKeys)) else {
      throw AutomationParseError.invalidField("KeepAlive")
    }

    for (key, value) in conditions {
      if booleanKeys.contains(key) {
        guard strictBoolean(value) != nil else {
          throw AutomationParseError.invalidField("KeepAlive")
        }
      } else {
        guard
          let dictionary = value as? [String: Any],
          dictionary.values.allSatisfy({ strictBoolean($0) != nil })
        else {
          throw AutomationParseError.invalidField("KeepAlive")
        }
      }
    }
  }

  private static func calendarSummary(_ fields: [String: Any]) throws -> String {
    let supportedKeys: Set<String> = ["Minute", "Hour", "Day", "Weekday", "Month"]
    guard Set(fields.keys).isSubset(of: supportedKeys) else {
      throw AutomationParseError.invalidField("StartCalendarInterval")
    }

    let minute = try calendarInteger("Minute", in: fields, range: 0...59)
    let hour = try calendarInteger("Hour", in: fields, range: 0...23)
    let day = try calendarInteger("Day", in: fields, range: 1...31)
    let weekday = try calendarInteger("Weekday", in: fields, range: 0...7)
    let month = try calendarInteger("Month", in: fields, range: 1...12)

    let weekdayNames = [
      "Sundays", "Mondays", "Tuesdays", "Wednesdays",
      "Thursdays", "Fridays", "Saturdays", "Sundays",
    ]
    let monthNames = [
      "", "January", "February", "March", "April", "May", "June",
      "July", "August", "September", "October", "November", "December",
    ]
    let weekdayDescription = weekday.map { weekdayNames[$0] }
    let dateDescription: String
    if let month {
      let monthName = monthNames[month]
      switch (day, weekdayDescription) {
      case (.some(let day), .some(let weekdayDescription)):
        dateDescription = "\(monthName) (day \(day) or \(weekdayDescription))"
      case (.some(let day), .none):
        dateDescription = "\(monthName) \(day)"
      case (.none, .some(let weekdayDescription)):
        dateDescription = "\(weekdayDescription) in \(monthName)"
      case (.none, .none):
        dateDescription = "Every \(monthName)"
      }
    } else {
      switch (day, weekdayDescription) {
      case (.some(let day), .some(let weekdayDescription)):
        dateDescription = "\(weekdayDescription) or Day \(day) of every month"
      case (.some(let day), .none):
        dateDescription = "Day \(day) of every month"
      case (.none, .some(let weekdayDescription)):
        dateDescription = weekdayDescription
      case (.none, .none):
        dateDescription = "Every day"
      }
    }

    if let hour, let minute {
      return "\(dateDescription) at \(String(format: "%02d:%02d", hour, minute))"
    }
    if let hour {
      return "\(dateDescription) during hour \(String(format: "%02d", hour))"
    }
    if let minute {
      return "\(dateDescription) at minute \(String(format: "%02d", minute)) of every hour"
    }
    return "\(dateDescription) every minute"
  }

  private static func calendarInteger(
    _ key: String,
    in fields: [String: Any],
    range: ClosedRange<Int>
  ) throws -> Int? {
    guard let value = fields[key] else { return nil }
    guard let integer = strictInteger(value), range.contains(integer) else {
      throw AutomationParseError.invalidField("StartCalendarInterval.\(key)")
    }
    return integer
  }

  private static func optionalNonemptyString(
    _ key: String,
    in plist: [String: Any]
  ) throws -> String? {
    guard let value = plist[key] else { return nil }
    guard let string = value as? String, !string.isEmpty else {
      throw AutomationParseError.invalidField(key)
    }
    return string
  }

  private static func optionalStringArray(
    _ key: String,
    in plist: [String: Any]
  ) throws -> [String]? {
    guard let value = plist[key] else { return nil }
    guard let values = value as? [Any], values.allSatisfy({ $0 is String }) else {
      throw AutomationParseError.invalidField(key)
    }
    return values.compactMap { $0 as? String }
  }

  private static func optionalStringDictionary(
    _ key: String,
    in plist: [String: Any]
  ) throws -> [String: String]? {
    guard let value = plist[key] else { return nil }
    guard let dictionary = value as? [String: Any],
          dictionary.keys.allSatisfy({ !$0.isEmpty }),
          dictionary.values.allSatisfy({ $0 is String }) else {
      throw AutomationParseError.invalidField(key)
    }
    return dictionary.reduce(into: [String: String]()) { result, entry in
      result[entry.key] = entry.value as? String
    }
  }

  private static func strictBoolean(_ value: Any) -> Bool? {
    guard
      let number = value as? NSNumber,
      CFGetTypeID(number) == CFBooleanGetTypeID()
    else {
      return nil
    }
    return number.boolValue
  }

  private static func strictInteger(_ value: Any) -> Int? {
    guard
      let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      let integer = value as? Int
    else {
      return nil
    }
    return integer
  }

  private static func intervalSummary(_ seconds: Int) -> String {
    if seconds.isMultiple(of: 3_600) {
      let hours = seconds / 3_600
      return "Every \(hours) \(hours == 1 ? "hour" : "hours")"
    }
    if seconds.isMultiple(of: 60) {
      let minutes = seconds / 60
      return "Every \(minutes) \(minutes == 1 ? "minute" : "minutes")"
    }
    return "Every \(seconds) \(seconds == 1 ? "second" : "seconds")"
  }
}
