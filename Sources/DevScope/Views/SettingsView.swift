import AppKit
import DevScopeCore
import SwiftUI

enum DevScopeSettingsKey {
  static let useAppleNaming = "useAppleNaming"
  static let showProcessGraphs = "showProcessGraphs"
  static let showLiveNotch = "showLiveNotch"
  static let selectedCategoryID = "selectedCategoryID"
  static let activityScope = "activityScope"
  static let isRailCollapsed = "isRailCollapsed"
  static let isLiveActivityExpanded = "isLiveActivityExpanded"
  static let liveActivityPreferredHeight = "liveActivityPreferredHeight"
  static let longRunningThresholdSeconds = AutomationPresentationSettings.longRunningThresholdSecondsKey
  static let includeAppleSystemServices = AutomationPresentationSettings.includeAppleSystemServicesKey
  static let selectedWorkspaceMode = AutomationPresentationSettings.selectedWorkspaceModeKey
  static let notifyLongRunningAutomation = AutomationPresentationSettings.notifyLongRunningAutomationKey
  static let notifyUnexpectedAutomationExit = AutomationPresentationSettings.notifyUnexpectedAutomationExitKey
  static let notifyRepeatedAutomationFailure = AutomationPresentationSettings.notifyRepeatedAutomationFailureKey
}

struct SettingsView: View {
  @ObservedObject var automationNotifier: AutomationNotifier
  @AppStorage(DevScopeSettingsKey.useAppleNaming) private var useAppleNaming = true
  @AppStorage(DevScopeSettingsKey.showProcessGraphs) private var showProcessGraphs = true
  @AppStorage(DevScopeSettingsKey.showLiveNotch) private var showLiveNotch = true
  @AppStorage(DevScopeSettingsKey.longRunningThresholdSeconds) private var longRunningThresholdSeconds = 14_400.0
  @AppStorage(DevScopeSettingsKey.includeAppleSystemServices) private var includeAppleSystemServices = false
  @AppStorage(DevScopeSettingsKey.notifyLongRunningAutomation) private var notifyLongRunningAutomation = false
  @AppStorage(DevScopeSettingsKey.notifyUnexpectedAutomationExit) private var notifyUnexpectedAutomationExit = false
  @AppStorage(DevScopeSettingsKey.notifyRepeatedAutomationFailure) private var notifyRepeatedAutomationFailure = false
  @State private var didCopyAccessDiagnostics = false
  @State private var didCopySupportURL = false
  @State private var finderRevealFeedback: FinderRevealFeedback?
  @State private var accessAssessment = ProcessAccessAssessment.assess(
    isSandboxed: ProcessAccessStatus.isSandboxed,
    processes: nil,
    errorDescription: nil
  )
  @State private var isCheckingAccess = false

  var body: some View {
    TabView {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          SettingsPanel(title: "Live Monitoring") {
            Toggle("Show process graphs", isOn: $showProcessGraphs)
            Toggle("Show live notch", isOn: $showLiveNotch)
            Text("Reveal DevScope Live by hovering the top-center screen notch area.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            SettingsValueRow(label: "Metric cadence", value: "2 seconds")
            SettingsValueRow(label: "History window", value: "2 minutes")
          }

          SettingsPanel(title: "Apple Intelligence") {
            Toggle("Use Apple naming when available", isOn: $useAppleNaming)
            Text(
              "Deterministic labels and workflow grouping stay in control. Apple Intelligence can add concise process names and workflow notes when available."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }

          Spacer()
        }
        .padding(20)
      }
      .tabItem {
        Label("General", systemImage: "gearshape")
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          SettingsPanel(title: "Automation Detection") {
            Stepper(value: thresholdHoursBinding, in: 1...168, step: 1) {
              LabeledContent("Long-running threshold", value: thresholdDescription)
            }
            Text("A process becomes Long Running at or after this duration. This remains independent from the Automated badge.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)

            Toggle("Include Apple System Services", isOn: $includeAppleSystemServices)
            Text("Off by default. User and third-party automations, including organization-managed third-party definitions, remain visible.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }

          SettingsPanel(title: "Automation Notifications") {
            Toggle("Long-running automation", isOn: $notifyLongRunningAutomation)
            Toggle("Unexpected automation exit", isOn: $notifyUnexpectedAutomationExit)
            Toggle("Repeated automation failure", isOn: $notifyRepeatedAutomationFailure)

            notificationDeliveryStatus

            if automationNotifier.deliveryState == .denied {
              Button("Open Notification Settings") { openNotificationSettings() }
                .accessibilityHint("Opens macOS notification settings so DevScope delivery can be allowed.")
            }
          }
          Spacer()
        }
        .padding(20)
      }
      .tabItem {
        Label("Automations", systemImage: "gearshape.2")
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          SettingsPanel(title: "Process Access") {
            HStack(alignment: .top, spacing: 12) {
              Image(systemName: accessSummary.symbolName)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(accessSummary.tint)
                .frame(width: 34, height: 34)

              VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                  Text(accessSummary.title)
                    .font(.headline)
                  Text(accessSummary.badge)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accessSummary.tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(accessSummary.tint.opacity(0.12), in: Capsule())
                }

                Text(accessSummary.message)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }

            Divider()

            ForEach(accessAssessment.requirements, id: \.kind) { requirement in
              AccessRequirementRow(requirement: requirement) { action in
                performAccessAction(action)
              }
            }

            Divider()

            if shouldShowFullDiskAccessGuidance {
              VStack(alignment: .leading, spacing: 8) {
                Text(fullDiskAccessGuidance.title)
                  .font(.callout.weight(.semibold))

                Text(fullDiskAccessGuidance.detail)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 3) {
                  Text("Current app")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                  Text(fullDiskAccessGuidance.appPath)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if !fullDiskAccessGuidance.isSandboxed
                  && neededAccessActions.contains(.fullDiskAccess)
                {
                  VStack(alignment: .leading, spacing: 6) {
                    ForEach(
                      Array(fullDiskAccessGuidance.steps.enumerated()), id: \.offset
                    ) { index, step in
                      HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("\(index + 1).")
                          .font(.caption.weight(.semibold))
                          .frame(width: 18, alignment: .trailing)
                        Text(step)
                          .font(.caption)
                          .fixedSize(horizontal: false, vertical: true)
                      }
                    }
                  }
                  .padding(.vertical, 4)

                  HStack {
                    Button {
                      openFullDiskAccess()
                    } label: {
                      Label(
                        "Open Full Disk Access", systemImage: "externaldrive.badge.timemachine")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityLabel("Open Full Disk Access")
                    .accessibilityHint(
                      "Opens Full Disk Access in macOS System Settings.")

                    Button {
                      revealDevScopeInFinder()
                    } label: {
                      Label("Reveal DevScope in Finder", systemImage: "finder")
                    }
                    .controlSize(.small)
                    .accessibilityHint("Selects the exact running DevScope app in Finder.")
                  }

                  if let finderRevealFeedback {
                    Label(
                      finderRevealFeedback.message, systemImage: finderRevealFeedback.symbolName
                    )
                    .font(.caption)
                    .foregroundStyle(finderRevealFeedback.tint)
                    .fixedSize(horizontal: false, vertical: true)
                  }
                }
              }

              Divider()
            }

            VStack(alignment: .leading, spacing: 8) {
              Text("General privacy settings")
                .font(.caption.weight(.semibold))
              Text(
                fullDiskAccessGuidance.isSandboxed
                  ? "You may inspect general privacy settings, but no permission toggle can remove this build's App Sandbox restriction."
                  : "Open the main Privacy & Security pane for other macOS privacy controls."
              )
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
              Button {
                openPrivacyAndSecurity()
              } label: {
                Label("Open Privacy & Security", systemImage: "gearshape.2")
              }
              .controlSize(.small)
              .accessibilityHint("Opens the general Privacy & Security pane in System Settings.")
            }

            HStack {
              Button {
                refreshAccessAssessment()
              } label: {
                Label(
                  isCheckingAccess ? "Checking" : "Check Access", systemImage: "arrow.clockwise")
              }
              .disabled(isCheckingAccess)
              .accessibilityLabel("Check process access")
              .accessibilityHint("Checks process metadata and folder-context access again.")

              Spacer()

              Button {
                copyAccessDiagnostics()
              } label: {
                Label(
                  didCopyAccessDiagnostics ? "Copied" : "Copy Diagnostics",
                  systemImage: didCopyAccessDiagnostics ? "checkmark" : "doc.on.doc")
              }
              .accessibilityLabel("Copy access diagnostics")
              .accessibilityHint("Copies DevScope access and sandbox diagnostics to the clipboard.")
            }
          }

          if accessAssessment.isSandboxed {
            SettingsPanel(title: "Distribution Guidance") {
              Text(
                "This build is sandboxed. If process metadata is blocked, there is no extra macOS privacy permission to request; ship a reduced App Store mode or a notarized Developer ID build for full DevScope process control."
              )
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            }
          }

          Spacer()
        }
        .padding(20)
      }
      .task {
        refreshAccessAssessment()
      }
      .tabItem {
        Label("Access", systemImage: "lock.shield")
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          SettingsPanel(title: "Support DevScope") {
            HStack(spacing: 10) {
              Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.pink)
                .frame(width: 32, height: 32)

              VStack(alignment: .leading, spacing: 2) {
                Text("Buy Me a Coffee")
                  .font(.headline)
                Text("Support open-source maintenance and faster DevScope releases.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }

            SettingsValueRow(
              label: "Destination",
              value: DevScopeSupport.buyMeACoffeeURL.host() ?? "buymeacoffee.com")
            Text(DevScopeSupport.buyMeACoffeeURLString)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)

            HStack {
              Button {
                copySupportURL()
              } label: {
                Label(
                  didCopySupportURL ? "Copied" : "Copy Link",
                  systemImage: didCopySupportURL ? "checkmark" : "doc.on.doc")
              }
              .accessibilityLabel("Copy Buy Me a Coffee link")
              .accessibilityHint("Copies the DevScope support link.")

              Spacer()

              Button {
                openSponsorURL()
              } label: {
                Label("Open Buy Me a Coffee", systemImage: "safari")
              }
              .buttonStyle(.borderedProminent)
              .accessibilityLabel("Open Buy Me a Coffee")
              .accessibilityHint("Opens the DevScope Buy Me a Coffee support page.")
            }

            Text(
              "This support destination is fixed for the public DevScope build so users see the same trusted link everywhere."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }

          Spacer()
        }
        .padding(20)
      }
      .tabItem {
        Label("Support", systemImage: "heart")
      }
    }
    .frame(width: 640, height: 520)
    .task {
      normalizeThreshold()
      await automationNotifier.synchronize(persistedNotificationPreferences)
    }
    .onChange(of: longRunningThresholdSeconds) { _, _ in normalizeThreshold() }
    .onChange(of: notifyLongRunningAutomation) { _, enabled in
      Task { await automationNotifier.setPreference(.crossedLongRunningThreshold, isEnabled: enabled) }
    }
    .onChange(of: notifyUnexpectedAutomationExit) { _, enabled in
      Task { await automationNotifier.setPreference(.unexpectedExit, isEnabled: enabled) }
    }
    .onChange(of: notifyRepeatedAutomationFailure) { _, enabled in
      Task { await automationNotifier.setPreference(.repeatedFailure, isEnabled: enabled) }
    }
  }

  private var thresholdHoursBinding: Binding<Double> {
    Binding(
      get: { AutomationPresentationSettings.normalizedThreshold(longRunningThresholdSeconds) / 3_600 },
      set: { longRunningThresholdSeconds = $0 * 3_600 }
    )
  }

  private var thresholdDescription: String {
    let hours = Int(AutomationPresentationSettings.normalizedThreshold(longRunningThresholdSeconds) / 3_600)
    if hours.isMultiple(of: 24) { return "\(hours / 24) day\(hours == 24 ? "" : "s")" }
    return "\(hours) hour\(hours == 1 ? "" : "s")"
  }

  private var persistedNotificationPreferences: AutomationNotificationPreferences {
    AutomationNotificationPreferences(
      crossedLongRunningThreshold: notifyLongRunningAutomation,
      unexpectedExit: notifyUnexpectedAutomationExit,
      repeatedFailure: notifyRepeatedAutomationFailure
    )
  }

  @ViewBuilder private var notificationDeliveryStatus: some View {
    switch automationNotifier.deliveryState {
    case .notRequested:
      Text("Notifications are off until you opt in. macOS may ask for permission.")
    case .requesting:
      Label("Waiting for macOS notification permission", systemImage: "clock")
    case .enabled:
      Label("Notification delivery is allowed", systemImage: "checkmark.circle")
        .foregroundStyle(.green)
    case .denied:
      Label("Preferences are saved, but macOS denied notification delivery.", systemImage: "exclamationmark.triangle")
        .foregroundStyle(.orange)
    case .authorizationFailed:
      Label("Preferences are saved, but DevScope could not verify notification permission. Turn a notification off and on to retry.", systemImage: "exclamationmark.triangle")
        .foregroundStyle(.orange)
    case .deliveryFailed:
      Label("macOS did not accept the last notification after one retry. Review notification permission before relying on alerts.", systemImage: "exclamationmark.triangle")
        .foregroundStyle(.orange)
    }
  }

  private func normalizeThreshold() {
    let normalized = AutomationPresentationSettings.normalizedThreshold(longRunningThresholdSeconds)
    if normalized != longRunningThresholdSeconds { longRunningThresholdSeconds = normalized }
  }

  private func openNotificationSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
    NSWorkspace.shared.open(url)
  }

  private func openSponsorURL() {
    NSWorkspace.shared.open(DevScopeSupport.buyMeACoffeeURL)
  }

  private func copySupportURL() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(DevScopeSupport.buyMeACoffeeURLString, forType: .string)
    didCopySupportURL = true
  }

  private var accessSummary: ProcessAccessSummary {
    ProcessAccessSummary(assessment: accessAssessment)
  }

  private var neededAccessActions: [ProcessAccessAction] {
    accessAssessment.requirements.reduce(into: []) { actions, requirement in
      guard requirement.state == .needed,
        let action = requirement.action,
        !actions.contains(action)
      else {
        return
      }
      actions.append(action)
    }
  }

  private var fullDiskAccessGuidance: FullDiskAccessGuidance {
    FullDiskAccessGuidance(
      appPath: Bundle.main.bundleURL.path,
      isSandboxed: accessAssessment.isSandboxed
    )
  }

  private var shouldShowFullDiskAccessGuidance: Bool {
    ProcessAccessStatus.isSandboxed || neededAccessActions.contains(.fullDiskAccess)
  }

  private func refreshAccessAssessment() {
    guard !isCheckingAccess else {
      return
    }

    let isSandboxed = ProcessAccessStatus.isSandboxed
    isCheckingAccess = true
    Task { @MainActor in
      accessAssessment = await Task.detached(priority: .userInitiated) {
        do {
          let processes = try SystemProcessScanner().snapshot(includeCurrentDirectories: true)
          return ProcessAccessAssessment.assess(
            isSandboxed: isSandboxed,
            processes: processes,
            errorDescription: nil
          )
        } catch {
          return ProcessAccessAssessment.assess(
            isSandboxed: isSandboxed,
            processes: nil,
            errorDescription: error.localizedDescription
          )
        }
      }.value
      isCheckingAccess = false
    }
  }

  private func performAccessAction(_ action: ProcessAccessAction) {
    switch action {
    case .privacySecurity:
      openPrivacyAndSecurity()
    case .fullDiskAccess:
      openFullDiskAccess()
    }
  }

  private func accessActionTitle(for action: ProcessAccessAction) -> String {
    switch action {
    case .privacySecurity:
      "Open Privacy & Security"
    case .fullDiskAccess:
      "Open Full Disk Access"
    }
  }

  private func accessActionDestination(for action: ProcessAccessAction) -> String {
    switch action {
    case .privacySecurity:
      "Privacy & Security"
    case .fullDiskAccess:
      "Full Disk Access"
    }
  }

  private func accessActionSymbol(for action: ProcessAccessAction) -> String {
    switch action {
    case .privacySecurity:
      "gearshape.2"
    case .fullDiskAccess:
      "externaldrive.badge.timemachine"
    }
  }

  private func openPrivacyAndSecurity() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
      NSWorkspace.shared.open(url)
    } else {
      openSystemSettingsApp()
    }
  }

  private func openFullDiskAccess() {
    FullDiskAccessSettingsRoute.open(
      using: NSWorkspace.shared.open,
      fallback: openPrivacyAndSecurity
    )
  }

  private func revealDevScopeInFinder() {
    let appURL = Bundle.main.bundleURL
    guard FileManager.default.fileExists(atPath: appURL.path) else {
      finderRevealFeedback = .failure(
        "The current DevScope app could not be found at the displayed path.")
      return
    }

    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    finderRevealFeedback = .success("DevScope is selected in Finder.")
  }

  private func openSystemSettingsApp() {
    for path in [
      "/System/Applications/System Settings.app",
      "/System/Applications/System Preferences.app",
    ] {
      let url = URL(fileURLWithPath: path, isDirectory: true)
      if FileManager.default.fileExists(atPath: url.path) {
        NSWorkspace.shared.open(url)
        return
      }
    }
  }

  private func copyAccessDiagnostics() {
    let bundle = Bundle.main
    let diagnostics = """
      DevScope Access Diagnostics
      Bundle ID: \(bundle.bundleIdentifier ?? "unknown")
      Version: \(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown") (\(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"))
      App path: \(bundle.bundlePath)
      Sandbox detected: \(ProcessAccessStatus.isSandboxed ? "yes" : "no")
      Process count: \(accessAssessment.processCount)
      Working directory count: \(accessAssessment.currentDirectoryCount)
      Access rows: \(accessAssessment.requirements.map { "\($0.title)=\($0.state.rawValue)" }.joined(separator: ", "))
      Scan error: \(accessAssessment.scanErrorDescription ?? "none")
      Scanner: user-level ps/lsof with native libproc fallback
      Guidance: DevScope only requests actionable permissions. App Sandbox process blocking cannot be fixed from Privacy & Security.
      """

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(diagnostics, forType: .string)
    didCopyAccessDiagnostics = true
  }
}

private struct FinderRevealFeedback {
  let message: String
  let symbolName: String
  let tint: Color

  static func success(_ message: String) -> FinderRevealFeedback {
    FinderRevealFeedback(message: message, symbolName: "checkmark.circle.fill", tint: .green)
  }

  static func failure(_ message: String) -> FinderRevealFeedback {
    FinderRevealFeedback(message: message, symbolName: "exclamationmark.triangle.fill", tint: .red)
  }
}

private struct ProcessAccessSummary {
  let title: String
  let badge: String
  let message: String
  let symbolName: String
  let tint: Color

  init(assessment: ProcessAccessAssessment) {
    if assessment.hasBlockedRequirement {
      title = "Process access blocked"
      badge = "Blocked"
      message =
        assessment.isSandboxed
        ? "The current build cannot inspect local process metadata. No Privacy & Security permission can override App Sandbox for unrestricted process inspection."
        : "DevScope could not inspect local process metadata. This failure is not mapped to a known macOS permission toggle."
      symbolName = "lock.shield"
      tint = .red
    } else if assessment.hasNeededAction {
      title = "Permission needed"
      badge = "Needed"
      message =
        "DevScope can see processes, but one optional capability needs a macOS privacy setting."
      symbolName = "exclamationmark.shield"
      tint = .orange
    } else {
      title = "Process access ready"
      badge = "Ready"
      message = "DevScope can inspect local running activity with current-user permissions."
      symbolName = "checkmark.shield"
      tint = .green
    }
  }
}

private enum ProcessAccessStatus {
  static var isSandboxed: Bool {
    ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
  }
}

private struct AccessRequirementRow: View {
  let requirement: ProcessAccessRequirement
  let performAction: (ProcessAccessAction) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: symbolName)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(tint)
          .frame(width: 22, height: 22)

        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 8) {
            Text(requirement.title)
              .font(.callout.weight(.medium))
            Text(badge)
              .font(.caption2.weight(.bold))
              .foregroundStyle(tint)
              .padding(.horizontal, 7)
              .padding(.vertical, 2)
              .background(tint.opacity(0.12), in: Capsule())
          }

          Text(requirement.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 12)
      }

      if let action = requirement.action, requirement.state == .needed {
        Button {
          performAction(action)
        } label: {
          Label(actionTitle(for: action), systemImage: actionSymbol(for: action))
        }
        .controlSize(.small)
        .accessibilityLabel(actionTitle(for: action))
        .accessibilityHint("Opens \(actionDestination(for: action)) in macOS System Settings.")
      } else if requirement.state == .blocked {
        Text("No System Settings permission can grant this access for the current build.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
  }

  private var symbolName: String {
    switch requirement.state {
    case .ready:
      "checkmark.circle.fill"
    case .needed:
      "exclamationmark.triangle.fill"
    case .blocked:
      "lock.fill"
    }
  }

  private var tint: Color {
    switch requirement.state {
    case .ready:
      .green
    case .needed:
      .orange
    case .blocked:
      .red
    }
  }

  private var badge: String {
    switch requirement.state {
    case .ready:
      "Ready"
    case .needed:
      "Needed"
    case .blocked:
      "Blocked"
    }
  }

  private func actionTitle(for action: ProcessAccessAction) -> String {
    switch action {
    case .privacySecurity:
      "Open Privacy & Security"
    case .fullDiskAccess:
      "Open Full Disk Access"
    }
  }

  private func actionSymbol(for action: ProcessAccessAction) -> String {
    switch action {
    case .privacySecurity:
      "gearshape.2"
    case .fullDiskAccess:
      "externaldrive.badge.timemachine"
    }
  }

  private func actionDestination(for action: ProcessAccessAction) -> String {
    switch action {
    case .privacySecurity:
      "Privacy & Security"
    case .fullDiskAccess:
      "Full Disk Access"
    }
  }
}

private struct SettingsPanel<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.headline)
      VStack(alignment: .leading, spacing: 10) {
        content
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .softPanel(cornerRadius: 12)
    }
  }
}

private struct SettingsValueRow: View {
  let label: String
  let value: String

  var body: some View {
    HStack {
      Text(label)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .monospacedDigit()
    }
    .font(.callout)
  }
}
