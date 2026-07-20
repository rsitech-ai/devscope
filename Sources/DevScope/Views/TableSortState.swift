import DevScopeCore
import Foundation

enum TableSortDirection: Equatable, Sendable {
  case ascending
  case descending

  var sortOrder: SortOrder { self == .ascending ? .forward : .reverse }
  var symbolName: String { self == .ascending ? "chevron.up" : "chevron.down" }
  var accessibilityTitle: String { self == .ascending ? "ascending" : "descending" }
}

enum ProcessTableSortColumn: CaseIterable, Equatable, Hashable, Sendable {
  case process, pid, cpu, memory, time, command

  var defaultDirection: TableSortDirection {
    switch self {
    case .cpu, .memory, .time: .descending
    case .process, .pid, .command: .ascending
    }
  }
}

struct ProcessTableSortState: Equatable, Sendable {
  var column: ProcessTableSortColumn?
  var direction: TableSortDirection

  init(column: ProcessTableSortColumn? = nil, direction: TableSortDirection = .ascending) {
    self.column = column
    self.direction = direction
  }

  mutating func activate(_ selected: ProcessTableSortColumn) {
    if column == selected {
      direction = direction == .ascending ? .descending : .ascending
    } else {
      column = selected
      direction = selected.defaultDirection
    }
  }

  var comparators: [KeyPathComparator<ProcessTableRow>] {
    guard let column else {
      return [KeyPathComparator(\ProcessTableRow.snapshotOrder, order: .forward)]
    }
    let order = direction.sortOrder
    switch column {
    case .process: return [KeyPathComparator(\ProcessTableRow.processName, order: order)]
    case .pid: return [KeyPathComparator(\ProcessTableRow.pid, order: order)]
    case .cpu: return [KeyPathComparator(\ProcessTableRow.cpuPercent, order: order)]
    case .memory: return [KeyPathComparator(\ProcessTableRow.memoryBytes, order: order)]
    case .time: return [KeyPathComparator(\ProcessTableRow.elapsedSeconds, order: order)]
    case .command: return [KeyPathComparator(\ProcessTableRow.command, order: order)]
    }
  }
}

enum AutomationTableSortColumn: CaseIterable, Equatable, Hashable, Sendable {
  case automation, kind, trigger, state, owner, runs

  var defaultDirection: TableSortDirection {
    self == .runs ? .descending : .ascending
  }
}

struct AutomationTableSortState: Equatable, Sendable {
  var column: AutomationTableSortColumn? = nil
  var direction: TableSortDirection = .ascending

  mutating func activate(_ selected: AutomationTableSortColumn) {
    if column == selected {
      direction = direction == .ascending ? .descending : .ascending
    } else {
      column = selected
      direction = selected.defaultDirection
    }
  }

  func sorted(_ rows: [AutomationTableRow]) -> [AutomationTableRow] {
    guard let column else { return rows }
    return rows.sorted { lhs, rhs in
      let comparison = compare(lhs, rhs, column: column)
      if comparison == .orderedSame {
        return lhs.id.rawValue < rhs.id.rawValue
      }
      return direction == .ascending
        ? comparison == .orderedAscending
        : comparison == .orderedDescending
    }
  }

  private func compare(
    _ lhs: AutomationTableRow,
    _ rhs: AutomationTableRow,
    column: AutomationTableSortColumn
  ) -> ComparisonResult {
    switch column {
    case .automation:
      return compareText(
        "\(lhs.record.displayName)\u{1F}\(lhs.record.label)",
        "\(rhs.record.displayName)\u{1F}\(rhs.record.label)"
      )
    case .trigger:
      return compareText(lhs.record.schedule.summary, rhs.record.schedule.summary)
    case .kind:
      return compareInteger(kindRank(lhs.record.kind), kindRank(rhs.record.kind))
    case .state:
      return compareInteger(stateRank(lhs.record.state), stateRank(rhs.record.state))
    case .owner:
      return compareInteger(
        ownershipRank(lhs.record.ownership),
        ownershipRank(rhs.record.ownership)
      )
    case .runs:
      return compareInteger(lhs.linkedProcessCount, rhs.linkedProcessCount)
    }
  }

  private func compareText(_ lhs: String, _ rhs: String) -> ComparisonResult {
    lhs.localizedStandardCompare(rhs)
  }

  private func compareInteger(_ lhs: Int, _ rhs: Int) -> ComparisonResult {
    lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
  }

  private func kindRank(_ kind: AutomationKind) -> Int {
    switch kind {
    case .launchAgent: 0
    case .launchDaemon: 1
    case .loginItem: 2
    case .backgroundItem: 3
    case .cron: 4
    }
  }

  private func stateRank(_ state: AutomationState) -> Int {
    switch state {
    case .running: 0
    case .idle: 1
    case .needsApproval: 2
    case .disabled: 3
    case .invalid: 4
    case .unresolved: 5
    }
  }

  private func ownershipRank(_ ownership: AutomationOwnership) -> Int {
    switch ownership {
    case .user: 0
    case .thirdPartySystem: 1
    case .managed: 2
    case .appleSystem: 3
    }
  }
}
