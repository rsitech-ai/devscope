import XCTest
@testable import DevScopeCore

final class ProcessActionPresentationTests: XCTestCase {
  func testEndedProcessGuidanceWinsForEveryDestructiveControl() {
    for control in ProcessActionControl.allCases {
      let presentation = ProcessActionPresentation.control(
        control,
        isEnded: true,
        actionDecision: .protected(reason: "policy reason must not win")
      )

      XCTAssertTrue(presentation.isDisabled)
      XCTAssertEqual(presentation.help, "Unavailable: This process has ended.")
      XCTAssertEqual(
        presentation.accessibilityHint,
        "Unavailable because the selected process has ended."
      )
    }
  }

  func testProtectedProcessDisablesEveryDestructiveControlWithPolicyGuidance() {
    let reason = "Critical macOS system infrastructure is protected"

    for control in ProcessActionControl.allCases {
      let presentation = ProcessActionPresentation.control(
        control,
        isEnded: false,
        actionDecision: .protected(reason: reason)
      )

      XCTAssertTrue(presentation.isDisabled)
      XCTAssertEqual(presentation.help, "Unavailable: \(reason)")
      XCTAssertEqual(presentation.accessibilityHint, "Unavailable: \(reason)")
    }
  }

  func testTerminationConsequencesStaySpecificToTheSelectedAction() {
    XCTAssertEqual(
      ProcessTerminationAction.single.consequence(pid: 77, descendantCount: 2),
      "Sends SIGTERM to PID 77. The process may save state before exiting."
    )
    XCTAssertEqual(
      ProcessTerminationAction.tree.consequence(pid: 77, descendantCount: 2),
      "Sends SIGTERM to PID 77 after 2 descendant processes."
    )
    XCTAssertEqual(
      ProcessTerminationAction.forceSingle.consequence(pid: 77, descendantCount: 2),
      "Sends SIGKILL to PID 77. The process cannot save state."
    )
    XCTAssertEqual(
      ProcessTerminationAction.forceTree.consequence(pid: 77, descendantCount: 1),
      "Sends SIGKILL to PID 77 and 1 descendant process. None can save state."
    )
  }
}
