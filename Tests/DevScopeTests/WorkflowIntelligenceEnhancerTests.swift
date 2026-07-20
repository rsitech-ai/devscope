import DevScopeCore
import XCTest
@testable import DevScope

final class WorkflowIntelligenceEnhancerTests: XCTestCase {
  func testCacheKeyChangesWhenWorkflowFactsChangeUnderTheSameStableID() {
    let baseline = workflow(cpu: 10, memory: 128 * 1_024 * 1_024, processIDs: [41])
    let changedUsage = workflow(cpu: 85, memory: 5 * 1_024 * 1_024 * 1_024, processIDs: [41])
    let changedComposition = workflow(cpu: 10, memory: 128 * 1_024 * 1_024, processIDs: [41, 42])

    XCTAssertNotEqual(
      WorkflowNoteCacheKey(workflow: baseline, items: []),
      WorkflowNoteCacheKey(workflow: changedUsage, items: [])
    )
    XCTAssertNotEqual(
      WorkflowNoteCacheKey(workflow: baseline, items: []),
      WorkflowNoteCacheKey(workflow: changedComposition, items: [])
    )
    XCTAssertEqual(
      WorkflowNoteCacheKey(workflow: baseline, items: []),
      WorkflowNoteCacheKey(workflow: baseline, items: [])
    )
  }

  private func workflow(cpu: Double, memory: Int64, processIDs: [Int32]) -> DevWorkflow {
    DevWorkflow(
      id: "workflow:stable",
      title: "Stable Workflow",
      subtitle: "facts",
      kind: .buildWorkspace,
      processIDs: processIDs,
      primaryProject: "DevScope",
      tags: [],
      totalCPU: cpu,
      totalMemoryBytes: memory,
      risk: cpu >= 80 ? .heavy : .normal,
      confidence: 0.9,
      summary: "Current workflow facts.",
      suggestedAction: "Inspect it."
    )
  }
}
