import Foundation
import DevScopeCore
import XCTest
@testable import DevScope

final class LocalAutomationFileSystemTests: XCTestCase {
  func testReadRejectsFilesLargerThanTheConfiguredBoundary() throws {
    let fixture = try FileSystemFixture()
    defer { fixture.cleanup() }
    let source = fixture.approved.appending(path: "oversized.plist")
    try Data(repeating: 0x41, count: 65).write(to: source)
    let fileSystem = LocalAutomationFileSystem(maxReadableBytes: 64)

    XCTAssertThrowsError(try fileSystem.read(source)) { error in
      XCTAssertEqual((error as? POSIXError)?.code, .EFBIG)
    }
  }

  func testFileAuthorizationAcceptsEquivalentParentWithDifferentDirectoryHint() throws {
    let parentWithHint = URL(fileURLWithPath: "/tmp/devscope-authorization", isDirectory: true)
    let parentWithoutHint = URL(fileURLWithPath: "/tmp/devscope-authorization")
    let directory = try XCTUnwrap(AutomationDirectoryAuthorization(
      directoryURL: parentWithHint,
      resourceIdentifier: "device:inode"
    ))

    XCTAssertNotNil(AutomationFileAuthorization(
      fileURL: parentWithoutHint.appendingPathComponent("source.plist"),
      directory: directory,
      expectation: .absent
    ))
  }

  func testTemporaryWriteRejectsAuthorizedParentReplacedBySymlink() throws {
    let fixture = try FileSystemFixture()
    defer { fixture.cleanup() }
    let fileSystem = LocalAutomationFileSystem()
    let authorization = try fixture.authorization(using: fileSystem)

    try fixture.swapApprovedParentForSymlinkToOutside()
    _ = try fileSystem.metadata(for: fixture.approved)
    XCTAssertThrowsError(try fileSystem.writeStagedFile(
      nextTo: fixture.approved.appending(path: "target"),
      data: Data("safe".utf8),
      permissions: 0o600,
      authorization: authorization
    ))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.outside.path), [])
  }

  func testTemporaryWriteRejectsAuthorizedParentReplacedByDifferentDirectory() throws {
    let fixture = try FileSystemFixture()
    defer { fixture.cleanup() }
    let fileSystem = LocalAutomationFileSystem()
    let authorization = try fixture.authorization(using: fileSystem)

    try fixture.swapApprovedParentForFreshDirectory()
    _ = try fileSystem.metadata(for: fixture.approved)
    XCTAssertThrowsError(try fileSystem.writeStagedFile(
      nextTo: fixture.approved.appending(path: "target"),
      data: Data("safe".utf8),
      permissions: 0o600,
      authorization: authorization
    ))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.approved.path), [])
  }

  func testRemoveRejectsParentSwapAndDoesNotUnlinkOutsideFile() throws {
    let fixture = try FileSystemFixture()
    defer { fixture.cleanup() }
    let source = fixture.approved.appending(path: "same-name")
    let outside = fixture.outside.appending(path: "same-name")
    try Data("approved".utf8).write(to: source)
    try Data("outside".utf8).write(to: outside)
    let fileSystem = LocalAutomationFileSystem()
    let authorization = try fixture.authorization(using: fileSystem)
    let sourceAuthorization = try fixture.fileAuthorization(
      source, directory: authorization, fileSystem: fileSystem
    )

    try fixture.swapApprovedParentForSymlinkToOutside()
    _ = try fileSystem.metadata(for: fixture.approved)
    XCTAssertThrowsError(try fileSystem.removeItem(sourceAuthorization))
    XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
  }

  func testRemoveRejectsLeafReplacementEvenAfterMetadataReadsReplacement() throws {
    let fixture = try FileSystemFixture()
    defer { fixture.cleanup() }
    let fileSystem = LocalAutomationFileSystem()
    let directory = try fixture.authorization(using: fileSystem)
    let source = fixture.approved.appending(path: "source")
    try Data("original".utf8).write(to: source)
    let sourceAuthorization = try fixture.fileAuthorization(
      source, directory: directory, fileSystem: fileSystem
    )

    try FileManager.default.removeItem(at: source)
    try Data("replacement".utf8).write(to: source)
    _ = try fileSystem.metadata(for: source)
    XCTAssertThrowsError(try fileSystem.removeItem(sourceAuthorization))
    XCTAssertEqual(try Data(contentsOf: source), Data("replacement".utf8))
  }

  func testTrashRejectsLeafReplacementAndRestoresReplacementInPlace() throws {
    let fixture = try FileSystemFixture()
    defer { fixture.cleanup() }
    let fileSystem = LocalAutomationFileSystem()
    let directory = try fixture.authorization(using: fileSystem)
    let source = fixture.approved.appending(path: "trash-source")
    try Data("original".utf8).write(to: source)
    let sourceAuthorization = try fixture.fileAuthorization(
      source, directory: directory, fileSystem: fileSystem
    )

    try FileManager.default.removeItem(at: source)
    try Data("replacement".utf8).write(to: source)
    XCTAssertThrowsError(try fileSystem.moveToTrash(sourceAuthorization))
    XCTAssertEqual(try Data(contentsOf: source), Data("replacement".utf8))
  }

  func testReplaceRejectsStagedFileReplacement() throws {
    let fixture = try FileSystemFixture()
    defer { fixture.cleanup() }
    let fileSystem = LocalAutomationFileSystem()
    let directory = try fixture.authorization(using: fileSystem)
    let destinationURL = fixture.approved.appending(path: "destination")
    try Data("destination".utf8).write(to: destinationURL)
    let destination = try fixture.fileAuthorization(
      destinationURL, directory: directory, fileSystem: fileSystem
    )
    let staged = try fileSystem.writeStagedFile(
      nextTo: destinationURL,
      data: Data("intended".utf8),
      permissions: 0o600,
      authorization: directory
    )

    try FileManager.default.removeItem(at: staged.url)
    try Data("attacker".utf8).write(to: staged.url)
    _ = try fileSystem.metadata(for: staged.url)
    XCTAssertThrowsError(try fileSystem.replaceItem(at: destination, with: staged))
    XCTAssertEqual(try Data(contentsOf: destinationURL), Data("destination".utf8))
  }

  func testReplaceRejectsSameInodeStagedByteMutationAtCommitBoundary() throws {
    let fixture = try FileSystemFixture()
    defer { fixture.cleanup() }
    let fileSystem = LocalAutomationFileSystem()
    let directory = try fixture.authorization(using: fileSystem)
    let destinationURL = fixture.approved.appending(path: "destination")
    try Data("destination".utf8).write(to: destinationURL)
    let destination = try fixture.fileAuthorization(
      destinationURL, directory: directory, fileSystem: fileSystem
    )
    let staged = try fileSystem.writeStagedFile(
      nextTo: destinationURL,
      data: Data("reviewed-bytes".utf8),
      permissions: 0o600,
      authorization: directory
    )
    let stagedIdentity = try fileSystem.metadata(for: staged.url).resourceIdentifier

    let handle = try FileHandle(forWritingTo: staged.url)
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: Data("attacker-bytes".utf8))
    try handle.close()
    XCTAssertEqual(try fileSystem.metadata(for: staged.url).resourceIdentifier, stagedIdentity)

    XCTAssertThrowsError(try fileSystem.replaceItem(at: destination, with: staged))
    XCTAssertEqual(try Data(contentsOf: destinationURL), Data("destination".utf8))
  }

  func testReplaceRejectsSameInodeStagedModeMutationAtCommitBoundary() throws {
    let fixture = try FileSystemFixture()
    defer { fixture.cleanup() }
    let fileSystem = LocalAutomationFileSystem()
    let directory = try fixture.authorization(using: fileSystem)
    let destinationURL = fixture.approved.appending(path: "destination")
    try Data("destination".utf8).write(to: destinationURL)
    let destination = try fixture.fileAuthorization(
      destinationURL, directory: directory, fileSystem: fileSystem
    )
    let staged = try fileSystem.writeStagedFile(
      nextTo: destinationURL,
      data: Data("reviewed-bytes".utf8),
      permissions: 0o600,
      authorization: directory
    )
    let stagedIdentity = try fileSystem.metadata(for: staged.url).resourceIdentifier

    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: staged.url.path
    )
    XCTAssertEqual(try fileSystem.metadata(for: staged.url).resourceIdentifier, stagedIdentity)

    XCTAssertThrowsError(try fileSystem.replaceItem(at: destination, with: staged))
    XCTAssertEqual(try Data(contentsOf: destinationURL), Data("destination".utf8))
  }

  func testReplaceRestoresDestinationWhenStagedInodeMutatesAfterPrecheck() throws {
    let fixture = try FileSystemFixture()
    defer { fixture.cleanup() }
    let fileSystem = LocalAutomationFileSystem(hooks: .init(
      beforeReplaceCommit: { stagedURL in
        let handle = try! FileHandle(forWritingTo: stagedURL)
        try! handle.truncate(atOffset: 0)
        try! handle.write(contentsOf: Data("attacker-bytes".utf8))
        try! handle.close()
      }
    ))
    let directory = try fixture.authorization(using: fileSystem)
    let destinationURL = fixture.approved.appending(path: "destination")
    try Data("destination".utf8).write(to: destinationURL)
    let destination = try fixture.fileAuthorization(
      destinationURL, directory: directory, fileSystem: fileSystem
    )
    let staged = try fileSystem.writeStagedFile(
      nextTo: destinationURL,
      data: Data("reviewed-bytes".utf8),
      permissions: 0o600,
      authorization: directory
    )

    let outcome = try fileSystem.replaceItem(at: destination, with: staged)

    XCTAssertEqual(outcome, .unchanged)
    XCTAssertEqual(try Data(contentsOf: destinationURL), Data("destination".utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: staged.url.path))
  }

  func testReplaceRestoresAbsentDestinationAndRemovesExactStagedInode() throws {
    let fixture = try FileSystemFixture()
    defer { fixture.cleanup() }
    let fileSystem = LocalAutomationFileSystem(hooks: .init(
      faults: [.replacePostRenameVerification]
    ))
    let directory = try fixture.authorization(using: fileSystem)
    let destinationURL = fixture.approved.appending(path: "destination")
    let destination = try XCTUnwrap(AutomationFileAuthorization(
      fileURL: destinationURL,
      directory: directory,
      expectation: .absent
    ))
    let staged = try fileSystem.writeStagedFile(
      nextTo: destinationURL,
      data: Data("reviewed".utf8),
      permissions: 0o600,
      authorization: directory
    )

    XCTAssertEqual(try fileSystem.replaceItem(at: destination, with: staged), .unchanged)
    XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: staged.url.path))
  }

  func testReplaceRestoreCleanupFailureReportsExactStagedRecovery() throws {
    let fixture = try FileSystemFixture()
    defer { fixture.cleanup() }
    let fileSystem = LocalAutomationFileSystem(hooks: .init(
      faults: [.replacePostRenameVerification, .replaceRestoredStagedUnlink]
    ))
    let directory = try fixture.authorization(using: fileSystem)
    let destinationURL = fixture.approved.appending(path: "destination")
    let destination = try XCTUnwrap(AutomationFileAuthorization(
      fileURL: destinationURL,
      directory: directory,
      expectation: .absent
    ))
    let staged = try fileSystem.writeStagedFile(
      nextTo: destinationURL,
      data: Data("reviewed".utf8),
      permissions: 0o600,
      authorization: directory
    )

    XCTAssertThrowsError(try fileSystem.replaceItem(at: destination, with: staged)) { error in
      let partial = try! XCTUnwrap(error as? AutomationFilePartialMutation)
      XCTAssertEqual(partial.kind, .remove)
      XCTAssertEqual(partial.commitState, .unknown)
      XCTAssertEqual(partial.recoveryHandle, staged.authorization)
      XCTAssertEqual(partial.observedFiles, [staged.authorization])
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    XCTAssertEqual(try Data(contentsOf: staged.url), Data("reviewed".utf8))
  }

  func testDisplacedUnlinkFailureReportsCommittedInstallAndExactRecoveryHandle() throws {
    let fixture = try FileSystemFixture()
    defer { fixture.cleanup() }
    let fileSystem = LocalAutomationFileSystem(hooks: .init(
      faults: [.replaceDisplacedUnlink]
    ))
    let directory = try fixture.authorization(using: fileSystem)
    let destinationURL = fixture.approved.appending(path: "destination")
    try Data("original".utf8).write(to: destinationURL)
    let destination = try fixture.fileAuthorization(
      destinationURL, directory: directory, fileSystem: fileSystem
    )
    let staged = try fileSystem.writeStagedFile(
      nextTo: destinationURL,
      data: Data("reviewed".utf8),
      permissions: 0o600,
      authorization: directory
    )

    XCTAssertThrowsError(try fileSystem.replaceItem(at: destination, with: staged)) { error in
      let partial = try! XCTUnwrap(error as? AutomationFilePartialMutation)
      XCTAssertEqual(partial.commitState, .committed)
      XCTAssertEqual(partial.observedFiles.first?.fileURL, destinationURL)
      let recovery = try! XCTUnwrap(partial.recoveryHandle)
      XCTAssertEqual(try! fileSystem.read(recovery.fileURL), Data("original".utf8))
    }
    XCTAssertEqual(try Data(contentsOf: destinationURL), Data("reviewed".utf8))
  }

  func testFailedRestoreCollisionReportsEveryObservedEntryAndInstalledRecovery() throws {
    let fixture = try FileSystemFixture()
    defer { fixture.cleanup() }
    let fileSystem = LocalAutomationFileSystem(hooks: .init(
      faults: [.replacePostRenameVerification, .replaceRestoreCollision]
    ))
    let directory = try fixture.authorization(using: fileSystem)
    let destinationURL = fixture.approved.appending(path: "destination")
    let destination = try XCTUnwrap(AutomationFileAuthorization(
      fileURL: destinationURL,
      directory: directory,
      expectation: .absent
    ))
    let staged = try fileSystem.writeStagedFile(
      nextTo: destinationURL,
      data: Data("reviewed".utf8),
      permissions: 0o600,
      authorization: directory
    )

    XCTAssertThrowsError(try fileSystem.replaceItem(at: destination, with: staged)) { error in
      let partial = try! XCTUnwrap(error as? AutomationFilePartialMutation)
      XCTAssertEqual(partial.commitState, .committed)
      XCTAssertEqual(Set(partial.observedFiles.map(\.fileURL)).count, 2)
      XCTAssertEqual(partial.recoveryHandle?.fileURL, destinationURL)
    }
    XCTAssertEqual(try Data(contentsOf: destinationURL), Data("reviewed".utf8))
  }

  func testFailedSwapBackReportsDisplacedOriginalAsExactRecovery() throws {
    let fixture = try FileSystemFixture()
    defer { fixture.cleanup() }
    let fileSystem = LocalAutomationFileSystem(hooks: .init(
      beforeReplaceCommit: { stagedURL in
        let handle = try! FileHandle(forWritingTo: stagedURL)
        try! handle.truncate(atOffset: 0)
        try! handle.write(contentsOf: Data("attacker".utf8))
        try! handle.close()
      },
      faults: [.replaceSwapBackFailure]
    ))
    let directory = try fixture.authorization(using: fileSystem)
    let destinationURL = fixture.approved.appending(path: "destination")
    try Data("original".utf8).write(to: destinationURL)
    let destination = try fixture.fileAuthorization(
      destinationURL, directory: directory, fileSystem: fileSystem
    )
    let staged = try fileSystem.writeStagedFile(
      nextTo: destinationURL,
      data: Data("reviewed".utf8),
      permissions: 0o600,
      authorization: directory
    )

    XCTAssertThrowsError(try fileSystem.replaceItem(at: destination, with: staged)) { error in
      let partial = try! XCTUnwrap(error as? AutomationFilePartialMutation)
      XCTAssertEqual(partial.commitState, .unknown)
      let recovery = try! XCTUnwrap(partial.recoveryHandle)
      XCTAssertEqual(try! fileSystem.read(recovery.fileURL), Data("original".utf8))
    }
    XCTAssertEqual(try Data(contentsOf: destinationURL), Data("attacker".utf8))
  }

  func testTrashFinalMoveFailureReturnsUnchangedOnlyAfterVerifiedRestore() throws {
    let fixture = try FileSystemFixture()
    defer { fixture.cleanup() }
    let fileSystem = LocalAutomationFileSystem(hooks: .init(
      faults: [.trashFinalMove],
      trashDirectory: fixture.root.appending(path: "trash", directoryHint: .isDirectory)
    ))
    let directory = try fixture.authorization(using: fileSystem)
    let sourceURL = fixture.approved.appending(path: "source")
    try Data("original".utf8).write(to: sourceURL)
    let source = try fixture.fileAuthorization(
      sourceURL, directory: directory, fileSystem: fileSystem
    )

    XCTAssertEqual(try fileSystem.moveToTrash(source), .unchanged)
    XCTAssertEqual(try Data(contentsOf: sourceURL), Data("original".utf8))
  }

  func testTrashStagedIdentityMismatchWithFailedRestoreReportsRecovery() throws {
    let fixture = try FileSystemFixture()
    defer { fixture.cleanup() }
    let fileSystem = LocalAutomationFileSystem(hooks: .init(
      faults: [.trashStagedIdentityMismatch, .trashRestoreCollision],
      trashDirectory: fixture.root.appending(path: "trash", directoryHint: .isDirectory)
    ))
    let directory = try fixture.authorization(using: fileSystem)
    let sourceURL = fixture.approved.appending(path: "source")
    try Data("original".utf8).write(to: sourceURL)
    let source = try fixture.fileAuthorization(
      sourceURL, directory: directory, fileSystem: fileSystem
    )

    XCTAssertThrowsError(try fileSystem.moveToTrash(source)) { error in
      let partial = try! XCTUnwrap(error as? AutomationFilePartialMutation)
      XCTAssertEqual(partial.kind, .trash)
      XCTAssertEqual(partial.commitState, .unknown)
      XCTAssertEqual(partial.observedFiles.count, 2)
      XCTAssertEqual(try! fileSystem.read(partial.recoveryHandle!.fileURL), Data("original".utf8))
    }
  }

  func testRemoveUnlinkFailureReturnsUnchangedOnlyAfterVerifiedRestore() throws {
    let fixture = try FileSystemFixture()
    defer { fixture.cleanup() }
    let fileSystem = LocalAutomationFileSystem(hooks: .init(faults: [.removeUnlink]))
    let directory = try fixture.authorization(using: fileSystem)
    let sourceURL = fixture.approved.appending(path: "source")
    try Data("original".utf8).write(to: sourceURL)
    let source = try fixture.fileAuthorization(
      sourceURL, directory: directory, fileSystem: fileSystem
    )

    XCTAssertEqual(try fileSystem.removeItem(source), .unchanged)
    XCTAssertEqual(try Data(contentsOf: sourceURL), Data("original".utf8))
  }

  func testRemoveStagedIdentityMismatchWithFailedRestoreReportsRecovery() throws {
    let fixture = try FileSystemFixture()
    defer { fixture.cleanup() }
    let fileSystem = LocalAutomationFileSystem(hooks: .init(
      faults: [.removeStagedIdentityMismatch, .removeRestoreCollision]
    ))
    let directory = try fixture.authorization(using: fileSystem)
    let sourceURL = fixture.approved.appending(path: "source")
    try Data("original".utf8).write(to: sourceURL)
    let source = try fixture.fileAuthorization(
      sourceURL, directory: directory, fileSystem: fileSystem
    )

    XCTAssertThrowsError(try fileSystem.removeItem(source)) { error in
      let partial = try! XCTUnwrap(error as? AutomationFilePartialMutation)
      XCTAssertEqual(partial.kind, .remove)
      XCTAssertEqual(partial.commitState, .unknown)
      XCTAssertEqual(partial.observedFiles.count, 2)
      XCTAssertEqual(try! fileSystem.read(partial.recoveryHandle!.fileURL), Data("original".utf8))
    }
  }

  func testAbsentDestinationThatAppearsIsNeverOverwritten() throws {
    let fixture = try FileSystemFixture()
    defer { fixture.cleanup() }
    let fileSystem = LocalAutomationFileSystem()
    let directory = try fixture.authorization(using: fileSystem)
    let destinationURL = fixture.approved.appending(path: "destination")
    let destination = try XCTUnwrap(AutomationFileAuthorization(
      fileURL: destinationURL,
      directory: directory,
      expectation: .absent
    ))
    let staged = try fileSystem.writeStagedFile(
      nextTo: destinationURL,
      data: Data("intended".utf8),
      permissions: 0o600,
      authorization: directory
    )

    try Data("attacker".utf8).write(to: destinationURL)
    XCTAssertThrowsError(try fileSystem.replaceItem(at: destination, with: staged))
    XCTAssertEqual(try Data(contentsOf: destinationURL), Data("attacker".utf8))
  }

  func testExistingDestinationReplacementIsNeverOverwritten() throws {
    let fixture = try FileSystemFixture()
    defer { fixture.cleanup() }
    let fileSystem = LocalAutomationFileSystem()
    let directory = try fixture.authorization(using: fileSystem)
    let destinationURL = fixture.approved.appending(path: "destination")
    try Data("original".utf8).write(to: destinationURL)
    let destination = try fixture.fileAuthorization(
      destinationURL, directory: directory, fileSystem: fileSystem
    )
    let staged = try fileSystem.writeStagedFile(
      nextTo: destinationURL,
      data: Data("intended".utf8),
      permissions: 0o600,
      authorization: directory
    )

    try FileManager.default.removeItem(at: destinationURL)
    try Data("attacker".utf8).write(to: destinationURL)
    XCTAssertThrowsError(try fileSystem.replaceItem(at: destination, with: staged))
    XCTAssertEqual(try Data(contentsOf: destinationURL), Data("attacker".utf8))
  }
}

private final class FileSystemFixture {
  let root: URL
  let approved: URL
  let parked: URL
  let outside: URL

  init() throws {
    root = try FileManager.default.url(
      for: .cachesDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    ).appending(path: "DevScopeTests", directoryHint: .isDirectory).appending(
      path: "devscope-fs-\(UUID().uuidString)", directoryHint: .isDirectory
    )
    approved = root.appending(path: "approved", directoryHint: .isDirectory)
    parked = root.appending(path: "parked", directoryHint: .isDirectory)
    outside = root.appending(path: "outside", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: approved, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
  }

  func authorization(
    using fileSystem: LocalAutomationFileSystem
  ) throws -> AutomationDirectoryAuthorization {
    let metadata = try fileSystem.metadata(for: approved)
    return try XCTUnwrap(AutomationDirectoryAuthorization(
      directoryURL: approved,
      resourceIdentifier: metadata.resourceIdentifier
    ))
  }

  func fileAuthorization(
    _ file: URL,
    directory: AutomationDirectoryAuthorization,
    fileSystem: LocalAutomationFileSystem
  ) throws -> AutomationFileAuthorization {
    let metadata = try fileSystem.metadata(for: file)
    return try XCTUnwrap(AutomationFileAuthorization(
      fileURL: file,
      directory: directory,
      expectation: .existing(resourceIdentifier: metadata.resourceIdentifier ?? "")
    ))
  }

  func swapApprovedParentForSymlinkToOutside() throws {
    try FileManager.default.moveItem(at: approved, to: parked)
    try FileManager.default.createSymbolicLink(at: approved, withDestinationURL: outside)
  }

  func swapApprovedParentForFreshDirectory() throws {
    try FileManager.default.moveItem(at: approved, to: parked)
    try FileManager.default.createDirectory(at: approved, withIntermediateDirectories: false)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }
}
