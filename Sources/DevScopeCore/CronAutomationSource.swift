import CryptoKit
import Darwin
import Foundation

public struct CronDocument: Equatable, Sendable {
  public let originalText: String
  public let originalLines: [String]
  public let environmentAssignments: [CronEnvironmentAssignment]
  public let environment: [String: String]
  public let entries: [CronEntry]
  public let invalidLines: [CronInvalidLine]
}

public enum CronDocumentChecksum {
  public static func normalizedData(_ data: Data) -> Data? {
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    var normalized = text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    while normalized.hasSuffix("\n") {
      normalized.removeLast()
    }
    normalized.append("\n")
    return Data(normalized.utf8)
  }

  public static func checksum(_ data: Data) -> String? {
    normalizedData(data).map {
      SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
    }
  }
}

public struct CronEnvironmentAssignment: Equatable, Sendable {
  public let lineNumber: Int
  public let name: String
  public let value: String
}

public struct CronInvalidLine: Equatable, Sendable {
  public let lineNumber: Int
  public let content: String
  public let reason: String
}

public struct CronEntry: Identifiable, Equatable, Sendable {
  public let id: String
  public let lineNumber: Int
  public let scheduleExpression: String
  public let command: String
  public let isEnabled: Bool
  public let environment: [String: String]
  public let schedule: AutomationSchedule
}

public enum CronParser {
  private static let disabledPrefix = "# devscope-disabled: "

  public static func parse(_ text: String) -> CronDocument {
    let lines = text.components(separatedBy: "\n")
    var environment: [String: String] = [:]
    var environmentAssignments: [CronEnvironmentAssignment] = []
    var entries: [CronEntry] = []
    var invalidLines: [CronInvalidLine] = []
    var scheduleOccurrences: [String: Int] = [:]

    for (offset, originalLine) in lines.enumerated() {
      let lineNumber = offset + 1
      let trimmed = originalLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }

      let isDisabled = trimmed.hasPrefix(disabledPrefix)
      if trimmed.hasPrefix("#"), !isDisabled { continue }

      if let assignment = environmentAssignment(in: trimmed) {
        environment[assignment.name] = assignment.value
        environmentAssignments.append(CronEnvironmentAssignment(
          lineNumber: lineNumber,
          name: assignment.name,
          value: assignment.value
        ))
        continue
      }

      let isEnabled = !isDisabled
      let candidate = isEnabled ? trimmed : String(trimmed.dropFirst(disabledPrefix.count))
      guard let parsed = parseEntry(candidate) else {
        invalidLines.append(CronInvalidLine(
          lineNumber: lineNumber,
          content: originalLine,
          reason: "Invalid crontab line"
        ))
        continue
      }

      let occurrence = scheduleOccurrences[parsed.expression, default: 0]
      scheduleOccurrences[parsed.expression] = occurrence + 1
      entries.append(CronEntry(
        id: stableEntryID(scheduleExpression: parsed.expression, occurrence: occurrence),
        lineNumber: lineNumber,
        scheduleExpression: parsed.expression,
        command: parsed.command,
        isEnabled: isEnabled,
        environment: environment,
        schedule: parsed.schedule
      ))
    }

    return CronDocument(
      originalText: text,
      originalLines: lines,
      environmentAssignments: environmentAssignments,
      environment: environment,
      entries: entries,
      invalidLines: invalidLines
    )
  }

  public static func recordID(for entry: CronEntry, ownerUID: uid_t) -> AutomationRecord.ID {
    AutomationRecord.ID(
      source: .crontab,
      ownerUID: ownerUID,
      label: "cron-entry",
      sourcePath: "/.devscope/current-user-crontab/\(entry.id)"
    )
  }

  private static func environmentAssignment(in line: String) -> (name: String, value: String)? {
    guard let equals = line.firstIndex(of: "=") else { return nil }
    let rawName = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
    let name: String
    if let quote = rawName.first, quote == "\"" || quote == "'" {
      guard rawName.count >= 2, rawName.last == quote else { return nil }
      name = String(rawName.dropFirst().dropLast())
    } else {
      guard !rawName.contains(where: \.isWhitespace),
            !rawName.contains("\""),
            !rawName.contains("'")
      else { return nil }
      name = String(rawName)
    }
    guard !name.isEmpty else { return nil }

    var value = line[line.index(after: equals)...]
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let quote = value.first, quote == "\"" || quote == "'" {
      guard value.count >= 2, value.last == quote else { return nil }
      value = String(value.dropFirst().dropLast())
    }
    return (name, String(value))
  }

  private static func parseEntry(
    _ line: String
  ) -> (expression: String, command: String, schedule: AutomationSchedule)? {
    let firstFields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
    guard !firstFields.isEmpty else { return nil }

    if firstFields[0].hasPrefix("@") {
      guard firstFields.count == 2 else { return nil }
      let expression = String(firstFields[0])
      let summary: String
      switch expression {
      case "@reboot": summary = "At startup"
      case "@hourly": summary = "Hourly"
      case "@daily": summary = "Daily"
      case "@weekly": summary = "Weekly"
      case "@monthly": summary = "Monthly"
      case "@yearly": summary = "Yearly"
      default: return nil
      }
      return (
        expression,
        String(firstFields[1]),
        AutomationSchedule(triggers: [.cron(expression)], summary: summary)
      )
    }

    let fields = line.split(maxSplits: 5, whereSeparator: \.isWhitespace)
    guard fields.count == 6 else { return nil }
    let specifications = [
      CronFieldSpecification(minimum: 0, maximum: 59),
      CronFieldSpecification(minimum: 0, maximum: 23),
      CronFieldSpecification(minimum: 1, maximum: 31),
      CronFieldSpecification(
        minimum: 1,
        maximum: 12,
        names: ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
      ),
      CronFieldSpecification(
        minimum: 0,
        maximum: 7,
        names: ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
      ),
    ]
    guard zip(fields.prefix(5), specifications).allSatisfy({ field, specification in
      isValid(field: String(field), specification: specification)
    }) else { return nil }

    let expression = fields.prefix(5).joined(separator: " ")
    let summary = expression == "0 9 * * 1" ? "Mondays at 09:00" : "Cron: \(expression)"
    return (
      expression,
      String(fields[5]),
      AutomationSchedule(triggers: [.cron(expression)], summary: summary)
    )
  }

  private struct CronFieldSpecification {
    let minimum: Int
    let maximum: Int
    var names: Set<String> = []
  }

  private static func isValid(
    field: String,
    specification: CronFieldSpecification
  ) -> Bool {
    if specification.names.contains(field.lowercased()) {
      return true
    }

    let items = field.split(separator: ",", omittingEmptySubsequences: false)
    guard !items.isEmpty,
          items.count == 1 || !items.contains(where: { $0.contains("*") })
    else { return false }
    return items.allSatisfy { item in
      let stepParts = item.split(separator: "/", omittingEmptySubsequences: false)
      guard stepParts.count == 1 || stepParts.count == 2 else { return false }
      let base = String(stepParts[0])

      if stepParts.count == 2 {
        guard isASCIIDigits(stepParts[1]),
              let step = Int(stepParts[1]), step > 0,
              base == "*" || base.contains("-")
        else { return false }
      }

      if base == "*" { return true }
      let rangeParts = base.split(separator: "-", omittingEmptySubsequences: false)
      if rangeParts.count == 2 {
        guard isASCIIDigits(rangeParts[0]),
              isASCIIDigits(rangeParts[1]),
              let lower = Int(rangeParts[0]),
              let upper = Int(rangeParts[1]),
              specification.minimum...specification.maximum ~= lower,
              specification.minimum...specification.maximum ~= upper
        else { return false }
        return lower <= upper
      }
      guard rangeParts.count == 1,
            isASCIIDigits(base),
            let value = Int(base)
      else { return false }
      return specification.minimum...specification.maximum ~= value
    }
  }

  private static func isASCIIDigits<S: StringProtocol>(_ value: S) -> Bool {
    !value.isEmpty && value.allSatisfy { character in
      character >= "0" && character <= "9"
    }
  }

  private static func stableEntryID(scheduleExpression: String, occurrence: Int) -> String {
    var identity = Data("devscope-crontab-entry\0".utf8)
    identity.append(Data(scheduleExpression.utf8))
    identity.append(0)
    identity.append(Data(String(occurrence).utf8))
    return SHA256.hash(data: identity)
      .map { String(format: "%02x", $0) }
      .joined()
  }
}

public struct CronAutomationSource: AutomationSource {
  public let kind: AutomationSourceKind = .crontab

  private let commandRunner: any AutomationCommandRunning
  private let currentUID: uid_t
  private let currentUsername: String

  public init(
    commandRunner: any AutomationCommandRunning,
    currentUID: uid_t,
    currentUsername: String
  ) {
    self.commandRunner = commandRunner
    self.currentUID = currentUID
    self.currentUsername = currentUsername
  }

  public func snapshot() async -> AutomationSourceSnapshot {
    let result: AutomationCommandResult
    do {
      result = try await commandRunner.run(AutomationCommand(
        executable: "/usr/bin/crontab",
        arguments: ["-l"],
        environment: ["LC_ALL": "C"]
      ))
    } catch {
      return .failed(
        kind: kind,
        message: "Unable to list the current-user crontab."
      )
    }

    if result.status == 1,
       result.standardOutput.isEmpty,
       Self.isNoCrontabDiagnostic(
         result.standardError,
         currentUsername: currentUsername
       )
    {
      return .healthy(kind: kind, records: [])
    }
    guard result.status == 0 else {
      return .failed(
        kind: kind,
        message: "Unable to list the current-user crontab (exit status \(result.status))."
      )
    }
    guard let text = String(data: result.standardOutput, encoding: .utf8) else {
      return .failed(
        kind: kind,
        message: "The current-user crontab is not valid UTF-8."
      )
    }

    let document = CronParser.parse(text)
    guard let documentChecksum = CronDocumentChecksum.checksum(result.standardOutput) else {
      return .failed(
        kind: kind,
        message: "The current-user crontab is not valid UTF-8."
      )
    }
    let entryRecords = document.entries.enumerated().map { index, entry in
      Self.record(
        for: entry,
        index: index,
        ownerUID: currentUID,
        documentChecksum: documentChecksum
      )
    }
    let invalidRecords = document.invalidLines.map {
      Self.invalidRecord(for: $0, ownerUID: currentUID, documentChecksum: documentChecksum)
    }
    let records = entryRecords + invalidRecords
    guard !invalidRecords.isEmpty else {
      return .healthy(kind: kind, records: records)
    }

    let count = invalidRecords.count
    return AutomationSourceSnapshot(
      records: records,
      health: AutomationSourceHealth(
        kind: kind,
        state: .partial,
        message: "\(count) invalid crontab line\(count == 1 ? "." : "s.")",
        refreshedAt: Date()
      )
    )
  }

  private static func record(
    for entry: CronEntry,
    index: Int,
    ownerUID: uid_t,
    documentChecksum: String
  ) -> AutomationRecord {
    let label = "Cron entry \(index + 1)"
    return AutomationRecord(
      id: CronParser.recordID(for: entry, ownerUID: ownerUID),
      kind: .cron,
      sourceKind: .crontab,
      label: label,
      displayName: label,
      providerBundleIdentifier: nil,
      ownerUID: ownerUID,
      ownership: .user,
      executable: nil,
      arguments: [],
      commandSignature: entry.command,
      environment: entry.environment,
      workingDirectory: nil,
      schedule: entry.schedule,
      sourceURL: nil,
      sourceChecksum: documentChecksum,
      enabledState: entry.isEnabled ? .enabled : .disabled,
      loadState: .unknown,
      approvalState: .notApplicable,
      state: entry.isEnabled ? .idle : .disabled,
      evidence: [AutomationEvidence(
        strength: .strong,
        source: "current-user crontab",
        detail: "Listed by the current-user crontab source"
      )],
      capabilities: [],
      validationFindings: []
    )
  }

  private static func invalidRecord(
    for invalidLine: CronInvalidLine,
    ownerUID: uid_t,
    documentChecksum: String
  ) -> AutomationRecord {
    let label = "Invalid crontab line \(invalidLine.lineNumber)"
    return AutomationRecord(
      id: AutomationRecord.ID(
        source: .crontab,
        ownerUID: ownerUID,
        label: "invalid-cron-entry",
        sourcePath: "/.devscope/current-user-crontab/invalid/\(invalidLine.lineNumber)"
      ),
      kind: .cron,
      sourceKind: .crontab,
      label: label,
      displayName: label,
      providerBundleIdentifier: nil,
      ownerUID: ownerUID,
      ownership: .user,
      executable: nil,
      arguments: [],
      environment: [:],
      workingDirectory: nil,
      schedule: AutomationSchedule(
        triggers: [.cron("invalid")],
        summary: "Invalid cron schedule"
      ),
      sourceURL: nil,
      sourceChecksum: documentChecksum,
      enabledState: .unknown,
      loadState: .unknown,
      approvalState: .notApplicable,
      state: .invalid,
      evidence: [AutomationEvidence(
        strength: .strong,
        source: "current-user crontab",
        detail: "The listed crontab contains an invalid line"
      )],
      capabilities: [],
      validationFindings: ["Invalid crontab line"]
    )
  }

  private static func isNoCrontabDiagnostic(
    _ data: Data,
    currentUsername: String
  ) -> Bool {
    guard !currentUsername.isEmpty,
          !currentUsername.contains(where: \.isNewline),
          let diagnostic = String(data: data, encoding: .utf8)
    else { return false }

    let expected = "crontab: no crontab for \(currentUsername)"
    return diagnostic == expected
      || diagnostic == expected + "\n"
      || diagnostic == expected + "\r\n"
  }
}
