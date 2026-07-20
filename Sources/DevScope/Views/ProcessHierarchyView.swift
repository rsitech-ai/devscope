import DevScopeCore
import SwiftUI

struct ProcessHierarchyView: View {
  let nodes: [ProcessHierarchyNode]
  @Binding var selection: Int32?
  let displayName: (ClassifiedDevProcess) -> String

  var body: some View {
    ZStack {
      List(selection: $selection) {
        OutlineGroup(nodes, children: \.outlineChildren) { node in
          hierarchyRow(node)
            .tag(node.id)
        }
      }
      .listStyle(.inset)

      if nodes.isEmpty {
        ContentUnavailableView(
          "No matching hierarchy",
          systemImage: "point.3.connected.trianglepath.dotted",
          description: Text("Try a different search or refresh the process snapshot.")
        )
      }
    }
  }

  private func hierarchyRow(_ node: ProcessHierarchyNode) -> some View {
    let item = node.item

    return HStack(spacing: 10) {
      Image(systemName: item.classification.kind.symbolName)
        .font(.caption.weight(.semibold))
        .foregroundStyle(DevScopePalette.color(for: item.classification.kind))
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 2) {
        Text(displayName(item))
          .font(.callout)
          .lineLimit(1)
        HStack(spacing: 8) {
          Text("PID \(item.process.pid)")
          Text("PPID \(item.process.parentPID)")
          if !node.children.isEmpty {
            Text("\(node.children.count) child\(node.children.count == 1 ? "" : "ren")")
          }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      }

      Spacer(minLength: 12)

      Text(ProcessMetricFormat.cpu(item.process.resourceUsage?.cpuPercent))
        .font(.callout.monospacedDigit())
        .frame(width: 76, alignment: .trailing)
      Text(ProcessMetricFormat.memory(item.process.resourceUsage?.residentMemoryBytes))
        .font(.callout.monospacedDigit())
        .frame(width: 96, alignment: .trailing)
    }
    .padding(.vertical, 3)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(displayName(item)), PID \(item.process.pid)")
    .accessibilityValue(
      "\(node.children.count) direct children, \(ProcessMetricFormat.cpu(item.process.resourceUsage?.cpuPercent)), \(ProcessMetricFormat.memory(item.process.resourceUsage?.residentMemoryBytes))"
    )
  }
}
