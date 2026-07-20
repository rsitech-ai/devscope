import XCTest
@testable import DevScopeCore

final class ProcessClassificationCacheTests: XCTestCase {
  func testBudgetedWorkspaceRevalidationProgressivelyReclassifiesChangedFacts() throws {
    var cache = ProcessClassificationCache()
    var classificationCalls = 0
    var flutterDirectories: Set<String> = []
    let workspaceFactsCache = WorkspaceFactsCache { path in
      flutterDirectories.contains(String(path.dropLast("/pubspec.yaml".count))) &&
        path.hasSuffix("/pubspec.yaml")
    }
    let processes = (1...9).map { index in
      process(
        pid: Int32(700 + index),
        command: "workspace-runner serve",
        currentDirectory: "/workspace/\(index)"
      )
    }

    _ = cache.classified(processes, workspaceFactsCache: workspaceFactsCache) { process, workspaceFacts in
      classificationCalls += 1
      return ProcessClassifier.classify(process, workspaceFacts: workspaceFacts)
    }
    flutterDirectories.insert("/workspace/9")
    workspaceFactsCache.invalidateAll()
    let firstCycle = cache.classified(
      processes,
      workspaceFactsCache: workspaceFactsCache
    ) { process, workspaceFacts in
      classificationCalls += 1
      return ProcessClassifier.classify(process, workspaceFacts: workspaceFacts)
    }
    let secondCycle = cache.classified(
      processes,
      workspaceFactsCache: workspaceFactsCache
    ) { process, workspaceFacts in
      classificationCalls += 1
      return ProcessClassifier.classify(process, workspaceFacts: workspaceFacts)
    }

    XCTAssertEqual(try XCTUnwrap(firstCycle.last).classification.kind, .other)
    XCTAssertEqual(try XCTUnwrap(secondCycle.last).classification.kind, .flutter)
    XCTAssertEqual(classificationCalls, 10)
  }

  func testReusesClassificationWhenInvalidatedWorkspaceFactsAreUnchanged() {
    var cache = ProcessClassificationCache()
    var classificationCalls = 0
    var workspaceProbeCount = 0
    let workspaceFactsCache = WorkspaceFactsCache { _ in
      workspaceProbeCount += 1
      return false
    }
    let unchanged = process()

    _ = cache.classified(
      [unchanged],
      workspaceFactsCache: workspaceFactsCache
    ) { process, workspaceFacts in
      classificationCalls += 1
      return ProcessClassifier.classify(process, workspaceFacts: workspaceFacts)
    }
    let initialWorkspaceProbeCount = workspaceProbeCount
    workspaceFactsCache.invalidateAll()
    _ = cache.classified(
      [unchanged],
      workspaceFactsCache: workspaceFactsCache
    ) { process, workspaceFacts in
      classificationCalls += 1
      return ProcessClassifier.classify(process, workspaceFacts: workspaceFacts)
    }

    XCTAssertEqual(classificationCalls, 1)
    XCTAssertGreaterThan(workspaceProbeCount, initialWorkspaceProbeCount)
  }

  func testReclassifiesImmediatelyWhenRefreshedWorkspaceFactsChange() throws {
    var cache = ProcessClassificationCache()
    var classificationCalls = 0
    var manifestExists = false
    let workspaceFactsCache = WorkspaceFactsCache { path in
      manifestExists && path.hasSuffix("/pubspec.yaml")
    }
    let process = process(command: "workspace-runner serve")

    let beforeManifest = cache.classified(
      [process],
      workspaceFactsCache: workspaceFactsCache
    ) { process, workspaceFacts in
      classificationCalls += 1
      return ProcessClassifier.classify(process, workspaceFacts: workspaceFacts)
    }
    manifestExists = true
    workspaceFactsCache.invalidateAll()
    let afterManifest = cache.classified(
      [process],
      workspaceFactsCache: workspaceFactsCache
    ) { process, workspaceFacts in
      classificationCalls += 1
      return ProcessClassifier.classify(process, workspaceFacts: workspaceFacts)
    }

    XCTAssertEqual(classificationCalls, 2)
    XCTAssertEqual(try XCTUnwrap(beforeManifest.first).classification.kind, .other)
    XCTAssertEqual(try XCTUnwrap(afterManifest.first).classification.kind, .flutter)
  }

  func testReusesClassificationWhenOnlyMetricsChange() throws {
    var cache = ProcessClassificationCache()
    var classificationCalls = 0
    let first = process(cpu: 1)
    let second = process(cpu: 80)

    _ = cache.classified([first]) { process in
      classificationCalls += 1
      return ProcessClassifier.classify(process)
    }
    let updated = cache.classified([second]) { process in
      classificationCalls += 1
      return ProcessClassifier.classify(process)
    }

    XCTAssertEqual(classificationCalls, 1)
    XCTAssertEqual(try XCTUnwrap(updated.first).process.resourceUsage?.cpuPercent, 80)
  }

  func testReclassifiesWhenCommandChangesAndDropsMissingPIDs() {
    var cache = ProcessClassificationCache()
    var calls = 0
    _ = cache.classified([process(command: "node vite")]) { process in
      calls += 1
      return ProcessClassifier.classify(process)
    }
    let updated = cache.classified([process(command: "python worker.py")]) { process in
      calls += 1
      return ProcessClassifier.classify(process)
    }
    let empty = cache.classified([]) { process in
      calls += 1
      return ProcessClassifier.classify(process)
    }

    XCTAssertEqual(calls, 2)
    XCTAssertEqual(updated.first?.classification.kind, .python)
    XCTAssertTrue(empty.isEmpty)
    XCTAssertEqual(cache.cachedProcessIDs, [])
  }

  func testReclassifiesRecycledPIDWhenBirthTokenChanges() throws {
    var cache = ProcessClassificationCache()
    var calls = 0
    let first = process(birthToken: ProcessBirthToken(seconds: 1_000, microseconds: 100))
    let recycled = process(birthToken: ProcessBirthToken(seconds: 1_000, microseconds: 101))

    _ = cache.classified([first]) { process in
      calls += 1
      return ProcessClassifier.classify(process)
    }
    let updated = cache.classified([recycled]) { process in
      calls += 1
      return ProcessClassifier.classify(process)
    }

    XCTAssertEqual(calls, 2)
    XCTAssertEqual(try XCTUnwrap(updated.first).process.birthToken, recycled.birthToken)
  }

  private func process(
    pid: Int32 = 700,
    cpu: Double = 1,
    command: String = "node vite",
    currentDirectory: String = NSHomeDirectory() + "/dev/example/devscope",
    birthToken: ProcessBirthToken? = nil
  ) -> DevProcess {
    DevProcess(
      pid: pid,
      parentPID: 1,
      executable: command.split(separator: " ").first.map(String.init) ?? command,
      command: command,
      currentDirectory: currentDirectory,
      resourceUsage: DevProcessResourceUsage(cpuPercent: cpu, residentMemoryBytes: 100, elapsedTime: "00:10"),
      birthToken: birthToken
    )
  }
}
