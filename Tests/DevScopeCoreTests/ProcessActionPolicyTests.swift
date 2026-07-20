import Foundation
import XCTest

@testable import DevScopeCore

final class ProcessActionPolicyTests: XCTestCase {
  func testProtectsPIDZero() {
    let item = classified(pid: 0, executable: "/usr/bin/ordinary", kind: .other)

    let decision = ProcessActionPolicy.decision(for: item, currentProcessID: 9000)

    XCTAssertFalse(decision.isAllowed)
    XCTAssertEqual(decision.reason, "macOS launch infrastructure is protected")
  }

  func testProtectsPIDOneWithNonLaunchdExecutable() {
    let item = classified(pid: 1, executable: "/usr/bin/ordinary", kind: .other)

    let decision = ProcessActionPolicy.decision(for: item, currentProcessID: 9000)

    XCTAssertFalse(decision.isAllowed)
    XCTAssertEqual(decision.reason, "macOS launch infrastructure is protected")
  }

  func testProtectsLaunchdAtAnOrdinaryPID() {
    let item = classified(pid: 4200, executable: "/sbin/launchd", kind: .other)

    let decision = ProcessActionPolicy.decision(for: item, currentProcessID: 9000)

    XCTAssertFalse(decision.isAllowed)
    XCTAssertEqual(decision.reason, "macOS launch infrastructure is protected")
  }

  func testProtectsCriticalSystemService() {
    let item = classified(
      pid: 4200, executable: "/System/Library/CoreServices/WindowServer", kind: .systemService)

    let decision = ProcessActionPolicy.decision(for: item, currentProcessID: 9000)

    XCTAssertFalse(decision.isAllowed)
    XCTAssertEqual(decision.reason, "Critical macOS system infrastructure is protected")
  }

  func testProtectsCriticalExecutableEvenWhenClassificationDegrades() {
    let item = classified(
      pid: 4200, executable: "/System/Library/CoreServices/WindowServer", kind: .other)

    XCTAssertFalse(ProcessActionPolicy.decision(for: item, currentProcessID: 9000).isAllowed)
  }

  func testProtectsTheRunningDevScopeProcess() {
    let item = classified(
      pid: 42, executable: "/Applications/DevScope.app/Contents/MacOS/DevScope", kind: .macApp)

    let decision = ProcessActionPolicy.decision(for: item, currentProcessID: 42)

    XCTAssertFalse(decision.isAllowed)
    XCTAssertEqual(decision.reason, "DevScope cannot terminate itself")
  }

  func testAllowsAUserOwnedDevelopmentProcess() {
    let item = classified(pid: 4200, executable: "/opt/homebrew/bin/node", kind: .javascript)

    XCTAssertEqual(
      ProcessActionPolicy.decision(for: item, currentProcessID: 42),
      .allowed
    )
  }

  private func classified(pid: Int32, executable: String, kind: DevRuntimeKind)
    -> ClassifiedDevProcess
  {
    ClassifiedDevProcess(
      process: DevProcess(pid: pid, parentPID: 1, executable: executable, command: executable),
      classification: DevProcessClassification(
        kind: kind, displayName: URL(fileURLWithPath: executable).lastPathComponent,
        projectHint: nil)
    )
  }
}
