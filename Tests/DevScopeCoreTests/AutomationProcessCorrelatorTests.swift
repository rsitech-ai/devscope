import XCTest
@testable import DevScopeCore

final class AutomationProcessCorrelatorTests: XCTestCase {
  func testExactExecutableAndArgumentsCreateVerifiedLink() {
    let links = AutomationProcessCorrelator.links(
      records: [Fixtures.userAgent],
      processes: [Fixtures.runningBackup],
      now: Date(timeIntervalSince1970: 10_000)
    )

    XCTAssertEqual(links.count, 1)
    XCTAssertEqual(links[0].strength, .strong)
    XCTAssertEqual(links[0].processIdentity.birthToken, Fixtures.runningBackup.birthToken)
    XCTAssertEqual(
      links[0].evidence.map(\.detail),
      ["Exact executable and arguments with direct PID 1 compatibility"]
    )
  }

  func testWeakResemblancePartialArgumentsAndNilBirthFailClosed() {
    let cases = [
      DevProcess(
        pid: 44, parentPID: 1, executable: "/tmp/backup-helper",
        command: "/tmp/backup-helper 14400",
        birthToken: ProcessBirthToken(seconds: 4, microseconds: 4)
      ),
      DevProcess(
        pid: 45, parentPID: 1, executable: "/bin/sleep",
        command: "/bin/sleep 144000",
        birthToken: ProcessBirthToken(seconds: 4, microseconds: 5)
      ),
      DevProcess(
        pid: 46, parentPID: 1, executable: "/bin/sleep",
        command: "/bin/sleep 14400"
      ),
    ]

    XCTAssertTrue(AutomationProcessCorrelator.links(
      records: [Fixtures.userAgent], processes: cases,
      now: Date(timeIntervalSince1970: 10_000)
    ).isEmpty)
  }

  func testExactExecutableFailsClosedWithoutExactArgumentVector() {
    let process = DevProcess(
      pid: 48, parentPID: 1, executable: "/bin/sleep",
      command: "/bin/sleep 14400", argumentVector: nil,
      birthToken: ProcessBirthToken(seconds: 4, microseconds: 8)
    )

    XCTAssertTrue(AutomationProcessCorrelator.links(
      records: [Fixtures.userAgent], processes: [process],
      now: Date(timeIntervalSince1970: 10_000)
    ).isEmpty)
  }

  func testExactExecutableAndArgumentsRejectManualNonLaunchAncestry() {
    let manuallyInvoked = DevProcess(
      pid: 54, parentPID: 9_001, executable: "/bin/sleep",
      command: "/bin/sleep 14400", argumentVector: ["/bin/sleep", "14400"],
      birthToken: ProcessBirthToken(seconds: 5, microseconds: 4)
    )

    XCTAssertTrue(AutomationProcessCorrelator.links(
      records: [Fixtures.userAgent], processes: [manuallyInvoked],
      now: Date(timeIntervalSince1970: 10_000)
    ).isEmpty)
  }

  func testExactLaunchLabelIsStrongerProvenanceThanDirectPIDOneParentage() {
    let exactLabel = DevProcess(
      pid: 55, parentPID: 9_002, executable: "/bin/sleep",
      command: "/bin/sleep 14400", argumentVector: ["/bin/sleep", "14400"],
      birthToken: ProcessBirthToken(seconds: 5, microseconds: 5),
      launchLabel: Fixtures.userAgent.label
    )

    let links = AutomationProcessCorrelator.links(
      records: [Fixtures.userAgent], processes: [exactLabel],
      now: Date(timeIntervalSince1970: 10_000)
    )

    XCTAssertEqual(links.map(\.processIdentity.pid), [55])
    XCTAssertEqual(links[0].evidence.map(\.detail), ["Exact executable, arguments, and launch label"])
  }

  func testMismatchedLaunchLabelRejectsEvenWithDirectPIDOneParentage() {
    let wrongLabel = DevProcess(
      pid: 56, parentPID: 1, executable: "/bin/sleep",
      command: "/bin/sleep 14400", argumentVector: ["/bin/sleep", "14400"],
      birthToken: ProcessBirthToken(seconds: 5, microseconds: 6),
      launchLabel: "com.example.different"
    )

    XCTAssertTrue(AutomationProcessCorrelator.links(
      records: [Fixtures.userAgent], processes: [wrongLabel],
      now: Date(timeIntervalSince1970: 10_000)
    ).isEmpty)
  }

  func testNilLaunchLabelDoesNotChooseBetweenIdenticalDefinitions() {
    let first = automationRecord(Fixtures.userAgent, label: "com.example.first")
    let second = automationRecord(Fixtures.userAgent, label: "com.example.second")

    let links = AutomationProcessCorrelator.links(
      records: [first, second],
      processes: [Fixtures.runningBackup],
      now: Date(timeIntervalSince1970: 10_000)
    )

    XCTAssertTrue(links.isEmpty)
  }

  func testExactLaunchLabelSelectsTheMatchingIdenticalDefinition() {
    let first = automationRecord(Fixtures.userAgent, label: "com.example.first")
    let second = automationRecord(Fixtures.userAgent, label: "com.example.second")
    let labeledProcess = DevProcess(
      pid: Fixtures.runningBackup.pid,
      parentPID: Fixtures.runningBackup.parentPID,
      executable: Fixtures.runningBackup.executable,
      command: Fixtures.runningBackup.command,
      argumentVector: Fixtures.runningBackup.argumentVector,
      birthToken: Fixtures.runningBackup.birthToken,
      launchLabel: second.label
    )

    let links = AutomationProcessCorrelator.links(
      records: [first, second],
      processes: [labeledProcess],
      now: Date(timeIntervalSince1970: 10_000)
    )

    XCTAssertEqual(links.map(\.recordID), [second.id])
  }

  func testEmptyRecordArgumentsRejectAnExactExecutableWithExtraArguments() {
    let definition = automationRecord(Fixtures.userAgent, arguments: [])
    let process = DevProcess(
      pid: 49, parentPID: 1, executable: "/bin/sleep",
      command: "/bin/sleep --unexpected",
      argumentVector: ["/bin/sleep", "--unexpected"],
      birthToken: ProcessBirthToken(seconds: 4, microseconds: 9)
    )

    XCTAssertTrue(AutomationProcessCorrelator.links(
      records: [definition], processes: [process],
      now: Date(timeIntervalSince1970: 10_000)
    ).isEmpty)
  }

  func testEmbeddedSpaceArgumentDoesNotMatchTwoKernelArguments() {
    let definition = automationRecord(
      Fixtures.userAgent, executable: "/opt/jobs/exact", arguments: ["folder name"]
    )
    let split = DevProcess(
      pid: 52, parentPID: 1, executable: "/opt/jobs/exact",
      command: "/opt/jobs/exact folder name",
      argumentVector: ["/opt/jobs/exact", "folder", "name"],
      birthToken: ProcessBirthToken(seconds: 5, microseconds: 2)
    )
    let exact = DevProcess(
      pid: 53, parentPID: 1, executable: "/opt/jobs/exact",
      command: "/opt/jobs/exact folder name",
      argumentVector: ["/opt/jobs/exact", "folder name"],
      birthToken: ProcessBirthToken(seconds: 5, microseconds: 3)
    )

    XCTAssertEqual(AutomationProcessCorrelator.links(
      records: [definition], processes: [split, exact],
      now: Date(timeIntervalSince1970: 10_000)
    ).map(\.processIdentity.pid), [53])
  }

  func testSingleQuotedBackslashRemainsLiteralDuringExactArgumentMatching() {
    let definition = automationRecord(
      Fixtures.userAgent,
      executable: "/opt/jobs/exact",
      arguments: ["folder\\name"]
    )
    let process = DevProcess(
      pid: 47, parentPID: 1, executable: "/opt/jobs/exact",
      command: "/opt/jobs/exact 'folder\\name'",
      argumentVector: ["/opt/jobs/exact", "folder\\name"],
      birthToken: ProcessBirthToken(seconds: 4, microseconds: 7)
    )

    XCTAssertEqual(AutomationProcessCorrelator.links(
      records: [definition], processes: [process],
      now: Date(timeIntervalSince1970: 10_000)
    ).map(\.processIdentity.pid), [47])
  }

  func testExactBundleIdentityLinksAndNameOrPathInferenceDoesNot() {
    let exact = DevProcess(
      pid: 50, parentPID: 1,
      executable: "/Applications/Owner.app/Contents/MacOS/Other",
      command: "/Applications/Owner.app/Contents/MacOS/Other",
      argumentVector: ["/Applications/Owner.app/Contents/MacOS/Other"],
      birthToken: ProcessBirthToken(seconds: 5, microseconds: 1),
      bundleIdentifier: "com.example.devscope-fixture-owner"
    )
    let inferredOnly = DevProcess(
      pid: 51, parentPID: 1,
      executable: "/Applications/com.example.devscope-fixture-owner.app/Contents/MacOS/Owner",
      command: "com.example.devscope-fixture-owner",
      birthToken: ProcessBirthToken(seconds: 5, microseconds: 2)
    )

    let links = AutomationProcessCorrelator.links(
      records: [automationRecord(Fixtures.userAgent, arguments: [])],
      processes: [exact, inferredOnly],
      now: Date(timeIntervalSince1970: 10_000)
    )

    XCTAssertEqual(links.map(\.processIdentity.pid), [50])
  }

  func testRecycledPIDProducesOnlyTheCurrentBirthIdentity() {
    let old = Fixtures.runningBackup
    let recycled = DevProcess(
      pid: old.pid, parentPID: old.parentPID, executable: old.executable,
      command: old.command, argumentVector: old.argumentVector,
      resourceUsage: old.resourceUsage,
      birthToken: ProcessBirthToken(seconds: 20_000, microseconds: 1)
    )

    let links = AutomationProcessCorrelator.links(
      records: [Fixtures.userAgent], processes: [recycled],
      now: Date(timeIntervalSince1970: 20_100)
    )

    XCTAssertEqual(links.map(\.processIdentity.birthToken), [recycled.birthToken])
  }

  func testDuplicatePIDRowsUseNewestBirthRegardlessOfInputOrder() {
    let old = Fixtures.runningBackup
    let newest = DevProcess(
      pid: old.pid, parentPID: 1, executable: "/bin/other", command: "/bin/other",
      argumentVector: ["/bin/other"],
      birthToken: ProcessBirthToken(seconds: 50_000, microseconds: 1)
    )

    XCTAssertTrue(AutomationProcessCorrelator.links(
      records: [Fixtures.userAgent], processes: [old, newest],
      now: Date(timeIntervalSince1970: 50_001)
    ).isEmpty)
    XCTAssertTrue(AutomationProcessCorrelator.links(
      records: [Fixtures.userAgent], processes: [newest, old],
      now: Date(timeIntervalSince1970: 50_001)
    ).isEmpty)
  }

  func testCronRequiresExactSignatureScheduleMinuteAndCronAncestry() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = date(2026, 7, 13, 10, 5, 30, calendar: calendar)
    let cron = cronRecord(signature: "/bin/sleep 60", expression: "5 10 * * *")
    let daemon = DevProcess(
      pid: 100, parentPID: 1, executable: "/usr/sbin/cron", command: "/usr/sbin/cron",
      argumentVector: ["/usr/sbin/cron"],
      birthToken: ProcessBirthToken(seconds: 1, microseconds: 1)
    )
    let shell = DevProcess(
      pid: 101, parentPID: 100, executable: "/bin/sh",
      command: "/bin/sh -c '/bin/sleep 60'",
      argumentVector: ["/bin/sh", "-c", "/bin/sleep 60"],
      resourceUsage: usage("00:00:30"),
      birthToken: ProcessBirthToken(seconds: 2, microseconds: 1)
    )
    let child = DevProcess(
      pid: 102, parentPID: 101, executable: "/bin/sleep", command: "/bin/sleep 60",
      argumentVector: ["/bin/sleep", "60"],
      resourceUsage: usage("00:00:25"),
      birthToken: ProcessBirthToken(seconds: 3, microseconds: 1)
    )

    let links = AutomationProcessCorrelator.links(
      records: [cron], processes: [daemon, shell, child], now: now, calendar: calendar
    )

    XCTAssertEqual(links.map(\.processIdentity.pid), [101])
    XCTAssertTrue(links.allSatisfy { $0.recordID == cron.id })
  }

  func testCronFailsClosedForWrongMinuteWrongAncestryAndReboot() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = date(2026, 7, 13, 10, 6, 30, calendar: calendar)
    let daemon = DevProcess(
      pid: 199, parentPID: 1, executable: "/usr/sbin/cron", command: "/usr/sbin/cron",
      argumentVector: ["/usr/sbin/cron"],
      birthToken: ProcessBirthToken(seconds: 4, microseconds: 0)
    )
    let shell = DevProcess(
      pid: 200, parentPID: 1, executable: "/bin/sh",
      command: "/bin/sh -c '/bin/sleep 60'",
      argumentVector: ["/bin/sh", "-c", "/bin/sleep 60"], resourceUsage: usage("00:00:30"),
      birthToken: ProcessBirthToken(seconds: 4, microseconds: 1)
    )

    XCTAssertTrue(AutomationProcessCorrelator.links(
      records: [cronRecord(signature: "/bin/sleep 60", expression: "5 10 * * *")],
      processes: [shell], now: now, calendar: calendar
    ).isEmpty)
    let wrongMinuteShell = DevProcess(
      pid: 201, parentPID: 199, executable: "/bin/sh",
      command: "/bin/sh -c '/bin/sleep 60'",
      argumentVector: ["/bin/sh", "-c", "/bin/sleep 60"], resourceUsage: usage("00:00:30"),
      birthToken: ProcessBirthToken(seconds: 4, microseconds: 2)
    )
    XCTAssertTrue(AutomationProcessCorrelator.links(
      records: [cronRecord(signature: "/bin/sleep 60", expression: "5 10 * * *")],
      processes: [daemon, wrongMinuteShell], now: now, calendar: calendar
    ).isEmpty)
    XCTAssertTrue(AutomationProcessCorrelator.links(
      records: [cronRecord(signature: "/bin/sleep 60", expression: "@reboot")],
      processes: [daemon, wrongMinuteShell], now: now, calendar: calendar
    ).isEmpty)
  }

  func testCronSignatureSubstringAndShellMetacharactersNeverMatch() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = date(2026, 7, 13, 10, 5, 30, calendar: calendar)
    let daemon = DevProcess(
      pid: 300, parentPID: 1, executable: "/usr/sbin/cron", command: "/usr/sbin/cron",
      argumentVector: ["/usr/sbin/cron"],
      birthToken: ProcessBirthToken(seconds: 5, microseconds: 0)
    )
    let shell = DevProcess(
      pid: 301, parentPID: 300, executable: "/bin/sh",
      command: "/bin/sh -c '/bin/sleep 600; echo unexpected'",
      argumentVector: ["/bin/sh", "-c", "/bin/sleep 600; echo unexpected"], resourceUsage: usage("00:00:30"),
      birthToken: ProcessBirthToken(seconds: 5, microseconds: 1)
    )

    XCTAssertTrue(AutomationProcessCorrelator.links(
      records: [cronRecord(signature: "/bin/sleep 60", expression: "5 10 * * *")],
      processes: [daemon, shell], now: now, calendar: calendar
    ).isEmpty)
  }

  func testCronRejectsDirectCommandTextWithoutExactShellCarrierArgv() {
    let calendar = utcCalendar()
    let now = date(2026, 7, 13, 10, 5, 30, calendar: calendar)
    let daemon = DevProcess(
      pid: 320, parentPID: 1, executable: "/usr/sbin/cron", command: "/usr/sbin/cron",
      argumentVector: ["/usr/sbin/cron"],
      birthToken: ProcessBirthToken(seconds: 5, microseconds: 0)
    )
    let shortcut = DevProcess(
      pid: 321, parentPID: 320, executable: "/bin/sleep", command: "/bin/sleep 60",
      argumentVector: ["/bin/sleep", "60"], resourceUsage: usage("00:00:30"),
      birthToken: ProcessBirthToken(seconds: 5, microseconds: 1)
    )

    XCTAssertTrue(AutomationProcessCorrelator.links(
      records: [cronRecord(signature: "/bin/sleep 60", expression: "5 10 * * *")],
      processes: [daemon, shortcut], now: now, calendar: calendar
    ).isEmpty)
  }

  func testCronCalendarRejectsMalformedListAndUsesWildcardOriginDOMDOWSemantics() {
    let calendar = utcCalendar()
    let monday = date(2026, 7, 13, 10, 5, 30, calendar: calendar)
    let daemon = cronDaemon()
    let carrier = cronCarrier(parentPID: daemon.pid, elapsed: "00:00:30")

    XCTAssertTrue(AutomationProcessCorrelator.links(
      records: [cronRecord(signature: "/bin/sleep 60", expression: "5,bad 10 * * *")],
      processes: [daemon, carrier], now: monday, calendar: calendar
    ).isEmpty)
    XCTAssertTrue(AutomationProcessCorrelator.links(
      records: [cronRecord(signature: "/bin/sleep 60", expression: "5 10 */2 * 2")],
      processes: [daemon, carrier], now: monday, calendar: calendar
    ).isEmpty)
    XCTAssertFalse(AutomationProcessCorrelator.links(
      records: [cronRecord(signature: "/bin/sleep 60", expression: "5 10 14 * 1")],
      processes: [daemon, carrier], now: monday, calendar: calendar
    ).isEmpty)
  }

  func testCronCalendarUsesInjectedTimezoneAtMinuteBoundary() {
    var warsaw = Calendar(identifier: .gregorian)
    warsaw.timeZone = TimeZone(identifier: "Europe/Warsaw")!
    let now = date(2026, 7, 13, 0, 0, 1, calendar: warsaw)
    let daemon = cronDaemon()
    let carrier = cronCarrier(parentPID: daemon.pid, elapsed: "00:00:01")

    XCTAssertEqual(AutomationProcessCorrelator.links(
      records: [cronRecord(signature: "/bin/sleep 60", expression: "0 0 * * *")],
      processes: [daemon, carrier], now: now, calendar: warsaw
    ).map(\.processIdentity.pid), [carrier.pid])
  }

  func testCronCalendarRejectsScalarAndNameStepBases() {
    let calendar = utcCalendar()
    let monday = date(2026, 7, 13, 10, 5, 30, calendar: calendar)
    let daemon = cronDaemon()
    let carrier = cronCarrier(parentPID: daemon.pid, elapsed: "00:00:30")

    for expression in ["5/10 10 * * *", "5 10 * * MON/2"] {
      XCTAssertTrue(AutomationProcessCorrelator.links(
        records: [cronRecord(signature: "/bin/sleep 60", expression: expression)],
        processes: [daemon, carrier], now: monday, calendar: calendar
      ).isEmpty, "Scalar step must fail closed: \(expression)")
    }
    XCTAssertEqual(AutomationProcessCorrelator.links(
      records: [cronRecord(signature: "/bin/sleep 60", expression: "5-15/10 10 * * MON-FRI/2")],
      processes: [daemon, carrier], now: monday, calendar: calendar
    ).map(\.processIdentity.pid), [carrier.pid])
  }

  func testIndexedCorrelationHandlesFiveHundredRecordsAndOneThousandProcesses() {
    let records = (0..<500).map { index in
      automationRecord(Fixtures.userAgent, executable: "/opt/jobs/job-\(index)", arguments: ["--exact", "\(index)"])
    }
    let processes = (0..<1_000).map { index in
      DevProcess(
        pid: Int32(10_000 + index), parentPID: 1,
        executable: "/opt/jobs/job-\(index)", command: "/opt/jobs/job-\(index) --exact \(index)",
        argumentVector: ["/opt/jobs/job-\(index)", "--exact", "\(index)"],
        birthToken: ProcessBirthToken(seconds: UInt64(index + 1), microseconds: 1)
      )
    }
    let start = Date()

    let links = AutomationProcessCorrelator.links(records: records, processes: processes, now: start)

    XCTAssertEqual(links.count, 500)
    XCTAssertLessThan(Date().timeIntervalSince(start), 2)
  }

  func testCompositeNonCronIndexBoundsSharedExecutableCandidateWork() {
    let records = (0..<500).map { index in
      automationRecord(Fixtures.userAgent, executable: "/opt/jobs/shared", arguments: ["--job", "\(index)"])
    }
    let processes = (0..<1_000).map { index in
      DevProcess(
        pid: Int32(20_000 + index), parentPID: 1,
        executable: "/opt/jobs/shared", command: "display text is not evidence",
        argumentVector: ["/opt/jobs/shared", "--job", "\(index)"],
        birthToken: ProcessBirthToken(seconds: UInt64(index + 1), microseconds: 2)
      )
    }
    var work = AutomationCorrelationWork()

    let links = AutomationProcessCorrelator.links(
      records: records, processes: processes,
      now: Date(timeIntervalSince1970: 30_000), work: &work
    )

    XCTAssertEqual(links.count, 500)
    XCTAssertEqual(work.indexedProcesses, 1_000)
    XCTAssertEqual(work.nonCronRecordLookups, 1_000)
    XCTAssertEqual(work.nonCronCandidateEvaluations, 500)
  }

  func testCompositeNonCronIndexReturnsEverySameKeyProcessDeterministically() {
    let first = DevProcess(
      pid: 401, parentPID: 1, executable: "/bin/sleep",
      command: "not evidence", argumentVector: ["/bin/sleep", "14400"],
      birthToken: ProcessBirthToken(seconds: 40, microseconds: 1)
    )
    let second = DevProcess(
      pid: 402, parentPID: 1, executable: "/bin/sleep",
      command: "also not evidence", argumentVector: ["/bin/sleep", "14400"],
      birthToken: ProcessBirthToken(seconds: 40, microseconds: 2)
    )

    let forward = AutomationProcessCorrelator.links(
      records: [Fixtures.userAgent], processes: [first, second],
      now: Date(timeIntervalSince1970: 50_000)
    )
    let reversed = AutomationProcessCorrelator.links(
      records: [Fixtures.userAgent], processes: [second, first],
      now: Date(timeIntervalSince1970: 50_000)
    )

    XCTAssertEqual(forward.map(\.processIdentity.pid), [401, 402])
    XCTAssertEqual(reversed, forward)
  }

  func testIndexedCronWorkIsBoundedForFiveHundredRecordsAndOneThousandProcesses() {
    let calendar = utcCalendar()
    let now = date(2026, 7, 13, 10, 5, 30, calendar: calendar)
    let records = (0..<500).map { index in
      cronRecord(signature: "/bin/job-\(index)", expression: "5 10 * * *")
    }
    let daemon = cronDaemon()
    let carriers = (0..<500).map { index in
      DevProcess(
        pid: Int32(1_000 + index), parentPID: daemon.pid,
        executable: "/bin/sh", command: "display text is not evidence",
        argumentVector: ["/bin/sh", "-c", "/bin/job-\(index)"],
        resourceUsage: usage("00:00:30"),
        birthToken: ProcessBirthToken(seconds: UInt64(100 + index), microseconds: 1)
      )
    }
    let noise = (0..<499).map { index in
      DevProcess(
        pid: Int32(2_000 + index), parentPID: 1,
        executable: "/bin/noise-\(index)", command: "/bin/noise-\(index)",
        argumentVector: ["/bin/noise-\(index)"],
        birthToken: ProcessBirthToken(seconds: UInt64(1_000 + index), microseconds: 1)
      )
    }
    var work = AutomationCorrelationWork()

    let links = AutomationProcessCorrelator.links(
      records: records, processes: [daemon] + carriers + noise,
      now: now, calendar: calendar, work: &work
    )

    XCTAssertEqual(links.count, 500)
    XCTAssertEqual(work.indexedProcesses, 1_000)
    XCTAssertEqual(work.cronRecordLookups, 500)
    XCTAssertEqual(work.cronCandidateEvaluations, 500)
    XCTAssertLessThanOrEqual(work.ancestrySteps, 2_000)
  }
}

private func automationRecord(
  _ source: AutomationRecord,
  label: String? = nil,
  executable: String? = nil,
  arguments: [String]? = nil
) -> AutomationRecord {
  let label = label ?? source.label
  return AutomationRecord(
    id: AutomationRecord.ID(
      source: source.sourceKind, ownerUID: source.ownerUID ?? 0,
      label: label, sourcePath: executable ?? source.sourceURL?.path ?? label
    ),
    kind: source.kind, sourceKind: source.sourceKind, label: label,
    displayName: source.displayName,
    providerBundleIdentifier: source.providerBundleIdentifier,
    ownerUID: source.ownerUID, ownership: source.ownership,
    executable: executable ?? source.executable,
    arguments: arguments ?? source.arguments,
    commandSignature: source.commandSignature,
    environment: source.environment, workingDirectory: source.workingDirectory,
    schedule: source.schedule, sourceURL: source.sourceURL,
    sourceChecksum: source.sourceChecksum, enabledState: source.enabledState,
    loadState: source.loadState, approvalState: source.approvalState, state: source.state,
    evidence: source.evidence, capabilities: source.capabilities,
    validationFindings: source.validationFindings
  )
}

private func cronRecord(signature: String, expression: String) -> AutomationRecord {
  AutomationRecord(
    id: AutomationRecord.ID(source: .crontab, ownerUID: 501, label: expression, sourcePath: "/cron/\(expression)"),
    kind: .cron, sourceKind: .crontab, label: "Cron", displayName: "Cron",
    providerBundleIdentifier: nil, ownerUID: 501, ownership: .user,
    executable: nil, arguments: [], commandSignature: signature,
    environment: [:], workingDirectory: nil,
    schedule: AutomationSchedule(triggers: [.cron(expression)], summary: expression),
    sourceURL: nil, sourceChecksum: nil, enabledState: .enabled, loadState: .unknown,
    approvalState: .notApplicable, state: .running, evidence: [], capabilities: [],
    validationFindings: []
  )
}

private func usage(_ elapsed: String) -> DevProcessResourceUsage {
  DevProcessResourceUsage(cpuPercent: 0, residentMemoryBytes: 0, elapsedTime: elapsed)
}

private func utcCalendar() -> Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  return calendar
}

private func cronDaemon() -> DevProcess {
  DevProcess(
    pid: 700, parentPID: 1, executable: "/usr/sbin/cron", command: "/usr/sbin/cron",
    argumentVector: ["/usr/sbin/cron"],
    birthToken: ProcessBirthToken(seconds: 7, microseconds: 0)
  )
}

private func cronCarrier(parentPID: Int32, elapsed: String) -> DevProcess {
  DevProcess(
    pid: 701, parentPID: parentPID, executable: "/bin/sh",
    command: "/bin/sh -c '/bin/sleep 60'",
    argumentVector: ["/bin/sh", "-c", "/bin/sleep 60"],
    resourceUsage: usage(elapsed),
    birthToken: ProcessBirthToken(seconds: 7, microseconds: 1)
  )
}

private func date(
  _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int,
  calendar: Calendar
) -> Date {
  calendar.date(from: DateComponents(
    year: year, month: month, day: day, hour: hour, minute: minute, second: second
  ))!
}
