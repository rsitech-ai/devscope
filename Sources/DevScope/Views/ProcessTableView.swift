import AppKit
import DevScopeCore
import SwiftUI

struct ProcessTableRow: Identifiable, Equatable, Sendable {
  let item: ClassifiedDevProcess
  let title: String
  let isFavorite: Bool
  let isWatched: Bool
  let automationBadges: [AutomationProcessBadge]
  let snapshotOrder: Int

  var id: Int32 { item.process.pid }
  var processName: String { title }
  var pid: Int32 { item.process.pid }
  var cpuPercent: Double { item.process.resourceUsage?.cpuPercent ?? 0 }
  var memoryBytes: Int64 { item.process.resourceUsage?.residentMemoryBytes ?? 0 }
  var elapsedTime: String { item.process.resourceUsage?.elapsedTime ?? "-" }
  var elapsedSeconds: Int64 { ProcessPresentation.elapsedSeconds(elapsedTime) }
  var command: String { item.process.command }
  var runtime: String { item.classification.kind.rawValue }
  var stableOrderKey: String {
    [
      String(format: "%08d", snapshotOrder),
      ProcessPresentation.projectName(for: item) ?? "",
      title,
      item.process.executableName,
      "\(item.process.pid)"
    ].joined(separator: "\u{1F}")
  }
}

struct ProcessTableView: View {
  let rows: [ProcessTableRow]
  let emptyTitle: String
  let emptyDescription: String
  @Binding var selection: Int32?
  @Binding var sort: ProcessTableSortState
  let copyCommand: (ClassifiedDevProcess) -> Void
  @Environment(\.controlActiveState) private var controlActiveState
  @State private var hoveredRowID: Int32?
  @State private var verticalScrollTargetID: Int32?
  @FocusState private var isTableFocused: Bool

  init(
    rows: [ProcessTableRow],
    emptyTitle: String = "No matching running items",
    emptyDescription: String = "Refresh after opening an app, starting a service, running a script, or launching a build watcher.",
    selection: Binding<Int32?>,
    sort: Binding<ProcessTableSortState>,
    copyCommand: @escaping (ClassifiedDevProcess) -> Void
  ) {
    self.rows = rows
    self.emptyTitle = emptyTitle
    self.emptyDescription = emptyDescription
    _selection = selection
    _sort = sort
    self.copyCommand = copyCommand
  }

  var body: some View {
    ZStack {
      ScrollView(.horizontal) {
        VStack(spacing: 0) {
          header

          ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
              ForEach(rows) { row in
                dataRow(for: row)
                  .id(row.id)
              }
            }
            .scrollTargetLayout()
          }
          .scrollPosition(id: $verticalScrollTargetID, anchor: .center)
        }
        .frame(minWidth: 920, maxWidth: .infinity, alignment: .topLeading)
      }

      if rows.isEmpty {
        ContentUnavailableView(
          emptyTitle,
          systemImage: emptySystemImage,
          description: Text(emptyDescription)
        )
      }
    }
    .focusable()
    .focused($isTableFocused)
    .focusEffectDisabled()
    .onKeyPress(.upArrow) {
      moveSelection(.previous)
      return .handled
    }
    .onKeyPress(.downArrow) {
      moveSelection(.next)
      return .handled
    }
  }

  private var header: some View {
    HStack(spacing: 0) {
      sortableHeader("Process", column: .process)
        .frame(width: 230, alignment: .leading)
      sortableHeader("PID", column: .pid)
        .frame(width: 76, alignment: .leading)
      sortableHeader("CPU", column: .cpu)
        .frame(width: 76, alignment: .leading)
      sortableHeader("Memory", column: .memory)
        .frame(width: 96, alignment: .leading)
      sortableHeader("Time", column: .time)
        .frame(width: 116, alignment: .leading)
      sortableHeader("Command", column: .command)
        .frame(width: 326, alignment: .leading)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.ultraThinMaterial)
    .overlay(alignment: .bottom) {
      Divider()
    }
  }

  private func dataRow(for row: ProcessTableRow) -> some View {
    Button {
      selection = row.id
      isTableFocused = true
    } label: {
      HStack(spacing: 0) {
        ProcessCell(row: row)
          .frame(width: 230, alignment: .leading)
        MonospaceValue("\(row.pid)")
          .frame(width: 76, alignment: .leading)
        MetricValue(ProcessMetricFormat.cpu(row.cpuPercent))
          .frame(width: 76, alignment: .leading)
        MetricValue(ProcessMetricFormat.memory(row.memoryBytes))
          .frame(width: 96, alignment: .leading)
        MonospaceValue(row.elapsedTime)
          .frame(width: 116, alignment: .leading)
        Text(row.command)
          .font(.callout)
          .lineLimit(1)
          .truncationMode(.middle)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .frame(width: 326, alignment: .leading)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 4)
      .contentShape(Rectangle())
      .background(rowBackground(for: row))
      .overlay(alignment: .leading) {
        if row.id == selection {
          Rectangle()
            .fill(DevScopePalette.accent)
            .frame(width: 3)
        }
      }
      .foregroundStyle(.primary)
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      hoveredRowID = hovering ? row.id : (hoveredRowID == row.id ? nil : hoveredRowID)
    }
    .contextMenu {
      processContextMenu(for: row.item)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(row.processName), \(row.runtime), PID \(row.pid)")
    .accessibilityValue("\(ProcessMetricFormat.cpu(row.cpuPercent)), \(ProcessMetricFormat.memory(row.memoryBytes))")
    .accessibilityAddTraits(row.id == selection ? .isSelected : [])
  }

  private func rowBackground(for row: ProcessTableRow) -> Color {
    if row.id == selection {
      return DevScopePalette.accent.opacity(controlActiveState == .inactive ? 0.10 : 0.20)
    }
    if row.id == hoveredRowID {
      return Color.primary.opacity(0.055)
    }
    return row.snapshotOrder.isMultiple(of: 2) ? Color.white.opacity(0.025) : Color.clear
  }

  private func moveSelection(_ direction: InterfaceSelectionDirection) {
    let nextSelection = InterfacePresentation.movedSelection(
      in: rows.map(\.id),
      current: selection,
      direction: direction
    )
    guard nextSelection != selection else {
      return
    }
    selection = nextSelection
    if let nextSelection {
      verticalScrollTargetID = nextSelection
    }
  }

  private func sortableHeader(_ title: String, column: ProcessTableSortColumn) -> some View {
    SortableTableHeader(
      title: title,
      column: column,
      activeColumn: sort.column,
      direction: sort.direction,
      activate: { sort.activate($0) }
    )
  }

  private var emptySystemImage: String {
    emptyTitle == "Process scanning blocked" ? "lock.shield" : "checkmark.seal"
  }

  @ViewBuilder
  private func processContextMenu(for item: ClassifiedDevProcess) -> some View {
    Button("Copy Command") {
      copyCommand(item)
    }

    Button("Copy PID") {
      copy("\(item.process.pid)")
    }

    if let currentDirectory = item.process.currentDirectory {
      Button("Open Folder") {
        NSWorkspace.shared.open(URL(fileURLWithPath: currentDirectory, isDirectory: true))
      }
    }
  }

  private func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }
}

private struct ProcessCell: View {
  let row: ProcessTableRow

  private var item: ClassifiedDevProcess { row.item }

  var body: some View {
    HStack(spacing: 10) {
      ZStack {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(DevScopePalette.color(for: item.classification.kind).opacity(0.16))
        Image(systemName: item.classification.kind.symbolName)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(DevScopePalette.color(for: item.classification.kind))
      }
      .frame(width: 28, height: 28)

      VStack(alignment: .leading, spacing: 2) {
        Text(row.title)
          .font(.callout.weight(.semibold))
          .lineLimit(1)
          .truncationMode(.tail)

        HStack(spacing: 5) {
          if row.isFavorite {
            Image(systemName: "star.fill")
              .foregroundStyle(.yellow)
              .help("Favorite")
          }

          if row.isWatched {
            Image(systemName: "eye.fill")
              .foregroundStyle(.cyan)
              .help("Watched")
          }

          Text(ProcessPresentation.contextLabel(for: item))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

          ForEach(item.classification.tags.prefix(2)) { tag in
            ProcessTagBadge(tag: tag)
          }
        }

        if !row.automationBadges.isEmpty {
          HStack(spacing: 5) {
            ForEach(Array(row.automationBadges.enumerated()), id: \.offset) { _, badge in
              AutomationProcessBadgeView(badge: badge)
            }
          }
        }
      }
    }
    .padding(.vertical, 5)
  }
}

private struct AutomationProcessBadgeView: View {
  let badge: AutomationProcessBadge

  var body: some View {
    Label(title, systemImage: symbolName)
      .font(.caption2.weight(.semibold))
      .lineLimit(1)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(tint.opacity(0.14), in: Capsule())
      .foregroundStyle(tint)
      .accessibilityLabel(accessibilityLabel)
      .help(accessibilityLabel)
  }

  private var title: String {
    switch badge {
    case .automated: "Automated"
    case .longRunning(let duration): "Long Running · \(duration)"
    }
  }

  private var symbolName: String {
    switch badge {
    case .automated: "gearshape.2"
    case .longRunning: "clock.badge.exclamationmark"
    }
  }

  private var tint: Color {
    switch badge {
    case .automated: DevScopePalette.accent
    case .longRunning: .orange
    }
  }

  private var accessibilityLabel: String {
    switch badge {
    case .automated: "Automated: linked to a verified automation definition"
    case .longRunning(let duration): "Long Running: crossed the configured threshold, running for \(duration)"
    }
  }
}

struct ProcessTagBadge: View {
  let tag: DevProcessTag

  var body: some View {
    Label(tag.title, systemImage: tag.symbolName)
      .font(.caption2.weight(.semibold))
      .labelStyle(.titleAndIcon)
      .lineLimit(1)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(DevScopePalette.accent.opacity(0.12), in: Capsule())
      .foregroundStyle(.secondary)
  }
}

private struct MetricValue: View {
  let value: String

  init(_ value: String) {
    self.value = value
  }

  var body: some View {
    Text(value)
      .font(.system(.callout, design: .monospaced))
      .foregroundStyle(.secondary)
      .contentTransition(.numericText())
      .lineLimit(1)
  }
}

private struct MonospaceValue: View {
  let value: String

  init(_ value: String) {
    self.value = value
  }

  var body: some View {
    Text(value)
      .font(.system(.callout, design: .monospaced))
      .foregroundStyle(.secondary)
      .textSelection(.enabled)
  }
}

enum ProcessMetricFormat {
  static func cpu(_ value: Double?) -> String {
    guard let value else {
      return "-"
    }

    return String(format: "%.1f%%", value)
  }

  static func gpu(_ value: Double?) -> String {
    guard let value else {
      return "Unavailable"
    }

    return String(format: "%.1f%%", value)
  }

  static func memory(_ bytes: Int64?) -> String {
    guard let bytes else {
      return "-"
    }

    let megabytes = Double(bytes) / 1_048_576
    if megabytes < 1024 {
      return String(format: "%.0f MB", megabytes)
    }

    return String(format: "%.1f GB", megabytes / 1024)
  }
}
