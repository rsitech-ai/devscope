import DevScopeCore
import SwiftUI

struct ApplicationFamilyListView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let families: [ProcessApplicationFamily]
  @Binding var selection: Int32?
  @Binding var expandedFamilyIDs: Set<String>
  let displayName: (ClassifiedDevProcess) -> String

  var body: some View {
    ZStack {
      VStack(spacing: 0) {
        header

        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(families) { family in
              familySection(family)
            }
          }
        }
      }

      if families.isEmpty {
        ContentUnavailableView(
          "No matching applications",
          systemImage: "macwindow.on.rectangle",
          description: Text(
            "Try a different search or open an application with visible OS processes."
          )
        )
      }
    }
  }

  private var header: some View {
    HStack(spacing: 0) {
      Text("Application family")
        .frame(maxWidth: .infinity, alignment: .leading)
      Text("OS processes")
        .frame(width: 96, alignment: .trailing)
      Text("CPU")
        .frame(width: 76, alignment: .trailing)
      Text("Memory")
        .frame(width: 96, alignment: .trailing)
    }
    .font(.caption.weight(.semibold))
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.ultraThinMaterial)
    .overlay(alignment: .bottom) { Divider() }
  }

  @ViewBuilder
  private func familySection(_ family: ProcessApplicationFamily) -> some View {
    let isExpanded = expandedFamilyIDs.contains(family.id)

    Button {
      withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
        if isExpanded {
          expandedFamilyIDs.remove(family.id)
        } else {
          expandedFamilyIDs.insert(family.id)
        }
      }
    } label: {
      HStack(spacing: 0) {
        HStack(spacing: 10) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 12)

          Image(systemName: "macwindow.on.rectangle")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(DevScopePalette.accent)
            .frame(width: 28, height: 28)
            .background(
              DevScopePalette.accent.opacity(0.14),
              in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )

          VStack(alignment: .leading, spacing: 2) {
            Text(family.title)
              .font(.callout.weight(.semibold))
              .lineLimit(1)
            Text(roleSummary(family))
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Text("\(family.members.count)")
          .font(.callout.monospacedDigit().weight(.semibold))
          .frame(width: 96, alignment: .trailing)
        Text(ProcessMetricFormat.cpu(family.totalCPU))
          .font(.callout.monospacedDigit())
          .frame(width: 76, alignment: .trailing)
        Text(ProcessMetricFormat.memory(family.totalMemoryBytes))
          .font(.callout.monospacedDigit())
          .frame(width: 96, alignment: .trailing)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(family.title)
    .accessibilityValue(
      "\(family.members.count) OS processes, \(roleSummary(family)), \(isExpanded ? "expanded" : "collapsed")"
    )
    .accessibilityHint(isExpanded ? "Collapses this application family." : "Shows its OS processes.")
    .help(isExpanded ? "Hide application processes" : "Show application processes")

    if isExpanded {
      ForEach(family.members) { member in
        memberRow(member)
      }
      .transition(.opacity)
    }

    Divider()
  }

  private func memberRow(_ member: ApplicationProcessMember) -> some View {
    let item = member.item
    let isSelected = selection == item.process.pid

    return Button {
      selection = item.process.pid
    } label: {
      HStack(spacing: 0) {
        HStack(spacing: 8) {
          Color.clear
            .frame(width: CGFloat(min(member.depth, 8)) * 14)

          Image(systemName: member.role.symbolName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(roleColor(member.role))
            .frame(width: 18)

          VStack(alignment: .leading, spacing: 2) {
            Text(displayName(item))
              .font(.callout.weight(isSelected ? .semibold : .regular))
              .lineLimit(1)
            HStack(spacing: 6) {
              Label(member.role.title, systemImage: member.role.symbolName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(roleColor(member.role))
              Text("PID \(item.process.pid)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Text("")
          .frame(width: 96)
        Text(ProcessMetricFormat.cpu(item.process.resourceUsage?.cpuPercent))
          .font(.callout.monospacedDigit())
          .frame(width: 76, alignment: .trailing)
        Text(ProcessMetricFormat.memory(item.process.resourceUsage?.residentMemoryBytes))
          .font(.callout.monospacedDigit())
          .frame(width: 96, alignment: .trailing)
      }
      .padding(.leading, 24)
      .padding(.trailing, 12)
      .padding(.vertical, 6)
      .contentShape(Rectangle())
      .background(isSelected ? DevScopePalette.accent.opacity(0.18) : Color.clear)
      .overlay(alignment: .leading) {
        if isSelected {
          Rectangle()
            .fill(DevScopePalette.accent)
            .frame(width: 3)
        }
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(displayName(item)), \(member.role.title), PID \(item.process.pid)")
    .accessibilityValue(
      "\(ProcessMetricFormat.cpu(item.process.resourceUsage?.cpuPercent)), \(ProcessMetricFormat.memory(item.process.resourceUsage?.residentMemoryBytes))"
    )
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private func roleSummary(_ family: ProcessApplicationFamily) -> String {
    [
      countLabel(family.applicationCount, singular: "app", plural: "apps"),
      countLabel(family.helperCount, singular: "helper", plural: "helpers"),
      countLabel(family.workerCount, singular: "worker", plural: "workers"),
    ].joined(separator: " · ")
  }

  private func countLabel(_ count: Int, singular: String, plural: String) -> String {
    "\(count) \(count == 1 ? singular : plural)"
  }

  private func roleColor(_ role: ApplicationProcessRole) -> Color {
    switch role {
    case .application:
      DevScopePalette.accent
    case .helper:
      .secondary
    case .worker:
      .orange
    }
  }
}
