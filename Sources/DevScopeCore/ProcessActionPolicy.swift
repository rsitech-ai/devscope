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
    // Session-critical GUI / preference / audio agents (basename match).
    "Finder", "Dock", "SystemUIServer", "cfprefsd", "distnoted",
    "UserEventAgent", "coreaudiod",
  ]

  /// Path prefixes for session-critical Apple infrastructure. Basename-only matching
  /// misses renamed or nested CoreServices / libexec helpers.
  private static let protectedPathPrefixes = [
    "/System/Library/CoreServices/",
    "/usr/libexec/",
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
    if protectedExecutables.contains(process.executableName)
      || isProtectedSystemPath(process.executable)
    {
      return .protected(reason: "Critical macOS system infrastructure is protected")
    }
    return .allowed
  }

  private static func isProtectedSystemPath(_ executable: String) -> Bool {
    let path = URL(fileURLWithPath: executable).standardizedFileURL.path
    return protectedPathPrefixes.contains { path.hasPrefix($0) }
  }
}
