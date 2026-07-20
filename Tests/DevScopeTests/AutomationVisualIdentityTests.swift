import DevScopeCore
import XCTest

@testable import DevScope

final class AutomationVisualIdentityTests: XCTestCase {
  func testEveryAutomationKindHasAnExactStableFallbackIdentity() {
    let expected: [AutomationKind: AutomationVisualIdentity] = [
      .launchAgent: .init(
        symbolName: "bolt.horizontal",
        colorToken: .blue,
        accessibilityTitle: "LaunchAgent"
      ),
      .launchDaemon: .init(
        symbolName: "bolt.horizontal.circle",
        colorToken: .indigo,
        accessibilityTitle: "LaunchDaemon"
      ),
      .loginItem: .init(
        symbolName: "person.crop.circle.badge.clock",
        colorToken: .cyan,
        accessibilityTitle: "Login item"
      ),
      .backgroundItem: .init(
        symbolName: "person.crop.circle.badge.clock",
        colorToken: .cyan,
        accessibilityTitle: "Background item"
      ),
      .cron: .init(
        symbolName: "calendar.badge.clock",
        colorToken: .purple,
        accessibilityTitle: "Scheduled automation"
      ),
    ]

    XCTAssertEqual(Set(expected.keys), Set(AutomationKind.allCases))
    for kind in AutomationKind.allCases {
      XCTAssertEqual(AutomationVisualIdentity.fallback(for: kind), expected[kind])
    }
  }

  func testAutomationStatesKeepSymbolTextAndSemanticColorTogether() {
    let expected: [(AutomationState, String, AutomationColorToken, String)] = [
      (.running, "play.circle.fill", .green, "Running"),
      (.idle, "pause.circle", .secondary, "Idle"),
      (.disabled, "nosign", .secondary, "Disabled"),
      (.needsApproval, "person.badge.clock", .orange, "Needs Approval"),
      (.invalid, "exclamationmark.triangle", .red, "Invalid"),
      (.unresolved, "questionmark.circle", .orange, "Unresolved"),
    ]

    for (state, symbolName, colorToken, accessibilityTitle) in expected {
      let identity = AutomationVisualIdentity.state(for: state)
      XCTAssertEqual(identity.symbolName, symbolName)
      XCTAssertEqual(identity.colorToken, colorToken)
      XCTAssertEqual(identity.accessibilityTitle, accessibilityTitle)
    }
  }

  func testEveryAutomationStateLabelCarriesVisibleTextSymbolAndColor() {
    let expected: [(AutomationState, String, String, AutomationColorToken)] = [
      (.running, "Running", "play.circle.fill", .green),
      (.idle, "Idle", "pause.circle", .secondary),
      (.disabled, "Disabled", "nosign", .secondary),
      (.needsApproval, "Needs Approval", "person.badge.clock", .orange),
      (.invalid, "Invalid", "exclamationmark.triangle", .red),
      (.unresolved, "Unresolved", "questionmark.circle", .orange),
    ]

    XCTAssertEqual(expected.count, AutomationState.allCases.count)
    for (state, title, symbolName, colorToken) in expected {
      let presentation = AutomationStateLabelPresentation(state: state)
      XCTAssertEqual(presentation.title, title)
      XCTAssertEqual(presentation.symbolName, symbolName)
      XCTAssertEqual(presentation.colorToken, colorToken)
      XCTAssertFalse(presentation.title.isEmpty)
      XCTAssertFalse(presentation.symbolName.isEmpty)
    }
  }
}
