import Darwin
import CryptoKit
import Foundation

public protocol AutomationSource: Sendable {
  var kind: AutomationSourceKind { get }
  func snapshot() async -> AutomationSourceSnapshot
}

public struct AutomationCommand: Equatable, Sendable {
  public let executable: String
  public let arguments: [String]
  public let environment: [String: String]

  public init(
    executable: String,
    arguments: [String],
    environment: [String: String] = [:]
  ) {
    self.executable = executable
    self.arguments = arguments
    self.environment = environment
  }
}

public struct AutomationCommandResult: Equatable, Sendable {
  public let status: Int32
  public let standardOutput: Data
  public let standardError: Data

  public init(status: Int32, standardOutput: Data, standardError: Data) {
    self.status = status
    self.standardOutput = standardOutput
    self.standardError = standardError
  }
}

public protocol AutomationCommandRunning: Sendable {
  func run(_ command: AutomationCommand) async throws -> AutomationCommandResult
}

public struct AutomationFileMetadata: Equatable, Sendable {
  public let canonicalURL: URL
  public let ownerUID: uid_t
  public let isSymbolicLink: Bool
  public let modificationDate: Date
  public let resourceIdentifier: String?
  public let permissions: Int?

  public init(
    canonicalURL: URL,
    ownerUID: uid_t,
    isSymbolicLink: Bool,
    modificationDate: Date,
    resourceIdentifier: String? = nil,
    permissions: Int? = nil
  ) {
    self.canonicalURL = canonicalURL
    self.ownerUID = ownerUID
    self.isSymbolicLink = isSymbolicLink
    self.modificationDate = modificationDate
    self.resourceIdentifier = resourceIdentifier
    self.permissions = permissions
  }
}

public protocol AutomationFileSystem: Sendable {
  func itemExists(at url: URL) -> Bool
  func plistURLs(in directory: URL) throws -> [URL]
  func read(_ url: URL) throws -> Data
  func metadata(for url: URL) throws -> AutomationFileMetadata
  func createDirectory(_ url: URL, permissions: Int) throws
  func writeStagedFile(
    nextTo url: URL,
    data: Data,
    permissions: Int,
    authorization: AutomationDirectoryAuthorization
  ) throws -> AutomationStagedFile
  func replaceItem(
    at destination: AutomationFileAuthorization,
    with staged: AutomationStagedFile
  ) throws -> AutomationFileMutationOutcome
  func fileMatchesBinding(
    _ file: AutomationFileAuthorization,
    binding: AutomationStagedFileBinding
  ) throws -> Bool
  func moveToTrash(_ source: AutomationFileAuthorization) throws -> AutomationFileMutationOutcome
  func removeItem(_ source: AutomationFileAuthorization) throws -> AutomationFileMutationOutcome
}

public struct AutomationDirectoryAuthorization: Equatable, Sendable {
  public let directoryURL: URL
  public let resourceIdentifier: String

  public init?(directoryURL: URL, resourceIdentifier: String?) {
    guard let resourceIdentifier, !resourceIdentifier.isEmpty else { return nil }
    self.directoryURL = directoryURL.standardizedFileURL
    self.resourceIdentifier = resourceIdentifier
  }
}

public enum AutomationFileExpectation: Equatable, Sendable {
  case absent
  case existing(resourceIdentifier: String)
}

public struct AutomationFileAuthorization: Equatable, Sendable {
  public let fileURL: URL
  public let directory: AutomationDirectoryAuthorization
  public let expectation: AutomationFileExpectation

  public init?(
    fileURL: URL,
    directory: AutomationDirectoryAuthorization,
    expectation: AutomationFileExpectation
  ) {
    let fileURL = fileURL.standardizedFileURL
    guard fileURL.deletingLastPathComponent().standardizedFileURL.path
      == directory.directoryURL.standardizedFileURL.path
    else {
      return nil
    }
    if case .existing(let resourceIdentifier) = expectation,
       resourceIdentifier.isEmpty { return nil }
    self.fileURL = fileURL
    self.directory = directory
    self.expectation = expectation
  }
}

public struct AutomationStagedFile: Equatable, Sendable {
  public let url: URL
  public let authorization: AutomationFileAuthorization
  public let binding: AutomationStagedFileBinding

  public init(
    url: URL,
    authorization: AutomationFileAuthorization,
    binding: AutomationStagedFileBinding
  ) {
    self.url = url
    self.authorization = authorization
    self.binding = binding
  }
}

public struct AutomationStagedFileBinding: Equatable, Sendable {
  public let data: Data
  public let checksum: String
  public let resourceIdentifier: String
  public let ownerUID: uid_t
  public let permissions: Int
  public let linkCount: UInt64

  public init(
    data: Data,
    resourceIdentifier: String,
    ownerUID: uid_t,
    permissions: Int,
    linkCount: UInt64
  ) {
    self.data = data
    checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    self.resourceIdentifier = resourceIdentifier
    self.ownerUID = ownerUID
    self.permissions = permissions
    self.linkCount = linkCount
  }
}

public struct AutomationFileMutationReceipt: Equatable, Sendable {
  public let primaryFile: AutomationFileAuthorization?
  public let resultURL: URL?
  public let bindingVerified: Bool

  public init(
    primaryFile: AutomationFileAuthorization?,
    resultURL: URL?,
    bindingVerified: Bool
  ) {
    self.primaryFile = primaryFile
    self.resultURL = resultURL
    self.bindingVerified = bindingVerified
  }
}

public enum AutomationFileMutationOutcome: Equatable, Sendable {
  case committed(AutomationFileMutationReceipt)
  case unchanged
}

public enum AutomationFileMutationCommitState: Equatable, Sendable {
  case committed
  case unknown
}

public enum AutomationFileMutationKind: Equatable, Sendable {
  case replace
  case remove
  case trash
}

public struct AutomationFilePartialMutation: Error, Equatable, Sendable {
  public let kind: AutomationFileMutationKind
  public let commitState: AutomationFileMutationCommitState
  public let observedFiles: [AutomationFileAuthorization]
  public let recoveryHandle: AutomationFileAuthorization?
  public let recoveryHandles: [AutomationFileAuthorization]
  public let resultURL: URL?

  public init(
    kind: AutomationFileMutationKind,
    commitState: AutomationFileMutationCommitState,
    observedFiles: [AutomationFileAuthorization],
    recoveryHandle: AutomationFileAuthorization?,
    recoveryHandles: [AutomationFileAuthorization] = [],
    resultURL: URL?
  ) {
    self.kind = kind
    self.commitState = commitState
    self.observedFiles = observedFiles
    var handles: [AutomationFileAuthorization] = []
    for handle in [recoveryHandle].compactMap({ $0 }) + recoveryHandles
      where !handles.contains(handle) {
      handles.append(handle)
    }
    self.recoveryHandle = handles.first
    self.recoveryHandles = handles
    self.resultURL = resultURL
  }
}
