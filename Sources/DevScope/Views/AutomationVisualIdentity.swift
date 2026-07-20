import DevScopeCore

enum AutomationColorToken: Equatable, Sendable {
  case accent
  case blue
  case indigo
  case cyan
  case purple
  case green
  case orange
  case red
  case secondary
}

struct AutomationVisualIdentity: Equatable, Sendable {
  let symbolName: String
  let colorToken: AutomationColorToken
  let accessibilityTitle: String

  static func fallback(for kind: AutomationKind) -> Self {
    switch kind {
    case .launchAgent:
      Self(
        symbolName: "bolt.horizontal",
        colorToken: .blue,
        accessibilityTitle: "LaunchAgent"
      )
    case .launchDaemon:
      Self(
        symbolName: "bolt.horizontal.circle",
        colorToken: .indigo,
        accessibilityTitle: "LaunchDaemon"
      )
    case .loginItem:
      Self(
        symbolName: "person.crop.circle.badge.clock",
        colorToken: .cyan,
        accessibilityTitle: "Login item"
      )
    case .backgroundItem:
      Self(
        symbolName: "person.crop.circle.badge.clock",
        colorToken: .cyan,
        accessibilityTitle: "Background item"
      )
    case .cron:
      Self(
        symbolName: "calendar.badge.clock",
        colorToken: .purple,
        accessibilityTitle: "Scheduled automation"
      )
    }
  }

  static func state(for state: AutomationState) -> Self {
    switch state {
    case .running:
      Self(
        symbolName: "play.circle.fill",
        colorToken: .green,
        accessibilityTitle: "Running"
      )
    case .idle:
      Self(
        symbolName: "pause.circle",
        colorToken: .secondary,
        accessibilityTitle: "Idle"
      )
    case .disabled:
      Self(
        symbolName: "nosign",
        colorToken: .secondary,
        accessibilityTitle: "Disabled"
      )
    case .needsApproval:
      Self(
        symbolName: "person.badge.clock",
        colorToken: .orange,
        accessibilityTitle: "Needs Approval"
      )
    case .invalid:
      Self(
        symbolName: "exclamationmark.triangle",
        colorToken: .red,
        accessibilityTitle: "Invalid"
      )
    case .unresolved:
      Self(
        symbolName: "questionmark.circle",
        colorToken: .orange,
        accessibilityTitle: "Unresolved"
      )
    }
  }
}

struct AutomationStateLabelPresentation: Equatable, Sendable {
  let title: String
  let symbolName: String
  let colorToken: AutomationColorToken

  init(state: AutomationState) {
    let identity = AutomationVisualIdentity.state(for: state)
    title = identity.accessibilityTitle
    symbolName = identity.symbolName
    colorToken = identity.colorToken
  }
}
