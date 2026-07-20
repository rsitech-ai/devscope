import XCTest
@testable import DevScopeCore

final class ProcessSnapshotBuilderTests: XCTestCase {
  func testInvalidatingWorkspaceFactsReclassifiesAnUnchangedProcess() throws {
    var manifestExists = false
    var probeCount = 0
    let workspaceFactsCache = WorkspaceFactsCache { path in
      probeCount += 1
      return manifestExists && path.hasSuffix("/pubspec.yaml")
    }
    var builder = ProcessSnapshotBuilder(workspaceFactsCache: workspaceFactsCache)
    let process = DevProcess(
      pid: 799,
      parentPID: 1,
      executable: "workspace-runner",
      command: "workspace-runner serve",
      currentDirectory: NSHomeDirectory() + "/dev/example/app",
      birthToken: ProcessBirthToken(seconds: 1_000, microseconds: 41)
    )
    let start = Date(timeIntervalSince1970: 100)

    let beforeManifest = builder.build(
      processes: [process],
      now: start,
      graceInterval: 2.5
    )
    manifestExists = true
    builder.invalidateWorkspaceFacts()
    let afterManifest = builder.build(
      processes: [process],
      now: start.addingTimeInterval(2),
      graceInterval: 2.5
    )

    XCTAssertEqual(try XCTUnwrap(beforeManifest.classified.first).classification.kind, .other)
    XCTAssertEqual(try XCTUnwrap(afterManifest.classified.first).classification.kind, .flutter)
    XCTAssertEqual(probeCount, 3)
  }

  func testUpdatesMetricsWithoutLosingClassificationOrLiveIdentity() throws {
    var builder = ProcessSnapshotBuilder()
    let start = Date(timeIntervalSince1970: 100)
    let birthToken = ProcessBirthToken(seconds: 1_000, microseconds: 42)

    let first = builder.build(
      processes: [process(cpu: 1, birthToken: birthToken)],
      now: start,
      graceInterval: 2.5
    )
    let second = builder.build(
      processes: [process(cpu: 90, birthToken: birthToken)],
      now: start.addingTimeInterval(2),
      graceInterval: 2.5
    )

    XCTAssertEqual(first.classified.first?.classification.kind, .javascript)
    XCTAssertEqual(second.classified.first?.classification.kind, .javascript)
    XCTAssertEqual(second.classified.first?.process.resourceUsage?.cpuPercent, 90)
    XCTAssertEqual(second.classified.first?.process.birthToken, birthToken)
    XCTAssertEqual(second.liveProcessIDs, Set([800]))
    XCTAssertEqual(second.processes, second.classified.map(\.process))
  }

  func testRehydratesCachedWorkflowMetricsWithoutRebuildingStructure() throws {
    var builder = ProcessSnapshotBuilder()
    let start = Date(timeIntervalSince1970: 100)
    let birthToken = ProcessBirthToken(seconds: 1_000, microseconds: 42)

    let first = builder.build(
      processes: [process(cpu: 1, birthToken: birthToken)],
      now: start,
      graceInterval: 2.5
    )
    let metricTick = builder.build(
      processes: [process(cpu: 90, birthToken: birthToken)],
      now: start.addingTimeInterval(2),
      graceInterval: 2.5
    )
    let workflowTick = builder.build(
      processes: [process(cpu: 90, birthToken: birthToken)],
      now: start.addingTimeInterval(10),
      graceInterval: 2.5
    )

    let firstWorkflow = try XCTUnwrap(first.workflows.first)
    XCTAssertEqual(metricTick.classified.first?.process.resourceUsage?.cpuPercent, 90)
    XCTAssertEqual(firstWorkflow.totalCPU, 1)
    XCTAssertEqual(metricTick.workflows.first?.totalCPU, 90)
    XCTAssertEqual(workflowTick.workflows.first?.totalCPU, 90)
  }

  func testInvalidatingWorkspaceFactsRefreshesCachedWorkflowMetrics() throws {
    var builder = ProcessSnapshotBuilder()
    let start = Date(timeIntervalSince1970: 100)
    let birthToken = ProcessBirthToken(seconds: 1_000, microseconds: 42)

    let first = builder.build(
      processes: [process(cpu: 1, birthToken: birthToken)],
      now: start,
      graceInterval: 2.5
    )
    builder.invalidateWorkspaceFacts()
    let afterInvalidation = builder.build(
      processes: [process(cpu: 90, birthToken: birthToken)],
      now: start.addingTimeInterval(2),
      graceInterval: 2.5
    )

    XCTAssertEqual(try XCTUnwrap(first.workflows.first).totalCPU, 1)
    XCTAssertEqual(try XCTUnwrap(afterInvalidation.workflows.first).totalCPU, 90)
  }

  private func process(cpu: Double, birthToken: ProcessBirthToken) -> DevProcess {
    let workspace = NSHomeDirectory() + "/dev/devscope-fixture"
    return DevProcess(
      pid: 800,
      parentPID: 1,
      executable: "node",
      command: "node \(workspace)/node_modules/.bin/vite",
      currentDirectory: workspace,
      resourceUsage: DevProcessResourceUsage(
        cpuPercent: cpu,
        residentMemoryBytes: 100,
        elapsedTime: "00:10"
      ),
      birthToken: birthToken
    )
  }
}
