import XCTest
@testable import DevScopeCore

final class BoundedSystemCommandRunnerTests: XCTestCase {
  func testProcessScannerRoutesPSAndLsofThroughTheBoundedRunner() throws {
    let runner = RecordingSystemCommandRunner(results: [
      "/bin/ps": BoundedSystemCommandResult(
        status: 0,
        standardOutput: Data("42 1 1.5 2048 00:10 /bin/sleep /bin/sleep 10\n".utf8),
        standardError: Data()
      ),
      "/usr/sbin/lsof": BoundedSystemCommandResult(
        status: 0,
        standardOutput: Data("p42\nn/var/tmp\n".utf8),
        standardError: Data()
      ),
    ])
    let scanner = SystemProcessScanner(
      nativeMetadataProvider: EmptyNativeMetadataProvider(),
      commandRunner: runner
    )

    let snapshot = try scanner.snapshot(includeCurrentDirectories: true)

    XCTAssertEqual(snapshot.map(\.pid), [42])
    XCTAssertEqual(snapshot.first?.currentDirectory, "/var/tmp")
    XCTAssertEqual(runner.requests.map(\.executablePath), ["/bin/ps", "/usr/sbin/lsof"])
  }

  func testGPUMetricProviderRoutesIORegThroughTheBoundedRunner() throws {
    let runner = RecordingSystemCommandRunner(results: [
      "/usr/sbin/ioreg": BoundedSystemCommandResult(
        status: 0,
        standardOutput: Data("\"Device Utilization %\" = 37\n\"model\" = \"Apple GPU\"\n".utf8),
        standardError: Data()
      )
    ])
    let provider = SystemGPUMetricProvider(
      executableURL: URL(fileURLWithPath: "/usr/sbin/ioreg"),
      commandRunner: runner
    )

    XCTAssertEqual(
      try provider.snapshot(),
      DevGPUMetric(utilizationPercent: 37, modelName: "Apple GPU")
    )
    XCTAssertEqual(runner.requests.map(\.executablePath), ["/usr/sbin/ioreg"])
  }

  func testTimeoutTerminatesTheCompleteCommandGroupWithinBound() throws {
    let runner = BoundedSystemCommandRunner(
      maximumCapturedBytes: 1_024,
      executionTimeout: 0.05,
      terminationGraceInterval: 0.05
    )
    let startedAt = ContinuousClock.now

    XCTAssertThrowsError(
      try runner.run(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "trap '' TERM; while :; do sleep 1; done"]
      )
    ) { error in
      XCTAssertEqual(error as? BoundedSystemCommandError, .executionTimedOut)
    }

    XCTAssertLessThan(startedAt.duration(to: .now), .seconds(2))
  }

  func testOutputLimitDrainsBothStreamsAndFailsClosed() throws {
    let runner = BoundedSystemCommandRunner(
      maximumCapturedBytes: 1_024,
      executionTimeout: 2,
      terminationGraceInterval: 0.05
    )

    XCTAssertThrowsError(
      try runner.run(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
          "-c",
          "i=0; while [ $i -lt 20000 ]; do printf x; printf y >&2; i=$((i+1)); done",
        ]
      )
    ) { error in
      XCTAssertEqual(error as? BoundedSystemCommandError, .outputLimitExceeded)
    }
  }

  func testSuccessfulCommandReturnsExactStatusAndBothStreams() throws {
    let result = try BoundedSystemCommandRunner().run(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "printf output; printf warning >&2; exit 7"]
    )

    XCTAssertEqual(result.status, 7)
    XCTAssertEqual(String(data: result.standardOutput, encoding: .utf8), "output")
    XCTAssertEqual(String(data: result.standardError, encoding: .utf8), "warning")
  }

  func testCommandReceivesTheIntendedMinimalUserEnvironment() throws {
    let result = try BoundedSystemCommandRunner().run(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "printf '%s\\n%s\\n%s' \"$HOME\" \"$USER\" \"$LC_ALL\""]
    )
    let lines = String(decoding: result.standardOutput, as: UTF8.self)
      .split(whereSeparator: \.isNewline)
      .map(String.init)

    XCTAssertEqual(lines, [
      FileManager.default.homeDirectoryForCurrentUser.path,
      NSUserName(),
      "C",
    ])
  }
}

private struct SystemCommandRequest: Equatable, Sendable {
  let executablePath: String
  let arguments: [String]
}

private final class RecordingSystemCommandRunner: SystemCommandRunning, @unchecked Sendable {
  private let lock = NSLock()
  private let results: [String: BoundedSystemCommandResult]
  private var recordedRequests: [SystemCommandRequest] = []

  init(results: [String: BoundedSystemCommandResult]) {
    self.results = results
  }

  var requests: [SystemCommandRequest] {
    lock.withLock { recordedRequests }
  }

  func run(executableURL: URL, arguments: [String]) throws -> BoundedSystemCommandResult {
    try lock.withLock {
      recordedRequests.append(SystemCommandRequest(
        executablePath: executableURL.path,
        arguments: arguments
      ))
      return try XCTUnwrap(results[executableURL.path])
    }
  }
}

private struct EmptyNativeMetadataProvider: NativeProcessMetadataProviding {
  func metadata(for processID: Int32) -> DevProcess? { nil }
}
