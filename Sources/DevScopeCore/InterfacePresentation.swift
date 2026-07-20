import Foundation

public enum DevScopeWorkspaceMode: String, CaseIterable, Sendable {
  case processes
  case automations
}

public enum AutomationPresentationSettings {
  public static let defaultLongRunningThreshold: TimeInterval = 14_400
  public static let minimumLongRunningThreshold: TimeInterval = 3_600
  public static let maximumLongRunningThreshold: TimeInterval = 604_800
  public static let longRunningThresholdStep: TimeInterval = 3_600

  public static let longRunningThresholdSecondsKey = "longRunningThresholdSeconds"
  public static let includeAppleSystemServicesKey = "includeAppleSystemServices"
  public static let selectedWorkspaceModeKey = "selectedWorkspaceMode"
  public static let notifyLongRunningAutomationKey = "notifyLongRunningAutomation"
  public static let notifyUnexpectedAutomationExitKey = "notifyUnexpectedAutomationExit"
  public static let notifyRepeatedAutomationFailureKey = "notifyRepeatedAutomationFailure"

  public static func normalizedThreshold(_ value: TimeInterval) -> TimeInterval {
    guard value.isFinite else { return defaultLongRunningThreshold }
    let clamped = min(max(value, minimumLongRunningThreshold), maximumLongRunningThreshold)
    return (clamped / longRunningThresholdStep).rounded() * longRunningThresholdStep
  }
}

public enum InterfaceSelectionDirection: Sendable {
  case previous
  case next
}

public enum InterfacePresentation {
  public static let defaultFocusLimit = 6

  public static func visibleFocusWorkflows(
    _ workflows: [DevWorkflow],
    selectedID: String,
    showsAll: Bool
  ) -> [DevWorkflow] {
    guard !showsAll else {
      return workflows
    }

    var visible = Array(workflows.prefix(defaultFocusLimit))
    if let selected = workflows.first(where: { $0.id == selectedID }),
       !visible.contains(where: { $0.id == selected.id }) {
      visible.append(selected)
    }
    return visible
  }

  public static func movedSelection(
    in visibleIDs: [Int32],
    current: Int32?,
    direction: InterfaceSelectionDirection
  ) -> Int32? {
    guard !visibleIDs.isEmpty else {
      return nil
    }

    guard let current, let currentIndex = visibleIDs.firstIndex(of: current) else {
      return direction == .next ? visibleIDs.first : visibleIDs.last
    }

    let destination = switch direction {
    case .previous:
      max(visibleIDs.startIndex, currentIndex - 1)
    case .next:
      min(visibleIDs.index(before: visibleIDs.endIndex), currentIndex + 1)
    }
    return visibleIDs[destination]
  }
}
