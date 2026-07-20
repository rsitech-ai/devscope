public enum ProcessActionControl: CaseIterable, Sendable {
  case terminate
  case terminateTree
  case forceOptions
}

public struct ProcessActionControlPresentation: Equatable, Sendable {
  public let isDisabled: Bool
  public let help: String
  public let accessibilityHint: String
}

public enum ProcessActionPresentation {
  public static func control(
    _ control: ProcessActionControl,
    isEnded: Bool,
    actionDecision: ProcessActionDecision
  ) -> ProcessActionControlPresentation {
    if isEnded {
      return ProcessActionControlPresentation(
        isDisabled: true,
        help: "Unavailable: This process has ended.",
        accessibilityHint: "Unavailable because the selected process has ended."
      )
    }
    if let reason = actionDecision.reason {
      let guidance = "Unavailable: \(reason)"
      return ProcessActionControlPresentation(
        isDisabled: true,
        help: guidance,
        accessibilityHint: guidance
      )
    }

    switch control {
    case .terminate:
      return ProcessActionControlPresentation(
        isDisabled: !actionDecision.isAllowed,
        help: "Requests confirmation before sending SIGTERM.",
        accessibilityHint: "Requests confirmation before sending SIGTERM to the selected process."
      )
    case .terminateTree:
      return ProcessActionControlPresentation(
        isDisabled: !actionDecision.isAllowed,
        help: "Requests confirmation before sending SIGTERM to the process tree.",
        accessibilityHint: "Requests confirmation before sending SIGTERM to the selected process and its descendants."
      )
    case .forceOptions:
      return ProcessActionControlPresentation(
        isDisabled: !actionDecision.isAllowed,
        help: "Force kill options",
        accessibilityHint: "Opens destructive SIGKILL options for the selected process."
      )
    }
  }
}

public enum ProcessTerminationAction: CaseIterable, Sendable {
  case single
  case tree
  case forceSingle
  case forceTree

  public func consequence(pid: Int32, descendantCount: Int) -> String {
    switch self {
    case .single:
      "Sends SIGTERM to PID \(pid). The process may save state before exiting."
    case .tree:
      "Sends SIGTERM to PID \(pid) after \(descendantCount) descendant process\(descendantCount == 1 ? "" : "es")."
    case .forceSingle:
      "Sends SIGKILL to PID \(pid). The process cannot save state."
    case .forceTree:
      "Sends SIGKILL to PID \(pid) and \(descendantCount) descendant process\(descendantCount == 1 ? "" : "es"). None can save state."
    }
  }
}
