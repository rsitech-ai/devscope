import XCTest
@testable import DevScopeCore

final class SystemProcessScannerTests: XCTestCase {
  func testBundleIdentityUsesInjectedExactMetadataProvider() {
    let provider = FakeBundleIdentityProvider(
      identifiers: ["/Applications/Exact.app/Contents/MacOS/Exact": "com.example.exact"]
    )

    XCTAssertEqual(
      ProcessScanner.bundleIdentifier(
        forExecutableURL: URL(fileURLWithPath: "/Applications/Exact.app/Contents/MacOS/Exact"),
        processID: 101,
        provider: provider
      ),
      "com.example.exact"
    )
    XCTAssertNil(ProcessScanner.bundleIdentifier(
      forExecutableURL: URL(fileURLWithPath: "/Applications/Exact.app/Contents/MacOS/Other"),
      processID: 102,
      provider: provider
    ))
    XCTAssertEqual(provider.requestedPaths, [
      "/Applications/Exact.app/Contents/MacOS/Exact",
      "/Applications/Exact.app/Contents/MacOS/Other",
    ])
  }

  func testBundleIdentityRecorderPreservesDistinctProcessIDsForSharedExecutableURL() {
    let recorder = OrderedProcessEvidenceCallRecorder()
    let provider = ConstantBundleIdentityProvider(
      identifier: "com.example.shared",
      recorder: recorder
    )
    let executableURL = URL(fileURLWithPath: "/Applications/Shared.app/Contents/MacOS/Shared")

    _ = ProcessScanner.bundleIdentifier(
      forExecutableURL: executableURL,
      processID: 101,
      provider: provider
    )
    _ = ProcessScanner.bundleIdentifier(
      forExecutableURL: executableURL,
      processID: 202,
      provider: provider
    )

    XCTAssertEqual(recorder.processIDs(for: .bundleIdentity), [101, 202])
  }

  func testFoundationBundleIdentityRequiresExactExecutableAndResolvesSymlinksAndNestedBundles() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("DevScopeBundle-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let outer = try makeBundle(at: root.appendingPathComponent("Outer.app"),
                               executable: "Outer", identifier: "com.example.outer")
    let unrelated = root.appendingPathComponent("Outer.app/Contents/Helpers/Other")
    try FileManager.default.createDirectory(
      at: unrelated.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    XCTAssertTrue(FileManager.default.createFile(atPath: unrelated.path, contents: Data()))
    let nested = try makeBundle(
      at: root.appendingPathComponent("Outer.app/Contents/Helpers/Nested.app"),
      executable: "Nested", identifier: "com.example.nested"
    )
    let symlink = root.appendingPathComponent("outer-link")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outer)
    let provider = FoundationProcessBundleIdentityProvider()

    XCTAssertEqual(
      provider.bundleIdentifier(forExecutableURL: symlink, processID: 101),
      "com.example.outer"
    )
    XCTAssertNil(provider.bundleIdentifier(forExecutableURL: unrelated, processID: 102))
    XCTAssertEqual(
      provider.bundleIdentifier(forExecutableURL: nested, processID: 103),
      "com.example.nested"
    )
  }

  func testNativeMetadataLooksUpOnlyCurrentPSRows() {
    let firstBirth = ProcessBirthToken(seconds: 1_000, microseconds: 1)
    let secondBirth = ProcessBirthToken(seconds: 1_000, microseconds: 2)
    let provider = FakeNativeMetadataProvider(processes: [
      101: nativeProcess(pid: 101, birthToken: firstBirth),
      102: nativeProcess(pid: 102, birthToken: secondBirth),
      999: nativeProcess(pid: 999, birthToken: ProcessBirthToken(seconds: 9_000, microseconds: 9)),
    ])
    let scanner = SystemProcessScanner(nativeMetadataProvider: provider)

    let metadata = scanner.nativeMetadata(
      for: [psProcess(pid: 101), psProcess(pid: 102)],
      birthTokens: [101: firstBirth, 102: secondBirth]
    )

    XCTAssertEqual(provider.requestedProcessIDs, [101, 102])
    XCTAssertEqual(Set(metadata.keys), Set([101, 102]))
    XCTAssertNil(metadata[999])
  }

  func testStablePositiveNativeMetadataRemainsCachedAfterNegativeTTL() {
    let birthToken = ProcessBirthToken(seconds: 1_000, microseconds: 1)
    let provider = FakeNativeMetadataProvider(processes: [
      101: nativeProcess(pid: 101, birthToken: birthToken),
    ])
    let scanner = SystemProcessScanner(nativeMetadataProvider: provider)
    let processes = [psProcess(pid: 101)]
    let birthTokens = [Int32(101): birthToken]
    let start = Date(timeIntervalSince1970: 1_000)

    _ = scanner.nativeMetadata(for: processes, birthTokens: birthTokens, now: start)
    _ = scanner.nativeMetadata(
      for: processes,
      birthTokens: birthTokens,
      now: start.addingTimeInterval(10_000)
    )

    XCTAssertEqual(provider.requestedProcessIDs, [101])
  }

  func testExactArgumentVectorIsPreservedByPositiveMetadataCache() throws {
    let birthToken = ProcessBirthToken(seconds: 1_000, microseconds: 11)
    let native = DevProcess(
      pid: 111, parentPID: 1, executable: "node", command: "/usr/bin/node",
      argumentVector: ["/usr/bin/node", "folder name"], birthToken: birthToken,
      launchLabel: "com.example.node-worker"
    )
    let provider = FakeNativeMetadataProvider(processes: [111: native])
    let scanner = SystemProcessScanner(nativeMetadataProvider: provider)
    let processes = [psProcess(pid: 111)]

    _ = scanner.nativeMetadata(for: processes, birthTokens: [111: birthToken])
    let cached = scanner.nativeMetadata(for: processes, birthTokens: [111: birthToken])

    XCTAssertEqual(try XCTUnwrap(cached[111]).argumentVector, native.argumentVector)
    XCTAssertEqual(try XCTUnwrap(cached[111]).launchLabel, native.launchLabel)
    XCTAssertEqual(provider.requestedProcessIDs, [111])
  }

  func testBirthTokenChangeRefreshesOnlyTheRecycledPID() {
    let firstBirth = ProcessBirthToken(seconds: 1_000, microseconds: 1)
    let recycledBirth = ProcessBirthToken(seconds: 2_000, microseconds: 2)
    let stableBirth = ProcessBirthToken(seconds: 1_000, microseconds: 3)
    let provider = FakeNativeMetadataProvider(processes: [
      101: nativeProcess(pid: 101, birthToken: recycledBirth),
      102: nativeProcess(pid: 102, birthToken: stableBirth),
    ])
    let scanner = SystemProcessScanner(nativeMetadataProvider: provider)
    let processes = [psProcess(pid: 101), psProcess(pid: 102)]
    let now = Date(timeIntervalSince1970: 1_000)

    _ = scanner.nativeMetadata(
      for: processes,
      birthTokens: [101: firstBirth, 102: stableBirth],
      now: now
    )
    _ = scanner.nativeMetadata(
      for: processes,
      birthTokens: [101: recycledBirth, 102: stableBirth],
      now: now
    )

    XCTAssertEqual(provider.requestedProcessIDs, [101, 102, 101])
  }

  func testInactivePIDMetadataIsPrunedFromTheCache() {
    let firstBirth = ProcessBirthToken(seconds: 1_000, microseconds: 1)
    let secondBirth = ProcessBirthToken(seconds: 1_000, microseconds: 2)
    let provider = FakeNativeMetadataProvider(processes: [
      101: nativeProcess(pid: 101, birthToken: firstBirth),
      102: nativeProcess(pid: 102, birthToken: secondBirth),
    ])
    let scanner = SystemProcessScanner(nativeMetadataProvider: provider)

    _ = scanner.nativeMetadata(
      for: [psProcess(pid: 101), psProcess(pid: 102)],
      birthTokens: [101: firstBirth, 102: secondBirth]
    )
    _ = scanner.nativeMetadata(
      for: [psProcess(pid: 102)],
      birthTokens: [102: secondBirth]
    )
    _ = scanner.nativeMetadata(
      for: [psProcess(pid: 101), psProcess(pid: 102)],
      birthTokens: [101: firstBirth, 102: secondBirth]
    )

    XCTAssertEqual(provider.requestedProcessIDs, [101, 102, 101])
  }

  func testUnavailableNativeMetadataDoesNotRetryBeforeTTL() {
    let birthToken = ProcessBirthToken(seconds: 1_000, microseconds: 1)
    let provider = FakeNativeMetadataProvider(processes: [:])
    let scanner = SystemProcessScanner(nativeMetadataProvider: provider)
    let processes = [psProcess(pid: 101)]
    let birthTokens = [Int32(101): birthToken]
    let start = Date(timeIntervalSince1970: 1_000)

    XCTAssertTrue(
      scanner.nativeMetadata(for: processes, birthTokens: birthTokens, now: start).isEmpty
    )
    XCTAssertTrue(
      scanner.nativeMetadata(
        for: processes,
        birthTokens: birthTokens,
        now: start.addingTimeInterval(119)
      ).isEmpty
    )

    XCTAssertEqual(provider.requestedProcessIDs, [101])
  }

  func testUnavailableNativeMetadataRetriesAfterTTLAndRecovers() {
    let birthToken = ProcessBirthToken(seconds: 1_000, microseconds: 1)
    let provider = FakeNativeMetadataProvider(processes: [:])
    let scanner = SystemProcessScanner(nativeMetadataProvider: provider)
    let processes = [psProcess(pid: 101)]
    let birthTokens = [Int32(101): birthToken]
    let start = Date(timeIntervalSince1970: 1_000)

    XCTAssertTrue(
      scanner.nativeMetadata(for: processes, birthTokens: birthTokens, now: start).isEmpty
    )
    provider.setProcess(nativeProcess(pid: 101, birthToken: birthToken), for: 101)

    let recovered = scanner.nativeMetadata(
      for: processes,
      birthTokens: birthTokens,
      now: start.addingTimeInterval(120)
    )

    XCTAssertEqual(recovered[101], nativeProcess(pid: 101, birthToken: birthToken))
    XCTAssertEqual(provider.requestedProcessIDs, [101, 101])
  }

  func testExpiredNativeMetadataMissesRetryWithinBudgetAndProgressAcrossScans() {
    let processIDs = (101...110).map(Int32.init)
    let processes = processIDs.map { psProcess(pid: $0) }
    let birthTokens = Dictionary(
      uniqueKeysWithValues: processIDs.map { processID in
        (processID, ProcessBirthToken(seconds: 1_000, microseconds: UInt64(processID)))
      }
    )
    let provider = FakeNativeMetadataProvider(processes: [:])
    let scanner = SystemProcessScanner(nativeMetadataProvider: provider)
    let start = Date(timeIntervalSince1970: 1_000)

    _ = scanner.nativeMetadata(for: processes, birthTokens: birthTokens, now: start)
    _ = scanner.nativeMetadata(
      for: processes,
      birthTokens: birthTokens,
      now: start.addingTimeInterval(120)
    )

    XCTAssertEqual(
      provider.requestedProcessIDs,
      processIDs + Array(processIDs.prefix(8))
    )

    _ = scanner.nativeMetadata(
      for: processes,
      birthTokens: birthTokens,
      now: start.addingTimeInterval(240)
    )

    XCTAssertEqual(provider.requestedProcessIDs.count, processIDs.count + 16)
    XCTAssertEqual(
      Set(provider.requestedProcessIDs.suffix(8)),
      Set(processIDs.suffix(2) + processIDs.prefix(6))
    )
  }

  func testGenericPSExecutableIsEnrichedByDirectPIDMetadata() throws {
    let birthToken = ProcessBirthToken(seconds: 1_000, microseconds: 1)
    let native = DevProcess(
      pid: 101,
      parentPID: 1,
      executable: "UserEventAgent",
      command: "/usr/libexec/UserEventAgent",
      birthToken: birthToken
    )
    let provider = FakeNativeMetadataProvider(processes: [101: native])
    let scanner = SystemProcessScanner(nativeMetadataProvider: provider)
    let process = psProcess(pid: 101, executable: "Use", command: "Use")

    let metadata = scanner.nativeMetadata(
      for: [process],
      birthTokens: [101: birthToken]
    )
    let merged = ProcessScanner.mergedProcess(
      psProcess: process,
      nativeProcess: try XCTUnwrap(metadata[101]),
      currentDirectory: nil,
      birthToken: birthToken
    )

    XCTAssertEqual(merged.executable, "/usr/libexec/UserEventAgent")
    XCTAssertEqual(provider.requestedProcessIDs, [101])
  }

  func testParsesLsofCurrentDirectoryOutput() {
    let output = """
      p12175
      czsh
      fcwd
      n/Users/example/dev/sample-app
      p12176
      cnode
      fcwd
      n/Users/example/dev/sample-service
      """

    let directories = ProcessScanner.parseLsofCurrentDirectories(output)

    XCTAssertEqual(directories[12175], "/Users/example/dev/sample-app")
    XCTAssertEqual(directories[12176], "/Users/example/dev/sample-service")
  }

  func testMergesNativeExecutablePathWhenPSExecutableIsTruncated() {
    let birthToken = ProcessBirthToken(seconds: 1_000, microseconds: 321)
    let psProcess = DevProcess(
      pid: 101,
      parentPID: 1,
      executable: "Use",
      command: "Use",
      resourceUsage: DevProcessResourceUsage(cpuPercent: 1.5, residentMemoryBytes: 42, elapsedTime: "01:02")
    )
    let nativeProcess = DevProcess(
      pid: 101,
      parentPID: 1,
      executable: "UserEventAgent",
      command: "/usr/libexec/UserEventAgent",
      birthToken: birthToken
    )

    let merged = ProcessScanner.mergedProcess(
      psProcess: psProcess,
      nativeProcess: nativeProcess,
      currentDirectory: "/",
      birthToken: birthToken
    )

    XCTAssertEqual(merged.executable, "/usr/libexec/UserEventAgent")
    XCTAssertEqual(merged.command, "/usr/libexec/UserEventAgent")
    XCTAssertEqual(merged.currentDirectory, "/")
    XCTAssertEqual(merged.resourceUsage, psProcess.resourceUsage)
    XCTAssertEqual(merged.birthToken, birthToken)
  }

  func testMergedProcessUsesFreshBirthTokenInsteadOfCachedNativeBirthToken() {
    let cachedBirthToken = ProcessBirthToken(seconds: 1_000, microseconds: 1)
    let freshBirthToken = ProcessBirthToken(seconds: 2_000, microseconds: 2)
    let psProcess = DevProcess(pid: 104, parentPID: 1, executable: "Use", command: "Use")
    let cachedNativeProcess = DevProcess(
      pid: 104,
      parentPID: 1,
      executable: "UserEventAgent",
      command: "/usr/libexec/UserEventAgent",
      birthToken: cachedBirthToken
    )

    let merged = ProcessScanner.mergedProcess(
      psProcess: psProcess,
      nativeProcess: cachedNativeProcess,
      currentDirectory: nil,
      birthToken: freshBirthToken
    )

    XCTAssertEqual(merged.birthToken, freshBirthToken)
    XCTAssertEqual(merged.executable, "Use")
  }

  func testCarriesCurrentDirectoryOnlyWhenKnownBirthTokensMatch() {
    let birthToken = ProcessBirthToken(seconds: 1_000, microseconds: 10)
    let previous = DevProcess(
      pid: 105,
      parentPID: 1,
      executable: "node",
      command: "node vite",
      currentDirectory: "/Users/example/dev/sample-app",
      birthToken: birthToken
    )
    let sameProcess = DevProcess(
      pid: 105,
      parentPID: 1,
      executable: "node",
      command: "node vite",
      birthToken: birthToken
    )
    let recycledProcess = DevProcess(
      pid: 105,
      parentPID: 1,
      executable: "node",
      command: "node vite",
      birthToken: ProcessBirthToken(seconds: 2_000, microseconds: 20)
    )
    let unknownProcess = DevProcess(pid: 105, parentPID: 1, executable: "node", command: "node vite")

    XCTAssertEqual(
      ProcessScanner.carriedCurrentDirectory(from: previous, to: sameProcess),
      "/Users/example/dev/sample-app"
    )
    XCTAssertNil(ProcessScanner.carriedCurrentDirectory(from: previous, to: recycledProcess))
    XCTAssertNil(ProcessScanner.carriedCurrentDirectory(from: previous, to: unknownProcess))
  }

  func testKeepsPSCommandArgumentsWhenMergingNativeExecutablePath() {
    let birthToken = ProcessBirthToken(seconds: 1_000, microseconds: 654)
    let psProcess = DevProcess(
      pid: 102,
      parentPID: 1,
      executable: "python",
      command: "python worker.py --queue jobs",
      resourceUsage: DevProcessResourceUsage(cpuPercent: 2.5, residentMemoryBytes: 84, elapsedTime: "03:04")
    )
    let nativeProcess = DevProcess(
      pid: 102,
      parentPID: 1,
      executable: "python3.12",
      command: "/opt/homebrew/bin/python3.12",
      birthToken: birthToken
    )

    let merged = ProcessScanner.mergedProcess(
      psProcess: psProcess,
      nativeProcess: nativeProcess,
      currentDirectory: "/Users/example/dev/sample-api",
      birthToken: birthToken
    )

    XCTAssertEqual(merged.executable, "/opt/homebrew/bin/python3.12")
    XCTAssertEqual(merged.command, "python worker.py --queue jobs")
    XCTAssertEqual(merged.currentDirectory, "/Users/example/dev/sample-api")
    XCTAssertEqual(merged.resourceUsage, psProcess.resourceUsage)
  }

  func testMergedProcessPreservesExactNativeBundleIdentityWithoutReplacingExecutable() {
    let birthToken = ProcessBirthToken(seconds: 1_000, microseconds: 700)
    let psProcess = DevProcess(
      pid: 107,
      parentPID: 1,
      executable: "/Applications/Exact.app/Contents/MacOS/Exact",
      command: "/Applications/Exact.app/Contents/MacOS/Exact --foreground"
    )
    let nativeProcess = DevProcess(
      pid: 107,
      parentPID: 1,
      executable: "Exact",
      command: "/Applications/Exact.app/Contents/MacOS/Exact",
      argumentVector: ["/Applications/Exact.app/Contents/MacOS/Exact", "--foreground"],
      birthToken: birthToken,
      bundleIdentifier: "com.example.exact",
      launchLabel: "com.example.exact.helper"
    )

    let merged = ProcessScanner.mergedProcess(
      psProcess: psProcess,
      nativeProcess: nativeProcess,
      currentDirectory: nil,
      birthToken: birthToken
    )

    XCTAssertEqual(merged.executable, psProcess.executable)
    XCTAssertEqual(merged.bundleIdentifier, "com.example.exact")
    XCTAssertEqual(merged.argumentVector, nativeProcess.argumentVector)
    XCTAssertEqual(merged.launchLabel, nativeProcess.launchLabel)
  }

  func testKernelArgumentBufferParsesExactArgumentsAndRejectsMalformedInput() {
    var argc = Int32(3)
    var bytes = withUnsafeBytes(of: &argc) { Array($0) }
    bytes += Array("/opt/jobs/exact".utf8) + [0, 0, 0]
    bytes += Array("/opt/jobs/exact".utf8) + [0]
    bytes += Array("folder name".utf8) + [0]
    bytes += [0]

    XCTAssertEqual(
      KernelProcessArgumentVectorProvider.parse(buffer: bytes),
      ["/opt/jobs/exact", "folder name", ""]
    )
    XCTAssertNil(KernelProcessArgumentVectorProvider.parse(buffer: Array(bytes.dropLast())))
    XCTAssertNil(KernelProcessArgumentVectorProvider.parse(buffer: [0, 0, 0]))
  }

  func testKernelArgumentBufferRejectsShiftedEmptyArgvZeroThatConsumesEnvironment() {
    var argc = Int32(2)
    var bytes = withUnsafeBytes(of: &argc) { Array($0) }
    bytes += Array("/opt/jobs/exact".utf8) + [0, 0, 0]
    bytes += [0] // Empty argv0 is indistinguishable from KERN_PROCARGS2 padding.
    bytes += Array("/opt/jobs/exact".utf8) + [0]
    bytes += Array("DEVSCOPE_TOKEN=private".utf8) + [0]
    bytes += Array("PATH=/usr/bin".utf8) + [0]

    XCTAssertNil(KernelProcessArgumentVectorProvider.parse(buffer: bytes))
  }

  func testKernelArgumentBufferRejectsFinalEnvironmentAssignmentAfterShiftedEmptyArgvZero() {
    var argc = Int32(2)
    var bytes = withUnsafeBytes(of: &argc) { Array($0) }
    bytes += Array("/opt/jobs/exact".utf8) + [0]
    bytes += [0] // Empty argv0 is indistinguishable from KERN_PROCARGS2 padding.
    bytes += Array("/opt/jobs/exact".utf8) + [0]
    bytes += Array("DEVSCOPE_TOKEN=private".utf8) + [0]

    XCTAssertNil(KernelProcessArgumentVectorProvider.parse(buffer: bytes))
  }

  func testKernelArgumentBufferAcceptsEqualsArgumentsOutsideExactEnvironmentNameGrammar() {
    var argc = Int32(2)
    var bytes = withUnsafeBytes(of: &argc) { Array($0) }
    bytes += Array("/opt/jobs/exact".utf8) + [0, 0]
    bytes += Array("/opt/jobs/exact".utf8) + [0]
    bytes += Array("--mode=value".utf8) + [0]

    XCTAssertEqual(
      KernelProcessArgumentVectorProvider.parse(buffer: bytes),
      ["/opt/jobs/exact", "--mode=value"]
    )
  }

  func testKernelArgumentBufferSupportedSubsetRejectsInvalidPrefixesCountsAndBounds() {
    func header(_ count: Int32) -> [UInt8] {
      var count = count
      return withUnsafeBytes(of: &count) { Array($0) }
    }

    XCTAssertNil(KernelProcessArgumentVectorProvider.parse(
      buffer: header(1) + [0, 0] + Array("/bin/tool".utf8) + [0]
    ))
    XCTAssertNil(KernelProcessArgumentVectorProvider.parse(
      buffer: header(1) + [0xFF, 0, 0] + Array("/bin/tool".utf8) + [0]
    ))
    XCTAssertNil(KernelProcessArgumentVectorProvider.parse(
      buffer: header(1) + Array("relative-tool".utf8) + [0, 0] + Array("relative-tool".utf8) + [0]
    ))
    XCTAssertNil(KernelProcessArgumentVectorProvider.parse(
      buffer: header(0) + Array("/bin/tool".utf8) + [0, 0]
    ))
    XCTAssertNil(KernelProcessArgumentVectorProvider.parse(
      buffer: header(4_097) + Array("/bin/tool".utf8) + [0, 0]
    ))
    XCTAssertNil(KernelProcessArgumentVectorProvider.parse(
      buffer: header(1) + Array("/bin/tool".utf8) + [0, 0, 0xFF, 0]
    ))
    XCTAssertNil(KernelProcessArgumentVectorProvider.parse(
      buffer: header(1) + Array("/bin/tool".utf8) + [0, 0] + Array("/bin/tool".utf8)
    ))
    XCTAssertNil(KernelProcessArgumentVectorProvider.parse(
      buffer: [UInt8](repeating: 0, count: 1_048_577)
    ))
  }

  func testNativeScannerFailsClosedWhenInjectedArgumentProviderFails() {
    let scanner = NativeProcessScanner(
      bundleIdentityProvider: FakeBundleIdentityProvider(identifiers: [:]),
      argumentVectorProvider: FakeArgumentVectorProvider(vectors: [:])
    )

    XCTAssertNil(scanner.argumentVector(for: getpid()))
  }

  func testNativeMetadataDropsCollectedArgumentsAndBundleWhenFinalBirthChanges() throws {
    let processID = getpid()
    let calls = OrderedProcessEvidenceCallRecorder()
    let initialBirth = try XCTUnwrap(NativeProcessScanner().birthToken(for: processID))
    let recycledBirth = ProcessBirthToken(
      seconds: initialBirth.seconds + 1,
      microseconds: initialBirth.microseconds
    )
    let bundleProvider = ConstantBundleIdentityProvider(
      identifier: "com.example.raced", recorder: calls
    )
    let argumentProvider = RecordingArgumentVectorProvider(
      vectors: [processID: ["/opt/jobs/exact", "--mode=value"]], recorder: calls
    )
    let scanner = NativeProcessScanner(
      bundleIdentityProvider: bundleProvider,
      argumentVectorProvider: argumentProvider,
      finalBirthTokenProvider: FakeFinalBirthTokenProvider(token: recycledBirth, recorder: calls)
    )

    XCTAssertNil(scanner.metadata(for: processID))
    XCTAssertEqual(argumentProvider.requestedProcessIDs, [processID])
    XCTAssertFalse(bundleProvider.requestedPaths.isEmpty, "Bundle metadata must precede final birth")
    XCTAssertEqual(calls.evidenceKinds(for: processID), [
      .argumentVector, .bundleIdentity, .finalBirth,
    ])
    XCTAssertEqual(calls.count(.finalBirth, for: processID), 1)
  }

  func testNativeMetadataKeepsStableBirthAfterCollectedEvidence() throws {
    let processID = getpid()
    let calls = OrderedProcessEvidenceCallRecorder()
    let birthToken = try XCTUnwrap(NativeProcessScanner().birthToken(for: processID))
    let argumentVector = ["/opt/jobs/exact", "--mode=value"]
    let scanner = NativeProcessScanner(
      bundleIdentityProvider: ConstantBundleIdentityProvider(
        identifier: "com.example.stable", recorder: calls
      ),
      argumentVectorProvider: FakeArgumentVectorProvider(
        vectors: [processID: argumentVector], recorder: calls
      ),
      finalBirthTokenProvider: FakeFinalBirthTokenProvider(token: birthToken, recorder: calls)
    )

    let metadata = try XCTUnwrap(scanner.metadata(for: processID))
    XCTAssertEqual(metadata.birthToken, birthToken)
    XCTAssertEqual(metadata.argumentVector, argumentVector)
    XCTAssertEqual(metadata.bundleIdentifier, "com.example.stable")
    XCTAssertEqual(calls.evidenceKinds(for: processID), [
      .argumentVector, .bundleIdentity, .finalBirth,
    ])
  }

  func testNativeSnapshotFinalBirthForCurrentProcessFollowsCollectedEvidence() throws {
    let processID = getpid()
    let baseline = try XCTUnwrap(NativeProcessScanner().metadata(for: processID))
    let birthToken = try XCTUnwrap(baseline.birthToken)
    let calls = OrderedProcessEvidenceCallRecorder()
    let argumentVector = ["/opt/jobs/exact", "--mode=value"]
    let scanner = NativeProcessScanner(
      bundleIdentityProvider: ConstantBundleIdentityProvider(
        identifier: "com.example.snapshot", recorder: calls
      ),
      argumentVectorProvider: FakeArgumentVectorProvider(
        vectors: [processID: argumentVector], recorder: calls
      ),
      finalBirthTokenProvider: FakeFinalBirthTokenProvider(token: birthToken, recorder: calls)
    )

    let snapshotProcess = try XCTUnwrap(scanner.snapshot().first { $0.pid == processID })

    XCTAssertEqual(snapshotProcess.birthToken, birthToken)
    XCTAssertEqual(snapshotProcess.argumentVector, argumentVector)
    XCTAssertEqual(snapshotProcess.bundleIdentifier, "com.example.snapshot")
    XCTAssertEqual(calls.evidenceKinds(for: processID), [
      .argumentVector, .bundleIdentity, .finalBirth,
    ])
  }

  func testNativeMetadataDropsRowWhenFinalBirthReadIsUnavailable() {
    let processID = getpid()
    let scanner = NativeProcessScanner(
      bundleIdentityProvider: ConstantBundleIdentityProvider(identifier: "com.example.unavailable"),
      argumentVectorProvider: FakeArgumentVectorProvider(
        vectors: [processID: ["/opt/jobs/exact", "--mode=value"]]
      ),
      finalBirthTokenProvider: FakeFinalBirthTokenProvider(token: nil)
    )

    XCTAssertNil(scanner.metadata(for: processID))
  }

  func testDoesNotDowngradeFullPSExecutableToNativeBasename() {
    let psProcess = DevProcess(
      pid: 103,
      parentPID: 1,
      executable: "/usr/libexec/configd",
      command: "/usr/libexec/configd",
      resourceUsage: DevProcessResourceUsage(cpuPercent: 0.2, residentMemoryBytes: 128, elapsedTime: "03:04")
    )
    let nativeProcess = DevProcess(
      pid: 103,
      parentPID: 1,
      executable: "configd",
      command: "configd"
    )

    let merged = ProcessScanner.mergedProcess(
      psProcess: psProcess,
      nativeProcess: nativeProcess,
      currentDirectory: nil,
      birthToken: nil
    )

    XCTAssertEqual(merged.executable, "/usr/libexec/configd")
    XCTAssertEqual(merged.command, "/usr/libexec/configd")
    XCTAssertEqual(merged.resourceUsage, psProcess.resourceUsage)
  }

  func testExcludesOnlyTheExplicitScannerHelperPID() {
    let scannerHelper = DevProcess(
      pid: 201,
      parentPID: 200,
      executable: "/bin/ps",
      command: "/bin/ps -axo pid=,ppid=,%cpu=,rss=,etime=,comm=,args="
    )
    let unrelatedPSProcess = DevProcess(
      pid: 202,
      parentPID: 1,
      executable: "/bin/ps",
      command: "/bin/ps aux"
    )
    let unrelatedProcess = DevProcess(
      pid: 203,
      parentPID: 1,
      executable: "/usr/bin/swift",
      command: "swift test"
    )

    let filtered = ProcessScanner.excludingScannerHelper(
      from: [scannerHelper, unrelatedPSProcess, unrelatedProcess],
      helperPID: scannerHelper.pid
    )

    XCTAssertEqual(filtered.map(\.pid), [unrelatedPSProcess.pid, unrelatedProcess.pid])
  }

  func testSnapshotCompletesAndIncludesTheCurrentTestProcess() throws {
    let scanner = SystemProcessScanner()

    let processes = try scanner.snapshot()

    XCTAssertFalse(processes.isEmpty)
    XCTAssertTrue(
      processes.contains { $0.pid == getpid() },
      "Expected snapshot to include the current XCTest process"
    )
  }

  func testNativeSnapshotCompletesAndIncludesTheCurrentProcess() throws {
    let scanner = NativeProcessScanner()

    let processes = try scanner.snapshot()
    let currentProcess = try XCTUnwrap(processes.first { $0.pid == getpid() })

    XCTAssertFalse(processes.isEmpty)
    XCTAssertNotNil(currentProcess.birthToken)
    XCTAssertNotNil(currentProcess.argumentVector)
    XCTAssertNil(currentProcess.launchLabel, "Native scanning must not infer a launch label")
  }

  private func psProcess(
    pid: Int32,
    executable: String = "/usr/bin/node",
    command: String = "/usr/bin/node worker.js"
  ) -> DevProcess {
    DevProcess(pid: pid, parentPID: 1, executable: executable, command: command)
  }

  private func nativeProcess(pid: Int32, birthToken: ProcessBirthToken) -> DevProcess {
    DevProcess(
      pid: pid,
      parentPID: 1,
      executable: "node",
      command: "/usr/bin/node",
      birthToken: birthToken
    )
  }

  private func makeBundle(at url: URL, executable: String, identifier: String) throws -> URL {
    let executableURL = url.appendingPathComponent("Contents/MacOS/\(executable)")
    try FileManager.default.createDirectory(
      at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    XCTAssertTrue(FileManager.default.createFile(atPath: executableURL.path, contents: Data()))
    let plist: [String: Any] = [
      "CFBundleExecutable": executable,
      "CFBundleIdentifier": identifier,
      "CFBundlePackageType": "APPL",
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: plist, format: .xml, options: 0
    )
    try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
    return executableURL
  }
}

private enum ProcessEvidenceKind: Equatable, Sendable {
  case argumentVector
  case bundleIdentity
  case finalBirth
}

private struct ProcessEvidenceCall: Equatable, Sendable {
  let kind: ProcessEvidenceKind
  let processID: Int32?
}

private final class OrderedProcessEvidenceCallRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedCalls: [ProcessEvidenceCall] = []

  func record(_ kind: ProcessEvidenceKind, processID: Int32?) {
    lock.withLock {
      recordedCalls.append(ProcessEvidenceCall(kind: kind, processID: processID))
    }
  }

  func evidenceKinds(for processID: Int32) -> [ProcessEvidenceKind] {
    lock.withLock {
      recordedCalls.filter { $0.processID == processID }.map(\.kind)
    }
  }

  func count(_ kind: ProcessEvidenceKind, for processID: Int32) -> Int {
    lock.withLock {
      recordedCalls.count { $0.processID == processID && $0.kind == kind }
    }
  }

  func processIDs(for kind: ProcessEvidenceKind) -> [Int32?] {
    lock.withLock {
      recordedCalls.filter { $0.kind == kind }.map(\.processID)
    }
  }
}

private final class FakeNativeMetadataProvider: @unchecked Sendable, NativeProcessMetadataProviding {
  private let lock = NSLock()
  private var processes: [Int32: DevProcess]
  private var requestedIDs: [Int32] = []

  init(processes: [Int32: DevProcess]) {
    self.processes = processes
  }

  var requestedProcessIDs: [Int32] {
    lock.withLock { requestedIDs }
  }

  func setProcess(_ process: DevProcess, for processID: Int32) {
    lock.withLock {
      processes[processID] = process
    }
  }

  func metadata(for processID: Int32) -> DevProcess? {
    lock.withLock {
      requestedIDs.append(processID)
      return processes[processID]
    }
  }
}

private final class FakeBundleIdentityProvider: @unchecked Sendable, ProcessBundleIdentityProviding {
  private let lock = NSLock()
  private let identifiers: [String: String]
  private var paths: [String] = []

  init(identifiers: [String: String]) {
    self.identifiers = identifiers
  }

  var requestedPaths: [String] {
    lock.withLock { paths }
  }

  func bundleIdentifier(forExecutableURL executableURL: URL, processID _: Int32) -> String? {
    lock.withLock {
      paths.append(executableURL.path)
      return identifiers[executableURL.path]
    }
  }
}

private struct FakeArgumentVectorProvider: ProcessArgumentVectorProviding {
  let vectors: [Int32: [String]]
  let recorder: OrderedProcessEvidenceCallRecorder?

  init(
    vectors: [Int32: [String]],
    recorder: OrderedProcessEvidenceCallRecorder? = nil
  ) {
    self.vectors = vectors
    self.recorder = recorder
  }

  func argumentVector(for processID: Int32) -> [String]? {
    recorder?.record(.argumentVector, processID: processID)
    return vectors[processID]
  }
}

private final class RecordingArgumentVectorProvider: @unchecked Sendable, ProcessArgumentVectorProviding {
  private let lock = NSLock()
  private let vectors: [Int32: [String]]
  private let recorder: OrderedProcessEvidenceCallRecorder?
  private var requestedIDs: [Int32] = []

  init(
    vectors: [Int32: [String]],
    recorder: OrderedProcessEvidenceCallRecorder? = nil
  ) {
    self.vectors = vectors
    self.recorder = recorder
  }

  var requestedProcessIDs: [Int32] {
    lock.withLock { requestedIDs }
  }

  func argumentVector(for processID: Int32) -> [String]? {
    recorder?.record(.argumentVector, processID: processID)
    return lock.withLock {
      requestedIDs.append(processID)
      return vectors[processID]
    }
  }
}

private struct FakeFinalBirthTokenProvider: ProcessBirthTokenProviding {
  let token: ProcessBirthToken?
  let recorder: OrderedProcessEvidenceCallRecorder?

  init(
    token: ProcessBirthToken?,
    recorder: OrderedProcessEvidenceCallRecorder? = nil
  ) {
    self.token = token
    self.recorder = recorder
  }

  func birthToken(for processID: Int32) -> ProcessBirthToken? {
    recorder?.record(.finalBirth, processID: processID)
    return token
  }
}

private final class ConstantBundleIdentityProvider: @unchecked Sendable, ProcessBundleIdentityProviding {
  private let lock = NSLock()
  private let identifier: String
  private let recorder: OrderedProcessEvidenceCallRecorder?
  private var paths: [String] = []

  init(
    identifier: String,
    recorder: OrderedProcessEvidenceCallRecorder? = nil
  ) {
    self.identifier = identifier
    self.recorder = recorder
  }

  var requestedPaths: [String] {
    lock.withLock { paths }
  }

  func bundleIdentifier(forExecutableURL executableURL: URL, processID: Int32) -> String? {
    recorder?.record(.bundleIdentity, processID: processID)
    return lock.withLock {
      paths.append(executableURL.path)
      return identifier
    }
  }
}
