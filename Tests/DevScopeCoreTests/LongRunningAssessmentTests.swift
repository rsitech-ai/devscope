import XCTest
@testable import DevScopeCore

final class LongRunningAssessmentTests: XCTestCase {
  func testFourHourBoundaryIsInclusive() {
    let below = DevProcessResourceUsage(
      cpuPercent: 0, residentMemoryBytes: 1, elapsedTime: "03:59:59")
    let boundary = DevProcessResourceUsage(
      cpuPercent: 0, residentMemoryBytes: 1, elapsedTime: "04:00:00")

    XCTAssertFalse(LongRunningAssessment.isLongRunning(below, threshold: 14_400))
    XCTAssertTrue(LongRunningAssessment.isLongRunning(boundary, threshold: 14_400))
  }

  func testUnavailableElapsedTimeDoesNotBecomeLongRunning() {
    let usage = DevProcessResourceUsage(
      cpuPercent: 0, residentMemoryBytes: 1, elapsedTime: "-")

    XCTAssertFalse(LongRunningAssessment.isLongRunning(usage, threshold: 14_400))
    XCTAssertFalse(LongRunningAssessment.isLongRunning(nil, threshold: 14_400))
  }

  func testDefaultThresholdIsExactlyFourHoursAndInclusive() {
    let below = DevProcessResourceUsage(
      cpuPercent: 0, residentMemoryBytes: 1, elapsedTime: "03:59:59")
    let boundary = DevProcessResourceUsage(
      cpuPercent: 0, residentMemoryBytes: 1, elapsedTime: "04:00:00")

    XCTAssertFalse(LongRunningAssessment.isLongRunning(below))
    XCTAssertTrue(LongRunningAssessment.isLongRunning(boundary))
  }
}
