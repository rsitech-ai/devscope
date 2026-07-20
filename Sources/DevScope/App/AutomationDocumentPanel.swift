import AppKit
import Darwin
import DevScopeCore
import Foundation
import UniformTypeIdentifiers

struct AutomationImportedDocument: Identifiable {
  let id = UUID()
  let sourceURL: URL
  let data: Data
}

@MainActor
final class AutomationDocumentPanel {
  static let maximumImportBytes = 2 * 1_024 * 1_024

  static func validatedImportData(at url: URL) throws -> Data {
    let descriptor = Darwin.open(
      url.path,
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
    )
    guard descriptor >= 0 else { throw currentPOSIXError() }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }

    var before = stat()
    guard fstat(descriptor, &before) == 0 else { throw currentPOSIXError() }
    guard (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    guard before.st_size >= 0,
          before.st_size <= off_t(maximumImportBytes) else {
      throw CocoaError(.fileReadTooLarge)
    }

    var data = Data()
    while data.count <= maximumImportBytes {
      let remaining = maximumImportBytes + 1 - data.count
      guard let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)),
            !chunk.isEmpty else { break }
      data.append(chunk)
    }
    guard data.count <= maximumImportBytes else { throw CocoaError(.fileReadTooLarge) }

    var after = stat()
    guard fstat(descriptor, &after) == 0 else { throw currentPOSIXError() }
    guard before.st_dev == after.st_dev,
          before.st_ino == after.st_ino,
          before.st_size == after.st_size,
          before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
          before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
          data.count == Int(after.st_size) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return data
  }

  private static func currentPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }

  static func writeExport(_ artifact: AutomationExportArtifact, to url: URL) throws {
    let fileManager = FileManager.default
    let temporaryURL = url.deletingLastPathComponent()
      .appendingPathComponent(".devscope-export-\(UUID().uuidString)")
    guard fileManager.createFile(
      atPath: temporaryURL.path,
      contents: nil,
      attributes: [.posixPermissions: 0o600]
    ) else {
      throw CocoaError(.fileWriteUnknown)
    }
    defer { try? fileManager.removeItem(at: temporaryURL) }

    let handle = try FileHandle(forWritingTo: temporaryURL)
    do {
      try handle.write(contentsOf: artifact.data)
      try handle.synchronize()
      try handle.close()
    } catch {
      try? handle.close()
      throw error
    }

    if fileManager.fileExists(atPath: url.path) {
      _ = try fileManager.replaceItemAt(
        url,
        withItemAt: temporaryURL,
        backupItemName: nil,
        options: [.usingNewMetadataOnly]
      )
    } else {
      try fileManager.moveItem(at: temporaryURL, to: url)
    }
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
      throw CocoaError(.fileWriteNoPermission)
    }
  }

  func openImport() throws -> AutomationImportedDocument? {
    let panel = NSOpenPanel()
    panel.title = "Import Automation"
    panel.prompt = "Preview Import"
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.propertyList, .plainText, .json]
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return AutomationImportedDocument(
      sourceURL: url,
      data: try Self.validatedImportData(at: url)
    )
  }

  func save(_ artifact: AutomationExportArtifact) throws -> Bool {
    let panel = NSSavePanel()
    panel.title = artifact.isRedacted ? "Save Redacted Automation Export" : "Save Unredacted Automation Export"
    panel.nameFieldStringValue = artifact.suggestedFilename
    guard panel.runModal() == .OK, let url = panel.url else { return false }
    try Self.writeExport(artifact, to: url)
    return true
  }
}
