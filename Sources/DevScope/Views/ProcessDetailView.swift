import AppKit
import DevScopeCore
import SwiftUI

struct ProcessDetailView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let process: ClassifiedDevProcess?
  let displayName: String?
  let metricHistory: [DevProcessMetricSample]
  let familySummary: ProcessFamilySummary?
  let showsMetricHistory: Bool
  let isEnded: Bool
  let isFavorite: Bool
  let isWatched: Bool
  let workflow: DevWorkflow?
  let processInsight: DevProcessInsight?
  let workflowNote: String?
  let automationLink: AutomationProcessLink?
  let automationRecord: AutomationRecord?
  let showInAutomations: (AutomationRecord.ID) -> Void

  var body: some View {
    Group {
      if let process {
        VStack(spacing: 0) {
          VStack(alignment: .leading, spacing: 12) {
            DetailHeader(process: process, title: displayName ?? process.classification.displayName)

            if let processInsight {
              ProcessSafetySummary(insight: processInsight)
            }

            if isEnded {
              Label(
                "This process ended. Last known details are retained for review.",
                systemImage: "checkmark.circle"
              )
              .font(.callout.weight(.medium))
              .foregroundStyle(.secondary)
              .padding(10)
              .frame(maxWidth: .infinity, alignment: .leading)
              .softPanel(cornerRadius: 10)
            }
          }
          .padding(16)

          Divider()

          ScrollView {
            VStack(alignment: .leading, spacing: 16) {
              DetailSection(title: "Status", systemImage: "checklist") {
                DetailGrid {
                  DetailChip(label: "State", value: isEnded ? "Ended" : "Live")
                  DetailChip(label: "Favorite", value: isFavorite ? "Yes" : "No")
                  DetailChip(label: "Watched", value: isWatched ? "Yes" : "No")
                  DetailChip(label: "PID", value: "\(process.process.pid)")
                  DetailChip(label: "PPID", value: "\(process.process.parentPID)")
                  if let familySummary {
                    DetailChip(label: "Children", value: "\(familySummary.childCount)")
                    DetailChip(label: "Tree", value: "\(familySummary.descendantCount)")
                  }
                }
              }

              DetailSection(title: "Resources", systemImage: "gauge.with.dots.needle.67percent") {
                DetailGrid {
                  DetailChip(
                    label: "CPU",
                    value: ProcessMetricFormat.cpu(process.process.resourceUsage?.cpuPercent))
                  DetailChip(label: "CPU Avg", value: ProcessMetricFormat.cpu(averageCPU))
                  DetailChip(label: "CPU Peak", value: ProcessMetricFormat.cpu(peakCPU))
                  DetailChip(
                    label: "Memory",
                    value: ProcessMetricFormat.memory(
                      process.process.resourceUsage?.residentMemoryBytes))
                  DetailChip(label: "Mem Avg", value: ProcessMetricFormat.memory(averageMemory))
                  DetailChip(label: "Mem Peak", value: ProcessMetricFormat.memory(peakMemory))
                  DetailChip(label: "GPU", value: ProcessMetricFormat.gpu(latestGPU))
                  DetailChip(
                    label: "Running", value: process.process.resourceUsage?.elapsedTime ?? "-")
                  DetailChip(label: "Samples", value: "\(metricHistory.count)")
                }
              }

              if !process.classification.tags.isEmpty {
                DetailSection(title: "Tags", systemImage: "tag") {
                  FlowTagList(tags: process.classification.tags)
                }
              }

              if let workflow {
                WorkflowContextCard(
                  workflow: workflow,
                  workflowNote: workflowNote
                )
              }

              if let automationLink, let automationRecord {
                DetailSection(title: "Automation", systemImage: "gearshape.2") {
                  DetailGrid {
                    DetailChip(label: "Definition", value: automationRecord.label)
                    DetailChip(label: "Source", value: automationRecord.sourceKind.displayTitle)
                    DetailChip(label: "Trigger", value: automationRecord.schedule.summary)
                    DetailChip(label: "Evidence", value: automationLink.strength == .strong ? "Strong" : "Weak")
                  }
                  ForEach(automationLink.evidence, id: \.self) { evidence in
                    Text("\(evidence.source): \(evidence.detail)")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .fixedSize(horizontal: false, vertical: true)
                  }
                  Button("Show in Automations") {
                    showInAutomations(automationRecord.id)
                  }
                  .buttonStyle(.borderedProminent)
                  .accessibilityHint("Switches workspace mode and selects this exact automation definition.")
                  .help("Show this definition in Automations")
                }
              }

              if showsMetricHistory {
                ProcessMetricHistoryView(samples: metricHistory)
              }

              Divider()

              DetailSection(title: "Identity", systemImage: "person.text.rectangle") {
                DetailGrid {
                  DetailChip(label: "Kind", value: process.classification.kind.rawValue)
                  DetailChip(
                    label: "Name", value: displayName ?? process.classification.displayName)
                  DetailChip(
                    label: "Executable",
                    value: URL(fileURLWithPath: ProcessPresentation.executablePath(for: process))
                      .lastPathComponent)
                  DetailChip(
                    label: "Project",
                    value: ProcessPresentation.projectName(for: process) ?? "Unknown")
                }

                DetailField(
                  label: "Executable Path", value: ProcessPresentation.executablePath(for: process))
                DetailField(
                  label: "Current Directory", value: process.process.currentDirectory ?? "Unknown")
              }

              DetailSection(title: "Command", systemImage: "terminal") {
                DetailGrid {
                  DetailChip(label: "Arguments", value: "\(commandArguments.count)")
                  DetailChip(label: "Length", value: "\(process.process.command.count) chars")
                  DetailChip(
                    label: "Redacted",
                    value: redactedCommand == process.process.command ? "No" : "Yes")
                }

                DetailField(label: "Command", value: process.process.command, lineLimit: 10)
                DetailField(label: "Redacted Command", value: redactedCommand, lineLimit: 8)

                if !commandArguments.isEmpty {
                  ArgumentTokenList(arguments: commandArguments)
                }
              }
            }
            .padding(16)
          }
        }
        .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.985)))
      } else {
        EmptyProcessInspector()
      }
    }
  }

  private var redactedCommand: String {
    guard let process else {
      return ""
    }

    return ProcessPresentation.redactedCommand(process.process.command)
  }

  private var commandArguments: [String] {
    guard let process else {
      return []
    }

    return process.process.command
      .split(whereSeparator: { $0.isWhitespace })
      .dropFirst()
      .map(String.init)
  }

  private var latestGPU: Double? {
    metricHistory.last { $0.gpuPercent != nil }?.gpuPercent
  }

  private var averageCPU: Double? {
    average(metricHistory.map(\.cpuPercent))
  }

  private var peakCPU: Double? {
    metricHistory.map(\.cpuPercent).max()
  }

  private var averageMemory: Int64? {
    let values = metricHistory.map(\.residentMemoryBytes)
    guard !values.isEmpty else {
      return nil
    }

    return values.reduce(Int64(0), +) / Int64(values.count)
  }

  private var peakMemory: Int64? {
    metricHistory.map(\.residentMemoryBytes).max()
  }

  private func average(_ values: [Double]) -> Double? {
    guard !values.isEmpty else {
      return nil
    }

    return values.reduce(0, +) / Double(values.count)
  }
}

private struct EmptyProcessInspector: View {
  var body: some View {
    VStack(spacing: 16) {
      Spacer(minLength: 24)

      Image(systemName: "cursorarrow.rays")
        .font(.system(size: 38, weight: .medium))
        .foregroundStyle(.tertiary)
        .frame(width: 68, height: 68)
        .softPanel(cornerRadius: 16)

      VStack(spacing: 6) {
        Text("Select a process")
          .font(.title3.weight(.semibold))
          .lineLimit(1)
        Text(
          "Choose any row to inspect identity, command, resources, process tree, workflow context, and safe actions."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 300)
      }

      VStack(alignment: .leading, spacing: 8) {
        EmptyInspectorLine(
          symbolName: "gauge.with.dots.needle.67percent", title: "Resources",
          detail: "CPU, memory, GPU sample, peaks, averages, and sample count")
        EmptyInspectorLine(
          symbolName: "point.3.connected.trianglepath.dotted", title: "Tree",
          detail: "Parent, children, and retained ended-process state")
        EmptyInspectorLine(
          symbolName: "terminal", title: "Command",
          detail: "Full command, redacted command, argument count, and copyable fields")
      }
      .padding(14)
      .frame(maxWidth: 340, alignment: .leading)
      .softPanel(cornerRadius: 14)

      Spacer(minLength: 24)
    }
    .padding(18)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct EmptyInspectorLine: View {
  let symbolName: String
  let title: String
  let detail: String

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: symbolName)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(DevScopePalette.accent)
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.caption.weight(.semibold))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

private struct DetailSection<Content: View>: View {
  let title: String
  let systemImage: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(title, systemImage: systemImage)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.primary)

      VStack(alignment: .leading, spacing: 10) {
        content
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct DetailGrid<Content: View>: View {
  @ViewBuilder let content: Content
  private let columns = [
    GridItem(.adaptive(minimum: 82, maximum: 160), spacing: 8, alignment: .topLeading)
  ]

  var body: some View {
    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
      content
    }
  }
}

private struct FlowTagList: View {
  let tags: [DevProcessTag]

  var body: some View {
    HStack(spacing: 6) {
      ForEach(tags) { tag in
        ProcessTagBadge(tag: tag)
      }
    }
  }
}

private struct WorkflowContextCard: View {
  let workflow: DevWorkflow
  let workflowNote: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: workflow.kind.symbolName)
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(workflowColor)
          .frame(width: 24)

        VStack(alignment: .leading, spacing: 4) {
          Text(workflow.title)
            .font(.headline)
            .lineLimit(1)
          Text(workflow.summary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer()

        Text(workflow.risk.rawValue)
          .font(.caption.weight(.semibold))
          .foregroundStyle(riskColor)
      }

      if let workflowNote {
        Label(workflowNote, systemImage: "sparkles")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

    }
    .padding(12)
    .softPanel(cornerRadius: 12)
  }

  private var workflowColor: Color {
    switch workflow.kind {
    case .aiMLLab, .localLLMStack:
      .pink
    case .notebookSession, .dataApp:
      .cyan
    case .trainingRun:
      .orange
    case .apiService, .webWorkspace:
      .indigo
    case .vectorDatabase:
      .purple
    case .buildWorkspace:
      .blue
    case .projectWorkspace, .runtimeGroup:
      DevScopePalette.accent
    }
  }

  private var riskColor: Color {
    switch workflow.risk {
    case .normal:
      .secondary
    case .busy:
      .orange
    case .heavy:
      .red
    }
  }
}

private struct ProcessSafetySummary: View {
  let insight: DevProcessInsight

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("At a glance", systemImage: "lightbulb")
        .font(.subheadline.weight(.semibold))

      VStack(alignment: .leading, spacing: 6) {
        InsightLine(title: "Role", value: insight.role)
        InsightLine(title: "Impact", value: insight.resourceBehavior)
        InsightLine(title: "Context", value: insight.workflowContext)
        InsightLine(title: "Safe action", value: insight.safeAction)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .softPanel(cornerRadius: 12)
  }
}

private struct InsightLine: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.tertiary)
      Text(value)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct DetailHeader: View {
  let process: ClassifiedDevProcess
  let title: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      ZStack {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
          .fill(DevScopePalette.color(for: process.classification.kind).opacity(0.18))
        Image(systemName: process.classification.kind.symbolName)
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(DevScopePalette.color(for: process.classification.kind))
      }
      .frame(width: 48, height: 48)
      .devScopeGlass(cornerRadius: 13)

      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.title3.weight(.semibold))
          .lineLimit(2)

        Text(
          process.classification.displayName == title
            ? ProcessPresentation.contextLabel(for: process) : process.classification.displayName
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }

      Spacer()
    }
  }
}

private struct DetailChip: View {
  let label: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.caption2.weight(.medium))
        .foregroundStyle(.tertiary)
      Text(value)
        .font(.caption.monospacedDigit().weight(.semibold))
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .softPanel(cornerRadius: 10)
  }
}

private struct DetailField: View {
  let label: String
  let value: String
  var lineLimit: Int = 4

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(label)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)

        Spacer()

        Button {
          copy(value)
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Copy \(label.lowercased())")
        .accessibilityHint("Copies the \(label.lowercased()) value to the clipboard.")
        .help("Copy \(label.lowercased())")
      }

      Text(value)
        .font(.system(.callout, design: .monospaced))
        .textSelection(.enabled)
        .lineLimit(lineLimit)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(
          .quaternary.opacity(0.34), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
  }

  private func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }
}

private struct ArgumentTokenList: View {
  let arguments: [String]
  private let maxVisibleArguments = 18

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text("Arguments")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      FlowLayout(spacing: 6) {
        ForEach(Array(arguments.prefix(maxVisibleArguments).enumerated()), id: \.offset) {
          _, argument in
          Text(argument)
            .font(.caption2.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.34), in: Capsule())
            .help(argument)
        }

        if arguments.count > maxVisibleArguments {
          Text("+\(arguments.count - maxVisibleArguments)")
            .font(.caption2.monospaced().weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.34), in: Capsule())
        }
      }
    }
  }
}

private struct FlowLayout: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    layout(in: proposal.width ?? 320, subviews: subviews).size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let result = layout(in: bounds.width, subviews: subviews)
    for item in result.items {
      subviews[item.index].place(
        at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
        proposal: ProposedViewSize(item.size)
      )
    }
  }

  private func layout(in width: CGFloat, subviews: Subviews) -> (
    items: [(index: Int, origin: CGPoint, size: CGSize)], size: CGSize
  ) {
    var items: [(index: Int, origin: CGPoint, size: CGSize)] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    let availableWidth = max(width, 1)

    for index in subviews.indices {
      let measuredSize = subviews[index].sizeThatFits(
        ProposedViewSize(width: availableWidth, height: nil)
      )
      let size = CGSize(
        width: min(measuredSize.width, availableWidth),
        height: measuredSize.height
      )
      if x > 0, x + size.width > availableWidth {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }

      items.append((index: index, origin: CGPoint(x: x, y: y), size: size))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }

    return (items, CGSize(width: availableWidth, height: y + rowHeight))
  }
}
