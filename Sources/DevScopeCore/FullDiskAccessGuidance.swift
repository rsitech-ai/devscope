import Foundation

public enum FullDiskAccessSettingsRoute {
  public static let deepLink =
    "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

  @discardableResult
  public static func open(
    deepLink: String = deepLink,
    using openURL: (URL) -> Bool,
    fallback: () -> Void
  ) -> Bool {
    guard let url = URL(string: deepLink), openURL(url) else {
      fallback()
      return false
    }
    return true
  }
}

public struct FullDiskAccessGuidance: Equatable, Sendable {
  public let appPath: String
  public let isSandboxed: Bool

  public init(appPath: String, isSandboxed: Bool) {
    self.appPath = appPath
    self.isSandboxed = isSandboxed
  }

  public var isInstalledInApplications: Bool {
    appPath.hasPrefix("/Applications/")
  }

  public var title: String {
    isSandboxed
      ? "This sandbox build cannot use Full Disk Access"
      : "Add DevScope to Full Disk Access"
  }

  public var detail: String {
    if isSandboxed {
      if !isInstalledInApplications {
        return
          "This validation/development build is running at \(appPath) and uses App Sandbox. Install the full DevScope build in Applications; Full Disk Access cannot override App Sandbox for process inspection."
      }
      return
        "Install the full DevScope build in Applications. Full Disk Access cannot override App Sandbox for process inspection."
    }
    if !isInstalledInApplications {
      return
        "Install DevScope in Applications first so macOS keeps permission attached to the app you launch. Current app: \(appPath)"
    }
    return "macOS requires you to add and enable the exact DevScope app manually."
  }

  public var steps: [String] {
    guard !isSandboxed else { return [] }
    return [
      "Open Full Disk Access.",
      "Click + and authenticate.",
      "Select \(appPath).",
      "Enable the DevScope toggle.",
      "Quit and reopen DevScope.",
      "Return here and choose Check Access.",
    ]
  }
}
