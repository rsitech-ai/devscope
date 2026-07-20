import Foundation
@testable import DevScopeCore

enum Fixtures {
  static let inventoryGeneration7 = AutomationInventorySnapshot(
    generation: 7,
    records: [userAgent],
    health: [
      .launchAgent: AutomationSourceHealth(
        kind: .launchAgent,
        state: .healthy,
        message: nil,
        refreshedAt: Date(timeIntervalSince1970: 7_000)
      ),
    ],
    refreshedAt: Date(timeIntervalSince1970: 7_000)
  )

  static let userAgent = makeUserAgent(
    idSource: .launchAgent,
    kind: .launchAgent,
    sourceKind: .launchAgent,
    loadState: .unloaded,
    state: .idle,
    evidenceSource: "synthetic launchd fixture"
  )

  static let runningUserAgent = makeUserAgent(
    idSource: .launchAgent,
    kind: .launchAgent,
    sourceKind: .launchAgent,
    loadState: .loaded,
    state: .running,
    evidenceSource: "synthetic launchd fixture"
  )

  static let backgroundCopyOfUserAgent = makeUserAgent(
    idSource: .serviceManagement,
    kind: .backgroundItem,
    sourceKind: .serviceManagement,
    loadState: .loaded,
    state: .running,
    evidenceSource: "synthetic background fixture"
  )

  static let runningBackup = DevProcess(
    pid: 42_001,
    parentPID: 1,
    executable: "/bin/sleep",
    command: "/bin/sleep 14400",
    argumentVector: ["/bin/sleep", "14400"],
    currentDirectory: "/tmp/devscope-fixtures",
    resourceUsage: DevProcessResourceUsage(
      cpuPercent: 0.1,
      residentMemoryBytes: 1_048_576,
      elapsedTime: "04:00:00"
    ),
    birthToken: ProcessBirthToken(seconds: 10_000, microseconds: 42)
  )

  static let runningBackupWithUpdatedMetrics = DevProcess(
    pid: runningBackup.pid,
    parentPID: runningBackup.parentPID,
    executable: runningBackup.executable,
    command: runningBackup.command,
    argumentVector: runningBackup.argumentVector,
    currentDirectory: runningBackup.currentDirectory,
    resourceUsage: DevProcessResourceUsage(
      cpuPercent: 0.2,
      residentMemoryBytes: 1_114_112,
      elapsedTime: "04:00:02"
    ),
    birthToken: runningBackup.birthToken
  )

  static func presentation(elapsedTime: String) -> AutomationPresentationSnapshot {
    let process = DevProcess(
      pid: runningBackup.pid,
      parentPID: runningBackup.parentPID,
      executable: runningBackup.executable,
      command: runningBackup.command,
      argumentVector: runningBackup.argumentVector,
      currentDirectory: runningBackup.currentDirectory,
      resourceUsage: DevProcessResourceUsage(
        cpuPercent: runningBackup.resourceUsage?.cpuPercent ?? 0,
        residentMemoryBytes: runningBackup.resourceUsage?.residentMemoryBytes ?? 0,
        elapsedTime: elapsedTime
      ),
      birthToken: runningBackup.birthToken
    )
    return AutomationPresentationSnapshot.build(
      inventory: inventoryGeneration7,
      processes: [process],
      longRunningThreshold: 14_400,
      now: Date(timeIntervalSince1970: 10_000)
    )
  }

  private static func makeUserAgent(
    idSource: AutomationSourceKind,
    kind: AutomationKind,
    sourceKind: AutomationSourceKind,
    loadState: AutomationLoadState,
    state: AutomationState,
    evidenceSource: String
  ) -> AutomationRecord {
    let label = "com.example.backup"
    let sourcePath = "/tmp/devscope-fixtures/\(sourceKind.rawValue)-backup.plist"

    return AutomationRecord(
      id: AutomationRecord.ID(
        source: idSource,
        ownerUID: 501,
        label: label,
        sourcePath: sourcePath
      ),
      kind: kind,
      sourceKind: sourceKind,
      label: label,
      displayName: "Synthetic Backup Fixture",
      providerBundleIdentifier: "com.example.devscope-fixture-owner",
      ownerUID: 501,
      ownership: .user,
      executable: "/bin/sleep",
      arguments: ["14400"],
      environment: ["DEVSCOPE_FIXTURE": "synthetic"],
      workingDirectory: "/tmp/devscope-fixtures",
      schedule: AutomationSchedule(
        triggers: [.runAtLoad, .interval(seconds: 14_400)],
        summary: "At load and every four hours"
      ),
      sourceURL: URL(fileURLWithPath: sourcePath),
      sourceChecksum: "synthetic-checksum",
      enabledState: .enabled,
      loadState: loadState,
      approvalState: .notApplicable,
      state: state,
      evidence: [AutomationEvidence(
        strength: .strong,
        source: evidenceSource,
        detail: "Exact synthetic label and /bin/sleep executable"
      )],
      capabilities: [.startNow, .disable, .disableAndStop, .edit, .exportRecord],
      validationFindings: []
    )
  }
}

struct FakeAutomationSource: AutomationSource {
  let kind: AutomationSourceKind
  private let value: AutomationSourceSnapshot

  init(snapshot: AutomationSourceSnapshot) {
    kind = snapshot.health.kind
    value = snapshot
  }

  func snapshot() async -> AutomationSourceSnapshot {
    value
  }
}

final class ControllableAutomationClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  init(_ value: Date) {
    self.value = value
  }

  func now() -> Date {
    lock.withLock { value }
  }

  func advance(by interval: TimeInterval) {
    lock.withLock {
      value = value.addingTimeInterval(interval)
    }
  }
}

actor CountingAutomationSource: AutomationSource {
  nonisolated let kind: AutomationSourceKind
  private let value: AutomationSourceSnapshot
  private let delayNanoseconds: UInt64
  private var count = 0

  init(snapshot: AutomationSourceSnapshot, delayNanoseconds: UInt64 = 0) {
    kind = snapshot.health.kind
    value = snapshot
    self.delayNanoseconds = delayNanoseconds
  }

  func snapshot() async -> AutomationSourceSnapshot {
    count += 1
    if delayNanoseconds > 0 {
      try? await Task.sleep(nanoseconds: delayNanoseconds)
    }
    return value
  }

  func invocationCount() -> Int {
    count
  }
}

enum AutomationTestFixtureError: Error, Equatable, Sendable {
  case commandFailed
  case missingItem(URL)
  case readFailed(URL)
  case authorizationFailed(URL)
  case removeFailed(URL)
}

final class RecordingAutomationCommandRunner: AutomationCommandRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var recordedInvocations: [AutomationCommand] = []
  private let result: Result<AutomationCommandResult, AutomationTestFixtureError>

  init(
    result: Result<AutomationCommandResult, AutomationTestFixtureError> = .success(
      AutomationCommandResult(
        status: 0,
        standardOutput: Data(),
        standardError: Data()
      )
    )
  ) {
    self.result = result
  }

  var invocations: [AutomationCommand] {
    lock.withLock { recordedInvocations }
  }

  func run(_ command: AutomationCommand) async throws -> AutomationCommandResult {
    lock.withLock {
      recordedInvocations.append(command)
    }
    return try result.get()
  }
}

final class InMemoryAutomationFileSystem: AutomationFileSystem, @unchecked Sendable {
  enum Operation: Equatable {
    case createDirectory(URL, permissions: Int)
    case writeTemporary(URL, permissions: Int)
    case replace(URL, URL)
    case moveToTrash(URL, URL)
    case remove(URL)
  }

  private let lock = NSLock()
  private var files: [URL: Data]
  private var metadataByURL: [URL: AutomationFileMetadata]
  private var directories: Set<URL>
  private var failingReads: Set<URL>
  private var metadataFailuresRemainingAfterReplace: [URL: Int]
  private var metadataOverridesAfterReplace: [URL: AutomationFileMetadata]
  private var dataOverridesAfterReplace: [URL: [Int: Data]]
  private var partialReplaceOccurrences: [URL: Set<Int>]
  private var partialReplaceRetainedStagedOccurrences: [URL: Set<Int>]
  private var unchangedReplaceOccurrences: [URL: Set<Int>]
  private let unchangedReplaceRetainsStaged: Bool
  private var partialReplaceObservedOnly: [URL: [URL]]
  private var replaceCounts: [URL: Int] = [:]
  private var partialTrashSources: Set<URL>
  private var partialRemoveSources: Set<URL>
  private var failingRemoves: Set<URL>
  private var unchangedRemoves: Set<URL>
  private var failStagedRemoves: Bool
  private var filesInstalledBeforeRemoveFailure: [URL: [URL: Data]]
  private var readObserver: (@Sendable (URL, Data) -> Void)?
  private var operations: [Operation] = []
  private var temporaryFileSequence = 0

  init(
    files: [URL: Data] = [:],
    metadata: [URL: AutomationFileMetadata] = [:],
    directories: Set<URL> = [],
    failingReads: Set<URL> = [],
    metadataFailuresAfterReplace: [URL: Int] = [:],
    metadataAfterReplace: [URL: AutomationFileMetadata] = [:],
    dataAfterReplace: [URL: Data] = [:],
    dataAfterReplaceOccurrences: [URL: [Int: Data]] = [:],
    partialReplaceAfterCommit: Set<URL> = [],
    partialReplaceAfterCommitOccurrences: [URL: Set<Int>] = [:],
    partialReplaceRetainsStagedOccurrences: [URL: Set<Int>] = [:],
    unchangedReplaceOccurrences: [URL: Set<Int>] = [:],
    unchangedReplaceRetainsStaged: Bool = false,
    partialReplaceObservedOnly: [URL: [URL]] = [:],
    partialTrashAfterCommit: Set<URL> = [],
    partialRemoveAfterCommit: Set<URL> = [],
    failingRemoves: Set<URL> = [],
    unchangedRemoves: Set<URL> = [],
    failStagedRemoves: Bool = false,
    filesInstalledBeforeRemoveFailure: [URL: [URL: Data]] = [:]
  ) {
    self.files = Dictionary(
      files.map { (Self.canonical($0.key), $0.value) },
      uniquingKeysWith: { _, latest in latest }
    )
    metadataByURL = Dictionary(
      metadata.map { (Self.canonical($0.key), $0.value) },
      uniquingKeysWith: { _, latest in latest }
    )
    self.directories = Set(
      directories.map(Self.canonical)
        + files.keys.map { Self.canonical($0.deletingLastPathComponent()) }
    )
    self.failingReads = Set(failingReads.map(Self.canonical))
    metadataFailuresRemainingAfterReplace = Dictionary(
      metadataFailuresAfterReplace.map { (Self.canonical($0.key), $0.value) },
      uniquingKeysWith: +
    )
    metadataOverridesAfterReplace = Dictionary(
      metadataAfterReplace.map { (Self.canonical($0.key), $0.value) },
      uniquingKeysWith: { _, latest in latest }
    )
    dataOverridesAfterReplace = Dictionary(
      dataAfterReplaceOccurrences.map { (Self.canonical($0.key), $0.value) },
      uniquingKeysWith: { _, latest in latest }
    )
    for (destination, data) in dataAfterReplace {
      dataOverridesAfterReplace[Self.canonical(destination), default: [:]][1] = data
    }
    partialReplaceOccurrences = Dictionary(
      partialReplaceAfterCommitOccurrences.map { (Self.canonical($0.key), $0.value) },
      uniquingKeysWith: { $0.union($1) }
    )
    for destination in partialReplaceAfterCommit.map(Self.canonical) {
      partialReplaceOccurrences[destination, default: []].insert(1)
    }
    partialReplaceRetainedStagedOccurrences = Dictionary(
      partialReplaceRetainsStagedOccurrences.map { (Self.canonical($0.key), $0.value) },
      uniquingKeysWith: { $0.union($1) }
    )
    self.unchangedReplaceOccurrences = Dictionary(
      unchangedReplaceOccurrences.map { (Self.canonical($0.key), $0.value) },
      uniquingKeysWith: { $0.union($1) }
    )
    self.unchangedReplaceRetainsStaged = unchangedReplaceRetainsStaged
    self.partialReplaceObservedOnly = Dictionary(
      partialReplaceObservedOnly.map {
        (Self.canonical($0.key), $0.value.map(Self.canonical))
      },
      uniquingKeysWith: +
    )
    partialTrashSources = Set(partialTrashAfterCommit.map(Self.canonical))
    partialRemoveSources = Set(partialRemoveAfterCommit.map(Self.canonical))
    self.failingRemoves = Set(failingRemoves.map(Self.canonical))
    self.unchangedRemoves = Set(unchangedRemoves.map(Self.canonical))
    self.failStagedRemoves = failStagedRemoves
    self.filesInstalledBeforeRemoveFailure = Dictionary(
      filesInstalledBeforeRemoveFailure.map { failureURL, installedFiles in
        (
          Self.canonical(failureURL),
          Dictionary(
            installedFiles.map { (Self.canonical($0.key), $0.value) },
            uniquingKeysWith: { _, latest in latest }
          )
        )
      },
      uniquingKeysWith: { _, latest in latest }
    )
  }

  var recordedOperations: [Operation] {
    lock.withLock { operations }
  }

  func itemExists(at url: URL) -> Bool {
    let url = Self.canonical(url)
    return lock.withLock { files[url] != nil || directories.contains(url) }
  }

  func storedData(at url: URL) -> Data? {
    lock.withLock { files[Self.canonical(url)] }
  }

  func setStoredData(_ data: Data, at url: URL) {
    let url = Self.canonical(url)
    lock.withLock {
      files[url] = data
      directories.insert(Self.canonical(url.deletingLastPathComponent()))
    }
  }

  func setMetadata(_ metadata: AutomationFileMetadata, for url: URL) {
    lock.withLock {
      metadataByURL[Self.canonical(url)] = metadata
    }
  }

  func setReadObserver(_ observer: (@Sendable (URL, Data) -> Void)?) {
    lock.withLock { readObserver = observer }
  }

  func plistURLs(in directory: URL) throws -> [URL] {
    let directory = Self.canonical(directory)
    return try lock.withLock {
      guard directories.contains(directory) else {
        throw AutomationTestFixtureError.missingItem(directory)
      }
      return files.keys
        .filter {
          $0.pathExtension == "plist"
            && Self.canonical($0.deletingLastPathComponent()) == directory
        }
        .sorted { $0.path < $1.path }
    }
  }

  func read(_ url: URL) throws -> Data {
    let url = Self.canonical(url)
    let (data, observer) = try lock.withLock {
      guard !failingReads.contains(url) else {
        throw AutomationTestFixtureError.readFailed(url)
      }
      guard let data = files[url] else {
        throw AutomationTestFixtureError.missingItem(url)
      }
      return (data, readObserver)
    }
    observer?(url, data)
    return data
  }

  func metadata(for url: URL) throws -> AutomationFileMetadata {
    let url = Self.canonical(url)
    return try lock.withLock {
      let wasReplaced = operations.contains { operation in
        if case .replace(let replacedURL, _) = operation { return replacedURL == url }
        return false
      }
      if wasReplaced, let failures = metadataFailuresRemainingAfterReplace[url], failures > 0 {
        metadataFailuresRemainingAfterReplace[url] = failures - 1
        throw AutomationTestFixtureError.readFailed(url)
      }
      guard files[url] != nil || directories.contains(url) else {
        throw AutomationTestFixtureError.missingItem(url)
      }
      return metadataByURL[url] ?? Self.defaultMetadata(for: url)
    }
  }

  func createDirectory(_ url: URL, permissions: Int) throws {
    let url = Self.canonical(url)
    lock.withLock {
      directories.insert(url)
      let existing = metadataByURL[url] ?? Self.defaultMetadata(for: url)
      metadataByURL[url] = AutomationFileMetadata(
        canonicalURL: url,
        ownerUID: existing.ownerUID,
        isSymbolicLink: existing.isSymbolicLink,
        modificationDate: existing.modificationDate,
        resourceIdentifier: existing.resourceIdentifier,
        permissions: permissions
      )
      operations.append(.createDirectory(url, permissions: permissions))
    }
  }

  func writeStagedFile(
    nextTo url: URL,
    data: Data,
    permissions: Int,
    authorization: AutomationDirectoryAuthorization
  ) throws -> AutomationStagedFile {
    let url = Self.canonical(url)
    return try lock.withLock {
      let directoryURL = Self.canonical(authorization.directoryURL)
      guard directoryURL.path == Self.canonical(url.deletingLastPathComponent()).path,
            directories.contains(directoryURL),
            (metadataByURL[directoryURL] ?? Self.defaultMetadata(for: directoryURL))
              .resourceIdentifier == authorization.resourceIdentifier
      else { throw AutomationTestFixtureError.authorizationFailed(directoryURL) }

      temporaryFileSequence += 1
      let temporaryURL = Self.canonical(
        directoryURL.appendingPathComponent(".devscope-fixture-\(temporaryFileSequence).tmp")
      )
      files[temporaryURL] = data
      let metadata = Self.defaultMetadata(for: temporaryURL)
      metadataByURL[temporaryURL] = AutomationFileMetadata(
        canonicalURL: temporaryURL,
        ownerUID: metadata.ownerUID,
        isSymbolicLink: false,
        modificationDate: metadata.modificationDate,
        resourceIdentifier: metadata.resourceIdentifier,
        permissions: permissions
      )
      operations.append(.writeTemporary(temporaryURL, permissions: permissions))
      guard let fileAuthorization = AutomationFileAuthorization(
        fileURL: temporaryURL,
        directory: authorization,
        expectation: .existing(resourceIdentifier: metadata.resourceIdentifier ?? "")
      ) else { throw AutomationTestFixtureError.authorizationFailed(temporaryURL) }
      return AutomationStagedFile(
        url: temporaryURL,
        authorization: fileAuthorization,
        binding: AutomationStagedFileBinding(
          data: data,
          resourceIdentifier: metadata.resourceIdentifier ?? "",
          ownerUID: metadata.ownerUID,
          permissions: permissions,
          linkCount: 1
        )
      )
    }
  }

  func replaceItem(
    at destination: AutomationFileAuthorization,
    with staged: AutomationStagedFile
  ) throws -> AutomationFileMutationOutcome {
    let destinationURL = Self.canonical(destination.fileURL)
    let stagedURL = Self.canonical(staged.url)
    return try lock.withLock {
      let directoryURL = Self.canonical(destination.directory.directoryURL)
      let directoryMetadata = metadataByURL[directoryURL] ?? Self.defaultMetadata(for: directoryURL)
      guard directories.contains(directoryURL),
            directoryMetadata.resourceIdentifier == destination.directory.resourceIdentifier,
            destinationURL.deletingLastPathComponent().path == directoryURL.path,
            staged.authorization.directory == destination.directory,
            Self.canonical(staged.authorization.fileURL) == stagedURL,
            stagedURL.deletingLastPathComponent().path == directoryURL.path,
            let data = files[stagedURL],
            let stagedMetadata = metadataByURL[stagedURL],
            case .existing(let stagedIdentity) = staged.authorization.expectation,
            stagedMetadata.resourceIdentifier == stagedIdentity,
            staged.binding.resourceIdentifier == stagedIdentity,
            staged.binding.data == data,
            staged.binding.ownerUID == stagedMetadata.ownerUID,
            staged.binding.permissions == stagedMetadata.permissions,
            staged.binding.linkCount == 1
      else { throw AutomationTestFixtureError.authorizationFailed(destinationURL) }

      switch destination.expectation {
      case .absent:
        guard files[destinationURL] == nil else {
          throw AutomationTestFixtureError.authorizationFailed(destinationURL)
        }
      case .existing(let expectedIdentity):
        guard files[destinationURL] != nil,
              (metadataByURL[destinationURL] ?? Self.defaultMetadata(for: destinationURL))
                .resourceIdentifier == expectedIdentity
        else { throw AutomationTestFixtureError.authorizationFailed(destinationURL) }
      }

      let replaceCount = (replaceCounts[destinationURL] ?? 0) + 1
      replaceCounts[destinationURL] = replaceCount
      if unchangedReplaceOccurrences[destinationURL]?.remove(replaceCount) != nil {
        if !unchangedReplaceRetainsStaged {
          files.removeValue(forKey: stagedURL)
          metadataByURL.removeValue(forKey: stagedURL)
        }
        return .unchanged
      }

      let displacedData = files[destinationURL]
      let displacedMetadata = metadataByURL[destinationURL]
        ?? Self.defaultMetadata(for: destinationURL)

      files[destinationURL] = data
      metadataByURL[destinationURL] = AutomationFileMetadata(
        canonicalURL: destinationURL,
        ownerUID: stagedMetadata.ownerUID,
        isSymbolicLink: false,
        modificationDate: stagedMetadata.modificationDate,
        resourceIdentifier: stagedMetadata.resourceIdentifier,
        permissions: stagedMetadata.permissions
      )
      if let override = metadataOverridesAfterReplace[destinationURL] {
        metadataByURL[destinationURL] = override
      }
      if let override = dataOverridesAfterReplace[destinationURL]?.removeValue(
        forKey: replaceCount
      ) {
        files[destinationURL] = override
      }
      files.removeValue(forKey: stagedURL)
      metadataByURL.removeValue(forKey: stagedURL)
      operations.append(.replace(destinationURL, stagedURL))
      let installed = AutomationFileAuthorization(
        fileURL: destinationURL,
        directory: destination.directory,
        expectation: .existing(resourceIdentifier: staged.binding.resourceIdentifier)
      )
      let shouldReportPartial = partialReplaceOccurrences[destinationURL]?.contains(
        replaceCount
      ) == true
      partialReplaceOccurrences[destinationURL]?.remove(replaceCount)
      if shouldReportPartial, let installed {
        let retainsStagedRecovery = partialReplaceRetainedStagedOccurrences[destinationURL]?
          .remove(replaceCount) != nil
        if retainsStagedRecovery {
          files[stagedURL] = data
          metadataByURL[stagedURL] = stagedMetadata
        }
        let recovery: AutomationFileAuthorization
        if let displacedData {
          temporaryFileSequence += 1
          let recoveryURL = Self.canonical(
            destination.directory.directoryURL.appendingPathComponent(
              ".devscope-fixture-displaced-\(temporaryFileSequence)"
            )
          )
          files[recoveryURL] = displacedData
          metadataByURL[recoveryURL] = AutomationFileMetadata(
            canonicalURL: recoveryURL,
            ownerUID: displacedMetadata.ownerUID,
            isSymbolicLink: false,
            modificationDate: displacedMetadata.modificationDate,
            resourceIdentifier: displacedMetadata.resourceIdentifier,
            permissions: displacedMetadata.permissions
          )
          guard let displacedIdentity = displacedMetadata.resourceIdentifier,
                let displacedRecovery = AutomationFileAuthorization(
                fileURL: recoveryURL,
                directory: destination.directory,
                expectation: .existing(resourceIdentifier: displacedIdentity)
              )
          else { throw AutomationTestFixtureError.authorizationFailed(recoveryURL) }
          recovery = displacedRecovery
        } else {
          recovery = installed
        }
        let observedOnly = (partialReplaceObservedOnly[destinationURL] ?? []).compactMap {
          observedURL -> AutomationFileAuthorization? in
          guard let observedIdentity = (metadataByURL[observedURL]
            ?? Self.defaultMetadata(for: observedURL)).resourceIdentifier,
                files[observedURL] != nil
          else { return nil }
          return AutomationFileAuthorization(
            fileURL: observedURL,
            directory: destination.directory,
            expectation: .existing(resourceIdentifier: observedIdentity)
          )
        }
        let retainedStaged = retainsStagedRecovery ? [staged.authorization] : []
        throw AutomationFilePartialMutation(
          kind: .replace,
          commitState: .committed,
          observedFiles: [installed, recovery] + retainedStaged + observedOnly,
          recoveryHandle: recovery,
          recoveryHandles: retainedStaged,
          resultURL: destinationURL
        )
      }
      return .committed(AutomationFileMutationReceipt(
        primaryFile: installed,
        resultURL: destinationURL,
        bindingVerified: true
      ))
    }
  }

  func moveToTrash(
    _ source: AutomationFileAuthorization
  ) throws -> AutomationFileMutationOutcome {
    let sourceURL = Self.canonical(source.fileURL)
    return try lock.withLock {
      let directoryURL = Self.canonical(source.directory.directoryURL)
      guard directories.contains(directoryURL),
            (metadataByURL[directoryURL] ?? Self.defaultMetadata(for: directoryURL))
              .resourceIdentifier == source.directory.resourceIdentifier,
            sourceURL.deletingLastPathComponent().path == directoryURL.path,
            case .existing(let expectedIdentity) = source.expectation,
            files[sourceURL] != nil
      else { throw AutomationTestFixtureError.authorizationFailed(sourceURL) }
      let sourceMetadata = metadataByURL[sourceURL] ?? Self.defaultMetadata(for: sourceURL)
      guard let data = files[sourceURL],
            sourceMetadata.resourceIdentifier == expectedIdentity
      else { throw AutomationTestFixtureError.authorizationFailed(sourceURL) }

      temporaryFileSequence += 1
      let trashURL = Self.canonical(URL(fileURLWithPath:
        "/tmp/devscope-fixtures/trash/\(temporaryFileSequence)-\(sourceURL.lastPathComponent)"
      ))
      files[trashURL] = data
      metadataByURL[trashURL] = AutomationFileMetadata(
        canonicalURL: trashURL,
        ownerUID: sourceMetadata.ownerUID,
        isSymbolicLink: false,
        modificationDate: sourceMetadata.modificationDate,
        resourceIdentifier: sourceMetadata.resourceIdentifier,
        permissions: sourceMetadata.permissions
      )
      files.removeValue(forKey: sourceURL)
      metadataByURL.removeValue(forKey: sourceURL)
      operations.append(.moveToTrash(sourceURL, trashURL))
      if partialTrashSources.remove(sourceURL) != nil {
        let trashDirectory = Self.canonical(trashURL.deletingLastPathComponent())
        directories.insert(trashDirectory)
        let directoryMetadata = metadataByURL[trashDirectory]
          ?? Self.defaultMetadata(for: trashDirectory)
        metadataByURL[trashDirectory] = directoryMetadata
        guard let directory = AutomationDirectoryAuthorization(
          directoryURL: trashDirectory,
          resourceIdentifier: directoryMetadata.resourceIdentifier
        ), let identity = sourceMetadata.resourceIdentifier,
        let recovery = AutomationFileAuthorization(
          fileURL: trashURL,
          directory: directory,
          expectation: .existing(resourceIdentifier: identity)
        ) else { throw AutomationTestFixtureError.authorizationFailed(trashURL) }
        throw AutomationFilePartialMutation(
          kind: .trash,
          commitState: .committed,
          observedFiles: [recovery],
          recoveryHandle: recovery,
          resultURL: trashURL
        )
      }
      return .committed(AutomationFileMutationReceipt(
        primaryFile: nil,
        resultURL: trashURL,
        bindingVerified: true
      ))
    }
  }

  func fileMatchesBinding(
    _ file: AutomationFileAuthorization,
    binding: AutomationStagedFileBinding
  ) throws -> Bool {
    let url = Self.canonical(file.fileURL)
    return lock.withLock {
      guard case .existing(let expectedIdentity) = file.expectation,
            let data = files[url]
      else { return false }
      let metadata = metadataByURL[url] ?? Self.defaultMetadata(for: url)
      return expectedIdentity == binding.resourceIdentifier
        && metadata.resourceIdentifier == binding.resourceIdentifier
        && metadata.ownerUID == binding.ownerUID
        && metadata.permissions == binding.permissions
        && data == binding.data
    }
  }

  func removeItem(
    _ source: AutomationFileAuthorization
  ) throws -> AutomationFileMutationOutcome {
    let sourceURL = Self.canonical(source.fileURL)
    return try lock.withLock {
      let directoryURL = Self.canonical(source.directory.directoryURL)
      guard directories.contains(directoryURL),
            (metadataByURL[directoryURL] ?? Self.defaultMetadata(for: directoryURL))
              .resourceIdentifier == source.directory.resourceIdentifier,
            sourceURL.deletingLastPathComponent().path == directoryURL.path,
            case .existing(let expectedIdentity) = source.expectation,
            files[sourceURL] != nil,
            (metadataByURL[sourceURL] ?? Self.defaultMetadata(for: sourceURL))
              .resourceIdentifier == expectedIdentity
      else { throw AutomationTestFixtureError.authorizationFailed(sourceURL) }
      if unchangedRemoves.contains(sourceURL) {
        return .unchanged
      }
      if failingRemoves.contains(sourceURL)
        || failStagedRemoves && sourceURL.lastPathComponent.hasPrefix(".devscope-fixture-") {
        for (installedURL, installedData) in filesInstalledBeforeRemoveFailure[sourceURL] ?? [:] {
          temporaryFileSequence += 1
          files[installedURL] = installedData
          let metadata = Self.defaultMetadata(for: installedURL)
          metadataByURL[installedURL] = AutomationFileMetadata(
            canonicalURL: installedURL,
            ownerUID: metadata.ownerUID,
            isSymbolicLink: false,
            modificationDate: metadata.modificationDate,
            resourceIdentifier: "fixture:remove-failure:\(temporaryFileSequence):\(installedURL.path)",
            permissions: metadata.permissions
          )
        }
        throw AutomationTestFixtureError.removeFailed(sourceURL)
      }
      let removedData = files[sourceURL] ?? Data()
      let removedMetadata = metadataByURL[sourceURL] ?? Self.defaultMetadata(for: sourceURL)
      files.removeValue(forKey: sourceURL)
      metadataByURL.removeValue(forKey: sourceURL)
      operations.append(.remove(sourceURL))
      if partialRemoveSources.remove(sourceURL) != nil {
        temporaryFileSequence += 1
        let recoveryURL = Self.canonical(
          directoryURL.appendingPathComponent(".devscope-fixture-remove-\(temporaryFileSequence)")
        )
        files[recoveryURL] = removedData
        metadataByURL[recoveryURL] = removedMetadata
        guard let identity = removedMetadata.resourceIdentifier,
              let recovery = AutomationFileAuthorization(
                fileURL: recoveryURL,
                directory: source.directory,
                expectation: .existing(resourceIdentifier: identity)
              )
        else { throw AutomationTestFixtureError.authorizationFailed(recoveryURL) }
        throw AutomationFilePartialMutation(
          kind: .remove,
          commitState: .committed,
          observedFiles: [recovery],
          recoveryHandle: recovery,
          resultURL: nil
        )
      }
      return .committed(AutomationFileMutationReceipt(
        primaryFile: nil,
        resultURL: nil,
        bindingVerified: true
      ))
    }
  }

  private static func canonical(_ url: URL) -> URL {
    URL(fileURLWithPath: url.standardizedFileURL.path)
  }

  private static func defaultMetadata(for url: URL) -> AutomationFileMetadata {
    AutomationFileMetadata(
      canonicalURL: canonical(url),
      ownerUID: 501,
      isSymbolicLink: false,
      modificationDate: Date(timeIntervalSince1970: 1_000),
      resourceIdentifier: "fixture:\(canonical(url).path)"
    )
  }
}

final class ControllableClock: @unchecked Sendable {
  private let lock = NSLock()
  private var currentDate: Date

  init(now: Date = Date(timeIntervalSince1970: 1_000)) {
    currentDate = now
  }

  func now() -> Date {
    lock.withLock { currentDate }
  }

  func advance(by interval: TimeInterval) {
    lock.withLock {
      currentDate = currentDate.addingTimeInterval(interval)
    }
  }
}

extension AutomationCapabilityContext {
  static func fixture(
    currentUID: uid_t,
    canonicalPathIsApproved: Bool,
    ownerUID: uid_t?,
    isSymlink: Bool = false,
    isManaged: Bool = false,
    implementedCapabilities: Set<AutomationCapability> = Set(AutomationCapability.allCases)
  ) -> Self {
    Self(
      currentUID: currentUID,
      canonicalPathIsApproved: canonicalPathIsApproved,
      sourceOwnerUID: ownerUID,
      isSymlink: isSymlink,
      isManaged: isManaged,
      implementedCapabilities: implementedCapabilities
    )
  }
}
