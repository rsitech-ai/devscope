import Foundation

public struct ProcessIdentityFingerprint: Hashable, Sendable {
  public let parentPID: Int32
  public let executable: String
  public let command: String
  public let currentDirectory: String?
  public let birthToken: ProcessBirthToken?
  public let workspaceFacts: WorkspaceFacts?

  public init(process: DevProcess, workspaceFacts: WorkspaceFacts? = nil) {
    parentPID = process.parentPID
    executable = process.executable
    command = process.command
    currentDirectory = process.currentDirectory
    birthToken = process.birthToken
    self.workspaceFacts = workspaceFacts
  }
}

public struct ProcessClassificationCache: Sendable {
  private struct Entry: Sendable {
    let fingerprint: ProcessIdentityFingerprint
    let classification: DevProcessClassification
  }

  private var entries: [Int32: Entry] = [:]

  public var cachedProcessIDs: Set<Int32> {
    Set(entries.keys)
  }

  public init() {}

  public mutating func invalidateAll() {
    entries.removeAll(keepingCapacity: true)
  }

  public mutating func classified(_ processes: [DevProcess]) -> [ClassifiedDevProcess] {
    classified(processes) { process in
      ProcessClassifier.classify(process)
    }
  }

  public mutating func classified(
    _ processes: [DevProcess],
    workspaceFactsCache: WorkspaceFactsCache
  ) -> [ClassifiedDevProcess] {
    classified(processes, workspaceFactsCache: workspaceFactsCache) { process, workspaceFacts in
      ProcessClassifier.classify(process, workspaceFacts: workspaceFacts)
    }
  }

  public mutating func classified(
    _ processes: [DevProcess],
    workspaceFactsCache: WorkspaceFactsCache,
    classifier: (DevProcess, WorkspaceFacts) -> DevProcessClassification?
  ) -> [ClassifiedDevProcess] {
    workspaceFactsCache.withRevalidationCycle(maximumStaleEntries: 8) {
      classified(
        processes,
        context: { process in
          workspaceFactsCache.facts(for: process.currentDirectory)
        },
        fingerprint: { process, workspaceFacts in
          ProcessIdentityFingerprint(process: process, workspaceFacts: workspaceFacts)
        },
        classifier: classifier
      )
    }
  }

  public mutating func classified(
    _ processes: [DevProcess],
    classifier: (DevProcess) -> DevProcessClassification?
  ) -> [ClassifiedDevProcess] {
    classified(
      processes,
      context: { _ in () },
      fingerprint: { process, _ in
        ProcessIdentityFingerprint(process: process)
      },
      classifier: { process, _ in
        classifier(process)
      }
    )
  }

  private mutating func classified<Context>(
    _ processes: [DevProcess],
    context: (DevProcess) -> Context,
    fingerprint: (DevProcess, Context) -> ProcessIdentityFingerprint,
    classifier: (DevProcess, Context) -> DevProcessClassification?
  ) -> [ClassifiedDevProcess] {
    let activeIDs = Set(processes.map(\.pid))
    entries = entries.filter { activeIDs.contains($0.key) }

    return processes.compactMap { process in
      let classificationContext = context(process)
      let fingerprint = fingerprint(process, classificationContext)
      let classification: DevProcessClassification

      if let cached = entries[process.pid], cached.fingerprint == fingerprint {
        classification = cached.classification
      } else {
        entries[process.pid] = nil
        guard let fresh = classifier(process, classificationContext) else {
          return nil
        }
        entries[process.pid] = Entry(fingerprint: fingerprint, classification: fresh)
        classification = fresh
      }

      return ClassifiedDevProcess(process: process, classification: classification)
    }
  }
}
