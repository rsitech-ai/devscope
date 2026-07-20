import Foundation

public enum LaunchctlServiceTargetState: Equatable, Sendable {
  case loaded
  case absent
  case unknown
}

public enum LaunchctlServiceTargetClassifier {
  public static func classify(
    _ result: AutomationCommandResult,
    label: String,
    guiUID: uid_t
  ) -> LaunchctlServiceTargetState {
    if result.status == 0 { return .loaded }
    guard result.status == 113 else { return .unknown }

    let expectedDiagnostic =
      "Bad request.\nCould not find service \"\(label)\" in domain for user gui: \(guiUID)\n"
    guard String(data: result.standardError, encoding: .utf8) == expectedDiagnostic else {
      return .unknown
    }
    return .absent
  }
}
