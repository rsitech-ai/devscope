import AppKit
import Combine
import DevScopeCore
import Foundation
import XCTest
@testable import DevScope

final class AutomationApplicationIconStoreTests: XCTestCase {
  @MainActor
  func testBundleIdentifierLookupPrecedesSourceAndExecutableCandidates() async {
    let locator = FakeAutomationApplicationLocator(
      bundleURLs: ["com.example.App": URL(fileURLWithPath: "/Applications/Example.app")],
      iconsByPath: [
        "/Applications/Example.app": NSImage(size: .init(width: 16, height: 16))
      ]
    )
    let store = AutomationApplicationIconStore(locator: locator, capacity: 8)
    let record = makeRecord(
      providerBundleIdentifier: "com.example.App",
      sourceURL: URL(fileURLWithPath: "/tmp/fallback.app"),
      executable: "/tmp/fallback.app/Contents/MacOS/fallback"
    )

    await store.resolve(record)

    XCTAssertNotNil(store.icon(for: record))
    XCTAssertEqual(locator.requestedBundleIdentifiers, ["com.example.App"])
    XCTAssertEqual(locator.requestedIconPaths, ["/Applications/Example.app"])
  }

  @MainActor
  func testMissingBundleLookupFallsThroughToSourceBeforeExecutable() async {
    let sourceURL = URL(fileURLWithPath: "/Applications/SourceFallback.app")
    let executableURL = URL(fileURLWithPath: "/Applications/ExecutableFallback.app")
    let locator = FakeAutomationApplicationLocator(
      iconsByPath: [
        sourceURL.path: NSImage(size: .init(width: 16, height: 16)),
        executableURL.path: NSImage(size: .init(width: 16, height: 16))
      ]
    )
    let store = AutomationApplicationIconStore(locator: locator, capacity: 8)
    let record = makeRecord(
      providerBundleIdentifier: "com.example.Missing",
      sourceURL: sourceURL,
      executable: executableURL.appendingPathComponent("Contents/MacOS/Executable").path
    )

    await store.resolve(record)

    XCTAssertNotNil(store.icon(for: record))
    XCTAssertEqual(locator.requestedBundleIdentifiers, ["com.example.Missing"])
    XCTAssertEqual(locator.requestedIconPaths, [sourceURL.path])
    XCTAssertEqual(locator.totalLookupCount, 2)
  }

  @MainActor
  func testMissingBundleIconFallsThroughToSourceBeforeExecutable() async {
    let bundleURL = URL(fileURLWithPath: "/Applications/BundleWithoutIcon.app")
    let sourceURL = URL(fileURLWithPath: "/Applications/SourceAfterBundleIcon.app")
    let executableURL = URL(fileURLWithPath: "/Applications/ExecutableMustNotLoad.app")
    let locator = FakeAutomationApplicationLocator(
      bundleURLs: ["com.example.NoIcon": bundleURL],
      iconsByPath: [
        sourceURL.path: NSImage(size: .init(width: 16, height: 16)),
        executableURL.path: NSImage(size: .init(width: 16, height: 16))
      ]
    )
    let store = AutomationApplicationIconStore(locator: locator, capacity: 8)
    let record = makeRecord(
      providerBundleIdentifier: "com.example.NoIcon",
      sourceURL: sourceURL,
      executable: executableURL.appendingPathComponent("Contents/MacOS/Executable").path
    )

    await store.resolve(record)

    XCTAssertNotNil(store.icon(for: record))
    XCTAssertEqual(locator.requestedBundleIdentifiers, ["com.example.NoIcon"])
    XCTAssertEqual(locator.requestedIconPaths, [bundleURL.path, sourceURL.path])
    XCTAssertEqual(locator.totalLookupCount, 3)
  }

  @MainActor
  func testExactApplicationSourceURLProvidesFallbackIcon() async {
    let sourceURL = URL(fileURLWithPath: "/Applications/Source.app")
    let locator = FakeAutomationApplicationLocator(
      iconsByPath: [sourceURL.path: NSImage(size: .init(width: 16, height: 16))]
    )
    let store = AutomationApplicationIconStore(locator: locator, capacity: 8)
    let record = makeRecord(sourceURL: sourceURL)

    await store.resolve(record)

    XCTAssertNotNil(store.icon(for: record))
    XCTAssertEqual(locator.requestedIconPaths, [sourceURL.path])
  }

  @MainActor
  func testExecutableInsideApplicationUsesExactContainingBundle() async {
    let applicationURL = URL(fileURLWithPath: "/Applications/Foo.app")
    let locator = FakeAutomationApplicationLocator(
      iconsByPath: [applicationURL.path: NSImage(size: .init(width: 16, height: 16))]
    )
    let store = AutomationApplicationIconStore(locator: locator, capacity: 8)
    let record = makeRecord(executable: "/Applications/Foo.app/Contents/MacOS/Foo")

    await store.resolve(record)

    XCTAssertNotNil(store.icon(for: record))
    XCTAssertEqual(locator.requestedIconPaths, [applicationURL.path])
  }

  @MainActor
  func testNonApplicationSourcesAndExecutableParentsAreRejected() async {
    let locator = FakeAutomationApplicationLocator(
      iconsByPath: [
        "/Applications/Unrelated": NSImage(size: .init(width: 16, height: 16)),
        "/usr/local": NSImage(size: .init(width: 16, height: 16))
      ]
    )
    let store = AutomationApplicationIconStore(locator: locator, capacity: 8)
    let record = makeRecord(
      sourceURL: URL(fileURLWithPath: "/Applications/Unrelated/Contents/Info.plist"),
      executable: "/usr/local/bin/Tool"
    )

    await store.resolve(record)

    XCTAssertNil(store.icon(for: record))
    XCTAssertTrue(locator.requestedIconPaths.isEmpty)
  }

  @MainActor
  func testPositiveResolutionIsCached() async {
    let sourceURL = URL(fileURLWithPath: "/Applications/Cached.app")
    let locator = FakeAutomationApplicationLocator(
      iconsByPath: [sourceURL.path: NSImage(size: .init(width: 16, height: 16))]
    )
    let store = AutomationApplicationIconStore(locator: locator, capacity: 8)
    let record = makeRecord(sourceURL: sourceURL)

    await store.resolve(record)
    await store.resolve(record)

    XCTAssertNotNil(store.icon(for: record))
    XCTAssertEqual(locator.requestedIconPaths, [sourceURL.path])
    XCTAssertEqual(store.revision, 1)
  }

  @MainActor
  func testStandardizedSourceAndExecutablePathsReuseOneCachedResolution() async {
    let canonicalSourceURL = URL(fileURLWithPath: "/Applications/Normalized.app")
    let locator = FakeAutomationApplicationLocator(
      iconsByPath: [
        canonicalSourceURL.path: NSImage(size: .init(width: 16, height: 16))
      ]
    )
    let store = AutomationApplicationIconStore(locator: locator, capacity: 8)
    let canonicalRecord = makeRecord(
      id: "canonical",
      sourceURL: canonicalSourceURL,
      executable: "/Applications/Normalized.app/Contents/MacOS/Normalized"
    )
    let equivalentRecord = makeRecord(
      id: "equivalent",
      sourceURL: URL(
        fileURLWithPath: "/Applications/Elsewhere/../Normalized.app"
      ),
      executable: "/Applications/Normalized.app/Contents/Helpers/../MacOS/Normalized"
    )

    XCTAssertNotEqual(canonicalRecord.sourceURL?.path, equivalentRecord.sourceURL?.path)
    XCTAssertNotEqual(canonicalRecord.executable, equivalentRecord.executable)
    XCTAssertEqual(store.key(for: canonicalRecord), store.key(for: equivalentRecord))

    await store.resolve(canonicalRecord)
    await store.resolve(equivalentRecord)

    XCTAssertNotNil(store.icon(for: equivalentRecord))
    XCTAssertEqual(locator.requestedIconPaths, [canonicalSourceURL.path])
    XCTAssertEqual(locator.totalLookupCount, 1)
    XCTAssertEqual(store.revision, 1)
  }

  @MainActor
  func testNegativeResolutionIsCached() async {
    let locator = FakeAutomationApplicationLocator()
    let store = AutomationApplicationIconStore(locator: locator, capacity: 8)
    let record = makeRecord(
      id: "missing",
      providerBundleIdentifier: "com.example.Missing"
    )

    await store.resolve(record)
    await store.resolve(record)

    XCTAssertNil(store.icon(for: record))
    XCTAssertEqual(locator.requestedBundleIdentifiers, ["com.example.Missing"])
    XCTAssertEqual(store.revision, 1)
  }

  @MainActor
  func testConcurrentRequestsForOneKeyCoalesce() async {
    let sourceURL = URL(fileURLWithPath: "/Applications/Coalesced.app")
    let locator = FakeAutomationApplicationLocator(
      iconsByPath: [sourceURL.path: NSImage(size: .init(width: 16, height: 16))]
    )
    let store = AutomationApplicationIconStore(locator: locator, capacity: 8)
    let record = makeRecord(sourceURL: sourceURL)

    let receivedIconCount = await withTaskGroup(of: Bool.self) { group in
      for _ in 0..<10 {
        group.addTask {
          await store.resolve(record)
          return await store.icon(for: record) != nil
        }
      }
      var count = 0
      for await receivedIcon in group {
        if receivedIcon {
          count += 1
        }
      }
      return count
    }

    XCTAssertEqual(receivedIconCount, 10)
    XCTAssertNotNil(store.icon(for: record))
    XCTAssertEqual(locator.requestedIconPaths, [sourceURL.path])
    XCTAssertEqual(store.revision, 1)
  }

  @MainActor
  func testCancellingOneWaiterDoesNotCancelSharedLookupOrSurvivingWaiter() async {
    let sourceURL = URL(fileURLWithPath: "/Applications/Cancellation.app")
    let gate = SynchronousIconLookupGate()
    let locator = FakeAutomationApplicationLocator(
      iconsByPath: [sourceURL.path: NSImage(size: .init(width: 16, height: 16))]
    )
    locator.iconLookupGate = gate
    let store = AutomationApplicationIconStore(locator: locator, capacity: 8)
    let record = makeRecord(sourceURL: sourceURL)

    let cancelledWaiter = Task { @MainActor in
      _ = await store.resolve(record)
    }
    let survivingWaiter = Task { @MainActor in
      await store.resolve(record) != nil
    }
    let cancellation = Task.detached {
      let lookupDidStart = gate.waitUntilLookupStarts()
      cancelledWaiter.cancel()
      gate.releaseLookup()
      return lookupDidStart
    }

    let survivingWaiterReceivedIcon = await survivingWaiter.value
    let lookupDidStart = await cancellation.value
    await cancelledWaiter.value

    XCTAssertTrue(lookupDidStart)
    XCTAssertTrue(cancelledWaiter.isCancelled)
    XCTAssertTrue(survivingWaiterReceivedIcon)
    XCTAssertNotNil(store.icon(for: record))
    XCTAssertEqual(locator.requestedIconPaths, [sourceURL.path])
    XCTAssertEqual(locator.totalLookupCount, 1)
    XCTAssertEqual(store.revision, 1)
  }

  @MainActor
  func testPositiveAndNegativeResolutionsDoNotPublishStoreWideInvalidations() async {
    let sourceURL = URL(fileURLWithPath: "/Applications/Localized.app")
    let locator = FakeAutomationApplicationLocator(
      iconsByPath: [sourceURL.path: NSImage(size: .init(width: 16, height: 16))]
    )
    let store = AutomationApplicationIconStore(locator: locator, capacity: 8)
    let resolved = makeRecord(id: "resolved", sourceURL: sourceURL)
    let missing = makeRecord(
      id: "missing",
      providerBundleIdentifier: "com.example.Missing"
    )
    var invalidationCount = 0
    let observation = store.objectWillChange.sink {
      invalidationCount += 1
    }

    await store.resolve(resolved)
    await store.resolve(missing)

    withExtendedLifetime(observation) {}
    XCTAssertEqual(invalidationCount, 0)
    XCTAssertNotNil(store.icon(for: resolved))
    XCTAssertNil(store.icon(for: missing))
  }

  @MainActor
  func testPositiveAndNegativeEntriesShareBoundedEviction() async {
    let firstURL = URL(fileURLWithPath: "/Applications/First.app")
    let thirdURL = URL(fileURLWithPath: "/Applications/Third.app")
    let locator = FakeAutomationApplicationLocator(
      iconsByPath: [
        firstURL.path: NSImage(size: .init(width: 16, height: 16)),
        thirdURL.path: NSImage(size: .init(width: 16, height: 16))
      ]
    )
    let store = AutomationApplicationIconStore(locator: locator, capacity: 2)
    let first = makeRecord(id: "first", sourceURL: firstURL)
    let missing = makeRecord(
      id: "missing",
      providerBundleIdentifier: "com.example.Missing"
    )
    let third = makeRecord(id: "third", sourceURL: thirdURL)

    await store.resolve(first)
    await store.resolve(missing)
    await store.resolve(third)
    await store.resolve(missing)
    await store.resolve(first)

    XCTAssertEqual(
      locator.requestedIconPaths,
      [firstURL.path, thirdURL.path, firstURL.path]
    )
    XCTAssertEqual(locator.requestedBundleIdentifiers, ["com.example.Missing"])
    XCTAssertEqual(store.revision, 4)
  }
}

@MainActor
private final class FakeAutomationApplicationLocator: AutomationApplicationLocating {
  var bundleURLs: [String: URL]
  var iconsByPath: [String: NSImage]
  var iconLookupGate: SynchronousIconLookupGate?
  private(set) var requestedBundleIdentifiers: [String] = []
  private(set) var requestedIconPaths: [String] = []

  init(bundleURLs: [String: URL] = [:], iconsByPath: [String: NSImage] = [:]) {
    self.bundleURLs = bundleURLs
    self.iconsByPath = iconsByPath
  }

  func applicationURL(forBundleIdentifier identifier: String) -> URL? {
    requestedBundleIdentifiers.append(identifier)
    return bundleURLs[identifier]
  }

  func icon(forApplicationAt url: URL) -> NSImage? {
    requestedIconPaths.append(url.path)
    iconLookupGate?.pauseLookupUntilReleased()
    return iconsByPath[url.path]
  }

  var totalLookupCount: Int {
    requestedBundleIdentifiers.count + requestedIconPaths.count
  }
}

private final class SynchronousIconLookupGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var lookupStarted = false
  private var lookupReleased = false

  func pauseLookupUntilReleased() {
    condition.lock()
    lookupStarted = true
    condition.broadcast()
    while !lookupReleased {
      condition.wait()
    }
    condition.unlock()
  }

  func waitUntilLookupStarts(timeout: TimeInterval = 5) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    let deadline = Date().addingTimeInterval(timeout)
    while !lookupStarted {
      guard condition.wait(until: deadline) else {
        return false
      }
    }
    return true
  }

  func releaseLookup() {
    condition.lock()
    lookupReleased = true
    condition.broadcast()
    condition.unlock()
  }
}

private func makeRecord(
  id: String = "icon-record",
  providerBundleIdentifier: String? = nil,
  sourceURL: URL? = nil,
  executable: String? = nil
) -> AutomationRecord {
  AutomationRecord(
    id: .init(rawValue: id),
    kind: .backgroundItem,
    sourceKind: .serviceManagement,
    label: id,
    displayName: "Icon Record",
    providerBundleIdentifier: providerBundleIdentifier,
    ownerUID: 501,
    ownership: .thirdPartySystem,
    executable: executable,
    arguments: [],
    environment: [:],
    workingDirectory: nil,
    schedule: .init(triggers: [.demand], summary: "On demand"),
    sourceURL: sourceURL,
    sourceChecksum: nil,
    enabledState: .enabled,
    loadState: .unknown,
    approvalState: .unknown,
    state: .idle,
    evidence: [],
    capabilities: [],
    validationFindings: []
  )
}
