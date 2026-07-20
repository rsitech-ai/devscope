import XCTest
@testable import DevScopeCore

final class WorkspaceFactsCacheTests: XCTestCase {
  func testBudgetedCycleRevalidatesOnlyItsStaleEntryBudget() {
    var probedDirectories: [String] = []
    let cache = WorkspaceFactsCache { path in
      if path.hasSuffix("/pubspec.yaml") {
        probedDirectories.append(String(path.dropLast("/pubspec.yaml".count)))
      }
      return false
    }
    let directories = (1...3).map { "/workspace/\($0)" }
    directories.forEach { _ = cache.facts(for: $0) }
    probedDirectories.removeAll()
    cache.invalidateAll()

    cache.withRevalidationCycle(maximumStaleEntries: 2) {
      directories.forEach { _ = cache.facts(for: $0) }
    }

    XCTAssertEqual(probedDirectories, Array(directories.prefix(2)))
  }

  func testLaterBudgetedCycleContinuesRevalidatingRemainingStaleEntries() {
    var probedDirectories: [String] = []
    let cache = WorkspaceFactsCache { path in
      if path.hasSuffix("/pubspec.yaml") {
        probedDirectories.append(String(path.dropLast("/pubspec.yaml".count)))
      }
      return false
    }
    let directories = (1...3).map { "/workspace/\($0)" }
    directories.forEach { _ = cache.facts(for: $0) }
    cache.invalidateAll()

    cache.withRevalidationCycle(maximumStaleEntries: 2) {
      directories.forEach { _ = cache.facts(for: $0) }
    }
    probedDirectories.removeAll()
    cache.withRevalidationCycle(maximumStaleEntries: 2) {
      directories.forEach { _ = cache.facts(for: $0) }
    }

    XCTAssertEqual(probedDirectories, [directories[2]])
  }

  func testDuplicateDirectoryUsesOneStaleEntrySlot() {
    var probedDirectories: [String] = []
    let cache = WorkspaceFactsCache { path in
      if path.hasSuffix("/pubspec.yaml") {
        probedDirectories.append(String(path.dropLast("/pubspec.yaml".count)))
      }
      return false
    }
    let directories = ["/workspace/shared", "/workspace/second", "/workspace/third"]
    directories.forEach { _ = cache.facts(for: $0) }
    cache.invalidateAll()
    probedDirectories.removeAll()

    cache.withRevalidationCycle(maximumStaleEntries: 2) {
      _ = cache.facts(for: directories[0])
      _ = cache.facts(for: directories[0])
      _ = cache.facts(for: directories[1])
      _ = cache.facts(for: directories[2])
    }

    XCTAssertEqual(probedDirectories, Array(directories.prefix(2)))
  }

  func testDirectLookupAfterInvalidationRevalidatesImmediately() {
    var manifestExists = false
    let cache = WorkspaceFactsCache { path in
      manifestExists && path.hasSuffix("/pubspec.yaml")
    }
    let directory = "/workspace/direct"

    XCTAssertFalse(cache.facts(for: directory).isFlutterWorkspace)
    manifestExists = true
    cache.invalidateAll()

    XCTAssertTrue(cache.facts(for: directory).isFlutterWorkspace)
  }

  func testUnseenDirectoryProbesAfterStaleBudgetIsExhausted() {
    var manifests: Set<String> = []
    let cache = WorkspaceFactsCache { path in
      manifests.contains(path)
    }
    let staleDirectory = "/workspace/stale"
    let newDirectory = "/workspace/new"
    _ = cache.facts(for: staleDirectory)
    cache.invalidateAll()
    manifests.insert(newDirectory + "/pubspec.yaml")

    let newFacts = cache.withRevalidationCycle(maximumStaleEntries: 0) {
      cache.facts(for: newDirectory)
    }

    XCTAssertTrue(newFacts.isFlutterWorkspace)
  }

  func testLaterInvalidationPrunesDirectoryNotAccessedSincePreviousInvalidation() {
    var manifests: Set<String> = []
    let cache = WorkspaceFactsCache { path in
      manifests.contains(path)
    }
    let activeDirectory = "/workspace/active"
    let inactiveDirectory = "/workspace/inactive"
    _ = cache.facts(for: activeDirectory)
    _ = cache.facts(for: inactiveDirectory)
    cache.invalidateAll()
    cache.withRevalidationCycle(maximumStaleEntries: 0) {
      _ = cache.facts(for: activeDirectory)
    }
    cache.invalidateAll()
    manifests.insert(inactiveDirectory + "/pubspec.yaml")

    let inactiveFacts = cache.withRevalidationCycle(maximumStaleEntries: 0) {
      cache.facts(for: inactiveDirectory)
    }

    XCTAssertTrue(inactiveFacts.isFlutterWorkspace)
  }

  func testProbeStartedBeforeConcurrentInvalidationCannotInstallItsResult() {
    let firstProbeStarted = DispatchSemaphore(value: 0)
    let allowFirstProbeToFinish = DispatchSemaphore(value: 0)
    let probeLock = NSLock()
    var pubspecProbeCount = 0
    let cache = WorkspaceFactsCache { path in
      guard path.hasSuffix("/pubspec.yaml") else {
        return false
      }
      let probeNumber = probeLock.withLock {
        pubspecProbeCount += 1
        return pubspecProbeCount
      }
      if probeNumber == 1 {
        firstProbeStarted.signal()
        _ = allowFirstProbeToFinish.wait(timeout: .now() + 2)
        return false
      }
      return true
    }
    let completed = expectation(description: "fresh generation returned")

    DispatchQueue.global().async {
      XCTAssertTrue(cache.facts(for: "/workspace/concurrent").isFlutterWorkspace)
      completed.fulfill()
    }
    XCTAssertEqual(firstProbeStarted.wait(timeout: .now() + 2), .success)
    cache.invalidateAll()
    allowFirstProbeToFinish.signal()

    wait(for: [completed], timeout: 3)
    XCTAssertEqual(probeLock.withLock { pubspecProbeCount }, 2)
  }
}
