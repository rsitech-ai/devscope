import DevScopeCore
import Foundation
import XCTest

@testable import DevScope

final class LaunchctlAutomationRuntimeStateProviderTests: XCTestCase {
  func testParsesNamedAndBooleanPrintDisabledValuesAndRejectsConflicts() {
    let parsed = LaunchctlAutomationRuntimeStateProvider.parseEnabledStates(
      Data(
        """
        disabled services = {
          "com.example.disabled" => disabled
          "com.example.enabled" => enabled
          "com.example.true" => true
          "com.example.false" => false
        }
        """.utf8))

    XCTAssertEqual(parsed?["com.example.disabled"], .disabled)
    XCTAssertEqual(parsed?["com.example.enabled"], .enabled)
    XCTAssertEqual(parsed?["com.example.true"], .disabled)
    XCTAssertEqual(parsed?["com.example.false"], .enabled)
    XCTAssertNil(
      LaunchctlAutomationRuntimeStateProvider.parseEnabledStates(
        Data(
          """
          "com.example.conflict" => enabled
          "com.example.conflict" => disabled
          """.utf8)))
  }

  func testQueriesOneDomainMapAndDistinguishesMissingTargetsFromOperationalFailures() async {
    let runner = RuntimeStateCommandRunner()
    let provider = LaunchctlAutomationRuntimeStateProvider(runner: runner)

    let states = await provider.states(
      for: [
        "com.example.loaded",
        "com.example.disabled",
        "com.example.default",
        "com.example.operational-failure",
      ],
      guiUID: 501
    )

    XCTAssertEqual(
      states["com.example.loaded"],
      LaunchdRuntimeState(
        enabledState: .enabled,
        loadState: .loaded
      ))
    XCTAssertEqual(
      states["com.example.disabled"],
      LaunchdRuntimeState(
        enabledState: .disabled,
        loadState: .unloaded
      ))
    XCTAssertEqual(
      states["com.example.default"],
      LaunchdRuntimeState(
        enabledState: .enabled,
        loadState: .unloaded
      ))
    XCTAssertEqual(
      states["com.example.operational-failure"],
      LaunchdRuntimeState(
        enabledState: .enabled,
        loadState: .unknown
      ))
    let invocations = await runner.invocations()
    XCTAssertEqual(invocations.filter { $0.arguments == ["print-disabled", "gui/501"] }.count, 1)
    XCTAssertEqual(
      Set(invocations.filter { $0.arguments.first == "print" }.map { $0.arguments.last! }),
      [
        "gui/501/com.example.loaded",
        "gui/501/com.example.disabled",
        "gui/501/com.example.default",
        "gui/501/com.example.operational-failure",
      ]
    )
    XCTAssertTrue(invocations.allSatisfy { $0.environment["LC_ALL"] == "C" })
  }

  func testDeduplicatesLabelsAndBoundsConcurrentPrintQueries() async {
    let runner = ConcurrencyTrackingRuntimeStateCommandRunner()
    let provider = LaunchctlAutomationRuntimeStateProvider(runner: runner)
    let uniqueLabels = (0..<12).map { "com.example.job-\($0)" }

    let states = await provider.states(
      for: uniqueLabels + [uniqueLabels[3], uniqueLabels[7], uniqueLabels[3]],
      guiUID: 501
    )
    let metrics = await runner.metrics()

    XCTAssertEqual(states.count, uniqueLabels.count)
    XCTAssertEqual(metrics.printInvocations, uniqueLabels.count)
    XCTAssertLessThanOrEqual(metrics.maximumConcurrentPrints, 4)
    for (index, label) in uniqueLabels.enumerated() {
      XCTAssertEqual(states[label]?.loadState, index.isMultiple(of: 2) ? .loaded : .unloaded)
    }
  }
}

private actor RuntimeStateCommandRunner: AutomationCommandRunning {
  private var commands: [AutomationCommand] = []

  func run(_ command: AutomationCommand) async throws -> AutomationCommandResult {
    commands.append(command)
    if command.arguments == ["print-disabled", "gui/501"] {
      return AutomationCommandResult(
        status: 0,
        standardOutput: Data("\"com.example.disabled\" => disabled\n".utf8),
        standardError: Data()
      )
    }
    if command.arguments.last == "gui/501/com.example.loaded" {
      return AutomationCommandResult(status: 0, standardOutput: Data(), standardError: Data())
    }
    if command.arguments.last == "gui/501/com.example.operational-failure" {
      return AutomationCommandResult(
        status: 113,
        standardOutput: Data(),
        standardError: Data("Operation not permitted\n".utf8)
      )
    }
    let label = command.arguments.last!.split(separator: "/").last!
    return AutomationCommandResult(
      status: 113,
      standardOutput: Data(),
      standardError: Data(
        "Bad request.\nCould not find service \"\(label)\" in domain for user gui: 501\n".utf8
      )
    )
  }

  func invocations() -> [AutomationCommand] { commands }
}

private actor ConcurrencyTrackingRuntimeStateCommandRunner: AutomationCommandRunning {
  private var printInvocations = 0
  private var activePrints = 0
  private var maximumConcurrentPrints = 0

  func run(_ command: AutomationCommand) async throws -> AutomationCommandResult {
    guard command.arguments.first == "print" else {
      return AutomationCommandResult(status: 0, standardOutput: Data(), standardError: Data())
    }
    printInvocations += 1
    activePrints += 1
    maximumConcurrentPrints = max(maximumConcurrentPrints, activePrints)
    defer { activePrints -= 1 }
    try? await Task.sleep(for: .milliseconds(10))

    let target = command.arguments.last!
    let label = String(target.split(separator: "/").last!)
    let index = Int(label.split(separator: "-").last!)!
    if index.isMultiple(of: 2) {
      return AutomationCommandResult(status: 0, standardOutput: Data(), standardError: Data())
    }
    return AutomationCommandResult(
      status: 113,
      standardOutput: Data(),
      standardError: Data(
        "Bad request.\nCould not find service \"\(label)\" in domain for user gui: 501\n".utf8
      )
    )
  }

  func metrics() -> (printInvocations: Int, maximumConcurrentPrints: Int) {
    (printInvocations, maximumConcurrentPrints)
  }
}
