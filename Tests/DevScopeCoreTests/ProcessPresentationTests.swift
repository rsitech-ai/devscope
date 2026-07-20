import XCTest

@testable import DevScopeCore

final class ProcessPresentationTests: XCTestCase {
  func testFiltersByRuntimeAndSearchableFields() {
    let items = sampleProcesses

    let filtered = ProcessPresentation.filtered(
      items,
      categoryID: DevRuntimeKind.javascript.id,
      searchText: "web 3010"
    )

    XCTAssertEqual(filtered.map(\.process.pid), [101])
  }

  func testFiltersSavedCategoriesByStableIdentityKey() {
    let items = sampleProcesses
    let favoriteKey = ProcessPresentation.identityKey(for: items[1])
    let watchedKey = ProcessPresentation.identityKey(for: items[2])

    XCTAssertEqual(
      ProcessPresentation.filtered(
        items,
        categoryID: ProcessPresentation.favoritesCategoryID,
        searchText: "",
        favoriteKeys: [favoriteKey]
      ).map(\.process.pid),
      [102]
    )
    XCTAssertEqual(
      ProcessPresentation.filtered(
        items,
        categoryID: ProcessPresentation.watchedCategoryID,
        searchText: "",
        watchedKeys: [watchedKey]
      ).map(\.process.pid),
      [201]
    )
  }

  func testEmptySavedKeysSkipIdentityHashing() {
    var identityLookupCount = 0

    let isSaved = ProcessPresentation.isSaved(
      sampleProcesses[0],
      in: [],
      identityKeys: { _ in
        identityLookupCount += 1
        return ["should-not-be-computed"]
      }
    )

    XCTAssertFalse(isSaved)
    XCTAssertEqual(identityLookupCount, 0)
  }

  func testSavedCategorySurvivesWorkingDirectoryEnrichment() {
    let initial = ClassifiedDevProcess(
      process: DevProcess(
        pid: 51963,
        parentPID: 1,
        executable: "/bin/sleep",
        command: "/bin/sleep 317",
        currentDirectory: nil
      ),
      classification: DevProcessClassification(
        kind: .other,
        displayName: "sleep",
        projectHint: nil,
        tags: []
      )
    )
    let enriched = ClassifiedDevProcess(
      process: DevProcess(
        pid: 51963,
        parentPID: 1,
        executable: "/bin/sleep",
        command: "/bin/sleep 317",
        currentDirectory: "/Users/example/dev/sample-app"
      ),
      classification: DevProcessClassification(
        kind: .other,
        displayName: "sleep",
        projectHint: "devscope",
        tags: []
      )
    )
    let savedKey = ProcessPresentation.identityKey(for: initial)

    let filtered = ProcessPresentation.filtered(
      [enriched],
      categoryID: ProcessPresentation.favoritesCategoryID,
      searchText: "",
      favoriteKeys: [savedKey]
    )

    XCTAssertEqual(filtered.map(\.process.pid), [51963])
  }

  func testSavedIdentityKeyDoesNotContainCommandOrWorkingDirectory() {
    let item = ClassifiedDevProcess(
      process: DevProcess(
        pid: 98,
        parentPID: 1,
        executable: "/usr/local/bin/worker",
        command: "worker --api-key sk-private-value",
        currentDirectory: "/Users/example/Secret Project"
      ),
      classification: DevProcessClassification(
        kind: .other,
        displayName: "worker",
        projectHint: "Secret Project",
        tags: []
      )
    )

    let key = ProcessPresentation.identityKey(for: item)

    XCTAssertTrue(key.hasPrefix("v2:"))
    XCTAssertFalse(key.contains("sk-private-value"))
    XCTAssertFalse(key.contains("Secret Project"))
    XCTAssertFalse(key.contains("/Users/example"))
  }

  func testSanitizedSavedIdentityKeysMigrateLegacyValuesWithoutRetainingRawData() {
    let safeKey = "v2:" + String(repeating: "a", count: 64)
    let legacyKey =
      "worker\u{1F}/Users/example/Secret Project\u{1F}worker --api-key sk-private-value"
    let keys = ProcessPresentation.sanitizedSavedIdentityKeys([
      safeKey,
      legacyKey,
      "v2:not-a-digest",
      "malformed legacy value",
    ])

    XCTAssertEqual(keys.count, 2)
    XCTAssertTrue(keys.contains(safeKey))
    XCTAssertTrue(keys.allSatisfy { $0.hasPrefix("v2:") })
    XCTAssertFalse(keys.joined().contains("sk-private-value"))
  }

  func testRedactsSensitiveCommandValuesForExport() {
    let command = """
      uvicorn app:app token=abc123 Authorization bearer secret-token password=hunter2 --api-key sk-test --client-secret client-value postgres://user:dbpass@localhost/db
      """

    let redacted = ProcessPresentation.redactedCommand(command)

    XCTAssertFalse(redacted.contains("abc123"))
    XCTAssertFalse(redacted.contains("secret-token"))
    XCTAssertFalse(redacted.contains("hunter2"))
    XCTAssertFalse(redacted.contains("sk-test"))
    XCTAssertFalse(redacted.contains("client-value"))
    XCTAssertFalse(redacted.contains("dbpass"))
    XCTAssertTrue(redacted.contains("token=<redacted>"))
    XCTAssertTrue(redacted.contains("bearer <redacted>"))
    XCTAssertTrue(redacted.contains("password=<redacted>"))
    XCTAssertTrue(redacted.contains("--api-key <redacted>"))
    XCTAssertTrue(redacted.contains("--client-secret <redacted>"))
    XCTAssertTrue(redacted.contains("postgres://<redacted>@localhost/db"))
  }

  func testRedactsCommonShortCredentialFlags() {
    let command =
      "redis-cli -a hunter2; mysql -pdbsecret; curl -u user:curlsecret https://example.test"

    let redacted = ProcessPresentation.redactedCommand(command)

    XCTAssertFalse(redacted.contains("hunter2"))
    XCTAssertFalse(redacted.contains("dbsecret"))
    XCTAssertFalse(redacted.contains("curlsecret"))
  }

  func testRedactsQuotedShortCredentialFlagValuesContainingSpaces() {
    let command =
      "redis-cli -a 'hunter 2'; mysql -p\"db secret\"; curl -u 'user:curl secret' https://example.test"

    let redacted = ProcessPresentation.redactedCommand(command)

    XCTAssertFalse(redacted.contains("hunter"))
    XCTAssertFalse(redacted.contains("db secret"))
    XCTAssertFalse(redacted.contains("curl secret"))
    XCTAssertFalse(redacted.contains("2'"))
  }

  func testRedactsReconstructedPSCredentialValuesThroughCommandBoundary() {
    let commands = [
      "redis-cli -a hunter --tls-shaped secret;stillsecret",
      "mysql -pdb --host-shaped secret;stillsecret",
      "curl -u user:curl --header-shaped secret;stillsecret",
    ]

    for command in commands {
      let redacted = ProcessPresentation.redactedCommand(command)

      XCTAssertFalse(redacted.contains("hunter"))
      XCTAssertFalse(redacted.contains("--tls-shaped"))
      XCTAssertFalse(redacted.contains("--host-shaped"))
      XCTAssertFalse(redacted.contains("--header-shaped"))
      XCTAssertFalse(redacted.contains("stillsecret"))
      XCTAssertEqual(redacted.components(separatedBy: "<redacted>").count - 1, 1)
    }
  }

  func testRedactsCurlLongCredentialOptionsThroughEndOfRow() {
    let commands = [
      "curl --user analyst:SYNTH_USER_SECRET --next-shaped value",
      "curl --user=analyst:SYNTH_USER_EQUALS_SECRET;stillsecret",
      "curl --proxy-user relay:SYNTH_PROXY_SECRET --proxy-shaped value",
      "curl --proxy-user=relay:SYNTH_PROXY_EQUALS_SECRET;stillsecret",
    ]

    for command in commands {
      let redacted = ProcessPresentation.redactedCommand(command)

      XCTAssertFalse(redacted.contains("SYNTH_"))
      XCTAssertFalse(redacted.contains("stillsecret"))
      XCTAssertFalse(redacted.contains("--next-shaped"))
      XCTAssertFalse(redacted.contains("--proxy-shaped"))
      XCTAssertEqual(redacted.components(separatedBy: "<redacted>").count - 1, 1)
    }
  }

  func testRedactsColonDelimitedCredentialHeaders() {
    let cases = [
      (
        command: "curl -H 'X-API-Key: SYNTH_API_KEY' https://example.test/resource",
        secret: "SYNTH_API_KEY",
        expected: "X-API-Key: <redacted>"
      ),
      (
        command:
          "curl --header \"Authorization: Basic SYNTH_BASIC_TOKEN\" https://example.test/resource",
        secret: "SYNTH_BASIC_TOKEN",
        expected: "Authorization: Basic <redacted>"
      ),
      (
        command: "curl -H 'x-auth-token : SYNTH_AUTH_TOKEN' https://example.test/resource",
        secret: "SYNTH_AUTH_TOKEN",
        expected: "x-auth-token : <redacted>"
      ),
    ]

    for testCase in cases {
      let redacted = ProcessPresentation.redactedCommand(testCase.command)

      XCTAssertFalse(redacted.contains(testCase.secret), testCase.command)
      XCTAssertTrue(redacted.contains(testCase.expected), redacted)
      XCTAssertTrue(redacted.contains("https://example.test/resource"), redacted)
    }

    let nonSensitive = "curl -H 'Accept: application/json' https://example.test/resource"
    XCTAssertEqual(ProcessPresentation.redactedCommand(nonSensitive), nonSensitive)
  }

  func testRedactsCredentialHeaderAliasesInsteadOfOnlyAFixedHeaderList() {
    let command = """
      curl -H 'PRIVATE-TOKEN: SYNTH_GITLAB_SECRET' -H 'X-Goog-Api-Key: SYNTH_GOOGLE_SECRET' -H 'X-Amz-Security-Token: SYNTH_AWS_SECRET' https://example.test
      """

    let redacted = ProcessPresentation.redactedCommand(command)

    XCTAssertFalse(redacted.contains("SYNTH_GITLAB_SECRET"))
    XCTAssertFalse(redacted.contains("SYNTH_GOOGLE_SECRET"))
    XCTAssertFalse(redacted.contains("SYNTH_AWS_SECRET"))
    XCTAssertTrue(redacted.contains("PRIVATE-TOKEN: <redacted>"))
    XCTAssertTrue(redacted.contains("X-Goog-Api-Key: <redacted>"))
    XCTAssertTrue(redacted.contains("X-Amz-Security-Token: <redacted>"))
  }

  func testRedactsCompleteSensitiveHeaderValuesAcrossAuthenticationSchemesAndCookies() {
    let cases = [
      (
        command:
          "curl -H 'Authorization: Digest username=alice, response=SYNTH_DIGEST_SECRET' https://example.test/digest",
        secrets: ["alice", "SYNTH_DIGEST_SECRET"],
        retainedURL: "https://example.test/digest"
      ),
      (
        command:
          "curl --header \"Authorization: AWS4-HMAC-SHA256 Credential=fixture, Signature=SYNTH_AWS_SIGNATURE\" https://example.test/aws",
        secrets: ["fixture", "SYNTH_AWS_SIGNATURE"],
        retainedURL: "https://example.test/aws"
      ),
      (
        command:
          "curl -H 'Proxy-Authorization: Negotiate SYNTH_PROXY_SECRET' -H 'Cookie: session=SYNTH_SESSION_COOKIE' https://example.test/cookie",
        secrets: ["SYNTH_PROXY_SECRET", "SYNTH_SESSION_COOKIE"],
        retainedURL: "https://example.test/cookie"
      ),
      (
        command:
          "curl -H 'Authorization: Digest username=\"alice\", response=\"SYNTH_QUOTED_DIGEST\"' https://example.test/quoted-digest",
        secrets: ["alice", "SYNTH_QUOTED_DIGEST"],
        retainedURL: "https://example.test/quoted-digest"
      ),
      (
        command:
          "curl -H 'Cookie: session=\"SYNTH_QUOTED_COOKIE\"; csrf=\"SYNTH_QUOTED_CSRF\"' https://example.test/quoted-cookie",
        secrets: ["SYNTH_QUOTED_COOKIE", "SYNTH_QUOTED_CSRF"],
        retainedURL: "https://example.test/quoted-cookie"
      ),
      (
        command:
          #"curl -H "Authorization: Digest username=\"alice\", response=\"SYNTH_ESCAPED_DIGEST\"" https://example.test/escaped-digest"#,
        secrets: ["alice", "SYNTH_ESCAPED_DIGEST"],
        retainedURL: "https://example.test/escaped-digest"
      ),
      (
        command:
          "curl -H X-API-Key:SYNTH_UNQUOTED_SECRET https://example.test/unquoted --verbose",
        secrets: ["SYNTH_UNQUOTED_SECRET"],
        retainedURL: "https://example.test/unquoted"
      ),
    ]

    for testCase in cases {
      let redacted = ProcessPresentation.redactedCommand(testCase.command)

      for secret in testCase.secrets {
        XCTAssertFalse(redacted.contains(secret), redacted)
      }
      XCTAssertTrue(redacted.contains(testCase.retainedURL), redacted)
      XCTAssertTrue(redacted.contains("<redacted>"), redacted)
    }
  }

  func testBulkExportRedactsColonDelimitedCredentialHeaders() {
    let item = ClassifiedDevProcess(
      process: DevProcess(
        pid: 4_202,
        parentPID: 1,
        executable: "/usr/bin/curl",
        command: "curl -H 'X-API-Key: SYNTH_EXPORT_HEADER_SECRET' https://example.test/private"
      ),
      classification: DevProcessClassification(
        kind: .other,
        displayName: "curl",
        projectHint: nil,
        tags: []
      )
    )

    let export = ProcessPresentation.exportRows([item])

    XCTAssertFalse(export.contains("SYNTH_EXPORT_HEADER_SECRET"))
    XCTAssertTrue(export.contains("X-API-Key: <redacted>"))
  }

  func testBulkExportRedactsCompleteCookieHeaderValue() {
    let item = ClassifiedDevProcess(
      process: DevProcess(
        pid: 4_203,
        parentPID: 1,
        executable: "/usr/bin/curl",
        command:
          "curl -H 'Cookie: session=\"SYNTH_EXPORT_COOKIE\"; csrf=\"SYNTH_EXPORT_CSRF\"' https://example.test/private"
      ),
      classification: DevProcessClassification(
        kind: .other,
        displayName: "curl",
        projectHint: nil,
        tags: []
      )
    )

    let export = ProcessPresentation.exportRows([item])

    XCTAssertFalse(export.contains("SYNTH_EXPORT_COOKIE"))
    XCTAssertFalse(export.contains("SYNTH_EXPORT_CSRF"))
    XCTAssertTrue(export.contains("Cookie: <redacted>"))
    XCTAssertTrue(export.contains("https://example.test/private"))
  }

  func testBulkExportRedactsCurlLongCredentialOptions() {
    let item = ClassifiedDevProcess(
      process: DevProcess(
        pid: 4_201,
        parentPID: 1,
        executable: "/usr/bin/curl",
        command: "curl --user analyst:SYNTH_EXPORT_SECRET https://example.test/private"
      ),
      classification: DevProcessClassification(
        kind: .other,
        displayName: "curl",
        projectHint: nil,
        tags: []
      )
    )

    let export = ProcessPresentation.exportRows([item])

    XCTAssertFalse(export.contains("SYNTH_EXPORT_SECRET"))
    XCTAssertTrue(export.contains("curl --user <redacted>"))
  }

  func testExportRowsNeutralizesSpreadsheetFormulasAndCellBreaks() {
    let item = ClassifiedDevProcess(
      process: DevProcess(
        pid: 1_234,
        parentPID: 1,
        executable: "/tmp/tool",
        command: "=HYPERLINK(\"https://example.test\")\tspill\nrow"
      ),
      classification: DevProcessClassification(
        kind: .other,
        displayName: "+formula",
        projectHint: "@project",
        tags: []
      )
    )

    let export = ProcessPresentation.exportRows([item])
    let rows = export.split(separator: "\n", omittingEmptySubsequences: false)

    XCTAssertEqual(rows.count, 2)
    XCTAssertTrue(export.contains("'@project"))
    XCTAssertTrue(export.contains("'+formula"))
    XCTAssertTrue(export.contains("'=HYPERLINK"))
    XCTAssertFalse(rows[1].contains("spill\trow"))
  }

  func testContextLabelSuppressesTruncatedExecutableFragments() {
    let systemItem = ClassifiedDevProcess(
      process: DevProcess(
        pid: 317,
        parentPID: 1,
        executable: "Library",
        command:
          "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/FSEvents.framework/Versions/A/Support/fseventsd"
      ),
      classification: DevProcessClassification(
        kind: .systemService,
        displayName: "fseventsd",
        projectHint: nil,
        tags: []
      )
    )
    let shortPrefixItem = ClassifiedDevProcess(
      process: DevProcess(
        pid: 319,
        parentPID: 1,
        executable: "Use",
        command: "/usr/libexec/UserEventAgent"
      ),
      classification: DevProcessClassification(
        kind: .systemService,
        displayName: "UserEventAgent",
        projectHint: nil,
        tags: []
      )
    )
    let projectItem = classified(
      pid: 101, kind: .javascript, displayName: "next dev", project: "web", command: "node next dev"
    )
    let regularItem = ClassifiedDevProcess(
      process: DevProcess(
        pid: 102, parentPID: 1, executable: "worker", command: "worker --foreground"),
      classification: DevProcessClassification(
        kind: .other, displayName: "worker", projectHint: nil, tags: [])
    )

    XCTAssertEqual(ProcessPresentation.contextLabel(for: systemItem), "System Service")
    XCTAssertEqual(ProcessPresentation.contextLabel(for: shortPrefixItem), "System Service")
    XCTAssertEqual(ProcessPresentation.contextLabel(for: projectItem), "web")
    XCTAssertEqual(ProcessPresentation.contextLabel(for: regularItem), "worker")
  }

  func testExecutablePathPrefersCommandPathForTruncatedExecutableFragments() {
    let shortPrefixItem = ClassifiedDevProcess(
      process: DevProcess(
        pid: 319,
        parentPID: 1,
        executable: "/usr/libexec/Use",
        command: "/usr/libexec/UserEventAgent (System)"
      ),
      classification: DevProcessClassification(
        kind: .systemService,
        displayName: "UserEventAgent",
        projectHint: nil,
        tags: []
      )
    )
    let regularItem = ClassifiedDevProcess(
      process: DevProcess(
        pid: 102, parentPID: 1, executable: "/opt/custom/bin/worker",
        command: "/opt/custom/bin/worker --foreground"),
      classification: DevProcessClassification(
        kind: .other, displayName: "worker", projectHint: nil, tags: [])
    )

    XCTAssertEqual(
      ProcessPresentation.executablePath(for: shortPrefixItem), "/usr/libexec/UserEventAgent")
    XCTAssertEqual(ProcessPresentation.executablePath(for: regularItem), "/opt/custom/bin/worker")
  }

  func testSummarizesVisibleProcessesByRuntimeAndProject() {
    let summary = ProcessPresentation.summary(for: sampleProcesses)

    XCTAssertEqual(summary.totalCount, 4)
    XCTAssertEqual(summary.count(for: .javascript), 2)
    XCTAssertEqual(summary.count(for: .python), 1)
    XCTAssertEqual(summary.count(for: .swift), 1)
    XCTAssertEqual(summary.count(for: .shell), 0)
    XCTAssertEqual(summary.projectCount, 3)
    XCTAssertEqual(summary.primaryProject, "devscope")
  }

  func testBuildsDynamicCategoriesOnlyForDetectedProcessTypes() {
    let categories = ProcessPresentation.categories(for: sampleProcesses)

    XCTAssertEqual(categories.map(\.title), ["All", "JavaScript", "Python", "Swift"])
    XCTAssertEqual(categories.map(\.count), [4, 2, 1, 1])
  }

  func testSavedCategoryCountSkipsIdentityChecksWhenNoKeysAreConfigured() {
    var identityCheckCount = 0

    let count = ProcessPresentation.savedCount(
      in: sampleProcesses,
      keys: []
    ) { _, _ in
      identityCheckCount += 1
      return true
    }

    XCTAssertEqual(count, 0)
    XCTAssertEqual(identityCheckCount, 0)
  }

  func testSortsProcessesByActivityMonitorStyleMetrics() {
    let items = [
      classified(
        pid: 101, kind: .javascript, displayName: "next dev", project: "web",
        command: "node next dev", cpu: 3, memory: 900),
      classified(
        pid: 102, kind: .python, displayName: "python worker", project: "api",
        command: "python worker.py", cpu: 48, memory: 300),
      classified(
        pid: 103, kind: .swift, displayName: "swift build", project: "devscope",
        command: "swift build", cpu: 12, memory: 1_600),
    ]

    XCTAssertEqual(
      ProcessPresentation.sorted(items, by: .cpuDescending).map(\.process.pid), [102, 103, 101])
    XCTAssertEqual(
      ProcessPresentation.sorted(items, by: .memoryDescending).map(\.process.pid), [103, 101, 102])
    XCTAssertEqual(
      ProcessPresentation.sorted(items, by: .processNameAscending).map(\.process.pid),
      [101, 102, 103])
  }

  func testParsesElapsedTimeForChronologicalTableSorting() {
    XCTAssertEqual(ProcessPresentation.elapsedSeconds("00:42"), 42)
    XCTAssertEqual(ProcessPresentation.elapsedSeconds("02:03:04"), 7_384)
    XCTAssertEqual(ProcessPresentation.elapsedSeconds("9-00:00:00"), 777_600)
    XCTAssertEqual(ProcessPresentation.elapsedSeconds("10-00:00:00"), 864_000)
    XCTAssertEqual(ProcessPresentation.elapsedSeconds("9223372036854775807-00:00:00"), -1)
    XCTAssertEqual(ProcessPresentation.elapsedSeconds("-"), -1)
  }

  func testSummarizesProcessFamilyForDetailPanels() {
    let processes = [
      DevProcess(pid: 10, parentPID: 1, executable: "npm", command: "npm run dev"),
      DevProcess(pid: 11, parentPID: 10, executable: "sh", command: "sh -c next dev"),
      DevProcess(pid: 12, parentPID: 11, executable: "node", command: "node next dev"),
      DevProcess(pid: 20, parentPID: 1, executable: "python", command: "python worker.py"),
    ]

    let family = ProcessPresentation.familySummary(for: processes[0], in: processes)

    XCTAssertEqual(family.parentPID, 1)
    XCTAssertEqual(family.childCount, 1)
    XCTAssertEqual(family.descendantCount, 2)
  }

  func testBuildsDashboardStatsForVisibleProcesses() {
    let totalItems = [
      classified(
        pid: 101, kind: .javascript, displayName: "next dev", project: "web",
        command: "node next dev", cpu: 3, memory: 900),
      classified(
        pid: 102, kind: .python, displayName: "python train", project: "ml",
        command: "python train.py", cpu: 48, memory: 300, tags: [.training]),
      classified(
        pid: 103, kind: .ai, displayName: "Ollama server", project: "llm", command: "ollama serve",
        cpu: 12, memory: 1_600, tags: [.llmServer]),
      classified(
        pid: 104, kind: .swift, displayName: "swift build", project: "devscope",
        command: "swift build", cpu: 80, memory: 2_400),
    ]
    let visibleItems = Array(totalItems.prefix(3))

    let stats = ProcessPresentation.dashboardStats(
      visibleItems: visibleItems,
      totalItems: totalItems,
      dashboardMetricHistory: [
        DevProcessMetricSample(
          timestamp: Date(),
          cpuPercent: 63,
          residentMemoryBytes: 2_800,
          gpuPercent: 42
        )
      ]
    )

    XCTAssertEqual(stats.visibleCount, 3)
    XCTAssertEqual(stats.totalCount, 4)
    XCTAssertEqual(stats.aiMLCount, 2)
    XCTAssertEqual(stats.topCPU?.process.pid, 104)
    XCTAssertEqual(stats.topMemory?.process.pid, 104)
    XCTAssertEqual(stats.runtimeCounts[.python], 1)
    XCTAssertEqual(stats.runtimeCounts[.swift], 1)
    XCTAssertEqual(stats.latestGPUPercent, 42)
  }

  func testParsesAppleAGXGPUUtilizationFromIORegistryOutput() {
    let output = #"""
      +-o AGXAcceleratorG15X  <class AGXAcceleratorG15X, active>
        "PerformanceStatistics" = {"Renderer Utilization %"=82,"Device Utilization %"=83,"In use system memory"=3049406464}
        "model" = "Apple M3 Max"
      """#

    let metric = SystemGPUMetricProvider.parse(output)

    XCTAssertEqual(metric?.utilizationPercent, 83)
    XCTAssertEqual(metric?.modelName, "Apple M3 Max")
  }

  private var sampleProcesses: [ClassifiedDevProcess] {
    [
      classified(
        pid: 101, kind: .javascript, displayName: "next dev", project: "web",
        command: "node next dev --port 3010"),
      classified(
        pid: 102, kind: .javascript, displayName: "vite", project: "devscope", command: "pnpm vite"),
      classified(
        pid: 201, kind: .python, displayName: "uvicorn", project: "api",
        command: "uvicorn app.main:app --reload"),
      classified(
        pid: 301, kind: .swift, displayName: "swift build", project: "devscope",
        command: "swift build"),
    ]
  }

  private func classified(
    pid: Int32,
    kind: DevRuntimeKind,
    displayName: String,
    project: String,
    command: String,
    cpu: Double = 0,
    memory: Int64 = 0,
    tags: [DevProcessTag] = []
  ) -> ClassifiedDevProcess {
    ClassifiedDevProcess(
      process: DevProcess(
        pid: pid,
        parentPID: 1,
        executable: command.split(separator: " ").first.map(String.init) ?? command,
        command: command,
        currentDirectory: "\(NSHomeDirectory())/dev/example/\(project)",
        resourceUsage: DevProcessResourceUsage(
          cpuPercent: cpu, residentMemoryBytes: memory, elapsedTime: "00:01")
      ),
      classification: DevProcessClassification(
        kind: kind,
        displayName: displayName,
        projectHint: project,
        tags: tags
      )
    )
  }
}
