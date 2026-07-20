import XCTest
@testable import DevScopeCore

final class InterfacePresentationTests: XCTestCase {
  func testWorkspaceModeAndAutomationSettingKeysAreStableAcrossReleases() {
    XCTAssertEqual(DevScopeWorkspaceMode.processes.rawValue, "processes")
    XCTAssertEqual(DevScopeWorkspaceMode.automations.rawValue, "automations")
    XCTAssertEqual(
      AutomationPresentationSettings.selectedWorkspaceModeKey,
      "selectedWorkspaceMode"
    )
    XCTAssertEqual(
      AutomationPresentationSettings.longRunningThresholdSecondsKey,
      "longRunningThresholdSeconds"
    )
    XCTAssertEqual(
      AutomationPresentationSettings.includeAppleSystemServicesKey,
      "includeAppleSystemServices"
    )
  }

  func testLongRunningThresholdClampsAndRoundsToOneHourSteps() {
    XCTAssertEqual(AutomationPresentationSettings.normalizedThreshold(-1), 3_600)
    XCTAssertEqual(AutomationPresentationSettings.normalizedThreshold(5_399), 3_600)
    XCTAssertEqual(AutomationPresentationSettings.normalizedThreshold(5_400), 7_200)
    XCTAssertEqual(AutomationPresentationSettings.normalizedThreshold(999_999), 604_800)
    XCTAssertEqual(AutomationPresentationSettings.normalizedThreshold(.nan), 14_400)
  }

  func testFocusWorkflowsShowSixItemsAndRetainAnOutOfRangeSelection() {
    let workflows = (1...10).map(workflow)

    XCTAssertEqual(
      InterfacePresentation.visibleFocusWorkflows(
        workflows,
        selectedID: workflows[8].id,
        showsAll: false
      ).map(\.id),
      workflows.prefix(6).map(\.id) + [workflows[8].id]
    )
  }

  func testKeyboardSelectionMovesWithinVisibleRowsAndRecoversFromAStaleSelection() {
    let visibleIDs: [Int32] = [11, 22, 33]

    XCTAssertEqual(
      InterfacePresentation.movedSelection(in: visibleIDs, current: 22, direction: .next),
      33
    )
    XCTAssertEqual(
      InterfacePresentation.movedSelection(in: visibleIDs, current: 33, direction: .next),
      33
    )
    XCTAssertEqual(
      InterfacePresentation.movedSelection(in: visibleIDs, current: 999, direction: .previous),
      33
    )
    XCTAssertNil(
      InterfacePresentation.movedSelection(in: [], current: 22, direction: .next)
    )
  }

  func testFocusDisclosureReturnsEveryWorkflowWhenExpanded() {
    let workflows = (1...10).map(workflow)

    XCTAssertEqual(
      InterfacePresentation.visibleFocusWorkflows(
        workflows,
        selectedID: workflows[8].id,
        showsAll: true
      ),
      workflows
    )
  }

  func testKeyboardSelectionStartsAndClampsAtTheRequestedEdge() {
    let visibleIDs: [Int32] = [11, 22, 33]

    XCTAssertEqual(
      InterfacePresentation.movedSelection(in: visibleIDs, current: nil, direction: .next),
      11
    )
    XCTAssertEqual(
      InterfacePresentation.movedSelection(in: visibleIDs, current: nil, direction: .previous),
      33
    )
    XCTAssertEqual(
      InterfacePresentation.movedSelection(in: visibleIDs, current: 11, direction: .previous),
      11
    )
  }

  private func workflow(_ index: Int) -> DevWorkflow {
    DevWorkflow(
      id: "workflow:\(index)",
      title: "Workflow \(index)",
      subtitle: "1 process",
      kind: .projectWorkspace,
      processIDs: [Int32(index)],
      primaryProject: nil,
      tags: [],
      totalCPU: 0,
      totalMemoryBytes: 0,
      risk: .normal,
      confidence: 1,
      summary: "Summary",
      suggestedAction: "Inspect"
    )
  }
}
