import Foundation
import XCTest
import DevScopeCore
@testable import DevScope

@MainActor
final class AutomationDocumentPanelTests: XCTestCase {
  func testValidatedImportDataRejectsContentBeyondLimitAfterRead() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("devscope-import-\(UUID().uuidString)")
    let oversized = Data(repeating: 0x41, count: AutomationDocumentPanel.maximumImportBytes + 1)
    try oversized.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    XCTAssertThrowsError(try AutomationDocumentPanel.validatedImportData(at: url)) { error in
      XCTAssertEqual((error as? CocoaError)?.code, .fileReadTooLarge)
    }
  }

  func testValidatedImportDataReturnsContentAtLimit() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("devscope-import-\(UUID().uuidString)")
    let content = Data(repeating: 0x42, count: AutomationDocumentPanel.maximumImportBytes)
    try content.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    XCTAssertEqual(try AutomationDocumentPanel.validatedImportData(at: url), content)
  }

  func testValidatedImportDataRefusesSymbolicLinksAndNonRegularFiles() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("devscope-import-types-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source")
    let link = directory.appendingPathComponent("link")
    let fifo = directory.appendingPathComponent("fifo")
    try Data("safe".utf8).write(to: source)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)

    XCTAssertThrowsError(try AutomationDocumentPanel.validatedImportData(at: link))
    XCTAssertThrowsError(try AutomationDocumentPanel.validatedImportData(at: fifo))
  }

  func testExportWriterRestrictsSecretBearingFileToCurrentUser() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("devscope-export-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: url) }
    let artifact = AutomationExportArtifact(
      suggestedFilename: "automation.plist",
      mediaType: "application/x-plist",
      format: "source.plist",
      data: Data("TOKEN=private".utf8),
      isRedacted: false
    )

    try AutomationDocumentPanel.writeExport(artifact, to: url)

    XCTAssertEqual(try Data(contentsOf: url), artifact.data)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  func testExportWriterAtomicallyReplacesExistingFileWithoutKeepingBroadPermissions() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("devscope-export-existing-\(UUID().uuidString)")
    try Data("old".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    defer { try? FileManager.default.removeItem(at: url) }
    let artifact = AutomationExportArtifact(
      suggestedFilename: "automation.plist",
      mediaType: "application/x-plist",
      format: "source.plist",
      data: Data("new-secret".utf8),
      isRedacted: false
    )

    try AutomationDocumentPanel.writeExport(artifact, to: url)

    XCTAssertEqual(try Data(contentsOf: url), artifact.data)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }
}
