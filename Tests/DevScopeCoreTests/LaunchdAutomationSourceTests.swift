import CryptoKit
import XCTest
@testable import DevScopeCore

final class LaunchdAutomationSourceTests: XCTestCase {
  func testSnapshotAppliesInjectedUserDomainEnabledAndLoadedState() async throws {
    let root = LaunchdScanRoot(
      url: URL(fileURLWithPath: "/fixtures/Library/LaunchAgents"),
      kind: .launchAgent,
      ownership: .user,
      isMutable: true
    )
    let enabledURL = root.url.appendingPathComponent("enabled.plist")
    let disabledURL = root.url.appendingPathComponent("disabled.plist")
    let provider = FakeLaunchdRuntimeStateProvider(states: [
      "com.example.enabled": LaunchdRuntimeState(
        enabledState: .enabled,
        loadState: .loaded
      ),
      "com.example.disabled": LaunchdRuntimeState(
        enabledState: .disabled,
        loadState: .loaded
      ),
    ])
    let source = LaunchdAutomationSource(
      fileSystem: InMemoryAutomationFileSystem(files: [
        enabledURL: try plistData(["Label": "com.example.enabled", "Program": "/bin/echo"]),
        disabledURL: try plistData(["Label": "com.example.disabled", "Program": "/bin/echo"]),
      ]),
      currentUID: 501,
      roots: [root],
      runtimeStateProvider: provider
    )

    let records = Dictionary(
      uniqueKeysWithValues: await source.snapshot().records.map { ($0.label, $0) }
    )

    XCTAssertEqual(records["com.example.enabled"]?.enabledState, .enabled)
    XCTAssertEqual(records["com.example.enabled"]?.loadState, .loaded)
    XCTAssertEqual(records["com.example.enabled"]?.state, .idle)
    XCTAssertEqual(records["com.example.disabled"]?.enabledState, .disabled)
    XCTAssertEqual(records["com.example.disabled"]?.loadState, .loaded)
    XCTAssertEqual(records["com.example.disabled"]?.state, .disabled)
    let requestedLabels = await provider.requestedLabels()
    XCTAssertEqual(requestedLabels, ["com.example.disabled", "com.example.enabled"])
  }

  func testHealthMessageBoundsLargeDiagnosticSetsAndKeepsRepresentativeIssues() {
    let errors = (1...20).map { index in
      "definition-\(index): " + String(repeating: "unreadable diagnostic detail ", count: 20)
    }

    let message = LaunchdAutomationSource.healthMessage(for: errors)

    XCTAssertTrue(message.contains("Launchd inspection found 20 issues."))
    XCTAssertTrue(message.contains("definition-1"))
    XCTAssertTrue(message.contains("definition-2"))
    XCTAssertFalse(message.contains("definition-3"))
    XCTAssertTrue(message.hasSuffix("Select an Invalid record for per-definition details."))
    XCTAssertLessThanOrEqual(message.count, 360)
  }

  func testParsesLabelProgramArgumentsAndCalendarSchedule() throws {
    let plist: [String: Any] = [
      "Label": "com.example.weekly-report",
      "ProgramArguments": ["/usr/bin/python3", "/Users/example/report.py"],
      "StartCalendarInterval": ["Weekday": 1, "Hour": 9, "Minute": 0],
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: plist,
      format: .xml,
      options: 0
    )

    let record = try LaunchdPlistParser.parse(
      data: data,
      sourceURL: URL(
        fileURLWithPath: "/Users/example/Library/LaunchAgents/com.example.weekly-report.plist"
      ),
      ownerUID: 501,
      ownership: .user
    )

    XCTAssertEqual(record.label, "com.example.weekly-report")
    XCTAssertEqual(record.executable, "/usr/bin/python3")
    XCTAssertEqual(record.arguments, ["/Users/example/report.py"])
    XCTAssertEqual(record.schedule.summary, "Mondays at 09:00")
  }

  func testParsesEnvironmentAndWorkingDirectoryWithoutDroppingDefinitionState() throws {
    let record = try LaunchdPlistParser.parse(
      data: plistData([
        "Label": "com.example.complete-definition",
        "Program": "/bin/echo",
        "EnvironmentVariables": ["MODE": "audit", "TOKEN": "local"],
        "WorkingDirectory": "/Users/example/Workspace",
      ]),
      sourceURL: URL(fileURLWithPath: "/Users/example/Library/LaunchAgents/com.example.complete-definition.plist"),
      ownerUID: 501,
      ownership: .user
    )

    XCTAssertEqual(record.environment, ["MODE": "audit", "TOKEN": "local"])
    XCTAssertEqual(record.workingDirectory, "/Users/example/Workspace")
  }

  func testRejectsNonStringEnvironmentValuesAndEmptyWorkingDirectory() throws {
    XCTAssertThrowsError(try LaunchdPlistParser.parse(
      data: plistData([
        "Label": "com.example.invalid-environment",
        "Program": "/bin/echo",
        "EnvironmentVariables": ["RETRIES": 3],
      ]),
      sourceURL: URL(fileURLWithPath: "/tmp/invalid-environment.plist"),
      ownerUID: 501,
      ownership: .user
    )) { error in
      XCTAssertEqual(error as? AutomationParseError, .invalidField("EnvironmentVariables"))
    }
    XCTAssertThrowsError(try LaunchdPlistParser.parse(
      data: plistData([
        "Label": "com.example.invalid-directory",
        "Program": "/bin/echo",
        "WorkingDirectory": "",
      ]),
      sourceURL: URL(fileURLWithPath: "/tmp/invalid-directory.plist"),
      ownerUID: 501,
      ownership: .user
    )) { error in
      XCTAssertEqual(error as? AutomationParseError, .invalidField("WorkingDirectory"))
    }
  }

  func testProgramTakesExecutablePrecedenceAndProgramArgumentsRemainArgv() throws {
    let data = try plistData([
      "Label": "com.example.explicit-program",
      "Program": "/usr/local/bin/worker",
      "ProgramArguments": ["custom-argv-zero", "--once"],
      "StartCalendarInterval": ["Weekday": 1, "Hour": 9, "Minute": 0],
    ])

    let record = try LaunchdPlistParser.parse(
      data: data,
      sourceURL: URL(fileURLWithPath: "/Library/LaunchDaemons/com.example.explicit-program.plist"),
      ownerUID: 0,
      ownership: .thirdPartySystem
    )

    XCTAssertEqual(record.kind, .launchDaemon)
    XCTAssertEqual(record.sourceKind, .launchDaemon)
    XCTAssertEqual(record.executable, "/usr/local/bin/worker")
    XCTAssertEqual(record.arguments, ["custom-argv-zero", "--once"])
  }

  func testParsesBundleRelativeProgramWithoutProgramArguments() throws {
    let record = try LaunchdPlistParser.parse(
      data: plistData([
        "Label": "com.example.bundle-worker",
        "BundleProgram": "Contents/MacOS/Worker",
        "StartCalendarInterval": ["Weekday": 1, "Hour": 9, "Minute": 0],
      ]),
      sourceURL: URL(fileURLWithPath: "/Library/LaunchAgents/com.example.bundle-worker.plist"),
      ownerUID: 0,
      ownership: .thirdPartySystem
    )

    XCTAssertEqual(record.executable, "Contents/MacOS/Worker")
    XCTAssertEqual(record.arguments, [])
  }

  func testParsesSupportedLaunchTriggersAndRelativeArgvZero() throws {
    let cases: [(fields: [String: Any], triggers: [AutomationSchedule.Trigger], summary: String)] = [
      (["RunAtLoad": true], [.runAtLoad], "At load"),
      (["KeepAlive": true], [.runAtLoad, .keepAlive], "At load, kept alive"),
      (
        ["KeepAlive": ["SuccessfulExit": false]],
        [.runAtLoad, .keepAlive],
        "At load, kept alive conditionally"
      ),
      (
        ["RunAtLoad": true, "KeepAlive": true],
        [.runAtLoad, .keepAlive],
        "At load, kept alive"
      ),
      (["StartInterval": 300], [.interval(seconds: 300)], "Every 5 minutes"),
      (["RunAtLoad": false, "KeepAlive": false], [.demand], "On demand"),
      ([:], [.demand], "On demand"),
    ]

    for (index, testCase) in cases.enumerated() {
      var plist = testCase.fields
      plist["Label"] = "com.example.trigger-\(index)"
      plist["ProgramArguments"] = ["relative-tool", "--once"]

      let record = try LaunchdPlistParser.parse(
        data: plistData(plist),
        sourceURL: URL(fileURLWithPath: "/Library/LaunchAgents/com.example.trigger-\(index).plist"),
        ownerUID: 0,
        ownership: .thirdPartySystem
      )

      XCTAssertEqual(record.executable, "relative-tool", "case \(index)")
      XCTAssertEqual(record.arguments, ["--once"], "case \(index)")
      XCTAssertEqual(record.schedule.triggers, testCase.triggers, "case \(index)")
      XCTAssertEqual(record.schedule.summary, testCase.summary, "case \(index)")
    }
  }

  func testKeepAliveAcceptsOnlyDocumentedConditionKeysAndTypes() throws {
    let validConditions: [[String: Any]] = [
      ["SuccessfulExit": true],
      ["NetworkState": false],
      ["Crashed": true],
      ["PathState": ["/tmp/ready": true, "/tmp/blocked": false]],
      ["OtherJobEnabled": ["com.example.dependency": true]],
      [
        "SuccessfulExit": false,
        "PathState": ["/tmp/ready": true],
        "OtherJobEnabled": ["com.example.dependency": false],
      ],
    ]

    for (index, conditions) in validConditions.enumerated() {
      let record = try LaunchdPlistParser.parse(
        data: plistData([
          "Label": "com.example.valid-keepalive-\(index)",
          "Program": "/bin/echo",
          "KeepAlive": conditions,
        ]),
        sourceURL: URL(fileURLWithPath: "/tmp/valid-keepalive-\(index).plist"),
        ownerUID: 501,
        ownership: .user
      )

      XCTAssertEqual(record.schedule.triggers, [.runAtLoad, .keepAlive], "case \(index)")
    }

    let invalidConditions: [(name: String, conditions: [String: Any])] = [
      ("unsupported key", ["AfterInitialDemand": true]),
      ("boolean as integer", ["SuccessfulExit": 1]),
      ("boolean as string", ["Crashed": "true"]),
      ("path state scalar", ["PathState": true]),
      ("path state non-boolean value", ["PathState": ["/tmp/ready": 1]]),
      ("path state nested value", ["PathState": ["/tmp/ready": ["nested": true]]]),
      ("other job scalar", ["OtherJobEnabled": false]),
      ("other job non-boolean value", ["OtherJobEnabled": ["com.example.job": "yes"]]),
    ]

    for testCase in invalidConditions {
      XCTAssertThrowsError(
        try LaunchdPlistParser.parse(
          data: plistData([
            "Label": "com.example.invalid-keepalive",
            "Program": "/bin/echo",
            "KeepAlive": testCase.conditions,
          ]),
          sourceURL: URL(fileURLWithPath: "/tmp/invalid-keepalive.plist"),
          ownerUID: 501,
          ownership: .user
        ),
        testCase.name
      ) { error in
        XCTAssertEqual(
          error as? AutomationParseError,
          .invalidField("KeepAlive"),
          testCase.name
        )
      }
    }
  }

  func testParsesCalendarIntervalArrayAsIndependentTriggers() throws {
    let record = try LaunchdPlistParser.parse(
      data: plistData([
        "Label": "com.example.calendar-array",
        "Program": "/bin/echo",
        "StartCalendarInterval": [
          ["Weekday": 7, "Hour": 7, "Minute": 15],
          ["Month": 1, "Day": 1, "Hour": 0, "Minute": 0],
        ],
      ]),
      sourceURL: URL(fileURLWithPath: "/Library/LaunchAgents/com.example.calendar-array.plist"),
      ownerUID: 0,
      ownership: .thirdPartySystem
    )

    XCTAssertEqual(record.schedule.triggers, [
      .calendar("Sundays at 07:15"),
      .calendar("January 1 at 00:00"),
    ])
    XCTAssertEqual(record.schedule.summary, "Sundays at 07:15; January 1 at 00:00")
  }

  func testCalendarMonthScopesTheDayOrWeekdayAlternatives() throws {
    let cases: [(fields: [String: Any], summary: String)] = [
      (
        ["Month": 1, "Weekday": 1, "Hour": 9, "Minute": 0],
        "Mondays in January at 09:00"
      ),
      (
        ["Month": 1, "Day": 15, "Weekday": 1, "Hour": 9, "Minute": 0],
        "January (day 15 or Mondays) at 09:00"
      ),
    ]

    for (index, testCase) in cases.enumerated() {
      let record = try LaunchdPlistParser.parse(
        data: plistData([
          "Label": "com.example.calendar-precedence-\(index)",
          "Program": "/bin/echo",
          "StartCalendarInterval": testCase.fields,
        ]),
        sourceURL: URL(fileURLWithPath: "/tmp/calendar-precedence-\(index).plist"),
        ownerUID: 501,
        ownership: .user
      )

      XCTAssertEqual(record.schedule.summary, testCase.summary, "case \(index)")
    }
  }

  func testCalendarWildcardsRemainIndependentFromStartInterval() throws {
    let record = try LaunchdPlistParser.parse(
      data: plistData([
        "Label": "com.example.calendar-wildcards",
        "Program": "/bin/echo",
        "StartInterval": 60,
        "StartCalendarInterval": [
          ["Minute": 15],
          [:],
        ],
      ]),
      sourceURL: URL(fileURLWithPath: "/Library/LaunchAgents/com.example.calendar-wildcards.plist"),
      ownerUID: 0,
      ownership: .thirdPartySystem
    )

    XCTAssertEqual(record.schedule.triggers, [
      .interval(seconds: 60),
      .calendar("Every day at minute 15 of every hour"),
      .calendar("Every day every minute"),
    ])
    XCTAssertEqual(
      record.schedule.summary,
      "Every 1 minute, Every day at minute 15 of every hour; Every day every minute"
    )
  }

  func testRejectsMalformedOrContractViolatingPropertyListsWithTypedErrors() throws {
    let cases: [(name: String, data: Data, error: AutomationParseError)] = [
      ("malformed XML", Data("<plist><dict>".utf8), .unreadablePropertyList),
      ("missing label", try plistData(["Program": "/bin/echo"]), .missingLabel),
      (
        "invalid label type",
        try plistData(["Label": 42, "Program": "/bin/echo"]),
        .invalidField("Label")
      ),
      ("missing program", try plistData(["Label": "com.example.missing"]), .missingProgram),
      (
        "relative Program",
        try plistData(["Label": "com.example.relative", "Program": "bin/tool"]),
        .invalidField("Program")
      ),
      (
        "absolute BundleProgram",
        try plistData(["Label": "com.example.bundle", "BundleProgram": "/Contents/MacOS/Tool"]),
        .invalidField("BundleProgram")
      ),
      (
        "non-string argv",
        try plistData([
          "Label": "com.example.argv",
          "Program": "/bin/echo",
          "ProgramArguments": ["echo", 42],
        ]),
        .invalidField("ProgramArguments")
      ),
      (
        "non-boolean RunAtLoad",
        try plistData(["Label": "com.example.run", "Program": "/bin/echo", "RunAtLoad": 1]),
        .invalidField("RunAtLoad")
      ),
      (
        "invalid KeepAlive",
        try plistData(["Label": "com.example.keep", "Program": "/bin/echo", "KeepAlive": "yes"]),
        .invalidField("KeepAlive")
      ),
      (
        "non-positive interval",
        try plistData(["Label": "com.example.interval", "Program": "/bin/echo", "StartInterval": 0]),
        .invalidField("StartInterval")
      ),
      (
        "calendar value outside man-page range",
        try plistData([
          "Label": "com.example.calendar",
          "Program": "/bin/echo",
          "StartCalendarInterval": ["Hour": 24],
        ]),
        .invalidField("StartCalendarInterval.Hour")
      ),
      (
        "empty calendar array",
        try plistData([
          "Label": "com.example.empty-calendar",
          "Program": "/bin/echo",
          "StartCalendarInterval": [],
        ]),
        .invalidField("StartCalendarInterval")
      ),
    ]

    for testCase in cases {
      XCTAssertThrowsError(
        try LaunchdPlistParser.parse(
          data: testCase.data,
          sourceURL: URL(fileURLWithPath: "/tmp/\(testCase.name).plist"),
          ownerUID: 501,
          ownership: .user
        ),
        testCase.name
      ) { error in
        XCTAssertEqual(error as? AutomationParseError, testCase.error, testCase.name)
      }
    }
  }

  func testPublicParserPreservesCanonicalIdentityButDefaultsToReadOnlyCapabilities() throws {
    let data = try plistData([
      "Label": "com.example.mutable-user-agent",
      "Program": "/bin/sleep",
      "ProgramArguments": ["sleep", "60"],
    ])
    let sourceURL = URL(
      fileURLWithPath: "/Users/example/Library/LaunchAgents/folder/../com.example.mutable-user-agent.plist"
    )

    let record = try LaunchdPlistParser.parse(
      data: data,
      sourceURL: sourceURL,
      ownerUID: 501,
      ownership: .user
    )

    XCTAssertEqual(record.ownerUID, 501)
    XCTAssertEqual(record.ownership, .user)
    XCTAssertEqual(record.kind, .launchAgent)
    XCTAssertEqual(record.sourceKind, .launchAgent)
    XCTAssertEqual(record.sourceURL, sourceURL.standardizedFileURL)
    XCTAssertEqual(
      record.id,
      AutomationRecord.ID(
        source: .launchAgent,
        ownerUID: 501,
        label: "com.example.mutable-user-agent",
        sourcePath: sourceURL.standardizedFileURL.path
      )
    )
    XCTAssertEqual(
      record.sourceChecksum,
      SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    )
    XCTAssertEqual(record.capabilities, [.exportRecord])
    XCTAssertEqual(record.evidence.first?.strength, .strong)
    XCTAssertEqual(record.state, .unresolved)
  }

  func testPublicParserInfersLaunchDaemonKindFromCanonicalDotSegmentPath() throws {
    let data = try plistData([
      "Label": "com.example.daemon",
      "Program": "/bin/echo",
    ])
    let sourceURL = URL(
      fileURLWithPath: "/Library/LaunchDaemons/folder/../job.plist"
    )
    let canonicalSourceURL = sourceURL.standardizedFileURL

    let record = try LaunchdPlistParser.parse(
      data: data,
      sourceURL: sourceURL,
      ownerUID: 0,
      ownership: .thirdPartySystem
    )

    XCTAssertEqual(record.sourceURL, canonicalSourceURL)
    XCTAssertEqual(record.kind, .launchDaemon)
    XCTAssertEqual(record.sourceKind, .launchDaemon)
    XCTAssertEqual(
      record.id,
      AutomationRecord.ID(
        source: .launchDaemon,
        ownerUID: 0,
        label: "com.example.daemon",
        sourcePath: canonicalSourceURL.path
      )
    )
  }

  func testDefaultRootsInventoryUserThirdPartyAndAppleLocations() {
    let home = URL(fileURLWithPath: "/Users/fixture")
    let roots = LaunchdAutomationSource.defaultRoots(homeDirectory: home)

    XCTAssertEqual(roots.map(\.url), [
      URL(fileURLWithPath: "/Users/fixture/Library/LaunchAgents"),
      URL(fileURLWithPath: "/Library/LaunchAgents"),
      URL(fileURLWithPath: "/Library/LaunchDaemons"),
      URL(fileURLWithPath: "/System/Library/LaunchAgents"),
      URL(fileURLWithPath: "/System/Library/LaunchDaemons"),
    ])
    XCTAssertEqual(roots.map(\.kind), [
      .launchAgent, .launchAgent, .launchDaemon, .launchAgent, .launchDaemon,
    ])
    XCTAssertEqual(roots.map(\.ownership), [
      .user, .thirdPartySystem, .thirdPartySystem, .appleSystem, .appleSystem,
    ])
    XCTAssertEqual(roots.map(\.isMutable), [true, false, false, false, false])
  }

  func testSnapshotInventoriesEveryRootAndKeepsDuplicateLabelsDistinct() async throws {
    let roots = LaunchdAutomationSource.defaultRoots(
      homeDirectory: URL(fileURLWithPath: "/Users/fixture")
    )
    var files: [URL: Data] = [:]
    var metadata: [URL: AutomationFileMetadata] = [:]

    for (index, root) in roots.enumerated() {
      let url = root.url.appendingPathComponent("duplicate-\(index).plist")
      files[url] = try plistData([
        "Label": "com.example.duplicate",
        "Program": "/bin/echo",
      ])
      metadata[url] = AutomationFileMetadata(
        canonicalURL: url,
        ownerUID: index == 0 ? 501 : 0,
        isSymbolicLink: false,
        modificationDate: Date(timeIntervalSince1970: 1_000),
        resourceIdentifier: "file-\(index)"
      )
    }

    let source = LaunchdAutomationSource(
      fileSystem: InMemoryAutomationFileSystem(files: files, metadata: metadata),
      currentUID: 501,
      roots: roots
    )
    let snapshot = await source.snapshot()

    XCTAssertEqual(snapshot.health.state, .healthy, snapshot.health.message ?? "no health message")
    XCTAssertEqual(snapshot.records.count, 5)
    XCTAssertEqual(Set(snapshot.records.map(\.id)).count, 5)
    XCTAssertEqual(snapshot.records.map(\.ownership), [
      .user, .thirdPartySystem, .thirdPartySystem, .appleSystem, .appleSystem,
    ])
    XCTAssertEqual(snapshot.records.map(\.ownerUID), [501, 0, 0, 0, 0])
    XCTAssertEqual(snapshot.records.map(\.kind), [
      .launchAgent, .launchAgent, .launchDaemon, .launchAgent, .launchDaemon,
    ])
    XCTAssertEqual(
      snapshot.records.first?.capabilities,
      [.edit, .duplicate, .exportRecord, .remove]
    )
    XCTAssertEqual(snapshot.records.dropFirst().first?.capabilities, [.exportRecord])
    XCTAssertTrue(snapshot.records.contains { $0.ownership == .appleSystem })
  }

  func testUserRootPreservesFileOwnerAndRequiresCurrentUIDForMutability() async throws {
    let root = LaunchdScanRoot(
      url: URL(fileURLWithPath: "/fixtures/Library/LaunchAgents"),
      kind: .launchAgent,
      ownership: .user,
      isMutable: true
    )
    let url = root.url.appendingPathComponent("other-owner.plist")
    let fileSystem = InMemoryAutomationFileSystem(
      files: [url: try plistData([
        "Label": "com.example.other-owner",
        "Program": "/bin/echo",
      ])],
      metadata: [url: AutomationFileMetadata(
        canonicalURL: url,
        ownerUID: 777,
        isSymbolicLink: false,
        modificationDate: Date(timeIntervalSince1970: 1_000),
        resourceIdentifier: "other-owner"
      )]
    )
    let source = LaunchdAutomationSource(
      fileSystem: fileSystem,
      currentUID: 501,
      roots: [root]
    )

    let record = await source.snapshot().records.first

    XCTAssertEqual(record?.ownerUID, 777)
    XCTAssertEqual(record?.ownership, .user)
    XCTAssertEqual(record?.capabilities, [.exportRecord])
  }

  func testSourceGrantsMutabilityOnlyToSafeRegularFilesInsideApprovedUserRoot() async throws {
    let root = LaunchdScanRoot(
      url: URL(fileURLWithPath: "/fixtures/Library/LaunchAgents"),
      kind: .launchAgent,
      ownership: .user,
      isMutable: true
    )
    let cases: [(
      name: String,
      canonicalURL: URL,
      isSymbolicLink: Bool,
      expectedCapabilities: Set<AutomationCapability>
    )] = [
      (
        "safe",
        root.url.appendingPathComponent("safe.plist"),
        false,
        [.edit, .duplicate, .exportRecord, .remove]
      ),
      (
        "symlink",
        root.url.appendingPathComponent("symlink.plist"),
        true,
        [.exportRecord]
      ),
      (
        "canonical-escape",
        URL(fileURLWithPath: "/fixtures/outside/canonical-escape.plist"),
        false,
        [.exportRecord]
      ),
      (
        "prefix-sibling",
        URL(fileURLWithPath: "/fixtures/Library/LaunchAgents-escaped/prefix-sibling.plist"),
        false,
        [.exportRecord]
      ),
    ]
    var files: [URL: Data] = [:]
    var metadata: [URL: AutomationFileMetadata] = [:]

    for testCase in cases {
      let enumeratedURL = root.url.appendingPathComponent("\(testCase.name).plist")
      files[enumeratedURL] = try plistData([
        "Label": "com.example.\(testCase.name)",
        "Program": "/bin/echo",
      ])
      metadata[enumeratedURL] = AutomationFileMetadata(
        canonicalURL: testCase.canonicalURL,
        ownerUID: 501,
        isSymbolicLink: testCase.isSymbolicLink,
        modificationDate: Date(timeIntervalSince1970: 1_000),
        resourceIdentifier: testCase.name
      )
    }
    let source = LaunchdAutomationSource(
      fileSystem: InMemoryAutomationFileSystem(files: files, metadata: metadata),
      currentUID: 501,
      roots: [root]
    )

    let recordsByLabel = Dictionary(
      uniqueKeysWithValues: await source.snapshot().records.map { ($0.label, $0) }
    )

    for testCase in cases {
      let record = recordsByLabel["com.example.\(testCase.name)"]
      XCTAssertEqual(record?.capabilities, testCase.expectedCapabilities, testCase.name)
      XCTAssertEqual(record?.sourceURL, testCase.canonicalURL.standardizedFileURL, testCase.name)
    }
  }

  func testSnapshotSurfacesMalformedDefinitionsAndMissingDirectoriesAsPartialHealth() async throws {
    let presentRoot = LaunchdScanRoot(
      url: URL(fileURLWithPath: "/fixtures/Library/LaunchAgents"),
      kind: .launchAgent,
      ownership: .user,
      isMutable: true
    )
    let missingRoot = LaunchdScanRoot(
      url: URL(fileURLWithPath: "/fixtures/System/Library/LaunchDaemons"),
      kind: .launchDaemon,
      ownership: .appleSystem,
      isMutable: false
    )
    let validURL = presentRoot.url.appendingPathComponent("valid.plist")
    let malformedURL = presentRoot.url.appendingPathComponent("broken.plist")
    let fileSystem = InMemoryAutomationFileSystem(files: [
      validURL: try plistData(["Label": "com.example.valid", "Program": "/bin/echo"]),
      malformedURL: Data("not a property list".utf8),
    ])
    let source = LaunchdAutomationSource(
      fileSystem: fileSystem,
      currentUID: 501,
      roots: [presentRoot, missingRoot]
    )

    let snapshot = await source.snapshot()

    XCTAssertEqual(snapshot.health.state, .partial)
    XCTAssertTrue(snapshot.health.message?.contains("broken.plist") == true)
    XCTAssertTrue(snapshot.health.message?.contains(missingRoot.url.path) == true)
    XCTAssertEqual(snapshot.records.count, 2)
    let invalid = snapshot.records.first { $0.state == .invalid }
    XCTAssertEqual(invalid?.label, "broken")
    XCTAssertEqual(invalid?.ownership, .user)
    XCTAssertEqual(invalid?.ownerUID, 501)
    XCTAssertEqual(invalid?.sourceURL, malformedURL.standardizedFileURL)
    XCTAssertTrue(invalid?.validationFindings.contains("Unreadable property list") == true)
    XCTAssertEqual(invalid?.capabilities, [])
  }

  func testReadFailurePreservesSuccessfulMetadataProvenanceAndCanonicalIdentity() async throws {
    let root = LaunchdScanRoot(
      url: URL(fileURLWithPath: "/fixtures/Library/LaunchAgents"),
      kind: .launchAgent,
      ownership: .user,
      isMutable: true
    )
    let enumeratedURL = root.url.appendingPathComponent("read-failure.plist")
    let canonicalURL = root.url.appendingPathComponent("canonical-read-failure.plist")
    let fileSystem = InMemoryAutomationFileSystem(
      files: [enumeratedURL: try plistData([
        "Label": "com.example.unreadable",
        "Program": "/bin/echo",
      ])],
      metadata: [enumeratedURL: AutomationFileMetadata(
        canonicalURL: canonicalURL,
        ownerUID: 777,
        isSymbolicLink: false,
        modificationDate: Date(timeIntervalSince1970: 1_000),
        resourceIdentifier: "read-failure"
      )],
      failingReads: [enumeratedURL]
    )
    let source = LaunchdAutomationSource(
      fileSystem: fileSystem,
      currentUID: 501,
      roots: [root]
    )

    let snapshot = await source.snapshot()
    let invalid = snapshot.records.first

    XCTAssertEqual(snapshot.health.state, .partial)
    XCTAssertEqual(invalid?.state, .invalid)
    XCTAssertEqual(invalid?.ownerUID, 777)
    XCTAssertEqual(invalid?.sourceURL, canonicalURL.standardizedFileURL)
    XCTAssertEqual(invalid?.label, "canonical-read-failure")
    XCTAssertEqual(
      invalid?.id,
      AutomationRecord.ID(
        source: .launchAgent,
        ownerUID: 777,
        label: "canonical-read-failure",
        sourcePath: canonicalURL.standardizedFileURL.path
      )
    )
  }

  func testCacheReusesOnlyTheCompleteCanonicalResourceDateAndChecksumIdentity() async throws {
    let root = LaunchdScanRoot(
      url: URL(fileURLWithPath: "/fixtures/Library/LaunchAgents"),
      kind: .launchAgent,
      ownership: .user,
      isMutable: true
    )
    let url = root.url.appendingPathComponent("cached.plist")
    let originalData = try plistData([
      "Label": "com.example.cached",
      "Program": "/bin/echo",
    ])
    let initialDate = Date(timeIntervalSince1970: 1_000)
    let fileSystem = InMemoryAutomationFileSystem(
      files: [url: originalData],
      metadata: [url: AutomationFileMetadata(
        canonicalURL: url,
        ownerUID: 501,
        isSymbolicLink: false,
        modificationDate: initialDate,
        resourceIdentifier: "resource-a"
      )]
    )
    let parseCounter = LockedCounter()
    let source = LaunchdAutomationSource(
      fileSystem: fileSystem,
      currentUID: 501,
      roots: [root],
      recordParser: { data, sourceURL, ownerUID, ownership, kind, isMutable in
        parseCounter.increment()
        return try LaunchdPlistParser.parse(
          data: data,
          canonicalSourceURL: sourceURL,
          ownerUID: ownerUID,
          ownership: ownership,
          kind: kind,
          isMutable: isMutable
        )
      }
    )

    _ = await source.snapshot()
    _ = await source.snapshot()
    XCTAssertEqual(parseCounter.value, 1, "unchanged identity should reuse the parsed record")

    fileSystem.setMetadata(AutomationFileMetadata(
      canonicalURL: url,
      ownerUID: 501,
      isSymbolicLink: false,
      modificationDate: initialDate,
      resourceIdentifier: "resource-b"
    ), for: url)
    _ = await source.snapshot()
    XCTAssertEqual(parseCounter.value, 2, "resource identity must invalidate reuse")

    fileSystem.setMetadata(AutomationFileMetadata(
      canonicalURL: url,
      ownerUID: 501,
      isSymbolicLink: false,
      modificationDate: initialDate.addingTimeInterval(1),
      resourceIdentifier: "resource-b"
    ), for: url)
    _ = await source.snapshot()
    XCTAssertEqual(parseCounter.value, 3, "modification date must invalidate reuse")

    fileSystem.setStoredData(try plistData([
      "Label": "com.example.cached",
      "Program": "/bin/echo",
      "RunAtLoad": true,
    ]), at: url)
    _ = await source.snapshot()
    XCTAssertEqual(parseCounter.value, 4, "checksum must invalidate reuse")
  }

  private func plistData(_ plist: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(
      fromPropertyList: plist,
      format: .xml,
      options: 0
    )
  }
}

private actor FakeLaunchdRuntimeStateProvider: LaunchdRuntimeStateProviding {
  private let values: [String: LaunchdRuntimeState]
  private var labels: [String] = []

  init(states: [String: LaunchdRuntimeState]) {
    values = states
  }

  func states(for requestedLabels: [String], guiUID: uid_t) async -> [String: LaunchdRuntimeState] {
    labels = requestedLabels
    return values
  }

  func requestedLabels() -> [String] { labels }
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.withLock { count }
  }

  func increment() {
    lock.withLock { count += 1 }
  }
}
