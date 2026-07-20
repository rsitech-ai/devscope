import XCTest
@testable import DevScopeCore

final class ProcessWorkflowCacheTests: XCTestCase {
  func testMetricOnlyUpdateRehydratesWorkflowsWithoutRebuilding() throws {
    let buildCount = Counter()
    var cache = ProcessWorkflowCache { items in
      buildCount.value += 1
      return ProcessIntelligence.uncappedWorkflows(for: items)
    }
    let start = Date(timeIntervalSince1970: 100)

    let first = cache.workflows(for: [item(cpu: 1)], now: start)
    let second = cache.workflows(
      for: [item(cpu: 90, memory: 900, elapsedTime: "00:12")],
      now: start.addingTimeInterval(2)
    )

    XCTAssertEqual(buildCount.value, 1)
    XCTAssertEqual(try XCTUnwrap(first.first).totalCPU, 1)
    XCTAssertEqual(try XCTUnwrap(second.first).totalCPU, 90)
    XCTAssertEqual(try XCTUnwrap(second.first).totalMemoryBytes, 900)
  }

  func testStableFingerprintReusesWorkflowsIndefinitely() throws {
    let buildCount = Counter()
    var cache = ProcessWorkflowCache { items in
      buildCount.value += 1
      return ProcessIntelligence.uncappedWorkflows(for: items)
    }
    let start = Date(timeIntervalSince1970: 100)

    let first = cache.workflows(for: [item(cpu: 1)], now: start)
    let afterTwoMinutes = cache.workflows(
      for: [item(cpu: 90, memory: 5_000_000_000, elapsedTime: "00:20")],
      now: start.addingTimeInterval(120)
    )
    let muchLater = cache.workflows(
      for: [item(cpu: 45, memory: 2_000_000_000, elapsedTime: "12:34")],
      now: start.addingTimeInterval(10_000)
    )

    let firstWorkflow = try XCTUnwrap(first.first)
    let afterTwoMinutesWorkflow = try XCTUnwrap(afterTwoMinutes.first)
    let muchLaterWorkflow = try XCTUnwrap(muchLater.first)
    XCTAssertEqual(buildCount.value, 1)
    XCTAssertEqual(firstWorkflow.totalCPU, 1)
    XCTAssertEqual(afterTwoMinutesWorkflow.totalCPU, 90)
    XCTAssertEqual(afterTwoMinutesWorkflow.totalMemoryBytes, 5_000_000_000)
    XCTAssertEqual(afterTwoMinutesWorkflow.risk, .heavy)
    XCTAssertEqual(muchLaterWorkflow.totalCPU, 45)
    XCTAssertEqual(muchLaterWorkflow.totalMemoryBytes, 2_000_000_000)
    XCTAssertEqual(muchLaterWorkflow.risk, .busy)
  }

  func testWorkflowRelevantIdentityAndClassificationChangesRecomputeImmediately() {
    let baseline = item(cpu: 1)
    let variants = [
      item(cpu: 1, pid: 801),
      item(cpu: 1, birthToken: ProcessBirthToken(seconds: 1_001, microseconds: 43)),
      item(cpu: 1, parentPID: 2),
      item(cpu: 1, executable: "bun"),
      item(cpu: 1, command: "node worker.js"),
      item(cpu: 1, currentDirectory: "/tmp/other"),
      item(cpu: 1, kind: .python),
      item(cpu: 1, displayName: "worker.js"),
      item(cpu: 1, projectHint: "other"),
      item(cpu: 1, tags: [.api, .experiment]),
    ]

    for variant in variants {
      let buildCount = Counter()
      var cache = ProcessWorkflowCache { items in
        buildCount.value += 1
        return ProcessIntelligence.uncappedWorkflows(for: items)
      }
      let start = Date(timeIntervalSince1970: 100)

      _ = cache.workflows(for: [baseline], now: start)
      _ = cache.workflows(for: [variant], now: start.addingTimeInterval(2))

      XCTAssertEqual(buildCount.value, 2, "Expected an immediate rebuild for \(variant)")
    }
  }

  func testAddingAndRemovingAProcessRecomputesImmediately() {
    let buildCount = Counter()
    var cache = ProcessWorkflowCache { items in
      buildCount.value += 1
      return ProcessIntelligence.uncappedWorkflows(for: items)
    }
    let start = Date(timeIntervalSince1970: 100)
    let first = item(cpu: 1)
    let second = item(cpu: 1, pid: 801)

    _ = cache.workflows(for: [first], now: start)
    _ = cache.workflows(for: [first, second], now: start.addingTimeInterval(2))
    _ = cache.workflows(for: [first], now: start.addingTimeInterval(4))

    XCTAssertEqual(buildCount.value, 3)
  }

  func testIrrelevantMachineProcessChurnDoesNotRebuildWorkflows() {
    let buildCount = Counter()
    var cache = ProcessWorkflowCache { items in
      buildCount.value += 1
      return ProcessIntelligence.uncappedWorkflows(for: items)
    }
    let start = Date(timeIntervalSince1970: 100)
    let relevant = item(cpu: 1)
    let firstSystemProcess = item(
      cpu: 0,
      pid: 900,
      executable: "/usr/libexec/distnoted",
      command: "/usr/libexec/distnoted agent",
      currentDirectory: "/",
      kind: .systemService,
      displayName: "distnoted",
      projectHint: nil,
      tags: []
    )
    let replacementSystemProcess = item(
      cpu: 0,
      pid: 901,
      executable: "/usr/libexec/distnoted",
      command: "/usr/libexec/distnoted agent",
      currentDirectory: "/",
      kind: .systemService,
      displayName: "distnoted",
      projectHint: nil,
      tags: []
    )

    let first = cache.workflows(for: [relevant, firstSystemProcess], now: start)
    let afterChurn = cache.workflows(
      for: [relevant, replacementSystemProcess],
      now: start.addingTimeInterval(2)
    )

    XCTAssertEqual(buildCount.value, 1)
    XCTAssertEqual(afterChurn, first)
  }

  func testProcessOrderChangeRecomputesImmediately() {
    let buildCount = Counter()
    var cache = ProcessWorkflowCache { items in
      buildCount.value += 1
      return ProcessIntelligence.uncappedWorkflows(for: items)
    }
    let start = Date(timeIntervalSince1970: 100)
    let first = item(cpu: 1)
    let second = item(cpu: 1, pid: 801)

    _ = cache.workflows(for: [first, second], now: start)
    _ = cache.workflows(for: [second, first], now: start.addingTimeInterval(2))

    XCTAssertEqual(buildCount.value, 2)
  }

  func testMetricRiskChangeReordersCachedWorkflowsWithoutRebuilding() {
    let buildCount = Counter()
    var cache = ProcessWorkflowCache { items in
      buildCount.value += 1
      return ProcessIntelligence.uncappedWorkflows(for: items)
    }
    let start = Date(timeIntervalSince1970: 100)
    let alpha = item(
      cpu: 1,
      currentDirectory: "\(NSHomeDirectory())/dev/example/alpha",
      projectHint: "alpha",
      tags: []
    )
    let beta = item(
      cpu: 1,
      pid: 801,
      currentDirectory: "\(NSHomeDirectory())/dev/example/beta",
      projectHint: "beta",
      tags: []
    )
    let heavyBeta = item(
      cpu: 90,
      pid: 801,
      currentDirectory: "\(NSHomeDirectory())/dev/example/beta",
      projectHint: "beta",
      tags: []
    )

    let initial = cache.workflows(for: [alpha, beta], now: start)
    let reordered = cache.workflows(
      for: [alpha, heavyBeta],
      now: start.addingTimeInterval(2)
    )

    XCTAssertEqual(initial.map(\.title), ["Alpha Web", "Beta Web"])
    XCTAssertEqual(reordered.map(\.title), ["Beta Web", "Alpha Web"])
    XCTAssertEqual(buildCount.value, 1)
  }

  func testMetricRiskChangePromotesThirteenthCachedWorkflowWithoutRebuilding() throws {
    let buildCount = Counter()
    var cache = ProcessWorkflowCache { items in
      buildCount.value += 1
      return ProcessIntelligence.uncappedWorkflows(for: items)
    }
    let start = Date(timeIntervalSince1970: 100)
    let items = (0..<13).map { index in
      item(
        cpu: 1,
        pid: Int32(1_000 + index),
        currentDirectory: "\(NSHomeDirectory())/dev/example/project-\(index)",
        projectHint: "project-\(index)",
        tags: []
      )
    }

    let initial = cache.workflows(for: items, now: start)
    let initialProcessIDs = Set(initial.flatMap(\.processIDs))
    let omittedPID = try XCTUnwrap(
      items.map(\.process.pid).first { !initialProcessIDs.contains($0) }
    )
    let updatedItems = (0..<13).map { index in
      let pid = Int32(1_000 + index)
      return item(
        cpu: pid == omittedPID ? 90 : 1,
        pid: pid,
        currentDirectory: "\(NSHomeDirectory())/dev/example/project-\(index)",
        projectHint: "project-\(index)",
        tags: []
      )
    }

    let promoted = cache.workflows(
      for: updatedItems,
      now: start.addingTimeInterval(2)
    )

    XCTAssertEqual(initial.count, 12)
    XCTAssertEqual(promoted.count, 12)
    XCTAssertTrue(promoted.contains { $0.processIDs.contains(omittedPID) })
    XCTAssertEqual(buildCount.value, 1)
  }

  func testStable850RowFingerprintPerformsNoSecondWorkflowBuild() {
    let buildCount = Counter()
    var cache = ProcessWorkflowCache { items in
      buildCount.value += 1
      return ProcessIntelligence.uncappedWorkflows(for: items)
    }
    let items = (0..<850).map { index in
      item(
        cpu: 1,
        pid: Int32(1_000 + index),
        currentDirectory: "\(NSHomeDirectory())/dev/example/project-\(index)",
        projectHint: "project-\(index)",
        tags: []
      )
    }
    let start = Date(timeIntervalSince1970: 100)

    let first = cache.workflows(for: items, now: start)
    let cached = cache.workflows(for: items, now: start.addingTimeInterval(10_000))

    XCTAssertEqual(buildCount.value, 1)
    XCTAssertEqual(cached, first)
  }

  func testExplicitInvalidationRecomputesImmediately() {
    let buildCount = Counter()
    var cache = ProcessWorkflowCache { items in
      buildCount.value += 1
      return ProcessIntelligence.uncappedWorkflows(for: items)
    }
    let start = Date(timeIntervalSince1970: 100)
    let process = item(cpu: 1)

    _ = cache.workflows(for: [process], now: start)
    cache.invalidate()
    _ = cache.workflows(for: [process], now: start.addingTimeInterval(2))

    XCTAssertEqual(buildCount.value, 2)
  }

  private func item(
    cpu: Double,
    memory: Int64 = 100,
    elapsedTime: String = "00:10",
    pid: Int32 = 800,
    birthToken: ProcessBirthToken = ProcessBirthToken(seconds: 1_000, microseconds: 42),
    parentPID: Int32 = 1,
    executable: String = "node",
    command: String = "node server.js",
    currentDirectory: String = "/tmp/example",
    kind: DevRuntimeKind = .javascript,
    displayName: String = "server.js",
    projectHint: String? = "example",
    tags: [DevProcessTag] = [.api]
  ) -> ClassifiedDevProcess {
    ClassifiedDevProcess(
      process: DevProcess(
        pid: pid,
        parentPID: parentPID,
        executable: executable,
        command: command,
        currentDirectory: currentDirectory,
        resourceUsage: DevProcessResourceUsage(
          cpuPercent: cpu,
          residentMemoryBytes: memory,
          elapsedTime: elapsedTime
        ),
        birthToken: birthToken
      ),
      classification: DevProcessClassification(
        kind: kind,
        displayName: displayName,
        projectHint: projectHint,
        tags: tags
      )
    )
  }
}

private final class Counter: @unchecked Sendable {
  var value = 0
}
