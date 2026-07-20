import Foundation

public struct WorkspaceFacts: Hashable, Sendable {
  public let isFlutterWorkspace: Bool

  public init(isFlutterWorkspace: Bool) {
    self.isFlutterWorkspace = isFlutterWorkspace
  }
}

public final class WorkspaceFactsCache: @unchecked Sendable {
  public typealias FileExists = (String) -> Bool

  private struct Entry {
    var facts: WorkspaceFacts
    var validatedGeneration: UInt64
    var lastAccessGeneration: UInt64
  }

  private struct RevalidationCycle {
    let identifier: UInt64
    let generation: UInt64
    var remainingStaleEntries: Int
    var claimedDirectories: Set<String> = []
  }

  private enum Lookup {
    case cached(WorkspaceFacts)
    case probe(expectedGeneration: UInt64)
  }

  private let fileExists: FileExists
  private let lock = NSLock()
  private var entries: [String: Entry] = [:]
  private var generation: UInt64 = 0
  private var nextCycleIdentifier: UInt64 = 0
  private var revalidationCycle: RevalidationCycle?

  public init(fileExists: @escaping FileExists = { FileManager.default.fileExists(atPath: $0) }) {
    self.fileExists = fileExists
  }

  public func facts(for directory: String?) -> WorkspaceFacts {
    guard let directory else {
      return WorkspaceFacts(isFlutterWorkspace: false)
    }

    while true {
      let lookup = lock.withLock { () -> Lookup in
        guard var entry = entries[directory] else {
          return .probe(expectedGeneration: generation)
        }

        entry.lastAccessGeneration = generation
        entries[directory] = entry

        guard entry.validatedGeneration != generation else {
          return .cached(entry.facts)
        }

        guard var cycle = revalidationCycle, cycle.generation == generation else {
          return .probe(expectedGeneration: generation)
        }
        guard !cycle.claimedDirectories.contains(directory) else {
          return .cached(entry.facts)
        }
        guard cycle.remainingStaleEntries > 0 else {
          return .cached(entry.facts)
        }

        cycle.claimedDirectories.insert(directory)
        cycle.remainingStaleEntries -= 1
        revalidationCycle = cycle
        return .probe(expectedGeneration: generation)
      }

      switch lookup {
      case .cached(let facts):
        return facts
      case .probe(let expectedGeneration):
        let components = URL(fileURLWithPath: directory).pathComponents.map { $0.lowercased() }
        let pathIdentifiesFlutter = components.contains("flutter") || components.contains(".dart_tool")
        let manifestIdentifiesFlutter = fileExists(directory + "/pubspec.yaml") ||
          fileExists(directory + "/.dart_tool/package_config.json")
        let facts = WorkspaceFacts(isFlutterWorkspace: pathIdentifiesFlutter || manifestIdentifiesFlutter)

        let storedFacts = lock.withLock { () -> WorkspaceFacts? in
          guard generation == expectedGeneration else {
            return nil
          }
          if let cached = entries[directory], cached.validatedGeneration == generation {
            return cached.facts
          }
          entries[directory] = Entry(
            facts: facts,
            validatedGeneration: generation,
            lastAccessGeneration: generation
          )
          return facts
        }

        if let storedFacts {
          return storedFacts
        }
      }
    }
  }

  public func withRevalidationCycle<Result>(
    maximumStaleEntries: Int,
    _ operation: () throws -> Result
  ) rethrows -> Result {
    let cycleIdentifier = lock.withLock { () -> UInt64 in
      nextCycleIdentifier &+= 1
      let identifier = nextCycleIdentifier
      revalidationCycle = RevalidationCycle(
        identifier: identifier,
        generation: generation,
        remainingStaleEntries: max(0, maximumStaleEntries)
      )
      return identifier
    }
    defer {
      lock.withLock {
        if revalidationCycle?.identifier == cycleIdentifier {
          revalidationCycle = nil
        }
      }
    }
    return try operation()
  }

  public func isFlutterWorkspace(_ directory: String?) -> Bool {
    facts(for: directory).isFlutterWorkspace
  }

  public func invalidateAll() {
    lock.withLock {
      entries = entries.filter { $0.value.lastAccessGeneration == generation }
      generation &+= 1
      revalidationCycle = nil
    }
  }
}
