import DevScopeCore
import XCTest
@testable import DevScope

final class TableSortStateTests: XCTestCase {
  func testAutomationRunsStartsDescendingAndNameStartsAscending() {
    var state = AutomationTableSortState()
    state.activate(.runs)
    XCTAssertEqual(state.direction, .descending)
    state.activate(.automation)
    XCTAssertEqual(state.direction, .ascending)
  }

  func testAutomationStateSortUsesSemanticRank() {
    let rows = [
      makeAutomationRow(id: "unresolved", state: .unresolved),
      makeAutomationRow(id: "disabled", state: .disabled),
      makeAutomationRow(id: "idle", state: .idle),
      makeAutomationRow(id: "invalid", state: .invalid),
      makeAutomationRow(id: "running", state: .running),
      makeAutomationRow(id: "needs-approval", state: .needsApproval)
    ]

    XCTAssertEqual(
      AutomationTableSortState(column: .state, direction: .ascending)
        .sorted(rows).map(\.record.state),
      [.running, .idle, .needsApproval, .disabled, .invalid, .unresolved]
    )
  }

  func testAutomationRunsSortsDescendingByLinkedProcessCount() {
    let rows = [
      makeAutomationRow(id: "none", linkedProcessCount: 0),
      makeAutomationRow(id: "many", linkedProcessCount: 5),
      makeAutomationRow(id: "some", linkedProcessCount: 2)
    ]

    XCTAssertEqual(
      AutomationTableSortState(column: .runs, direction: .descending)
        .sorted(rows).map(\.linkedProcessCount),
      [5, 2, 0]
    )
  }

  func testAutomationTextColumnsSortByPresentedText() {
    let rows = [
      makeAutomationRow(id: "two", displayName: "Zulu", trigger: "At login"),
      makeAutomationRow(id: "one", displayName: "Alpha", trigger: "Weekly")
    ]

    XCTAssertEqual(
      AutomationTableSortState(column: .automation, direction: .ascending)
        .sorted(rows).map(\.id.rawValue),
      ["one", "two"]
    )
    XCTAssertEqual(
      AutomationTableSortState(column: .trigger, direction: .ascending)
        .sorted(rows).map(\.id.rawValue),
      ["two", "one"]
    )
  }

  func testAutomationKindAndOwnerSortUseSemanticRanks() {
    let kindRows = [
      makeAutomationRow(id: "a", kind: .cron),
      makeAutomationRow(id: "b", kind: .backgroundItem),
      makeAutomationRow(id: "c", kind: .loginItem),
      makeAutomationRow(id: "d", kind: .launchDaemon),
      makeAutomationRow(id: "e", kind: .launchAgent)
    ]
    let ownerRows = [
      makeAutomationRow(id: "a", ownership: .appleSystem),
      makeAutomationRow(id: "b", ownership: .managed),
      makeAutomationRow(id: "c", ownership: .thirdPartySystem),
      makeAutomationRow(id: "d", ownership: .user)
    ]

    XCTAssertEqual(
      AutomationTableSortState(column: .kind, direction: .ascending)
        .sorted(kindRows).map(\.record.kind),
      [.launchAgent, .launchDaemon, .loginItem, .backgroundItem, .cron]
    )
    XCTAssertEqual(
      AutomationTableSortState(column: .owner, direction: .ascending)
        .sorted(ownerRows).map(\.record.ownership),
      [.user, .thirdPartySystem, .managed, .appleSystem]
    )
  }

  func testAutomationSortPreservesIdentityAndUsesRecordIDForTies() {
    let rows = [
      makeAutomationRow(id: "c", linkedProcessCount: 1),
      makeAutomationRow(id: "a", linkedProcessCount: 1),
      makeAutomationRow(id: "b", linkedProcessCount: 1)
    ]
    let sorted = AutomationTableSortState(column: .runs, direction: .descending).sorted(rows)
    let selectedID = AutomationRecord.ID(rawValue: "b")

    XCTAssertEqual(AutomationTableSortState().sorted(rows).map(\.id.rawValue), ["c", "a", "b"])
    XCTAssertEqual(sorted.map(\.id.rawValue), ["a", "b", "c"])
    XCTAssertEqual(Set(sorted.map(\.id)), Set(rows.map(\.id)))
    XCTAssertEqual(
      AutomationPresentation.resolvedSelection(current: selectedID, visibleIDs: sorted.map(\.id)),
      selectedID
    )
  }

  func testProcessSortStartsInSnapshotOrderWithoutAnActiveHeader() {
    let state = ProcessTableSortState()
    XCTAssertNil(state.column)
    XCTAssertEqual(state.direction, .ascending)
  }

  func testDefaultComparatorsPreserveSnapshotOrder() {
    let rows = [
      processRow(pid: 30, snapshotOrder: 2),
      processRow(pid: 10, snapshotOrder: 0),
      processRow(pid: 20, snapshotOrder: 1)
    ]

    XCTAssertEqual(sortedRows(rows, using: ProcessTableSortState()).map(\.pid), [10, 20, 30])
  }

  func testFirstActivationSortsEveryProcessColumnInItsSemanticDefaultDirection() {
    let rows = processSortingRows()
    let expectations: [(ProcessTableSortColumn, [Int])] = [
      (.process, [0, 1, 2]),
      (.pid, [0, 2, 1]),
      (.cpu, [1, 0, 2]),
      (.memory, [1, 2, 0]),
      (.time, [2, 0, 1]),
      (.command, [2, 1, 0])
    ]

    for (column, expectedSnapshotOrder) in expectations {
      var state = ProcessTableSortState()
      state.activate(column)

      XCTAssertEqual(
        sortedRows(rows, using: state).map(\.snapshotOrder),
        expectedSnapshotOrder,
        "Unexpected first-activation order for \(column)"
      )
    }
  }

  func testRepeatActivationReversesActualRowOrder() {
    let rows = processSortingRows()
    var state = ProcessTableSortState()
    state.activate(.memory)
    let firstOrder = sortedRows(rows, using: state).map(\.snapshotOrder)

    state.activate(.memory)

    XCTAssertEqual(
      sortedRows(rows, using: state).map(\.snapshotOrder),
      Array(firstOrder.reversed())
    )
  }

  func testEqualPrimaryValuesUseDeterministicStableTieOrder() {
    let rows = [
      processRow(pid: 30, memory: 100, snapshotOrder: 2),
      processRow(pid: 10, memory: 100, snapshotOrder: 0),
      processRow(pid: 20, memory: 100, snapshotOrder: 1)
    ]
    var state = ProcessTableSortState()
    state.activate(.memory)

    XCTAssertEqual(sortedRows(rows, using: state).map(\.pid), [10, 20, 30])
  }

  func testProcessMetricSortStartsDescendingAndReverses() {
    var state = ProcessTableSortState()
    state.activate(.cpu)
    XCTAssertEqual(state.column, .cpu)
    XCTAssertEqual(state.direction, .descending)
    state.activate(.cpu)
    XCTAssertEqual(state.direction, .ascending)
  }

  func testProcessTextSortStartsAscendingWhenChangingColumns() {
    var state = ProcessTableSortState(column: .memory, direction: .ascending)
    state.activate(.process)
    XCTAssertEqual(state.column, .process)
    XCTAssertEqual(state.direction, .ascending)
  }
}

private func makeAutomationRow(
  id: String,
  displayName: String? = nil,
  kind: AutomationKind = .launchAgent,
  state: AutomationState = .idle,
  ownership: AutomationOwnership = .user,
  trigger: String = "On demand",
  linkedProcessCount: Int = 0
) -> AutomationTableRow {
  let record = AutomationRecord(
    id: .init(rawValue: id),
    kind: kind,
    sourceKind: kind == .cron ? .crontab : .launchAgent,
    label: id,
    displayName: displayName ?? id,
    providerBundleIdentifier: nil,
    ownerUID: 501,
    ownership: ownership,
    executable: "/bin/true",
    arguments: [],
    environment: [:],
    workingDirectory: nil,
    schedule: .init(triggers: [.demand], summary: trigger),
    sourceURL: URL(fileURLWithPath: "/tmp/\(id).plist"),
    sourceChecksum: nil,
    enabledState: .enabled,
    loadState: .unknown,
    approvalState: .notApplicable,
    state: state,
    evidence: [],
    capabilities: [],
    validationFindings: []
  )
  return AutomationTableRow(record: record, linkedProcessCount: linkedProcessCount)
}

private func processSortingRows() -> [ProcessTableRow] {
  [
    processRow(
      pid: 10,
      title: "Alpha",
      cpu: 20,
      memory: 100,
      elapsedTime: "00:00:20",
      command: "charlie",
      snapshotOrder: 0
    ),
    processRow(
      pid: 30,
      title: "Beta",
      cpu: 30,
      memory: 300,
      elapsedTime: "00:00:10",
      command: "bravo",
      snapshotOrder: 1
    ),
    processRow(
      pid: 20,
      title: "Charlie",
      cpu: 10,
      memory: 200,
      elapsedTime: "00:00:30",
      command: "alpha",
      snapshotOrder: 2
    )
  ]
}

private func processRow(
  pid: Int32,
  title: String = "Process",
  cpu: Double = 0,
  memory: Int64 = 0,
  elapsedTime: String = "00:00:00",
  command: String = "command",
  snapshotOrder: Int
) -> ProcessTableRow {
  ProcessTableRow(
    item: ClassifiedDevProcess(
      process: DevProcess(
        pid: pid,
        parentPID: 1,
        executable: title,
        command: command,
        resourceUsage: DevProcessResourceUsage(
          cpuPercent: cpu,
          residentMemoryBytes: memory,
          elapsedTime: elapsedTime
        )
      ),
      classification: DevProcessClassification(
        kind: .javascript,
        displayName: title,
        projectHint: nil
      )
    ),
    title: title,
    isFavorite: false,
    isWatched: false,
    automationBadges: [],
    snapshotOrder: snapshotOrder
  )
}

private func sortedRows(
  _ rows: [ProcessTableRow],
  using state: ProcessTableSortState
) -> [ProcessTableRow] {
  rows.sorted(using: state.comparators + [
    KeyPathComparator(\ProcessTableRow.stableOrderKey, order: .forward)
  ])
}
