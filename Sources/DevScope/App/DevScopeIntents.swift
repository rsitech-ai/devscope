import AppIntents
import AppKit
import Foundation

struct OpenDevScopeIntent: AppIntent {
  static let title: LocalizedStringResource = "Open DevScope"
  static let description = IntentDescription("Open DevScope to inspect local apps, services, agents, and processes.")
  static var openAppWhenRun: Bool { true }

  @available(macOS 26.0, *)
  static var supportedModes: IntentModes {
    .foreground(.immediate)
  }

  @MainActor
  func perform() async throws -> some IntentResult {
    NSApp.activate(ignoringOtherApps: true)
    return .result()
  }
}

struct RefreshDevScopeIntent: AppIntent {
  static let title: LocalizedStringResource = "Refresh DevScope"
  static let description = IntentDescription("Refresh the DevScope running activity list.")
  static var openAppWhenRun: Bool { true }

  @available(macOS 26.0, *)
  static var supportedModes: IntentModes {
    .foreground(.immediate)
  }

  @MainActor
  func perform() async throws -> some IntentResult {
    NSApp.activate(ignoringOtherApps: true)
    NotificationCenter.default.post(name: .devScopeRefreshRequested, object: nil)
    return .result()
  }
}

struct DevScopeShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: OpenDevScopeIntent(),
      phrases: [
        "Open \(.applicationName)",
        "Show \(.applicationName)"
      ],
      shortTitle: "Open DevScope",
      systemImageName: "scope"
    )

    AppShortcut(
      intent: RefreshDevScopeIntent(),
      phrases: [
        "Refresh \(.applicationName)",
        "Scan with \(.applicationName)"
      ],
      shortTitle: "Refresh",
      systemImageName: "arrow.clockwise"
    )
  }
}
