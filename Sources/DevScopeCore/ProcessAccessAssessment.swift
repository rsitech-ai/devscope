import Foundation

public enum ProcessAccessRequirementKind: String, Sendable {
  case processMetadata
  case workingDirectories
}

public enum ProcessAccessRequirementState: String, Sendable {
  case ready
  case needed
  case blocked
}

public enum ProcessAccessAction: String, Sendable {
  case privacySecurity
  case fullDiskAccess
}

public struct ProcessAccessRequirement: Equatable, Sendable {
  public let kind: ProcessAccessRequirementKind
  public let state: ProcessAccessRequirementState
  public let title: String
  public let detail: String
  public let action: ProcessAccessAction?

  public init(
    kind: ProcessAccessRequirementKind,
    state: ProcessAccessRequirementState,
    title: String,
    detail: String,
    action: ProcessAccessAction?
  ) {
    self.kind = kind
    self.state = state
    self.title = title
    self.detail = detail
    self.action = action
  }
}

public struct ProcessAccessAssessment: Equatable, Sendable {
  public let isSandboxed: Bool
  public let processCount: Int
  public let currentDirectoryCount: Int
  public let scanErrorDescription: String?
  public let requirements: [ProcessAccessRequirement]

  public var hasNeededAction: Bool {
    requirements.contains { $0.action != nil && $0.state == .needed }
  }

  public var hasBlockedRequirement: Bool {
    requirements.contains { $0.state == .blocked }
  }

  public init(
    isSandboxed: Bool,
    processCount: Int,
    currentDirectoryCount: Int,
    scanErrorDescription: String?,
    requirements: [ProcessAccessRequirement]
  ) {
    self.isSandboxed = isSandboxed
    self.processCount = processCount
    self.currentDirectoryCount = currentDirectoryCount
    self.scanErrorDescription = scanErrorDescription
    self.requirements = requirements
  }

  public static func assess(
    isSandboxed: Bool,
    processes: [DevProcess]?,
    errorDescription: String?
  ) -> ProcessAccessAssessment {
    let processCount = processes?.count ?? 0
    let currentDirectoryCount = processes?.filter { $0.currentDirectory != nil }.count ?? 0
    var requirements: [ProcessAccessRequirement] = []

    if isSandboxed {
      requirements.append(
        ProcessAccessRequirement(
          kind: .processMetadata,
          state: .blocked,
          title: "Process Metadata",
          detail: "Blocked by App Sandbox. There is no macOS privacy permission that grants unrestricted process inspection to this build.",
          action: nil
        )
      )
      return ProcessAccessAssessment(
        isSandboxed: isSandboxed,
        processCount: processCount,
        currentDirectoryCount: currentDirectoryCount,
        scanErrorDescription: errorDescription,
        requirements: requirements
      )
    }

    if processCount > 0 {
      requirements.append(
        ProcessAccessRequirement(
          kind: .processMetadata,
          state: .ready,
          title: "Process Metadata",
          detail: "\(processCount) local processes are visible to DevScope.",
          action: nil
        )
      )
    } else {
      requirements.append(
        ProcessAccessRequirement(
          kind: .processMetadata,
          state: .blocked,
          title: "Process Metadata",
          detail: errorDescription ?? "macOS is not returning process metadata to DevScope. This is not a known user-grantable Privacy & Security permission.",
          action: nil
        )
      )
    }

    if processCount > 0 {
      requirements.append(
        ProcessAccessRequirement(
          kind: .workingDirectories,
          state: currentDirectoryCount > 0 ? .ready : .needed,
          title: "Working Directories",
          detail: currentDirectoryCount > 0
            ? "\(currentDirectoryCount) process folders are visible for project grouping."
            : "Process rows are visible, but folder context is hidden. Grant Full Disk Access only if you need project folders and richer grouping.",
          action: currentDirectoryCount > 0 ? nil : .fullDiskAccess
        )
      )
    }

    return ProcessAccessAssessment(
      isSandboxed: isSandboxed,
      processCount: processCount,
      currentDirectoryCount: currentDirectoryCount,
      scanErrorDescription: errorDescription,
      requirements: requirements
    )
  }
}
