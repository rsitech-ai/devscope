import Darwin
import Foundation

public enum AutomationPathAuthorization {
  public static func isApprovedDestination(
    _ destination: URL,
    approvedRoot: URL,
    destinationExists: Bool,
    verifiedMetadataURL: URL,
    metadataIsSymbolicLink: Bool
  ) -> Bool {
    let destination = destination.standardizedFileURL
    let root = approvedRoot.standardizedFileURL
    let verifiedMetadataURL = verifiedMetadataURL.standardizedFileURL
    let expectedMetadataURL = destinationExists
      ? destination
      : destination.deletingLastPathComponent().standardizedFileURL
    return !metadataIsSymbolicLink
      && destination.path.hasPrefix(root.path + "/")
      && verifiedMetadataURL.path == expectedMetadataURL.path
  }
}

public struct AutomationCapabilityDecision: Equatable, Sendable {
  public let capabilities: Set<AutomationCapability>
  public let reason: String?

  public init(capabilities: Set<AutomationCapability>, reason: String?) {
    self.capabilities = capabilities
    self.reason = reason
  }
}

public struct AutomationCapabilityContext: Equatable, Sendable {
  public let currentUID: uid_t
  public let canonicalPathIsApproved: Bool
  public let sourceOwnerUID: uid_t?
  public let isSymlink: Bool
  public let isManaged: Bool
  public let implementedCapabilities: Set<AutomationCapability>

  public init(
    currentUID: uid_t,
    canonicalPathIsApproved: Bool,
    sourceOwnerUID: uid_t?,
    isSymlink: Bool,
    isManaged: Bool,
    implementedCapabilities: Set<AutomationCapability> = []
  ) {
    self.currentUID = currentUID
    self.canonicalPathIsApproved = canonicalPathIsApproved
    self.sourceOwnerUID = sourceOwnerUID
    self.isSymlink = isSymlink
    self.isManaged = isManaged
    self.implementedCapabilities = implementedCapabilities
  }
}

public enum AutomationCapabilityPolicy {
  private static let inspectionCapabilities: Set<AutomationCapability> = [.exportRecord]
  private static let mutableSourceKinds: Set<AutomationSourceKind> = [
    .launchAgent,
    .legacyLoginItem,
    .crontab,
  ]

  public static func decision(
    for record: AutomationRecord,
    context: AutomationCapabilityContext
  ) -> AutomationCapabilityDecision {
    if context.isManaged || record.ownership == .managed {
      return denied("This automation is managed by your organization.", context: context)
    }
    if record.ownership == .appleSystem {
      return denied("Apple system services are inspection only.", context: context)
    }
    if record.ownership == .thirdPartySystem || record.kind == .launchDaemon {
      return denied(
        "System-wide automations require administrator management outside DevScope.",
        context: context
      )
    }
    if record.sourceKind == .serviceManagement || record.kind == .backgroundItem {
      return denied(
        "Modern background items must be managed by their owning app or System Settings.",
        context: context
      )
    }
    guard record.ownership == .user else {
      return denied("Only automations owned by the current user can be managed.", context: context)
    }
    guard mutableSourceKinds.contains(record.sourceKind) else {
      return denied("This automation source is inspection only.", context: context)
    }
    guard context.canonicalPathIsApproved else {
      return denied(canonicalPathReason(for: record.sourceKind), context: context)
    }
    guard !context.isSymlink else {
      return denied("Symbolic-link automation sources are inspection only.", context: context)
    }
    guard let ownerUID = context.sourceOwnerUID else {
      return denied("DevScope could not verify who owns this automation source.", context: context)
    }
    guard ownerUID == context.currentUID, record.ownerUID == context.currentUID else {
      return denied("The automation source is not owned by the current user.", context: context)
    }
    if record.sourceKind == .launchAgent,
       record.enabledState == .unknown || record.loadState == .unknown
    {
      return denied(
        "DevScope could not verify this LaunchAgent's enabled and loaded state, so management is unavailable.",
        context: context
      )
    }

    let capabilities = Set(AutomationCapability.allCases)
      .intersection(context.implementedCapabilities)
    let reason: String?
    if capabilities == Set(AutomationCapability.allCases) {
      reason = nil
    } else {
      reason = unavailableReason(for: record.sourceKind)
    }
    return AutomationCapabilityDecision(capabilities: capabilities, reason: reason)
  }

  private static func denied(
    _ reason: String,
    context: AutomationCapabilityContext
  ) -> AutomationCapabilityDecision {
    AutomationCapabilityDecision(
      capabilities: inspectionCapabilities.intersection(context.implementedCapabilities),
      reason: reason
    )
  }

  private static func unavailableReason(for sourceKind: AutomationSourceKind) -> String {
    switch sourceKind {
    case .crontab:
      "Current-user crontab management is unavailable until recoverable source access is installed."
    case .legacyLoginItem:
      "Legacy login-item management is unavailable until recoverable source access is installed."
    case .launchAgent:
      "Some LaunchAgent management operations are not installed."
    case .launchDaemon:
      "System-wide launchd management is not installed."
    case .serviceManagement:
      "Modern background-item management is not installed."
    }
  }

  private static func canonicalPathReason(for sourceKind: AutomationSourceKind) -> String {
    switch sourceKind {
    case .launchAgent:
      "The source resolves outside your LaunchAgents folder."
    case .crontab:
      "The recoverable source does not represent your current-user crontab."
    case .legacyLoginItem:
      "The recoverable source does not represent your current-user login items."
    case .launchDaemon:
      "The source resolves outside the approved launchd domain."
    case .serviceManagement:
      "The source resolves outside the approved background-item domain."
    }
  }
}
