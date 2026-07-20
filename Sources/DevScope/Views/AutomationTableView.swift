import DevScopeCore
import SwiftUI

struct AutomationTableRow: Identifiable, Equatable, Sendable {
  let record: AutomationRecord
  let linkedProcessCount: Int

  var id: AutomationRecord.ID { record.id }
}

enum AutomationTableMetrics {
  static let automationColumnWidth: CGFloat = 220
  static let kindColumnWidth: CGFloat = 100
  static let triggerColumnWidth: CGFloat = 145
  static let stateColumnWidth: CGFloat = 90
  static let ownerColumnWidth: CGFloat = 90
  static let runsColumnWidth: CGFloat = 55
  static let horizontalPadding: CGFloat = 12
  static let contentWidth = automationColumnWidth
    + kindColumnWidth
    + triggerColumnWidth
    + stateColumnWidth
    + ownerColumnWidth
    + runsColumnWidth
    + (horizontalPadding * 2)
}

struct AutomationTableView: View {
  let rows: [AutomationTableRow]
  let sourceHealthHasFailure: Bool
  @Binding var selection: AutomationRecord.ID?
  @Binding var sort: AutomationTableSortState
  let iconStore: AutomationApplicationIconStore
  @Environment(\.controlActiveState) private var controlActiveState
  @FocusState private var isFocused: Bool
  @State private var hoveredID: AutomationRecord.ID?
  @State private var verticalScrollTargetID: AutomationRecord.ID?

  var body: some View {
    ZStack {
      ScrollView(.horizontal) {
        VStack(spacing: 0) {
          header

          ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
              ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                rowButton(row, index: index)
                  .id(row.id)
              }
            }
            .scrollTargetLayout()
          }
          .scrollPosition(id: $verticalScrollTargetID, anchor: .center)
        }
        .frame(
          minWidth: AutomationTableMetrics.contentWidth,
          maxWidth: .infinity,
          alignment: .topLeading
        )
      }

      if rows.isEmpty {
        ContentUnavailableView(
          sourceHealthHasFailure ? "Automation sources unavailable" : "No matching automations",
          systemImage: sourceHealthHasFailure ? "exclamationmark.triangle" : "gearshape.2",
          description: Text(sourceHealthHasFailure
            ? "Review the source-specific status above. Healthy sources remain available."
            : "Adjust search or filters. Idle definitions remain visible in this workspace.")
        )
      }
    }
    .focusable()
    .focused($isFocused)
    .focusEffectDisabled()
    .onKeyPress(.upArrow) {
      move(.previous)
      return .handled
    }
    .onKeyPress(.downArrow) {
      move(.next)
      return .handled
    }
  }

  private var header: some View {
    HStack(spacing: 0) {
      sortableHeader("Automation", column: .automation)
        .frame(width: AutomationTableMetrics.automationColumnWidth, alignment: .leading)
      sortableHeader("Kind", column: .kind)
        .frame(width: AutomationTableMetrics.kindColumnWidth, alignment: .leading)
      sortableHeader("Trigger", column: .trigger)
        .frame(width: AutomationTableMetrics.triggerColumnWidth, alignment: .leading)
      sortableHeader("State", column: .state)
        .frame(width: AutomationTableMetrics.stateColumnWidth, alignment: .leading)
      sortableHeader("Owner", column: .owner)
        .frame(width: AutomationTableMetrics.ownerColumnWidth, alignment: .leading)
      sortableHeader("Runs", column: .runs, contentAlignment: .trailing)
        .frame(width: AutomationTableMetrics.runsColumnWidth, alignment: .trailing)
    }
    .padding(.horizontal, AutomationTableMetrics.horizontalPadding)
    .padding(.vertical, 8)
    .background(.ultraThinMaterial)
    .overlay(alignment: .bottom) { Divider() }
  }

  private func rowButton(_ row: AutomationTableRow, index: Int) -> some View {
    Button {
      selection = row.id
      isFocused = true
    } label: {
      HStack(spacing: 0) {
        AutomationCell(record: row.record, iconStore: iconStore)
        .frame(width: AutomationTableMetrics.automationColumnWidth, alignment: .leading)
        Text(row.record.kind.displayTitle)
          .foregroundStyle(DevScopePalette.color(for: row.record.kind))
          .frame(width: AutomationTableMetrics.kindColumnWidth, alignment: .leading)
        Text(row.record.schedule.summary)
          .frame(width: AutomationTableMetrics.triggerColumnWidth, alignment: .leading)
        AutomationStateLabelView(state: row.record.state)
          .frame(width: AutomationTableMetrics.stateColumnWidth, alignment: .leading)
        Text(row.record.ownership.displayTitle)
          .frame(width: AutomationTableMetrics.ownerColumnWidth, alignment: .leading)
        Text("\(row.linkedProcessCount)")
          .monospacedDigit()
          .frame(width: AutomationTableMetrics.runsColumnWidth, alignment: .trailing)
      }
      .font(.callout)
      .padding(.horizontal, AutomationTableMetrics.horizontalPadding)
      .padding(.vertical, 4)
      .contentShape(Rectangle())
      .background(background(row.id, index: index))
      .overlay(alignment: .leading) {
        if selection == row.id {
          Rectangle().fill(DevScopePalette.accent).frame(width: 3)
        }
      }
      .foregroundStyle(.primary)
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      hoveredID = hovering ? row.id : (hoveredID == row.id ? nil : hoveredID)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(row.record.displayName), \(row.record.kind.displayTitle), \(row.record.state.displayTitle)")
    .accessibilityValue("\(row.linkedProcessCount) linked process\(row.linkedProcessCount == 1 ? "" : "es")")
    .accessibilityAddTraits(selection == row.id ? .isSelected : [])
  }

  private func background(_ id: AutomationRecord.ID, index: Int) -> Color {
    if selection == id {
      return DevScopePalette.accent.opacity(controlActiveState == .inactive ? 0.10 : 0.20)
    }
    if hoveredID == id { return Color.primary.opacity(0.055) }
    return index.isMultiple(of: 2) ? Color.white.opacity(0.025) : .clear
  }

  private func sortableHeader(
    _ title: String,
    column: AutomationTableSortColumn,
    contentAlignment: Alignment = .leading
  ) -> some View {
    SortableTableHeader(
      title: title,
      column: column,
      activeColumn: sort.column,
      direction: sort.direction,
      contentAlignment: contentAlignment,
      activate: { sort.activate($0) }
    )
  }

  private func move(_ direction: InterfaceSelectionDirection) {
    let ids = rows.map(\.id)
    guard !ids.isEmpty else { selection = nil; return }
    let index = selection.flatMap(ids.firstIndex(of:))
    let nextIndex: Int
    switch (direction, index) {
    case (.previous, nil): nextIndex = ids.count - 1
    case (.next, nil): nextIndex = 0
    case (.previous, let index?): nextIndex = max(0, index - 1)
    case (.next, let index?): nextIndex = min(ids.count - 1, index + 1)
    }
    let next = ids[nextIndex]
    selection = next
    verticalScrollTargetID = next
  }
}

private struct AutomationCell: View {
  let record: AutomationRecord
  let iconStore: AutomationApplicationIconStore

  var body: some View {
    HStack(spacing: 10) {
      AutomationIdentityView(record: record, store: iconStore, size: 28)

      VStack(alignment: .leading, spacing: 2) {
        Text(record.displayName)
          .font(.callout.weight(.semibold))
          .lineLimit(1)
          .truncationMode(.tail)
        Text(contextLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
    .padding(.vertical, 5)
  }

  private var contextLabel: String {
    guard let providerBundleIdentifier = record.providerBundleIdentifier else {
      return record.label
    }
    return "\(record.label) · \(providerBundleIdentifier)"
  }
}

private struct AutomationStateLabelView: View {
  let state: AutomationState

  var body: some View {
    let presentation = AutomationStateLabelPresentation(state: state)
    HStack(spacing: 4) {
      Image(systemName: presentation.symbolName)
      Text(presentation.title)
    }
    .foregroundStyle(presentation.colorToken.color)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(presentation.title)
  }
}
