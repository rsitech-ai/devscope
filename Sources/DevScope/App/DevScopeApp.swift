import AppKit
import SwiftUI

@main
struct DevScopeApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var processStore: ProcessStore
  @StateObject private var automationStore: AutomationStore
  @StateObject private var automationNotifier: AutomationNotifier

  init() {
    let composition = DevScopeComposition.make()
    _processStore = StateObject(wrappedValue: composition.processStore)
    _automationStore = StateObject(wrappedValue: composition.automationStore)
    _automationNotifier = StateObject(wrappedValue: composition.automationNotifier)
  }

  var body: some Scene {
    Window("DevScope", id: "main") {
      ContentView(
        store: processStore,
        automationStore: automationStore,
        automationNotifier: automationNotifier
      )
      .frame(minWidth: 1120, minHeight: 620)
    }
    .windowResizability(.contentSize)
    .commands {
      CommandGroup(replacing: .appSettings) {
        SettingsLink {
          Text("Settings...")
        }
        .keyboardShortcut(",", modifiers: [.command])
      }

      CommandGroup(after: .appInfo) {
        Button("Refresh Current Workspace") {
          NotificationCenter.default.post(name: .devScopeRefreshRequested, object: nil)
        }
        .keyboardShortcut("r", modifiers: [.command])

        Button("Restore Last Copy") {
          NotificationCenter.default.post(name: .devScopeRestoreLastCopyRequested, object: nil)
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
      }
    }

    Settings {
      SettingsView(automationNotifier: automationNotifier)
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }
}

extension Notification.Name {
  static let devScopeRefreshRequested = Notification.Name("devScopeRefreshRequested")
  static let devScopeRestoreLastCopyRequested = Notification.Name(
    "devScopeRestoreLastCopyRequested")
}
