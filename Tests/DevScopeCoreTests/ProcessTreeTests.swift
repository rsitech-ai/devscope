import XCTest
@testable import DevScopeCore

final class ProcessTreeTests: XCTestCase {
  func testFindsAllDescendantsWithoutIncludingRootOrUnrelatedProcesses() {
    let processes = [
      DevProcess(pid: 10, parentPID: 1, executable: "npm", command: "npm run dev"),
      DevProcess(pid: 11, parentPID: 10, executable: "sh", command: "sh -c next dev"),
      DevProcess(pid: 12, parentPID: 11, executable: "node", command: "node next dev"),
      DevProcess(pid: 20, parentPID: 1, executable: "python", command: "python other.py")
    ]

    let descendants = ProcessTree.descendants(of: 10, in: processes)

    XCTAssertEqual(descendants.map(\.pid).sorted(), [11, 12])
  }

  func testIgnoresCyclesInMalformedSnapshots() {
    let processes = [
      DevProcess(pid: 10, parentPID: 12, executable: "npm", command: "npm run dev"),
      DevProcess(pid: 11, parentPID: 10, executable: "sh", command: "sh -c next dev"),
      DevProcess(pid: 12, parentPID: 11, executable: "node", command: "node next dev")
    ]

    let descendants = ProcessTree.descendants(of: 10, in: processes)

    XCTAssertEqual(descendants.map(\.pid).sorted(), [11, 12])
  }
}
