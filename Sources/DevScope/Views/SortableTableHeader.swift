import SwiftUI

struct SortableTableHeader<Column: Hashable>: View {
  let title: String
  let column: Column
  let activeColumn: Column?
  let direction: TableSortDirection
  let contentAlignment: Alignment
  let activate: (Column) -> Void

  init(
    title: String,
    column: Column,
    activeColumn: Column?,
    direction: TableSortDirection,
    contentAlignment: Alignment = .leading,
    activate: @escaping (Column) -> Void
  ) {
    self.title = title
    self.column = column
    self.activeColumn = activeColumn
    self.direction = direction
    self.contentAlignment = contentAlignment
    self.activate = activate
  }

  var body: some View {
    Button { activate(column) } label: {
      HStack(spacing: 4) {
        Text(title).font(.caption.weight(.semibold))
        if activeColumn == column {
          Image(systemName: direction.symbolName).font(.caption2.weight(.bold))
        }
      }
      .frame(maxWidth: .infinity, alignment: contentAlignment)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityValue(activeColumn == column ? "Sorted \(direction.accessibilityTitle)" : "Not sorted")
    .help(activeColumn == column
      ? "Sort by \(title) \(direction == .ascending ? "descending" : "ascending")"
      : "Sort by \(title)")
  }
}
