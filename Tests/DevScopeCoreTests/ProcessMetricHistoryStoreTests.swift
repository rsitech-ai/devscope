import XCTest
@testable import DevScopeCore

final class ProcessMetricHistoryStoreTests: XCTestCase {
  func testRecordsMetricSamplesForAProcess() throws {
    var store = ProcessMetricHistoryStore(limit: 3)
    let timestamp = Date(timeIntervalSince1970: 100)

    store.record(
      processes: [process(pid: 700, cpu: 12, memory: 256)],
      gpuMetric: DevGPUMetric(utilizationPercent: 34),
      timestamp: timestamp
    )

    let sample = try XCTUnwrap(store.history(for: 700).first)
    XCTAssertEqual(sample.timestamp, timestamp)
    XCTAssertEqual(sample.cpuPercent, 12)
    XCTAssertEqual(sample.residentMemoryBytes, 256)
    XCTAssertEqual(sample.gpuPercent, 34)
  }

  func testCapsEachProcessHistoryAtTheConfiguredLimit() {
    var store = ProcessMetricHistoryStore(limit: 2)

    for value in 1...3 {
      store.record(
        processes: [process(pid: 700, cpu: Double(value), memory: Int64(value))],
        gpuMetric: nil,
        timestamp: Date(timeIntervalSince1970: TimeInterval(value))
      )
    }

    XCTAssertEqual(store.history(for: 700).map(\.cpuPercent), [2, 3])
  }

  func testDropsHistoryForInactiveProcesses() {
    var store = ProcessMetricHistoryStore(limit: 3)
    store.record(
      processes: [
        process(pid: 700, cpu: 1, memory: 100),
        process(pid: 701, cpu: 2, memory: 200),
      ],
      gpuMetric: nil,
      timestamp: Date(timeIntervalSince1970: 1)
    )

    store.record(
      processes: [process(pid: 701, cpu: 3, memory: 300)],
      gpuMetric: nil,
      timestamp: Date(timeIntervalSince1970: 2)
    )

    XCTAssertTrue(store.history(for: 700).isEmpty)
    XCTAssertEqual(store.history(for: 701).map(\.cpuPercent), [2, 3])
  }

  func testResetsHistoryWhenAPIDIsRecycled() {
    var store = ProcessMetricHistoryStore(limit: 3)
    store.record(
      processes: [
        process(
          pid: 700,
          cpu: 1,
          memory: 100,
          birthToken: ProcessBirthToken(seconds: 1_000, microseconds: 100)
        )
      ],
      gpuMetric: nil,
      timestamp: Date(timeIntervalSince1970: 1)
    )

    store.record(
      processes: [
        process(
          pid: 700,
          cpu: 2,
          memory: 200,
          birthToken: ProcessBirthToken(seconds: 1_000, microseconds: 101)
        )
      ],
      gpuMetric: nil,
      timestamp: Date(timeIntervalSince1970: 2)
    )

    XCTAssertEqual(store.history(for: 700).map(\.cpuPercent), [2])
  }

  func testResetsRecycledPIDBeforeNewMetricsArrive() {
    var store = ProcessMetricHistoryStore(limit: 3)
    store.record(
      processes: [
        process(
          pid: 700,
          cpu: 1,
          memory: 100,
          birthToken: ProcessBirthToken(seconds: 1_000, microseconds: 100)
        )
      ],
      gpuMetric: nil,
      timestamp: Date(timeIntervalSince1970: 1)
    )

    store.record(
      processes: [
        processWithoutMetrics(
          pid: 700,
          birthToken: ProcessBirthToken(seconds: 1_000, microseconds: 101)
        )
      ],
      gpuMetric: nil,
      timestamp: Date(timeIntervalSince1970: 2)
    )

    XCTAssertTrue(store.history(for: 700).isEmpty)
  }

  func testResetsUnknownBirthHistoryWhenFallbackIdentityChanges() {
    var store = ProcessMetricHistoryStore(limit: 3)
    store.record(
      processes: [process(pid: 700, cpu: 1, memory: 100)],
      gpuMetric: nil,
      timestamp: Date(timeIntervalSince1970: 1)
    )

    store.record(
      processes: [
        process(
          pid: 700,
          cpu: 2,
          memory: 200,
          command: "worker --replacement"
        )
      ],
      gpuMetric: nil,
      timestamp: Date(timeIntervalSince1970: 2)
    )

    XCTAssertEqual(store.history(for: 700).map(\.cpuPercent), [2])
  }

  func testRetainsHistoryWhenKnownBirthMetadataIsEnriched() {
    var store = ProcessMetricHistoryStore(limit: 3)
    let birthToken = ProcessBirthToken(seconds: 1_000, microseconds: 100)
    store.record(
      processes: [
        process(
          pid: 700,
          cpu: 1,
          memory: 100,
          executable: "node",
          command: "node",
          birthToken: birthToken
        )
      ],
      gpuMetric: nil,
      timestamp: Date(timeIntervalSince1970: 1)
    )

    store.record(
      processes: [
        process(
          pid: 700,
          cpu: 2,
          memory: 200,
          parentPID: 99,
          executable: "/opt/homebrew/bin/node",
          command: "/opt/homebrew/bin/node server.js",
          birthToken: birthToken
        )
      ],
      gpuMetric: nil,
      timestamp: Date(timeIntervalSince1970: 2)
    )

    XCTAssertEqual(store.history(for: 700).map(\.cpuPercent), [1, 2])
  }

  private func process(
    pid: Int32,
    cpu: Double,
    memory: Int64,
    parentPID: Int32 = 1,
    executable: String = "worker",
    command: String = "worker --serve",
    birthToken: ProcessBirthToken? = nil
  ) -> DevProcess {
    DevProcess(
      pid: pid,
      parentPID: parentPID,
      executable: executable,
      command: command,
      resourceUsage: DevProcessResourceUsage(
        cpuPercent: cpu,
        residentMemoryBytes: memory,
        elapsedTime: "00:10"
      ),
      birthToken: birthToken
    )
  }

  private func processWithoutMetrics(
    pid: Int32,
    birthToken: ProcessBirthToken
  ) -> DevProcess {
    DevProcess(
      pid: pid,
      parentPID: 1,
      executable: "worker",
      command: "worker --serve",
      birthToken: birthToken
    )
  }
}
