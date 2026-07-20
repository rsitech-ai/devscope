import XCTest
@testable import DevScopeCore

final class ProcessCacheIdentityTests: XCTestCase {
  func testKnownBirthIdentityIgnoresMetadataEnrichment() {
    let birthToken = ProcessBirthToken(seconds: 1_000, microseconds: 42)
    let initial = DevProcess(
      pid: 700,
      parentPID: 1,
      executable: "node",
      command: "node",
      birthToken: birthToken
    )
    let enriched = DevProcess(
      pid: 700,
      parentPID: 99,
      executable: "/opt/homebrew/bin/node",
      command: "/opt/homebrew/bin/node server.js",
      birthToken: birthToken
    )

    XCTAssertEqual(
      ProcessCacheIdentity(process: initial),
      ProcessCacheIdentity(process: enriched)
    )
  }

  func testUnknownBirthUsesConservativeProcessMetadataFallback() {
    let original = processWithoutBirth()
    let originalIdentity = ProcessCacheIdentity(process: original)

    XCTAssertEqual(
      originalIdentity,
      ProcessCacheIdentity(process: processWithoutBirth())
    )
    XCTAssertNotEqual(
      originalIdentity,
      ProcessCacheIdentity(process: processWithoutBirth(parentPID: 2))
    )
    XCTAssertNotEqual(
      originalIdentity,
      ProcessCacheIdentity(process: processWithoutBirth(executable: "python"))
    )
    XCTAssertNotEqual(
      originalIdentity,
      ProcessCacheIdentity(process: processWithoutBirth(command: "worker --other"))
    )
  }

  func testKnownBirthChangeAndBirthAvailabilityTransitionChangeIdentity() {
    let withoutBirth = processWithoutBirth()
    let firstBirth = DevProcess(
      pid: withoutBirth.pid,
      parentPID: withoutBirth.parentPID,
      executable: withoutBirth.executable,
      command: withoutBirth.command,
      birthToken: ProcessBirthToken(seconds: 1_000, microseconds: 1)
    )
    let secondBirth = DevProcess(
      pid: firstBirth.pid,
      parentPID: firstBirth.parentPID,
      executable: firstBirth.executable,
      command: firstBirth.command,
      birthToken: ProcessBirthToken(seconds: 1_000, microseconds: 2)
    )

    XCTAssertNotEqual(
      ProcessCacheIdentity(process: firstBirth),
      ProcessCacheIdentity(process: secondBirth)
    )
    XCTAssertNotEqual(
      ProcessCacheIdentity(process: withoutBirth),
      ProcessCacheIdentity(process: firstBirth)
    )
  }

  private func processWithoutBirth(
    parentPID: Int32 = 1,
    executable: String = "worker",
    command: String = "worker --serve"
  ) -> DevProcess {
    DevProcess(
      pid: 700,
      parentPID: parentPID,
      executable: executable,
      command: command
    )
  }
}
