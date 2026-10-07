import Foundation
import XCTest
@testable import DevScope

final class BlockingSystemWorkTests: XCTestCase {
  func testSystemWorkRunsOutsideSwiftTasksAndReturnsItsResult() async throws {
    let result = try await BlockingSystemWork.run {
      (withUnsafeCurrentTask { $0 == nil }, Thread.isMainThread, 42)
    }
    XCTAssertTrue(result.0)
    XCTAssertFalse(result.1)
    XCTAssertEqual(result.2, 42)
  }

  func testPropagatesSystemErrors() async {
    do {
      _ = try await BlockingSystemWork.run { throw CocoaError(.fileReadNoPermission) }
      XCTFail("Expected the system error")
    } catch {
      XCTAssertEqual((error as? CocoaError)?.code, .fileReadNoPermission)
    }
  }
}
