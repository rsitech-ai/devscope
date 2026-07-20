import XCTest
@testable import DevScopeCore

final class ProcessSnapshotStabilizerTests: XCTestCase {
  func testRetainsRecentlyMissingProcessesToReduceRefreshChurn() {
    var stabilizer = ClassifiedProcessSnapshotStabilizer()
    let start = Date(timeIntervalSince1970: 1_000)

    let first = stabilizer.merge(
      liveItems: [
        classified(pid: 10, displayName: "api"),
        classified(pid: 20, displayName: "worker")
      ],
      now: start,
      graceInterval: 2
    )

    XCTAssertEqual(first.map(\.process.pid), [10, 20])
    XCTAssertEqual(stabilizer.liveProcessIDs, [10, 20])

    let second = stabilizer.merge(
      liveItems: [
        classified(pid: 20, displayName: "worker")
      ],
      now: start.addingTimeInterval(1),
      graceInterval: 2
    )

    XCTAssertEqual(second.map(\.process.pid), [10, 20])
    XCTAssertEqual(stabilizer.liveProcessIDs, [20])
  }

  func testDropsMissingProcessesAfterGraceInterval() {
    var stabilizer = ClassifiedProcessSnapshotStabilizer()
    let start = Date(timeIntervalSince1970: 1_000)

    _ = stabilizer.merge(
      liveItems: [
        classified(pid: 10, displayName: "api"),
        classified(pid: 20, displayName: "worker")
      ],
      now: start,
      graceInterval: 2
    )

    let result = stabilizer.merge(
      liveItems: [
        classified(pid: 20, displayName: "worker")
      ],
      now: start.addingTimeInterval(3),
      graceInterval: 2
    )

    XCTAssertEqual(result.map(\.process.pid), [20])
    XCTAssertEqual(stabilizer.liveProcessIDs, [20])
  }

  func testPreservesFirstSeenOrderWhenNewProcessesArrive() {
    var stabilizer = ClassifiedProcessSnapshotStabilizer()
    let start = Date(timeIntervalSince1970: 1_000)

    _ = stabilizer.merge(
      liveItems: [
        classified(pid: 20, displayName: "worker")
      ],
      now: start,
      graceInterval: 2
    )

    let result = stabilizer.merge(
      liveItems: [
        classified(pid: 10, displayName: "api"),
        classified(pid: 20, displayName: "worker")
      ],
      now: start.addingTimeInterval(1),
      graceInterval: 2
    )

    XCTAssertEqual(result.map(\.process.pid), [20, 10])
  }

  private func classified(pid: Int32, displayName: String) -> ClassifiedDevProcess {
    ClassifiedDevProcess(
      process: DevProcess(
        pid: pid,
        parentPID: 1,
        executable: displayName,
        command: displayName,
        currentDirectory: "\(NSHomeDirectory())/dev/example/\(displayName)",
        resourceUsage: DevProcessResourceUsage(cpuPercent: 0, residentMemoryBytes: 1, elapsedTime: "00:01")
      ),
      classification: DevProcessClassification(
        kind: .javascript,
        displayName: displayName,
        projectHint: displayName
      )
    )
  }
}
