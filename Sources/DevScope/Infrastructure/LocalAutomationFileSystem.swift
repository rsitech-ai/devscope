import Darwin
import CryptoKit
import DevScopeCore
import Foundation

enum LocalAutomationFileSystemFault: Hashable, Sendable {
  case replaceDisplacedUnlink
  case replacePostRenameVerification
  case replaceRestoreCollision
  case replaceSwapBackFailure
  case replaceRestoredStagedUnlink
  case trashFinalMove
  case trashStagedIdentityMismatch
  case trashRestoreCollision
  case removeUnlink
  case removeStagedIdentityMismatch
  case removeRestoreCollision
}

struct LocalAutomationFileSystemHooks: Sendable {
  var beforeReplaceCommit: (@Sendable (URL) -> Void)?
  var faults: Set<LocalAutomationFileSystemFault>
  var trashDirectory: URL?

  init(
    beforeReplaceCommit: (@Sendable (URL) -> Void)? = nil,
    faults: Set<LocalAutomationFileSystemFault> = [],
    trashDirectory: URL? = nil
  ) {
    self.beforeReplaceCommit = beforeReplaceCommit
    self.faults = faults
    self.trashDirectory = trashDirectory
  }
}

final class LocalAutomationFileSystem: AutomationFileSystem, @unchecked Sendable {
  private let fileManager = FileManager.default
  private let hooks: LocalAutomationFileSystemHooks
  private let maxReadableBytes: Int

  init(
    hooks: LocalAutomationFileSystemHooks = .init(),
    maxReadableBytes: Int = 8 * 1_024 * 1_024
  ) {
    self.hooks = hooks
    self.maxReadableBytes = max(0, maxReadableBytes)
  }

  func itemExists(at url: URL) -> Bool {
    do {
      let (parent, name) = try Self.openParent(of: url)
      defer { _ = close(parent) }
      var status = stat()
      return fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT
    } catch {
      return true
    }
  }

  func plistURLs(in directory: URL) throws -> [URL] {
    let descriptor = try Self.openDirectoryNoFollow(directory)
    _ = close(descriptor)
    return try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension.caseInsensitiveCompare("plist") == .orderedSame }
      .sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
  }

  func read(_ url: URL) throws -> Data {
    let (parent, name) = try Self.openParent(of: url)
    defer { _ = close(parent) }
    let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw Self.posixError() }
    defer { _ = close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
      throw POSIXError(.EPERM)
    }
    guard status.st_size >= 0, UInt64(status.st_size) <= UInt64(maxReadableBytes) else {
      throw POSIXError(.EFBIG)
    }
    return try Self.readAll(descriptor, maxBytes: maxReadableBytes)
  }

  func metadata(for url: URL) throws -> AutomationFileMetadata {
    let path = url.standardizedFileURL.path
    if path == "/" {
      let descriptor = try Self.openDirectoryNoFollow(url)
      defer { _ = close(descriptor) }
      var status = stat()
      guard fstat(descriptor, &status) == 0 else { throw Self.posixError() }
      return Self.metadata(path: path, status: status, isSymbolicLink: false)
    }

    let (parent, name) = try Self.openParent(of: url)
    defer { _ = close(parent) }
    var parentStatus = stat()
    guard fstat(parent, &parentStatus) == 0 else { throw Self.posixError() }
    var status = stat()
    guard fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
      throw Self.posixError()
    }
    let isSymbolicLink = (status.st_mode & S_IFMT) == S_IFLNK
    return Self.metadata(path: path, status: status, isSymbolicLink: isSymbolicLink)
  }

  func createDirectory(_ url: URL, permissions: Int) throws {
    let path = url.standardizedFileURL.path
    guard path.hasPrefix("/"), 0...0o777 ~= permissions else { throw POSIXError(.EINVAL) }
    let components = path.split(separator: "/").map(String.init)
    var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard parent >= 0 else { throw Self.posixError() }
    defer { if parent >= 0 { _ = close(parent) } }

    var traversed = ""
    for (index, component) in components.enumerated() {
      traversed += "/\(component)"
      let isFinal = index == components.count - 1
      var child = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      var created = false
      if child < 0, errno == ENOENT {
        guard mkdirat(parent, component, mode_t(isFinal ? permissions : 0o700)) == 0 else {
          throw Self.posixError()
        }
        created = true
        child = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard child >= 0 else { throw Self.posixError() }
      var status = stat()
      guard fstat(child, &status) == 0 else {
        _ = close(child)
        throw Self.posixError()
      }
      if isFinal {
        let mode = Int(status.st_mode & 0o777)
        if created {
          guard fchmod(child, mode_t(permissions)) == 0 else {
            _ = close(child)
            throw Self.posixError()
          }
          guard fstat(child, &status) == 0 else {
            _ = close(child)
            throw Self.posixError()
          }
        } else if mode != permissions {
          _ = close(child)
          throw POSIXError(.EPERM)
        }
      }
      _ = close(parent)
      parent = child
    }
  }


  func writeStagedFile(
    nextTo url: URL,
    data: Data,
    permissions: Int,
    authorization: AutomationDirectoryAuthorization
  ) throws -> AutomationStagedFile {
    guard 0...0o777 ~= permissions else { throw POSIXError(.EINVAL) }
    let parentURL = url.deletingLastPathComponent().standardizedFileURL
    return try withVerifiedParent(of: url, authorization: authorization) { parent, _ in
      for _ in 0..<16 {
        let name = ".devscope-\(UUID().uuidString.lowercased()).tmp"
        let descriptor = openat(
          parent, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
          mode_t(permissions)
        )
        if descriptor < 0 {
          if errno == EEXIST { continue }
          throw Self.posixError()
        }
        do {
          try Self.writeAll(data, to: descriptor)
          var status = stat()
          guard fsync(descriptor) == 0, fstat(descriptor, &status) == 0 else {
            throw Self.posixError()
          }
          let temporaryURL = parentURL.appending(path: name, directoryHint: .notDirectory)
          let resourceIdentifier = Self.resourceIdentifier(status)
          guard (status.st_mode & S_IFMT) == S_IFREG,
                status.st_nlink == 1,
                let fileAuthorization = AutomationFileAuthorization(
            fileURL: temporaryURL,
            directory: authorization,
            expectation: .existing(resourceIdentifier: resourceIdentifier)
          ), close(descriptor) == 0 else { throw Self.posixError() }
          return AutomationStagedFile(
            url: temporaryURL,
            authorization: fileAuthorization,
            binding: AutomationStagedFileBinding(
              data: data,
              resourceIdentifier: resourceIdentifier,
              ownerUID: status.st_uid,
              permissions: Int(status.st_mode & 0o777),
              linkCount: UInt64(status.st_nlink)
            )
          )
        } catch {
          _ = close(descriptor)
          _ = unlinkat(parent, name, 0)
          throw error
        }
      }
      throw POSIXError(.EEXIST)
    }
  }


  func replaceItem(
    at destination: AutomationFileAuthorization,
    with staged: AutomationStagedFile
  ) throws -> AutomationFileMutationOutcome {
    guard destination.directory == staged.authorization.directory,
          destination.fileURL.deletingLastPathComponent().standardizedFileURL
            == destination.directory.directoryURL,
          staged.url == staged.authorization.fileURL,
          case .existing(let stagedIdentity) = staged.authorization.expectation
    else { throw POSIXError(.EPERM) }

    return try withVerifiedParent(
      of: destination.fileURL,
      authorization: destination.directory
    ) { parent, destinationName in
      let stagedName = staged.url.lastPathComponent
      guard staged.binding.resourceIdentifier == stagedIdentity,
            try Self.entryMatchesBinding(
              parent: parent,
              name: stagedName,
              binding: staged.binding
            )
      else {
        throw POSIXError(.EPERM)
      }
      hooks.beforeReplaceCommit?(staged.url)
      switch destination.expectation {
      case .absent:
        guard renameatx_np(parent, stagedName, parent, destinationName, UInt32(RENAME_EXCL)) == 0
        else { throw Self.posixError() }
        let installedMatchesBinding = hooks.faults.contains(.replacePostRenameVerification)
          ? false
          : (try? Self.entryMatchesBinding(
          parent: parent,
          name: destinationName,
          binding: staged.binding
        )) == true
        guard installedMatchesBinding else {
          if hooks.faults.contains(.replaceRestoreCollision) {
            let collision = openat(
              parent,
              stagedName,
              O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
              mode_t(0o600)
            )
            if collision >= 0 { _ = close(collision) }
          }
          let restored = renameatx_np(
            parent, destinationName, parent, stagedName, UInt32(RENAME_EXCL)
          ) == 0
          if restored,
             (try? Self.entryIdentity(parent: parent, name: destinationName)) == nil {
            try cleanupRestoredStaged(
              parent: parent,
              name: stagedName,
              staged: staged
            )
            return .unchanged
          }
          var observed: [AutomationFileAuthorization] = []
          let installedIdentity = try? Self.entryIdentity(parent: parent, name: destinationName)
          let collisionIdentity = try? Self.entryIdentity(parent: parent, name: stagedName)
          let installed = installedIdentity.flatMap {
            AutomationFileAuthorization(
              fileURL: destination.fileURL,
              directory: destination.directory,
              expectation: .existing(resourceIdentifier: $0)
            )
          }
          let collision = collisionIdentity.flatMap {
            AutomationFileAuthorization(
              fileURL: staged.url,
              directory: destination.directory,
              expectation: .existing(resourceIdentifier: $0)
            )
          }
          if let installed { observed.append(installed) }
          if let collision { observed.append(collision) }
          let installedIsRecovery = (try? Self.entryMatchesBinding(
            parent: parent,
            name: destinationName,
            binding: staged.binding
          )) == true
          throw AutomationFilePartialMutation(
            kind: .replace,
            commitState: installedIsRecovery ? .committed : .unknown,
            observedFiles: observed,
            recoveryHandle: installedIsRecovery ? installed : nil,
            resultURL: destination.fileURL
          )
        }
      case .existing(let destinationIdentity):
        guard try Self.entryIdentity(parent: parent, name: destinationName) == destinationIdentity,
              renameatx_np(parent, stagedName, parent, destinationName, UInt32(RENAME_SWAP)) == 0
        else { throw POSIXError(.EPERM) }
        let installedMatches = (try? Self.entryMatchesBinding(
          parent: parent,
          name: destinationName,
          binding: staged.binding
        )) == true
        let displacedMatches = (try? Self.entryIdentity(
          parent: parent, name: stagedName
        )) == destinationIdentity
        guard installedMatches, displacedMatches else {
          let swappedBack = !hooks.faults.contains(.replaceSwapBackFailure)
            && renameatx_np(
              parent, stagedName, parent, destinationName, UInt32(RENAME_SWAP)
            ) == 0
          if swappedBack,
             (try? Self.entryIdentity(parent: parent, name: destinationName))
               == destinationIdentity,
             (try? Self.entryIdentity(parent: parent, name: stagedName)) == stagedIdentity {
            try cleanupRestoredStaged(
              parent: parent,
              name: stagedName,
              staged: staged
            )
            return .unchanged
          }
          let destinationObserved = (try? Self.entryIdentity(
            parent: parent, name: destinationName
          )).flatMap {
            AutomationFileAuthorization(
              fileURL: destination.fileURL,
              directory: destination.directory,
              expectation: .existing(resourceIdentifier: $0)
            )
          }
          let stagedObserved = (try? Self.entryIdentity(
            parent: parent, name: stagedName
          )).flatMap {
            AutomationFileAuthorization(
              fileURL: staged.url,
              directory: staged.authorization.directory,
              expectation: .existing(resourceIdentifier: $0)
            )
          }
          let observed = [destinationObserved, stagedObserved].compactMap { $0 }
          let recovery = destinationObserved?.expectation
            == .existing(resourceIdentifier: destinationIdentity)
            ? destinationObserved
            : (stagedObserved?.expectation == .existing(resourceIdentifier: destinationIdentity)
              ? stagedObserved : nil)
          throw AutomationFilePartialMutation(
            kind: .replace,
            commitState: .unknown,
            observedFiles: observed,
            recoveryHandle: recovery,
            resultURL: destination.fileURL
          )
        }
        if hooks.faults.contains(.replaceDisplacedUnlink)
          || unlinkat(parent, stagedName, 0) != 0
        {
          let installed = AutomationFileAuthorization(
            fileURL: destination.fileURL,
            directory: destination.directory,
            expectation: .existing(resourceIdentifier: staged.binding.resourceIdentifier)
          )
          let recovery = AutomationFileAuthorization(
            fileURL: staged.url,
            directory: destination.directory,
            expectation: .existing(resourceIdentifier: destinationIdentity)
          )
          throw AutomationFilePartialMutation(
            kind: .replace,
            commitState: .committed,
            observedFiles: [installed, recovery].compactMap { $0 },
            recoveryHandle: recovery,
            resultURL: destination.fileURL
          )
        }
      }
      _ = fsync(parent)
      let installedAuthorization = AutomationFileAuthorization(
        fileURL: destination.fileURL,
        directory: destination.directory,
        expectation: .existing(resourceIdentifier: staged.binding.resourceIdentifier)
      )
      return .committed(AutomationFileMutationReceipt(
        primaryFile: installedAuthorization,
        resultURL: destination.fileURL,
        bindingVerified: true
      ))
    }
  }

  private func cleanupRestoredStaged(
    parent: Int32,
    name: String,
    staged: AutomationStagedFile
  ) throws {
    let exactStagedAuthorization = (try? Self.entryIdentity(parent: parent, name: name))
      == staged.binding.resourceIdentifier ? staged.authorization : nil
    guard let exactStagedAuthorization else {
      let observed = (try? Self.entryIdentity(parent: parent, name: name)).flatMap {
        AutomationFileAuthorization(
          fileURL: staged.url,
          directory: staged.authorization.directory,
          expectation: .existing(resourceIdentifier: $0)
        )
      }
      throw AutomationFilePartialMutation(
        kind: .remove,
        commitState: .unknown,
        observedFiles: observed.map { [$0] } ?? [],
        recoveryHandle: nil,
        resultURL: staged.url
      )
    }
    guard !hooks.faults.contains(.replaceRestoredStagedUnlink),
          unlinkat(parent, name, 0) == 0,
          (try? Self.entryIdentity(parent: parent, name: name)) == nil
    else {
      throw AutomationFilePartialMutation(
        kind: .remove,
        commitState: .unknown,
        observedFiles: [exactStagedAuthorization],
        recoveryHandle: exactStagedAuthorization,
        resultURL: staged.url
      )
    }
    _ = fsync(parent)
  }

  func fileMatchesBinding(
    _ file: AutomationFileAuthorization,
    binding: AutomationStagedFileBinding
  ) throws -> Bool {
    guard case .existing(let expectedIdentity) = file.expectation,
          expectedIdentity == binding.resourceIdentifier
    else { return false }
    return try withVerifiedParent(of: file.fileURL, authorization: file.directory) {
      parent, name in
      try Self.entryMatchesBinding(parent: parent, name: name, binding: binding)
    }
  }


  func moveToTrash(
    _ source: AutomationFileAuthorization
  ) throws -> AutomationFileMutationOutcome {
    guard case .existing(let expectedIdentity) = source.expectation else {
      throw POSIXError(.EPERM)
    }
    let trash = hooks.trashDirectory ?? FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".Trash", directoryHint: .isDirectory)
    try createDirectory(trash, permissions: 0o700)
    let trashDescriptor = try Self.openDirectoryNoFollow(trash)
    defer { _ = close(trashDescriptor) }
    return try withVerifiedParent(of: source.fileURL, authorization: source.directory) {
      parent, name in
      let stagedName = ".devscope-trash-\(UUID().uuidString.lowercased())"
      guard renameatx_np(parent, name, parent, stagedName, UInt32(RENAME_EXCL)) == 0 else {
        throw Self.posixError()
      }
      let stagedIdentityMatches = !hooks.faults.contains(.trashStagedIdentityMismatch)
        && (try? Self.entryIdentity(parent: parent, name: stagedName)) == expectedIdentity
      guard stagedIdentityMatches else {
        if hooks.faults.contains(.trashRestoreCollision) {
          let collision = openat(
            parent, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
          )
          if collision >= 0 { _ = close(collision) }
        }
        let restored = renameatx_np(
          parent, stagedName, parent, name, UInt32(RENAME_EXCL)
        ) == 0
        if restored,
           (try? Self.entryIdentity(parent: parent, name: name)) == expectedIdentity,
           (try? Self.entryIdentity(parent: parent, name: stagedName)) == nil {
          return .unchanged
        }
        let evidence = Self.partialMutationEvidence(
          parent: parent,
          source: source,
          sourceName: name,
          stagedName: stagedName,
          expectedIdentity: expectedIdentity
        )
        throw AutomationFilePartialMutation(
          kind: .trash,
          commitState: .unknown,
          observedFiles: evidence.observed,
          recoveryHandle: evidence.recovery,
          resultURL: nil
        )
      }
      let destinationName = "\(name)-\(UUID().uuidString.lowercased())"
      let movedToTrash = !hooks.faults.contains(.trashFinalMove)
        && renameat(parent, stagedName, trashDescriptor, destinationName) == 0
      guard movedToTrash else {
        let restored = renameatx_np(
          parent, stagedName, parent, name, UInt32(RENAME_EXCL)
        ) == 0
        if restored,
           (try? Self.entryIdentity(parent: parent, name: name)) == expectedIdentity,
           (try? Self.entryIdentity(parent: parent, name: stagedName)) == nil {
          return .unchanged
        }
        var observed: [AutomationFileAuthorization] = []
        let sourceIdentity = try? Self.entryIdentity(parent: parent, name: name)
        let stagedIdentity = try? Self.entryIdentity(parent: parent, name: stagedName)
        let sourceObserved = sourceIdentity.flatMap {
          AutomationFileAuthorization(
            fileURL: source.fileURL,
            directory: source.directory,
            expectation: .existing(resourceIdentifier: $0)
          )
        }
        let stagedURL = source.directory.directoryURL.appending(
          path: stagedName, directoryHint: .notDirectory
        )
        let stagedObserved = stagedIdentity.flatMap {
          AutomationFileAuthorization(
            fileURL: stagedURL,
            directory: source.directory,
            expectation: .existing(resourceIdentifier: $0)
          )
        }
        if let sourceObserved { observed.append(sourceObserved) }
        if let stagedObserved { observed.append(stagedObserved) }
        let recovery = sourceIdentity == expectedIdentity ? sourceObserved
          : (stagedIdentity == expectedIdentity ? stagedObserved : nil)
        throw AutomationFilePartialMutation(
          kind: .trash,
          commitState: .unknown,
          observedFiles: observed,
          recoveryHandle: recovery,
          resultURL: nil
        )
      }
      _ = fsync(parent)
      _ = fsync(trashDescriptor)
      let resultURL = trash.appending(path: destinationName, directoryHint: .notDirectory)
      var trashStatus = stat()
      let trashIdentity = try? Self.entryIdentity(
        parent: trashDescriptor,
        name: destinationName
      )
      let trashAuthorization = fstat(trashDescriptor, &trashStatus) == 0
        ? AutomationDirectoryAuthorization(
          directoryURL: trash,
          resourceIdentifier: Self.resourceIdentifier(trashStatus)
        ) : nil
      let observedFile = trashAuthorization.flatMap { directory in
        trashIdentity.flatMap { identity in
          AutomationFileAuthorization(
            fileURL: resultURL,
            directory: directory,
            expectation: .existing(resourceIdentifier: identity)
          )
        }
      }
      guard trashIdentity == expectedIdentity,
            let trashedFile = observedFile
      else {
        throw AutomationFilePartialMutation(
          kind: .trash,
          commitState: trashIdentity == expectedIdentity ? .committed : .unknown,
          observedFiles: observedFile.map { [$0] } ?? [],
          recoveryHandle: trashIdentity == expectedIdentity ? observedFile : nil,
          resultURL: resultURL
        )
      }
      return .committed(AutomationFileMutationReceipt(
        primaryFile: trashedFile,
        resultURL: resultURL,
        bindingVerified: true
      ))
    }
  }


  func removeItem(
    _ source: AutomationFileAuthorization
  ) throws -> AutomationFileMutationOutcome {
    guard case .existing(let expectedIdentity) = source.expectation else {
      throw POSIXError(.EPERM)
    }
    return try withVerifiedParent(of: source.fileURL, authorization: source.directory) {
      parent, name in
      let stagedName = ".devscope-remove-\(UUID().uuidString.lowercased())"
      guard renameatx_np(parent, name, parent, stagedName, UInt32(RENAME_EXCL)) == 0 else {
        throw Self.posixError()
      }
      let stagedIdentityMatches = !hooks.faults.contains(.removeStagedIdentityMismatch)
        && (try? Self.entryIdentity(parent: parent, name: stagedName)) == expectedIdentity
      guard stagedIdentityMatches else {
        if hooks.faults.contains(.removeRestoreCollision) {
          let collision = openat(
            parent, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
          )
          if collision >= 0 { _ = close(collision) }
        }
        let restored = renameatx_np(
          parent, stagedName, parent, name, UInt32(RENAME_EXCL)
        ) == 0
        if restored,
           (try? Self.entryIdentity(parent: parent, name: name)) == expectedIdentity,
           (try? Self.entryIdentity(parent: parent, name: stagedName)) == nil {
          return .unchanged
        }
        let evidence = Self.partialMutationEvidence(
          parent: parent,
          source: source,
          sourceName: name,
          stagedName: stagedName,
          expectedIdentity: expectedIdentity
        )
        throw AutomationFilePartialMutation(
          kind: .remove,
          commitState: .unknown,
          observedFiles: evidence.observed,
          recoveryHandle: evidence.recovery,
          resultURL: nil
        )
      }
      if hooks.faults.contains(.removeUnlink) || unlinkat(parent, stagedName, 0) != 0 {
        let restored = renameatx_np(
          parent, stagedName, parent, name, UInt32(RENAME_EXCL)
        ) == 0
        if restored,
           (try? Self.entryIdentity(parent: parent, name: name)) == expectedIdentity,
           (try? Self.entryIdentity(parent: parent, name: stagedName)) == nil {
          return .unchanged
        }
        var observed: [AutomationFileAuthorization] = []
        let sourceIdentity = try? Self.entryIdentity(parent: parent, name: name)
        let stagedIdentity = try? Self.entryIdentity(parent: parent, name: stagedName)
        let sourceObserved = sourceIdentity.flatMap {
          AutomationFileAuthorization(
            fileURL: source.fileURL,
            directory: source.directory,
            expectation: .existing(resourceIdentifier: $0)
          )
        }
        let stagedURL = source.directory.directoryURL.appending(
          path: stagedName, directoryHint: .notDirectory
        )
        let stagedObserved = stagedIdentity.flatMap {
          AutomationFileAuthorization(
            fileURL: stagedURL,
            directory: source.directory,
            expectation: .existing(resourceIdentifier: $0)
          )
        }
        if let sourceObserved { observed.append(sourceObserved) }
        if let stagedObserved { observed.append(stagedObserved) }
        let recovery = sourceIdentity == expectedIdentity ? sourceObserved
          : (stagedIdentity == expectedIdentity ? stagedObserved : nil)
        throw AutomationFilePartialMutation(
          kind: .remove,
          commitState: .unknown,
          observedFiles: observed,
          recoveryHandle: recovery,
          resultURL: nil
        )
      }
      _ = fsync(parent)
      return .committed(AutomationFileMutationReceipt(
        primaryFile: nil,
        resultURL: nil,
        bindingVerified: true
      ))
    }
  }

  private func withVerifiedParent<T>(
    of url: URL,
    authorization: AutomationDirectoryAuthorization,
    _ body: (Int32, String) throws -> T
  ) throws -> T {
    let parentURL = url.deletingLastPathComponent().standardizedFileURL
    guard parentURL == authorization.directoryURL,
          !authorization.resourceIdentifier.isEmpty else { throw POSIXError(.EPERM) }
    let parent = try Self.openDirectoryNoFollow(parentURL)
    defer { _ = close(parent) }
    var status = stat()
    guard fstat(parent, &status) == 0,
          Self.resourceIdentifier(status) == authorization.resourceIdentifier else {
      throw POSIXError(.EPERM)
    }
    let name = url.lastPathComponent
    guard !name.isEmpty, !name.contains("/") else { throw POSIXError(.EINVAL) }
    return try body(parent, name)
  }

  private static func partialMutationEvidence(
    parent: Int32,
    source: AutomationFileAuthorization,
    sourceName: String,
    stagedName: String,
    expectedIdentity: String
  ) -> (observed: [AutomationFileAuthorization], recovery: AutomationFileAuthorization?) {
    let sourceIdentity = try? entryIdentity(parent: parent, name: sourceName)
    let stagedIdentity = try? entryIdentity(parent: parent, name: stagedName)
    let sourceObserved = sourceIdentity.flatMap {
      AutomationFileAuthorization(
        fileURL: source.fileURL,
        directory: source.directory,
        expectation: .existing(resourceIdentifier: $0)
      )
    }
    let stagedURL = source.directory.directoryURL.appending(
      path: stagedName, directoryHint: .notDirectory
    )
    let stagedObserved = stagedIdentity.flatMap {
      AutomationFileAuthorization(
        fileURL: stagedURL,
        directory: source.directory,
        expectation: .existing(resourceIdentifier: $0)
      )
    }
    let observed = [sourceObserved, stagedObserved].compactMap { $0 }
    let recovery = sourceIdentity == expectedIdentity ? sourceObserved
      : (stagedIdentity == expectedIdentity ? stagedObserved : nil)
    return (observed, recovery)
  }

  private static func openParent(of url: URL) throws -> (Int32, String) {
    let standardized = url.standardizedFileURL
    let name = standardized.lastPathComponent
    guard !name.isEmpty, !name.contains("/") else { throw POSIXError(.EINVAL) }
    return (try openDirectoryNoFollow(standardized.deletingLastPathComponent()), name)
  }

  private static func openDirectoryNoFollow(_ url: URL) throws -> Int32 {
    let path = url.standardizedFileURL.path
    guard path.hasPrefix("/") else { throw POSIXError(.EINVAL) }
    var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard descriptor >= 0 else { throw posixError() }
    if path == "/" { return descriptor }
    for component in path.split(separator: "/").map(String.init) {
      let next = openat(
        descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
      guard next >= 0 else {
        let error = posixError()
        _ = close(descriptor)
        throw error
      }
      _ = close(descriptor)
      descriptor = next
    }
    return descriptor
  }

  private static func metadata(
    path: String,
    status: stat,
    isSymbolicLink: Bool
  ) -> AutomationFileMetadata {
    let canonicalURL = isSymbolicLink
      ? URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
      : URL(fileURLWithPath: path).standardizedFileURL
    return AutomationFileMetadata(
      canonicalURL: canonicalURL,
      ownerUID: status.st_uid,
      isSymbolicLink: isSymbolicLink,
      modificationDate: Date(
        timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)
          + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
      ),
      resourceIdentifier: resourceIdentifier(status),
      permissions: Int(status.st_mode & 0o777)
    )
  }

  private static func resourceIdentifier(_ status: stat) -> String {
    "\(status.st_dev):\(status.st_ino)"
  }

  private static func entryIdentity(parent: Int32, name: String) throws -> String {
    var status = stat()
    guard fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) == 0,
          (status.st_mode & S_IFMT) == S_IFREG else { throw posixError() }
    return resourceIdentifier(status)
  }

  private static func entryMatchesBinding(
    parent: Int32,
    name: String,
    binding: AutomationStagedFileBinding
  ) throws -> Bool {
    let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw posixError() }
    defer { _ = close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0 else { throw posixError() }
    guard (status.st_mode & S_IFMT) == S_IFREG,
          resourceIdentifier(status) == binding.resourceIdentifier,
          status.st_uid == binding.ownerUID,
          Int(status.st_mode & 0o777) == binding.permissions,
          UInt64(status.st_nlink) == binding.linkCount
    else { return false }
    let data = try readAll(descriptor, maxBytes: binding.data.count)
    let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return data == binding.data && checksum == binding.checksum
  }

  private static func readAll(_ descriptor: Int32, maxBytes: Int) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else { throw posixError() }
      if count == 0 { return data }
      guard count <= maxBytes - data.count else { throw POSIXError(.EFBIG) }
      data.append(buffer, count: count)
    }
  }

  private static func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
      guard var base = rawBuffer.baseAddress else { return }
      var remaining = rawBuffer.count
      while remaining > 0 {
        let count = Darwin.write(descriptor, base, remaining)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw posixError() }
        remaining -= count
        base = base.advanced(by: count)
      }
    }
  }

  private static func posixError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}
