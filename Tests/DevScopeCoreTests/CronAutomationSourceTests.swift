import XCTest
@testable import DevScopeCore

final class CronAutomationSourceTests: XCTestCase {
  func testParsesEnvironmentMacrosSchedulesAndDisabledDevScopeEntries() {
    let document = CronParser.parse("""
      SHELL=/bin/zsh
      PATH=/opt/homebrew/bin:/usr/bin:/bin
      @reboot /Users/example/bin/start-sync
      0 9 * * 1 /Users/example/bin/report --weekly
      # devscope-disabled: 30 2 * * * /Users/example/bin/cleanup
      """)

    XCTAssertEqual(document.environment["SHELL"], "/bin/zsh")
    XCTAssertEqual(document.entries.count, 3)
    XCTAssertEqual(document.entries[0].schedule.summary, "At startup")
    XCTAssertEqual(document.entries[1].schedule.summary, "Mondays at 09:00")
    XCTAssertFalse(document.entries[2].isEnabled)
    XCTAssertEqual(document.entries[2].scheduleExpression, "30 2 * * *")
    XCTAssertEqual(document.entries[2].command, "/Users/example/bin/cleanup")
    XCTAssertEqual(
      document.originalLines[4],
      "# devscope-disabled: 30 2 * * * /Users/example/bin/cleanup"
    )
    XCTAssertEqual(
      document.entries[2].id,
      CronParser.parse("30 2 * * * /Users/example/bin/cleanup").entries[0].id
    )
  }

  func testDisabledMarkerWithInvalidPayloadRemainsVisibleAndMakesSourcePartial() async {
    let line = "# devscope-disabled: # not-a-cron-entry"
    let document = CronParser.parse(line)

    XCTAssertTrue(document.entries.isEmpty)
    XCTAssertEqual(document.invalidLines, [CronInvalidLine(
      lineNumber: 1,
      content: line,
      reason: "Invalid crontab line"
    )])

    let snapshot = await CronAutomationSource(
      commandRunner: RecordingAutomationCommandRunner(result: .success(AutomationCommandResult(
        status: 0,
        standardOutput: Data("\(line)\n".utf8),
        standardError: Data()
      ))),
      currentUID: 501,
      currentUsername: "test-user"
    ).snapshot()

    XCTAssertEqual(snapshot.health.state, .partial)
    XCTAssertEqual(snapshot.health.message, "1 invalid crontab line.")
    XCTAssertEqual(snapshot.records.map(\.state), [.invalid])
  }

  func testPreservesOriginalTextEnvironmentOrderAndForwardOnlyContext() {
    let source = """
      # retained comment

      TOKEN=first-secret
      0 1 * * * /bin/echo before%mail-body
      TOKEN="second secret"
      0 2 * * * /bin/echo after\\%literal

      """

    let document = CronParser.parse(source)

    XCTAssertEqual(document.originalText, source)
    XCTAssertEqual(document.originalLines, source.components(separatedBy: "\n"))
    XCTAssertEqual(document.environmentAssignments.map(\.name), ["TOKEN", "TOKEN"])
    XCTAssertEqual(document.environmentAssignments.map(\.lineNumber), [3, 5])
    XCTAssertEqual(document.entries[0].environment["TOKEN"], "first-secret")
    XCTAssertEqual(document.entries[1].environment["TOKEN"], "second secret")
    XCTAssertEqual(document.entries[0].command, "/bin/echo before%mail-body")
    XCTAssertEqual(document.entries[1].command, "/bin/echo after\\%literal")
  }

  func testValidatesOfficialFiveFieldFormsAndKeepsMalformedLinesVisible() {
    let document = CronParser.parse("""
      */15 0-23/2 1,15 1-12 0-7 /bin/true
      5 4 * jan sun /bin/true
      30 4 1,15 * 5 /bin/true
      60 0 * * * /bin/echo minute-secret
      0 24 * * * /bin/echo hour-secret
      0 0 0 * * /bin/false
      0 0 * 13 * /bin/false
      0 0 * * 8 /bin/false
      0-10/0 * * * * /bin/false
      10-1 * * * * /bin/false
      1,,2 * * * * /bin/false
      0 0 * jan-mar * /bin/false
      @annually /bin/false
      @midnight /bin/false
      not a cron line containing=secret
      """)

    XCTAssertEqual(document.entries.count, 3)
    XCTAssertEqual(document.invalidLines.map(\.lineNumber), Array(4...15))
    XCTAssertEqual(
      document.entries[2].schedule.triggers,
      [.cron("30 4 1,15 * 5")]
    )
    XCTAssertTrue(document.invalidLines.allSatisfy { $0.reason == "Invalid crontab line" })
  }

  func testStableEntryIdentityExcludesEnvironmentAndCommandSecrets() {
    let first = CronParser.parse("""
      API_TOKEN=alpha-secret
      0 6 * * * /bin/run --token command-alpha
      0 6 * * * /bin/run-second
      """)
    let second = CronParser.parse("""
      # an unrelated retained comment
      API_TOKEN=beta-secret
      EXTRA_SECRET=gamma-secret
      0 6 * * * /bin/run --token command-beta
      0 6 * * * /bin/run-second
      """)

    XCTAssertEqual(first.entries.map(\.id), second.entries.map(\.id))
    XCTAssertEqual(Set(first.entries.map(\.id)).count, 2)
    for id in first.entries.map(\.id) + second.entries.map(\.id) {
      XCTAssertFalse(id.contains("secret"))
      XCTAssertFalse(id.contains("token"))
      XCTAssertFalse(id.contains("/bin/run"))
    }
  }

  func testSourceRunsCurrentUserCrontabWithoutShellAndMapsUIDAndSafeCapabilities() async {
    let output = Data("""
      TOKEN=environment-secret
      0 6 * * * /bin/run --token command-secret
      # devscope-disabled: @daily /bin/disabled
      61 * * * * /bin/invalid-secret
      """.utf8)
    let runner = RecordingAutomationCommandRunner(result: .success(AutomationCommandResult(
      status: 0,
      standardOutput: output,
      standardError: Data()
    )))
    let source = CronAutomationSource(
      commandRunner: runner,
      currentUID: 777,
      currentUsername: "test-user"
    )

    let snapshot = await source.snapshot()

    XCTAssertEqual(runner.invocations, [AutomationCommand(
      executable: "/usr/bin/crontab",
      arguments: ["-l"],
      environment: ["LC_ALL": "C"]
    )])
    XCTAssertEqual(snapshot.health.state, .partial)
    XCTAssertEqual(snapshot.health.message, "1 invalid crontab line.")
    XCTAssertEqual(snapshot.records.count, 3)
    XCTAssertTrue(snapshot.records.allSatisfy { $0.ownerUID == 777 })
    XCTAssertTrue(snapshot.records.allSatisfy { $0.ownership == .user })
    XCTAssertTrue(snapshot.records.allSatisfy { $0.sourceKind == .crontab })
    XCTAssertTrue(snapshot.records.allSatisfy { $0.kind == .cron })
    XCTAssertTrue(snapshot.records.allSatisfy { $0.capabilities.isEmpty })
    let expectedChecksum = CronDocumentChecksum.checksum(output)
    XCTAssertTrue(snapshot.records.allSatisfy { $0.sourceChecksum == expectedChecksum })
    XCTAssertEqual(snapshot.records.map(\.state), [.idle, .disabled, .invalid])
    XCTAssertEqual(snapshot.records[0].environment["TOKEN"], "environment-secret")
    XCTAssertEqual(
      snapshot.records[0].commandSignature,
      "/bin/run --token command-secret"
    )

    for record in snapshot.records {
      let publicMetadata = [
        record.id.rawValue,
        record.label,
        record.displayName,
        record.validationFindings.joined(separator: " "),
        record.evidence.map(\.detail).joined(separator: " "),
      ].joined(separator: " ").lowercased()
      XCTAssertFalse(publicMetadata.contains("secret"))
      XCTAssertFalse(publicMetadata.contains("/bin/"))
    }
  }

  func testFollowsOfficialCommentEnvironmentAndSupportedMacroGrammar() {
    let document = CronParser.parse("""
      #TOKEN=ignored-comment
      "SPACED NAME" = " value "
      PLAIN = bare
      @reboot /bin/one
      @hourly /bin/two with args
      @daily /bin/three
      @weekly /bin/four
      @monthly /bin/five
      @yearly /bin/six
      *,1 * * * * /bin/invalid
      +1 * * * * /bin/invalid
      UNFINISHED="unterminated
      """)

    XCTAssertEqual(document.environmentAssignments.map(\.name), ["SPACED NAME", "PLAIN"])
    XCTAssertEqual(document.environment["SPACED NAME"], " value ")
    XCTAssertNil(document.environment["#TOKEN"])
    XCTAssertEqual(document.entries.count, 6)
    XCTAssertEqual(document.entries[1].command, "/bin/two with args")
    XCTAssertEqual(document.entries.map(\.schedule.summary), [
      "At startup", "Hourly", "Daily", "Weekly", "Monthly", "Yearly",
    ])
    XCTAssertEqual(document.invalidLines.map(\.lineNumber), [10, 11, 12])
  }

  func testSourceDistinguishesStandardNoCrontabFromAllOtherFailures() async {
    let emptyRunner = RecordingAutomationCommandRunner(result: .success(AutomationCommandResult(
      status: 1,
      standardOutput: Data(),
      standardError: Data("crontab: no crontab for ExampleUser\n".utf8)
    )))
    let empty = await CronAutomationSource(
      commandRunner: emptyRunner,
      currentUID: 501,
      currentUsername: "ExampleUser"
    ).snapshot()
    XCTAssertEqual(empty.health.state, .healthy)
    XCTAssertNil(empty.health.message)
    XCTAssertTrue(empty.records.isEmpty)

    let failures = [
      AutomationCommandResult(
        status: 1,
        standardOutput: Data(),
        standardError: Data("crontab: permission denied for diagnostic-secret\n".utf8)
      ),
      AutomationCommandResult(
        status: 2,
        standardOutput: Data("0 0 * * * /bin/fabricated\n".utf8),
        standardError: Data("diagnostic-secret\n".utf8)
      ),
      AutomationCommandResult(
        status: 0,
        standardOutput: Data([0xFF]),
        standardError: Data()
      ),
    ]

    for result in failures {
      let snapshot = await CronAutomationSource(
        commandRunner: RecordingAutomationCommandRunner(result: .success(result)),
        currentUID: 501,
        currentUsername: "ExampleUser"
      ).snapshot()
      XCTAssertEqual(snapshot.health.kind, .crontab)
      XCTAssertEqual(snapshot.health.state, .failed)
      XCTAssertTrue(snapshot.records.isEmpty)
      XCTAssertFalse(snapshot.health.message?.contains("secret") ?? false)
      XCTAssertFalse(snapshot.health.message?.contains("/bin/fabricated") ?? false)
    }

    let thrown = await CronAutomationSource(
      commandRunner: RecordingAutomationCommandRunner(result: .failure(.commandFailed)),
      currentUID: 501,
      currentUsername: "ExampleUser"
    ).snapshot()
    XCTAssertEqual(thrown.health.state, .failed)
    XCTAssertTrue(thrown.records.isEmpty)
  }

  func testNoCrontabDiagnosticRejectsEveryNearMatchForInjectedUsername() async {
    let diagnostic = "crontab: no crontab for ExampleUser"
    let failures = [
      AutomationCommandResult(
        status: 1,
        standardOutput: Data(),
        standardError: Data("crontab: no crontab for OtherUser\n".utf8)
      ),
      AutomationCommandResult(
        status: 1,
        standardOutput: Data(),
        standardError: Data("\(diagnostic)-extra\n".utf8)
      ),
      AutomationCommandResult(
        status: 1,
        standardOutput: Data(),
        standardError: Data("crontab: no crontab for exampleuser\n".utf8)
      ),
      AutomationCommandResult(
        status: 1,
        standardOutput: Data(),
        standardError: Data(" \(diagnostic)\n".utf8)
      ),
      AutomationCommandResult(
        status: 1,
        standardOutput: Data(),
        standardError: Data("\(diagnostic) \n".utf8)
      ),
      AutomationCommandResult(
        status: 1,
        standardOutput: Data(),
        standardError: Data("\(diagnostic)\nextra line\n".utf8)
      ),
      AutomationCommandResult(
        status: 1,
        standardOutput: Data(),
        standardError: Data("\(diagnostic)\n\n".utf8)
      ),
      AutomationCommandResult(
        status: 1,
        standardOutput: Data("unexpected stdout".utf8),
        standardError: Data("\(diagnostic)\n".utf8)
      ),
      AutomationCommandResult(
        status: 1,
        standardOutput: Data(),
        standardError: Data([0xFF])
      ),
      AutomationCommandResult(
        status: 2,
        standardOutput: Data(),
        standardError: Data("\(diagnostic)\n".utf8)
      ),
    ]

    for result in failures {
      let snapshot = await CronAutomationSource(
        commandRunner: RecordingAutomationCommandRunner(result: .success(result)),
        currentUID: 501,
        currentUsername: "ExampleUser"
      ).snapshot()

      XCTAssertEqual(snapshot.health.state, .failed)
      XCTAssertTrue(snapshot.records.isEmpty)
    }
  }

  func testNoCrontabDiagnosticAcceptsExactUsernameWithOneTerminalNewlineConvention() async {
    for terminator in ["", "\n", "\r\n"] {
      let snapshot = await CronAutomationSource(
        commandRunner: RecordingAutomationCommandRunner(result: .success(AutomationCommandResult(
          status: 1,
          standardOutput: Data(),
          standardError: Data("crontab: no crontab for ExampleUser\(terminator)".utf8)
        ))),
        currentUID: 501,
        currentUsername: "ExampleUser"
      ).snapshot()

      XCTAssertEqual(snapshot.health.state, .healthy)
      XCTAssertTrue(snapshot.records.isEmpty)
    }
  }
}
