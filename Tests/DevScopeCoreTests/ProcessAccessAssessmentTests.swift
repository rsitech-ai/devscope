import DevScopeCore
import XCTest

final class ProcessAccessAssessmentTests: XCTestCase {
  func testSandboxedBuildDoesNotSuggestPrivacyPermissions() {
    let assessment = ProcessAccessAssessment.assess(
      isSandboxed: true,
      processes: [],
      errorDescription: "Native process scanning returned no visible processes"
    )

    XCTAssertTrue(assessment.hasBlockedRequirement)
    XCTAssertFalse(assessment.hasNeededAction)
    XCTAssertEqual(assessment.requirements.map(\.kind), [.processMetadata])
    XCTAssertEqual(assessment.requirements.first?.state, .blocked)
    XCTAssertNil(assessment.requirements.first?.action)
  }

  func testReadyProcessAndFolderAccessShowsNoNeededActions() {
    let assessment = ProcessAccessAssessment.assess(
      isSandboxed: false,
      processes: [
        process(pid: 100, currentDirectory: "/Users/example/dev/sample-app"),
        process(pid: 101, currentDirectory: "/Users/example/dev/sample-service")
      ],
      errorDescription: nil
    )

    XCTAssertFalse(assessment.hasBlockedRequirement)
    XCTAssertFalse(assessment.hasNeededAction)
    XCTAssertEqual(assessment.processCount, 2)
    XCTAssertEqual(assessment.currentDirectoryCount, 2)
    XCTAssertEqual(assessment.requirements.map(\.state), [.ready, .ready])
  }

  func testMissingFolderContextSuggestsFullDiskAccessOnly() {
    let assessment = ProcessAccessAssessment.assess(
      isSandboxed: false,
      processes: [
        process(pid: 100, currentDirectory: nil),
        process(pid: 101, currentDirectory: nil)
      ],
      errorDescription: nil
    )

    XCTAssertTrue(assessment.hasNeededAction)
    XCTAssertEqual(assessment.requirements.map(\.kind), [.processMetadata, .workingDirectories])
    XCTAssertEqual(assessment.requirements.map(\.state), [.ready, .needed])
    XCTAssertEqual(assessment.requirements.last?.action, .fullDiskAccess)
  }

  func testProcessScanFailureDoesNotSuggestUserGrantablePermission() {
    let assessment = ProcessAccessAssessment.assess(
      isSandboxed: false,
      processes: nil,
      errorDescription: "Process scanning is blocked by macOS"
    )

    XCTAssertTrue(assessment.hasBlockedRequirement)
    XCTAssertFalse(assessment.hasNeededAction)
    XCTAssertEqual(assessment.requirements.map(\.kind), [.processMetadata])
    XCTAssertEqual(assessment.requirements.first?.state, .blocked)
    XCTAssertNil(assessment.requirements.first?.action)
  }

  private func process(pid: Int32, currentDirectory: String?) -> DevProcess {
    DevProcess(
      pid: pid,
      parentPID: 1,
      executable: "python3.12",
      command: "python train.py",
      currentDirectory: currentDirectory,
      resourceUsage: nil
    )
  }
}
