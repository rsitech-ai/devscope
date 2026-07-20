import CryptoKit
import Darwin
import Foundation

public struct LegacyLoginItemDescriptor: Equatable, Sendable {
  public let name: String
  public let path: String
  public let isHidden: Bool

  public init(name: String, path: String, isHidden: Bool) {
    self.name = name
    self.path = path
    self.isHidden = isHidden
  }
}

struct LegacyLoginItemRecoveryDescriptor: Codable, Equatable, Sendable {
  let version: Int
  let recordID: String
  let ownerUID: uid_t
  let name: String
  let path: String
  let isHidden: Bool
}

public enum LegacyLoginItemRecoveryDocumentError: Error, Equatable, Sendable {
  case invalidBinding
}

public enum LegacyLoginItemRecoveryDocument {
  public static func checksum(ofEncodedDocument data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  public static func encode(
    selectedRecord: AutomationRecord,
    descriptor: LegacyLoginItemDescriptor,
    currentUID: uid_t
  ) throws -> Data {
    guard descriptor.path.hasPrefix("/"), !descriptor.path.contains("\0") else {
      throw LegacyLoginItemRecoveryDocumentError.invalidBinding
    }
    let canonicalPath = URL(fileURLWithPath: descriptor.path).standardizedFileURL.path
    let expectedID = AutomationRecord.ID(
      source: .legacyLoginItem,
      ownerUID: currentUID,
      label: descriptor.name,
      sourcePath: canonicalPath
    )
    guard selectedRecord.kind == .loginItem,
          selectedRecord.sourceKind == .legacyLoginItem,
          selectedRecord.ownership == .user,
          selectedRecord.ownerUID == currentUID,
          selectedRecord.id == expectedID,
          selectedRecord.label == descriptor.name,
          let executable = selectedRecord.executable,
          URL(fileURLWithPath: executable).standardizedFileURL.path
            == canonicalPath
    else { throw LegacyLoginItemRecoveryDocumentError.invalidBinding }
    let recovery = LegacyLoginItemRecoveryDescriptor(
      version: 1,
      recordID: selectedRecord.id.rawValue,
      ownerUID: currentUID,
      name: descriptor.name,
      path: canonicalPath,
      isHidden: descriptor.isHidden
    )
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      return try encoder.encode(recovery)
    } catch {
      throw LegacyLoginItemRecoveryDocumentError.invalidBinding
    }
  }
}

public enum LegacyLoginItemAdapterError: Error, Equatable, Sendable {
  case permissionDenied
  case unavailable
}

public protocol LegacyLoginItemListing: Sendable {
  func currentUserLoginItems() async throws -> [LegacyLoginItemDescriptor]
}

public struct OSACommandLegacyLoginItemAdapter: LegacyLoginItemListing {
  private struct Item: Decodable {
    let name: String
    let path: String
    let hidden: Bool
  }

  private static let fixedProgram = """
    const systemEvents = Application('System Events');
    JSON.stringify(systemEvents.loginItems().map(item => ({
      name: item.name(),
      path: item.path(),
      hidden: item.hidden()
    })));
    """

  private let runner: any AutomationCommandRunning

  public init(runner: any AutomationCommandRunning) {
    self.runner = runner
  }

  public func currentUserLoginItems() async throws -> [LegacyLoginItemDescriptor] {
    let result: AutomationCommandResult
    do {
      result = try await runner.run(AutomationCommand(
        executable: "/usr/bin/osascript",
        arguments: ["-l", "JavaScript", "-e", Self.fixedProgram]
      ))
    } catch {
      throw LegacyLoginItemAdapterError.unavailable
    }

    guard result.status == 0 else {
      throw LegacyLoginItemAdapterError.permissionDenied
    }
    guard let items = try? JSONDecoder().decode([Item].self, from: result.standardOutput) else {
      throw LegacyLoginItemAdapterError.unavailable
    }
    return items.map {
      LegacyLoginItemDescriptor(name: $0.name, path: $0.path, isHidden: $0.hidden)
    }
  }
}

public struct LegacyLoginItemAutomationSource: AutomationSource {
  public let kind: AutomationSourceKind = .legacyLoginItem

  private let adapter: any LegacyLoginItemListing
  private let currentUID: uid_t
  private let now: @Sendable () -> Date

  public init(
    adapter: any LegacyLoginItemListing,
    currentUID: uid_t,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.adapter = adapter
    self.currentUID = currentUID
    self.now = now
  }

  public func snapshot() async -> AutomationSourceSnapshot {
    let items: [LegacyLoginItemDescriptor]
    do {
      items = try await adapter.currentUserLoginItems()
    } catch LegacyLoginItemAdapterError.permissionDenied {
      return AutomationSourceSnapshot(
        records: [],
        health: AutomationSourceHealth(
          kind: kind,
          state: .permissionRequired,
          message: "Allow DevScope to inspect current-user login items in System Settings.",
          refreshedAt: now()
        )
      )
    } catch {
      return .failed(
        kind: kind,
        message: "Current-user login items are unavailable.",
        refreshedAt: now()
      )
    }

    var invalidCount = 0
    let records = items.compactMap { item -> AutomationRecord? in
      guard !item.name.isEmpty, item.path.hasPrefix("/") else {
        invalidCount += 1
        return nil
      }
      let provisionalRecord = Self.record(
        for: item,
        currentUID: currentUID,
        sourceChecksum: nil
      )
      guard let recoveryData = try? LegacyLoginItemRecoveryDocument.encode(
        selectedRecord: provisionalRecord,
        descriptor: item,
        currentUID: currentUID
      ) else {
        invalidCount += 1
        return nil
      }
      return Self.record(
        for: item,
        currentUID: currentUID,
        sourceChecksum: LegacyLoginItemRecoveryDocument.checksum(
          ofEncodedDocument: recoveryData
        )
      )
    }
    let refreshDate = now()
    return AutomationSourceSnapshot(
      records: records,
      health: AutomationSourceHealth(
        kind: kind,
        state: invalidCount == 0 ? .healthy : (records.isEmpty ? .failed : .partial),
        message: invalidCount == 0 ? nil : "Some login-item records were not usable.",
        refreshedAt: refreshDate
      )
    )
  }

  private static func record(
    for item: LegacyLoginItemDescriptor,
    currentUID: uid_t,
    sourceChecksum: String?
  ) -> AutomationRecord {
    let sourceURL = URL(fileURLWithPath: item.path).standardizedFileURL
    return AutomationRecord(
      id: AutomationRecord.ID(
        source: .legacyLoginItem,
        ownerUID: currentUID,
        label: item.name,
        sourcePath: sourceURL.path
      ),
      kind: .loginItem,
      sourceKind: .legacyLoginItem,
      label: item.name,
      displayName: item.name,
      providerBundleIdentifier: nil,
      ownerUID: currentUID,
      ownership: .user,
      executable: sourceURL.path,
      arguments: [],
      environment: [:],
      workingDirectory: nil,
      schedule: AutomationSchedule(triggers: [.atLogin], summary: "At login"),
      sourceURL: sourceURL,
      sourceChecksum: sourceChecksum,
      enabledState: .enabled,
      loadState: .unknown,
      approvalState: .notApplicable,
      state: .unresolved,
      evidence: [AutomationEvidence(
        strength: .strong,
        source: "Current-user legacy login items",
        detail: item.isHidden ? "Configured hidden at login" : "Configured at login"
      )],
      capabilities: [.exportRecord],
      validationFindings: []
    )
  }
}

public enum BackgroundTaskDiagnosticPolicy: Equatable, Sendable {
  case available
  case administratorApprovalRequired

  public static var currentSystem: Self {
    forOperatingSystemMajorVersion(
      ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    )
  }

  public static func forOperatingSystemMajorVersion(_ majorVersion: Int) -> Self {
    majorVersion >= 27 ? .administratorApprovalRequired : .available
  }
}

public actor BackgroundTaskAutomationSource: AutomationSource {
  public nonisolated let kind: AutomationSourceKind = .serviceManagement

  private struct ParsedDiagnostic: Sendable {
    let records: [AutomationRecord]
    let boundaryCount: Int
    let unusableCount: Int
    let rawOutputHash: String
  }

  private struct BoundedFields {
    var values: [String: String] = [:]
    var hasConflict = false
  }

  private static let recognizedKeys: Set<String> = [
    "Name",
    "Identifier",
    "URL",
    "Bundle Identifier",
    "Executable Path",
    "Disposition",
    "Parent Identifier",
    "Team Identifier",
    "Developer Name",
    "Type",
  ]

  private let runner: any AutomationCommandRunning
  private let diagnosticPolicy: BackgroundTaskDiagnosticPolicy
  private let now: @Sendable () -> Date
  private var rawOutputHash: String?

  public init(
    runner: any AutomationCommandRunning,
    diagnosticPolicy: BackgroundTaskDiagnosticPolicy = .currentSystem,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.runner = runner
    self.diagnosticPolicy = diagnosticPolicy
    self.now = now
  }

  public func currentRawOutputHash() -> String? {
    rawOutputHash
  }

  public func snapshot() async -> AutomationSourceSnapshot {
    guard diagnosticPolicy == .available else {
      return AutomationSourceSnapshot(
        records: [],
        health: AutomationSourceHealth(
          kind: kind,
          state: .permissionRequired,
          message: "macOS 27 or later requires administrator approval for this Background Items "
            + "diagnostic. Review Background Items in System Settings; DevScope did not run the diagnostic.",
          refreshedAt: now()
        )
      )
    }

    let result: AutomationCommandResult
    do {
      result = try await runner.run(AutomationCommand(
        executable: "/usr/bin/sfltool",
        arguments: ["dumpbtm"]
      ))
    } catch {
      return failedSnapshot(message: "Background Task Management diagnostic is unavailable.")
    }

    rawOutputHash = Self.hash(result.standardOutput)
    guard result.status == 0 else {
      return failedSnapshot(message: "Background Task Management diagnostic failed.")
    }
    guard let parsed = Self.parse(result.standardOutput) else {
      return failedSnapshot(message: "Background Task Management output could not be interpreted.")
    }
    rawOutputHash = parsed.rawOutputHash

    let refreshDate = now()
    let healthState: AutomationSourceHealthState
    let message: String?
    if parsed.boundaryCount == 0 {
      healthState = .failed
      message = "Background Task Management record boundaries were not recognized."
    } else if parsed.unusableCount > 0 {
      healthState = parsed.records.isEmpty ? .failed : .partial
      message = "Some Background Task Management records were unresolved."
    } else {
      healthState = .healthy
      message = nil
    }
    return AutomationSourceSnapshot(
      records: parsed.records,
      health: AutomationSourceHealth(
        kind: kind,
        state: healthState,
        message: message,
        refreshedAt: refreshDate
      )
    )
  }

  private func failedSnapshot(message: String) -> AutomationSourceSnapshot {
    .failed(kind: kind, message: message, refreshedAt: now())
  }

  private static func parse(_ data: Data) -> ParsedDiagnostic? {
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    var boundedRecords: [BoundedFields] = []
    var currentRecord: BoundedFields?
    var driftCount = 0

    for line in text.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if isRecordBoundary(trimmed) {
        if let currentRecord {
          boundedRecords.append(currentRecord)
        }
        currentRecord = BoundedFields()
        continue
      }
      if isBoundaryLike(trimmed) {
        if let currentRecord {
          boundedRecords.append(currentRecord)
        }
        currentRecord = nil
        driftCount += 1
        continue
      }
      guard currentRecord != nil,
            let delimiter = trimmed.range(of: ": ")
      else { continue }
      let key = String(trimmed[..<delimiter.lowerBound])
      guard recognizedKeys.contains(key) else { continue }
      let value = String(trimmed[delimiter.upperBound...])
        .trimmingCharacters(in: .whitespaces)
      if !value.isEmpty {
        if let existing = currentRecord?.values[key], existing != value {
          currentRecord?.hasConflict = true
        } else {
          currentRecord?.values[key] = value
        }
      }
    }
    if let currentRecord {
      boundedRecords.append(currentRecord)
    }

    let fingerprint = hash(data)
    let records = boundedRecords.compactMap { bounded -> AutomationRecord? in
      guard !bounded.hasConflict else { return nil }
      return record(from: bounded.values, fingerprint: fingerprint)
    }
    return ParsedDiagnostic(
      records: records,
      boundaryCount: boundedRecords.count,
      unusableCount: boundedRecords.count - records.count + driftCount,
      rawOutputHash: fingerprint
    )
  }

  private static func isRecordBoundary(_ line: String) -> Bool {
    guard line.first == "#", line.last == ":" else { return false }
    let digits = line.dropFirst().dropLast()
    return !digits.isEmpty && digits.utf8.allSatisfy { byte in
      byte >= Character("0").asciiValue! && byte <= Character("9").asciiValue!
    }
  }

  private static func isBoundaryLike(_ line: String) -> Bool {
    line.first == "#" && line.last == ":"
  }

  private static func record(
    from fields: [String: String],
    fingerprint: String
  ) -> AutomationRecord? {
    let bundleIdentifier = fields["Bundle Identifier"]
    let identifier = fields["Identifier"]
    let executable = normalizedFilePath(fields["Executable Path"])
    let sourceURL = normalizedFileURL(fields["URL"])
    let hasStrongBundleIdentity = bundleIdentifier?.isEmpty == false
    let hasStrongLabeledPathIdentity = identifier?.isEmpty == false
      && (executable != nil || sourceURL != nil)
    guard hasStrongBundleIdentity || hasStrongLabeledPathIdentity else { return nil }

    let label = identifier ?? bundleIdentifier!
    let displayName = fields["Name"] ?? label
    let identityPath = sourceURL?.path ?? executable ?? "bundle:\(bundleIdentifier!)"
    var evidence: [AutomationEvidence] = []
    if let bundleIdentifier {
      evidence.append(AutomationEvidence(
        strength: .strong,
        source: "Background Task Management diagnostic",
        detail: "Exact bundle identifier: \(bundleIdentifier)"
      ))
    }
    if let identifier {
      evidence.append(AutomationEvidence(
        strength: executable == nil && sourceURL == nil ? .weak : .strong,
        source: "Background Task Management diagnostic",
        detail: "Exact item identifier: \(identifier)"
      ))
    }
    for key in [
      "Disposition", "Parent Identifier", "Team Identifier", "Developer Name", "Type",
    ] {
      if let value = fields[key] {
        evidence.append(AutomationEvidence(
          strength: .weak,
          source: "Background Task Management diagnostic \(key)",
          detail: value
        ))
      }
    }

    return AutomationRecord(
      id: AutomationRecord.ID(
        source: .serviceManagement,
        ownerUID: 0,
        label: label,
        sourcePath: identityPath
      ),
      kind: .backgroundItem,
      sourceKind: .serviceManagement,
      label: label,
      displayName: displayName,
      providerBundleIdentifier: bundleIdentifier,
      ownerUID: nil,
      ownership: .thirdPartySystem,
      executable: executable,
      arguments: [],
      environment: [:],
      workingDirectory: nil,
      schedule: AutomationSchedule(triggers: [.demand], summary: "System-managed background item"),
      sourceURL: sourceURL,
      sourceChecksum: fingerprint,
      enabledState: .unknown,
      loadState: .unknown,
      approvalState: .unknown,
      state: .unresolved,
      evidence: evidence,
      capabilities: [.exportRecord],
      validationFindings: []
    )
  }

  private static func normalizedFileURL(_ value: String?) -> URL? {
    guard let value else { return nil }
    if value.hasPrefix("/") {
      return URL(fileURLWithPath: value).standardizedFileURL
    }
    guard let url = URL(string: value), url.isFileURL else { return nil }
    return url.standardizedFileURL
  }

  private static func normalizedFilePath(_ value: String?) -> String? {
    normalizedFileURL(value)?.path
  }

  private static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
