import XCTest
@testable import DevScopeCore

final class PersistentCopyStoreTests: XCTestCase {
  func testSavesLoadsAndClearsLastCopiedPayload() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = PersistentCopyStore(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }

    let timestamp = Date()
    let saved = try store.save(text: "pid\tcommand\n1\tnode", label: "Visible rows", timestamp: timestamp)
    let loaded = try XCTUnwrap(store.load())

    XCTAssertEqual(loaded.label, "Visible rows")
    XCTAssertEqual(loaded.text, "pid\tcommand\n1\tnode")
    XCTAssertEqual(loaded.isTruncated, saved.isTruncated)
    XCTAssertEqual(loaded.timestamp.timeIntervalSince1970, timestamp.timeIntervalSince1970, accuracy: 1.0)

    try store.clear()
    XCTAssertNil(try store.load())
  }

  func testBoundsLargePayloadsForRecoveryCache() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = PersistentCopyStore(directory: directory, maxStoredBytes: 64)
    defer { try? FileManager.default.removeItem(at: directory) }

    let saved = try store.save(text: String(repeating: "a", count: 200), label: "Large export")

    XCTAssertTrue(saved.isTruncated)
    XCTAssertLessThanOrEqual(Data(saved.text.utf8).count, 64)
    XCTAssertTrue(saved.text.contains("[truncated"))
  }

  func testBoundsPayloadWhenByteLimitIsSmallerThanTruncationMarker() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = PersistentCopyStore(directory: directory, maxStoredBytes: 8)
    defer { try? FileManager.default.removeItem(at: directory) }

    let saved = try store.save(text: "sensitive-value", label: "Small cache")

    XCTAssertTrue(saved.isTruncated)
    XCTAssertLessThanOrEqual(Data(saved.text.utf8).count, 8)
  }

  func testMaximumSizedEscapedPayloadCanBeLoadedAfterSaving() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let maxStoredBytes = 70_000
    let store = PersistentCopyStore(directory: directory, maxStoredBytes: maxStoredBytes)
    defer { try? FileManager.default.removeItem(at: directory) }
    let text = String(repeating: "\"", count: maxStoredBytes)

    let saved = try store.save(text: text, label: "Escaped export")
    let loaded = try XCTUnwrap(store.load())

    XCTAssertFalse(saved.isTruncated)
    XCTAssertEqual(loaded.label, saved.label)
    XCTAssertEqual(loaded.text, saved.text)
    XCTAssertEqual(loaded.isTruncated, saved.isTruncated)
    XCTAssertEqual(loaded.timestamp.timeIntervalSince1970, saved.timestamp.timeIntervalSince1970, accuracy: 1.0)
  }

  func testSaveRejectsPayloadWhoseEncodedMetadataExceedsReadableLimit() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = PersistentCopyStore(directory: directory, maxStoredBytes: 64)
    defer { try? FileManager.default.removeItem(at: directory) }
    let oversizedLabel = String(repeating: "x", count: 70_000)

    XCTAssertThrowsError(try store.save(text: "value", label: oversizedLabel)) { error in
      XCTAssertEqual(error as? PersistentCopyStoreError, .payloadTooLarge)
    }
  }

  func testRecoveryCacheUsesOwnerOnlyPermissions() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = PersistentCopyStore(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }

    try store.save(text: "pid\tcommand\n1\tnode --token <redacted>", label: "Visible rows")

    let payloadURL = directory.appendingPathComponent("last-copy.json", isDirectory: false)
    let directoryMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)
    let payloadMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: payloadURL.path)[.posixPermissions] as? NSNumber)

    XCTAssertEqual(directoryMode.intValue & 0o777, 0o700)
    XCTAssertEqual(payloadMode.intValue & 0o777, 0o600)
  }

  func testLoadRejectsAnOversizedTamperedRecoveryCache() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = PersistentCopyStore(directory: directory, maxStoredBytes: 64)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: 70_000).write(
      to: directory.appendingPathComponent("last-copy.json")
    )

    XCTAssertThrowsError(try store.load())
  }
}
