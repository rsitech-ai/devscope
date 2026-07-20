import CryptoKit
import Darwin
import Foundation

public enum AutomationKind: String, CaseIterable, Hashable, Sendable {
  case launchAgent, launchDaemon, loginItem, backgroundItem, cron
}

public enum AutomationSourceKind: String, CaseIterable, Hashable, Sendable {
  case launchAgent, launchDaemon, serviceManagement, legacyLoginItem, crontab
}

public enum AutomationOwnership: String, CaseIterable, Hashable, Sendable {
  case user, thirdPartySystem, appleSystem, managed
}

public enum AutomationState: String, CaseIterable, Hashable, Sendable {
  case running, idle, disabled, needsApproval, invalid, unresolved
}

public enum AutomationEnabledState: String, Hashable, Sendable {
  case enabled, disabled, unknown
}

public enum AutomationLoadState: String, Hashable, Sendable {
  case loaded, unloaded, unknown
}

public enum AutomationApprovalState: String, Sendable {
  case approved, needsApproval, notApplicable, unknown
}

public enum AutomationCapability: String, CaseIterable, Hashable, Sendable {
  case startNow, stopCurrentRun, enable, disable, disableAndStop
  case edit, duplicate, importRecord, exportRecord, remove, restore
}

public struct AutomationSchedule: Equatable, Hashable, Sendable {
  public enum Trigger: Equatable, Hashable, Sendable {
    case atLogin
    case runAtLoad
    case interval(seconds: Int)
    case calendar(String)
    case keepAlive
    case cron(String)
    case demand
  }

  public let triggers: [Trigger]
  public let summary: String

  public init(triggers: [Trigger], summary: String) {
    self.triggers = triggers
    self.summary = summary
  }
}

public struct AutomationEvidence: Equatable, Hashable, Sendable {
  public enum Strength: Int, Comparable, Sendable {
    case weak = 0
    case strong = 1

    public static func < (lhs: Self, rhs: Self) -> Bool {
      lhs.rawValue < rhs.rawValue
    }
  }

  public let strength: Strength
  public let source: String
  public let detail: String

  public init(strength: Strength, source: String, detail: String) {
    self.strength = strength
    self.source = source
    self.detail = detail
  }
}

public struct AutomationRecord: Identifiable, Equatable, Sendable {
  public struct ID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
      self.rawValue = rawValue
    }

    public init(
      source: AutomationSourceKind,
      ownerUID: uid_t,
      label: String,
      sourcePath: String
    ) {
      let canonicalPath = URL(fileURLWithPath: sourcePath).standardizedFileURL.path
      var identity = Data()
      for component in [source.rawValue, String(ownerUID), label, canonicalPath] {
        let bytes = Data(component.utf8)
        let byteCount = UInt64(bytes.count)
        for shift in stride(from: 56, through: 0, by: -8) {
          identity.append(UInt8(truncatingIfNeeded: byteCount >> shift))
        }
        identity.append(bytes)
      }
      rawValue = SHA256.hash(data: identity)
        .map { String(format: "%02x", $0) }
        .joined()
    }
  }

  public let id: ID
  public let kind: AutomationKind
  public let sourceKind: AutomationSourceKind
  public let label: String
  public let displayName: String
  public let providerBundleIdentifier: String?
  public let ownerUID: uid_t?
  public let ownership: AutomationOwnership
  public let executable: String?
  public let arguments: [String]
  public let commandSignature: String?
  public let environment: [String: String]
  public let workingDirectory: String?
  public let schedule: AutomationSchedule
  public let sourceURL: URL?
  public let sourceChecksum: String?
  public let enabledState: AutomationEnabledState
  public let loadState: AutomationLoadState
  public let approvalState: AutomationApprovalState
  public let state: AutomationState
  public let evidence: [AutomationEvidence]
  public let capabilities: Set<AutomationCapability>
  public let validationFindings: [String]

  public init(
    id: ID,
    kind: AutomationKind,
    sourceKind: AutomationSourceKind,
    label: String,
    displayName: String,
    providerBundleIdentifier: String?,
    ownerUID: uid_t?,
    ownership: AutomationOwnership,
    executable: String?,
    arguments: [String],
    commandSignature: String? = nil,
    environment: [String: String],
    workingDirectory: String?,
    schedule: AutomationSchedule,
    sourceURL: URL?,
    sourceChecksum: String?,
    enabledState: AutomationEnabledState,
    loadState: AutomationLoadState,
    approvalState: AutomationApprovalState,
    state: AutomationState,
    evidence: [AutomationEvidence],
    capabilities: Set<AutomationCapability>,
    validationFindings: [String]
  ) {
    self.id = id
    self.kind = kind
    self.sourceKind = sourceKind
    self.label = label
    self.displayName = displayName
    self.providerBundleIdentifier = providerBundleIdentifier
    self.ownerUID = ownerUID
    self.ownership = ownership
    self.executable = executable
    self.arguments = arguments
    self.commandSignature = commandSignature
    self.environment = environment
    self.workingDirectory = workingDirectory
    self.schedule = schedule
    self.sourceURL = sourceURL
    self.sourceChecksum = sourceChecksum
    self.enabledState = enabledState
    self.loadState = loadState
    self.approvalState = approvalState
    self.state = state
    self.evidence = evidence
    self.capabilities = capabilities
    self.validationFindings = validationFindings
  }
}

public enum AutomationSourceHealthState: String, Sendable {
  case healthy, partial, failed, permissionRequired
}

public struct AutomationSourceHealth: Equatable, Sendable {
  public let kind: AutomationSourceKind
  public let state: AutomationSourceHealthState
  public let message: String?
  public let refreshedAt: Date

  public init(
    kind: AutomationSourceKind,
    state: AutomationSourceHealthState,
    message: String?,
    refreshedAt: Date
  ) {
    self.kind = kind
    self.state = state
    self.message = message
    self.refreshedAt = refreshedAt
  }
}

public struct AutomationSourceSnapshot: Equatable, Sendable {
  public let records: [AutomationRecord]
  public let health: AutomationSourceHealth

  public init(records: [AutomationRecord], health: AutomationSourceHealth) {
    self.records = records
    self.health = health
  }

  public static func healthy(
    kind: AutomationSourceKind,
    records: [AutomationRecord],
    refreshedAt: Date = Date()
  ) -> Self {
    Self(
      records: records,
      health: AutomationSourceHealth(
        kind: kind,
        state: .healthy,
        message: nil,
        refreshedAt: refreshedAt
      )
    )
  }

  public static func failed(
    kind: AutomationSourceKind,
    message: String,
    refreshedAt: Date = Date()
  ) -> Self {
    Self(
      records: [],
      health: AutomationSourceHealth(
        kind: kind,
        state: .failed,
        message: message,
        refreshedAt: refreshedAt
      )
    )
  }
}

public enum AutomationParseError: Error, Equatable, Sendable {
  case unreadablePropertyList
  case missingLabel
  case missingProgram
  case invalidField(String)
}
