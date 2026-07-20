import Foundation

public enum ProcessActionDecision: Equatable, Sendable {
  case allowed
  case protected(reason: String)

  public var isAllowed: Bool {
    if case .allowed = self { return true }
    return false
  }

  public var reason: String? {
    guard case .protected(let reason) = self else { return nil }
    return reason
  }
}

public enum ProcessActionPolicy {
  private static let protectedExecutables: Set<String> = [
    "kernel_task", "launchd", "loginwindow", "WindowServer", "runningboardd",
    "securityd", "tccd", "opendirectoryd", "powerd",
  ]

  public static func decision(
    for item: ClassifiedDevProcess,
    currentProcessID: Int32
  ) -> ProcessActionDecision {
    let process = item.process
    if process.pid == currentProcessID {
      return .protected(reason: "DevScope cannot terminate itself")
    }
    if process.pid == 0 || process.pid == 1 || process.executableName == "launchd" {
      return .protected(reason: "macOS launch infrastructure is protected")
    }
    if protectedExecutables.contains(process.executableName) {
      return .protected(reason: "Critical macOS system infrastructure is protected")
    }
    return .allowed
  }
}
