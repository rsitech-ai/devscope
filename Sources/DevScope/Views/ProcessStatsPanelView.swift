import DevScopeCore
import Foundation
import SwiftUI

private enum SystemLoadFormat {
  static var cpuCapacity: Double {
    max(1, Double(ProcessInfo.processInfo.activeProcessorCount) * 100)
  }

  static func cpuCapacityPercent(_ aggregateCPU: Double?) -> String {
    guard let aggregateCPU else {
      return "-"
    }

    return "\(Int((cpuLoadFraction(aggregateCPU) * 100).rounded()))% cap"
  }

  static func cpuLoadPercent(_ aggregateCPU: Double) -> Double {
    cpuLoadFraction(aggregateCPU) * 100
  }

  static func cpuLoadFraction(_ aggregateCPU: Double) -> Double {
    min(max(aggregateCPU / cpuCapacity, 0), 1)
  }

  static func pressureScore(for sample: DevProcessMetricSample?) -> Double {
    guard let sample else {
      return 0
    }

    let cpuLoad = cpuLoadFraction(sample.cpuPercent)
    let gpuLoad = min(max((sample.gpuPercent ?? 0) / 100, 0), 1)
    let memoryLoad = min(
      max(Double(sample.residentMemoryBytes) / Double(ProcessInfo.processInfo.physicalMemory), 0), 1
    )
    let weighted = cpuLoad * 0.40 + gpuLoad * 0.35 + memoryLoad * 0.25

    return min(max(max(weighted, max(cpuLoad, gpuLoad, memoryLoad) * 0.72), 0), 1)
  }

  static func pressureLabel(for score: Double) -> String {
    switch score {
    case 0..<0.25:
      "Low"
    case 0.25..<0.50:
      "Normal"
    case 0.50..<0.75:
      "Busy"
    case 0.75..<0.90:
      "Heavy"
    default:
      "Critical"
    }
  }

  static func pressureTint(for score: Double) -> Color {
    switch score {
    case 0..<0.25:
      .green
    case 0.25..<0.50:
      DevScopePalette.accent
    case 0.50..<0.75:
      .orange
    default:
      .red
    }
  }
}

enum LiveNotchPresentationState: Equatable {
  case collapsed
  case compact
  case expanded

  var isVisible: Bool {
    self != .collapsed
  }

  var isExpanded: Bool {
    self == .expanded
  }
}

struct DynamicIslandStatusView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let stats: ProcessDashboardStats
  let metricHistory: [DevProcessMetricSample]
  let selectedScope: String
  let isRefreshing: Bool
  let lastRefresh: Date?
  let refreshAction: @MainActor () -> Void
  let displayName: @MainActor (ClassifiedDevProcess) -> String
  @ObservedObject var presentationModel: LiveNotchPresentationModel
  @State private var isSystemStatsPresented = false

  private var presentationAnimation: Animation? {
    reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86)
  }

  private var islandTransition: AnyTransition {
    if reduceMotion {
      return .opacity
    }

    return .asymmetric(
      insertion: .opacity.combined(with: .move(edge: .top)).combined(
        with: .scale(scale: 0.96, anchor: .top)),
      removal: .opacity.combined(with: .move(edge: .top))
    )
  }

  private var expandedContentTransition: AnyTransition {
    reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
  }

  private var isVisible: Bool {
    presentationModel.state.isVisible
  }

  private var isExpanded: Bool {
    presentationModel.state.isExpanded
  }

  var body: some View {
    ZStack(alignment: .top) {
      notchHoverTarget

      ZStack(alignment: .top) {
        if isVisible {
          islandSurface
            .padding(.top, 5)
            .transition(islandTransition)
        }
      }
      .animation(presentationAnimation, value: presentationModel.state)
    }
    .frame(
      width: isVisible ? (isExpanded ? 780 : 640) : 128,
      height: isVisible ? (isExpanded ? 178 : 52) : 18, alignment: .top
    )
    .sheet(isPresented: $isSystemStatsPresented) {
      SystemStatsSheet(samples: metricHistory, runtimeCounts: stats.runtimeCounts)
    }
  }

  private var notchHoverTarget: some View {
    Capsule()
      .fill(isVisible ? Color.primary.opacity(0.10) : Color.black.opacity(0.001))
      .overlay {
        Capsule()
          .stroke(isVisible ? Color.white.opacity(0.10) : Color.clear, lineWidth: 1)
      }
      .frame(width: 112, height: 12)
      .contentShape(Capsule())
      .accessibilityLabel("DevScope live notch")
      .accessibilityHint("Hover to reveal live process status.")
      .help("Hover to reveal DevScope Live")
  }

  private var islandSurface: some View {
    VStack(alignment: .leading, spacing: isExpanded ? 10 : 0) {
      compactRow
        .contentShape(Capsule())

      if isExpanded {
        expandedContent
          .transition(expandedContentTransition)
      }
    }
    .padding(.horizontal, isExpanded ? 14 : 12)
    .padding(.vertical, isExpanded ? 12 : 9)
    .frame(width: isExpanded ? 760 : 620, alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: isExpanded ? 30 : 24, style: .continuous)
        .fill(.black.opacity(0.70))
        .background(
          .regularMaterial,
          in: RoundedRectangle(cornerRadius: isExpanded ? 30 : 24, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: isExpanded ? 30 : 24, style: .continuous)
            .stroke(.white.opacity(isExpanded ? 0.16 : 0.12), lineWidth: 1)
        }
        .overlay(alignment: .top) {
          Capsule()
            .fill(.white.opacity(isExpanded ? 0.16 : 0.10))
            .frame(width: isExpanded ? 58 : 44, height: 2)
            .padding(.top, 4)
        }
    }
    .overlay {
      RoundedRectangle(cornerRadius: isExpanded ? 30 : 24, style: .continuous)
        .stroke(pressureTint.opacity(isExpanded ? 0.16 : 0.10), lineWidth: 1)
        .blendMode(.plusLighter)
    }
    .shadow(color: .black.opacity(0.28), radius: isExpanded ? 20 : 14, y: isExpanded ? 10 : 7)
    .animation(presentationAnimation, value: isExpanded)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Live DevScope status")
    .accessibilityValue(accessibilityStatus)
    .help("Hover the top-center notch to reveal live status.")
  }

  private var compactRow: some View {
    HStack(spacing: 8) {
      LivePulseDot(tint: pressureTint, isActive: isRefreshing || stats.totalCount > 0)

      Text("DevScope")
        .font(.callout.weight(.semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
        .layoutPriority(3)

      Text("\(stats.totalCount)")
        .font(.callout.monospacedDigit().weight(.bold))
        .foregroundStyle(DevScopePalette.accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(DevScopePalette.accent.opacity(0.18), in: Capsule())

      Text(selectedScope)
        .font(.caption.weight(.medium))
        .foregroundStyle(.white.opacity(0.70))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: 110, alignment: .leading)
        .layoutPriority(1)

      Spacer(minLength: 8)

      LiveIslandMetricLabel(title: "CPU", value: cpuText, tint: .orange)
      LiveIslandMetricLabel(title: "GPU", value: gpuText, tint: .green)
      LiveIslandMetricLabel(title: "MEM", value: memoryText, tint: .cyan)

      Label(pressureLabel, systemImage: "gauge.with.dots.needle.67percent")
        .font(.caption.weight(.semibold))
        .foregroundStyle(pressureTint)
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
        .layoutPriority(1)

      Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
        .font(.caption.weight(.bold))
        .foregroundStyle(.white.opacity(0.55))
    }
  }

  private var expandedContent: some View {
    VStack(alignment: .leading, spacing: 10) {
      Divider()
        .overlay(.white.opacity(0.14))

      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 8) {
            GraphLegendItem(title: "CPU", color: .orange)
            GraphLegendItem(title: "GPU", color: .green)
            GraphLegendItem(title: "Memory", color: .cyan)
            Spacer()
            Text(lastRefreshText)
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.white.opacity(0.46))
          }

          LiveIslandSparkline(samples: metricHistory)
            .frame(height: 42)
        }
        .frame(minWidth: 300, maxWidth: .infinity, alignment: .leading)

        VStack(alignment: .leading, spacing: 8) {
          LiveIslandTopProcessRow(
            title: "Top Memory", process: stats.topMemory, displayName: displayName)
        }
        .frame(width: 170, alignment: .leading)

        VStack(spacing: 8) {
          LiveIslandActionButton(
            title: "Refresh", symbolName: "arrow.clockwise", tint: DevScopePalette.accent
          ) {
            refreshAction()
          }

          LiveIslandActionButton(title: "Inspect", symbolName: "chart.xyaxis.line", tint: .orange) {
            isSystemStatsPresented = true
          }
        }
        .frame(width: 112)
      }
    }
  }

  private var latest: DevProcessMetricSample? {
    metricHistory.last
  }

  private var cpuText: String {
    SystemLoadFormat.cpuCapacityPercent(latest?.cpuPercent)
  }

  private var gpuText: String {
    ProcessMetricFormat.gpu(latest?.gpuPercent)
  }

  private var memoryText: String {
    ProcessMetricFormat.memory(latest?.residentMemoryBytes)
  }

  private var pressureScore: Double {
    SystemLoadFormat.pressureScore(for: latest)
  }

  private var pressureLabel: String {
    switch pressureScore {
    case 0..<0.25:
      "Low"
    case 0.25..<0.50:
      "Normal"
    case 0.50..<0.75:
      "Busy"
    case 0.75..<0.90:
      "Heavy"
    default:
      "Critical"
    }
  }

  private var pressureTint: Color {
    switch pressureScore {
    case 0..<0.25:
      .green
    case 0.25..<0.50:
      DevScopePalette.accent
    case 0.50..<0.75:
      .orange
    default:
      .red
    }
  }

  private var lastRefreshText: String {
    guard let lastRefresh else {
      return isRefreshing ? "collecting" : "waiting"
    }

    return "updated \(lastRefresh.formatted(date: .omitted, time: .standard))"
  }

  private var accessibilityStatus: String {
    "\(stats.totalCount) running items, CPU \(cpuText), GPU \(gpuText), memory \(memoryText), machine load \(pressureLabel)"
  }
}

private struct LivePulseDot: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let tint: Color
  let isActive: Bool

  var body: some View {
    Group {
      if reduceMotion {
        pulse(phase: 0)
      } else {
        TimelineView(.animation(minimumInterval: 0.8)) { timeline in
          let phase =
            isActive
            ? timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6)
              / 1.6 : 0
          pulse(phase: phase)
        }
      }
    }
    .frame(width: 22, height: 22)
  }

  private func pulse(phase: Double) -> some View {
    ZStack {
      Circle()
        .fill(tint.opacity(0.24))
        .frame(width: 20, height: 20)
        .scaleEffect(1 + phase * 0.55)
        .opacity(isActive ? 1 - phase : 0.35)

      Circle()
        .fill(tint)
        .frame(width: 8, height: 8)
        .shadow(color: tint.opacity(0.55), radius: 8)
    }
  }
}

private struct LiveIslandMetricLabel: View {
  let title: String
  let value: String
  let tint: Color

  var body: some View {
    HStack(spacing: 4) {
      Circle()
        .fill(tint)
        .frame(width: 6, height: 6)
      Text(title)
        .foregroundStyle(.white.opacity(0.48))
      Text(value)
        .foregroundStyle(.white.opacity(0.82))
        .monospacedDigit()
    }
    .font(.caption2.weight(.semibold))
    .lineLimit(1)
    .fixedSize(horizontal: true, vertical: false)
  }
}

private struct LiveIslandSparkline: View {
  let samples: [DevProcessMetricSample]

  var body: some View {
    Canvas { context, size in
      drawGrid(context: &context, size: size)
      drawLine(
        values: samples.map { SystemLoadFormat.cpuLoadPercent($0.cpuPercent) },
        maxValue: 100,
        color: .orange,
        context: &context,
        size: size
      )
      drawLine(
        values: samples.map { $0.gpuPercent ?? 0 },
        maxValue: 100,
        color: .green,
        context: &context,
        size: size
      )
      drawLine(
        values: samples.map { Double($0.residentMemoryBytes) },
        maxValue: max(1, Double(samples.map(\.residentMemoryBytes).max() ?? 1)),
        color: .cyan,
        context: &context,
        size: size
      )
    }
    .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(.white.opacity(0.10), lineWidth: 1)
    }
  }

  private func drawGrid(context: inout GraphicsContext, size: CGSize) {
    var path = Path()
    for fraction in [0.33, 0.66] {
      let y = size.height * fraction
      path.move(to: CGPoint(x: 0, y: y))
      path.addLine(to: CGPoint(x: size.width, y: y))
    }
    context.stroke(path, with: .color(.white.opacity(0.08)), lineWidth: 1)
  }

  private func drawLine(
    values: [Double],
    maxValue: Double,
    color: Color,
    context: inout GraphicsContext,
    size: CGSize
  ) {
    guard values.count > 1, maxValue > 0 else {
      return
    }

    var path = Path()
    for index in values.indices {
      let progress = Double(index) / Double(values.count - 1)
      let normalizedValue = min(max(values[index] / maxValue, 0), 1)
      let point = CGPoint(
        x: progress * size.width,
        y: size.height - normalizedValue * size.height
      )
      if index == values.startIndex {
        path.move(to: point)
      } else {
        path.addLine(to: point)
      }
    }

    context.stroke(path, with: .color(color.opacity(0.88)), lineWidth: 1.6)
  }
}

private struct LiveIslandTopProcessRow: View {
  let title: String
  let process: ClassifiedDevProcess?
  let displayName: (ClassifiedDevProcess) -> String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.caption2.weight(.medium))
        .foregroundStyle(.white.opacity(0.46))
      Text(process.map(displayName) ?? "No process")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white.opacity(0.84))
        .lineLimit(1)
        .truncationMode(.tail)
    }
  }
}

private struct LiveIslandActionButton: View {
  let title: String
  let symbolName: String
  let tint: Color
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: symbolName)
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: 28)
    }
    .buttonStyle(.plain)
    .foregroundStyle(tint)
    .background(tint.opacity(0.14), in: Capsule())
    .overlay {
      Capsule()
        .stroke(tint.opacity(0.26), lineWidth: 1)
    }
  }
}

struct LiveActivitiesDockView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let stats: ProcessDashboardStats
  let metricHistory: [DevProcessMetricSample]
  let isRefreshing: Bool
  let lastRefresh: Date?
  @Binding var isExpanded: Bool
  @State private var isSystemStatsPresented = false

  var body: some View {
    GeometryReader { proxy in
      let mode = LiveActivityLayoutPolicy.mode(availableWidth: proxy.size.width)
      let verticalMode = LiveActivityLayoutPolicy.verticalMode(
        availableHeight: proxy.size.height,
        layoutMode: mode
      )

      VStack(alignment: .leading, spacing: isExpanded ? 10 : 0) {
        responsiveHeader

        if isExpanded {
          expandedMetrics(verticalMode: verticalMode)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(12)
      .devScopeGlass(cornerRadius: 16)
    }
    .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: isExpanded)
    .sheet(isPresented: $isSystemStatsPresented) {
      SystemStatsSheet(samples: metricHistory, runtimeCounts: stats.runtimeCounts)
    }
  }

  private var responsiveHeader: some View {
    ViewThatFits(in: .horizontal) {
      wideHeader
      compactHeader
    }
  }

  private var wideHeader: some View {
    HStack(spacing: 12) {
      headerIdentity

      Spacer(minLength: 8)

      compactMetricSummary
      loadIndicator
      expansionButton
    }
  }

  private var compactHeader: some View {
    HStack(spacing: 8) {
      headerIdentity

      Spacer(minLength: 4)

      loadIndicator
      expansionButton
    }
  }

  private var headerIdentity: some View {
    HStack(spacing: 12) {
      Label("Live Activity", systemImage: "dock.rectangle")
        .font(.callout.weight(.semibold))
        .foregroundStyle(.primary)
        .lineLimit(1)

      Text(statusText)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
  }

  private var compactMetricSummary: some View {
    HStack(spacing: 12) {
      CompactLiveMetric(
        title: "CPU",
        value: SystemLoadFormat.cpuCapacityPercent(latestSample?.cpuPercent),
        color: .orange
      )
      CompactLiveMetric(
        title: "GPU",
        value: latestSample?.gpuPercent.map(ProcessMetricFormat.gpu) ?? "-",
        color: .green
      )
      CompactLiveMetric(
        title: "Memory",
        value: ProcessMetricFormat.memory(latestSample?.residentMemoryBytes),
        color: .cyan
      )
    }
  }

  private var loadIndicator: some View {
    Label(loadLabel, systemImage: "gauge.with.dots.needle.67percent")
      .font(.caption.weight(.semibold))
      .foregroundStyle(loadTint)
      .lineLimit(1)
  }

  private var expansionButton: some View {
    Button {
      isExpanded.toggle()
    } label: {
      Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
        .frame(width: 20, height: 20)
    }
    .buttonStyle(.borderless)
    .accessibilityLabel(isExpanded ? "Hide live activity details" : "Show live activity details")
    .accessibilityHint("Toggles the detailed CPU, GPU, and memory history graph.")
    .help(isExpanded ? "Hide live activity details" : "Show live activity details")
  }

  @ViewBuilder
  private func expandedMetrics(
    verticalMode: LiveActivityVerticalMode
  ) -> some View {
    historyGraph(density: verticalMode == .condensed ? .condensed : .standard)
  }

  private func historyGraph(
    density: DashboardMetricGraphDensity = .standard
  ) -> some View {
    DashboardMetricGraph(
      samples: metricHistory,
      density: density,
      showsLegend: false,
      showsInspectButton: false,
      showsSummary: false,
      fillsAvailableHeight: true
    ) {
      isSystemStatsPresented = true
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  }

  private var statusText: String {
    guard let lastRefresh else {
      return isRefreshing ? "collecting" : "waiting"
    }

    return "updated \(lastRefresh.formatted(date: .omitted, time: .standard))"
  }

  private var latestSample: DevProcessMetricSample? {
    metricHistory.last
  }

  private var loadScore: Double {
    SystemLoadFormat.pressureScore(for: latestSample)
  }

  private var loadLabel: String {
    SystemLoadFormat.pressureLabel(for: loadScore)
  }

  private var loadTint: Color {
    SystemLoadFormat.pressureTint(for: loadScore)
  }
}

private struct CompactLiveMetric: View {
  let title: String
  let value: String
  let color: Color

  var body: some View {
    HStack(spacing: 4) {
      Circle()
        .fill(color)
        .frame(width: 5, height: 5)
      Text("\(title) \(value)")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
  }
}

private enum DashboardMetricGraphDensity {
  case standard
  case condensed
}

private struct DashboardMetricGraph: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let samples: [DevProcessMetricSample]
  var density: DashboardMetricGraphDensity = .standard
  var showsLegend = true
  var showsInspectButton = true
  var showsSummary = true
  var fillsAvailableHeight = false
  let action: () -> Void
  @State private var hoverLocation: CGPoint?

  private func selectedSample(width: CGFloat? = nil) -> DevProcessMetricSample? {
    guard let hoverLocation, samples.count > 1 else {
      return samples.last
    }

    let graphWidth = max(1, width ?? 1)
    let progress = min(max(hoverLocation.x / graphWidth, 0), 1)
    let index = min(
      samples.count - 1, max(0, Int((progress * CGFloat(samples.count - 1)).rounded())))
    return samples[index]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if density == .standard, showsLegend {
        HStack(spacing: 12) {
          GraphLegendItem(title: "CPU cap", color: .orange)
          GraphLegendItem(title: "GPU", color: .green)
          GraphLegendItem(title: "Memory", color: .cyan)
          Text("Running activity")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.tertiary)
          if showsInspectButton {
            Button(action: action) {
              Label("Inspect", systemImage: "arrow.up.left.and.arrow.down.right")
                .font(.caption2.weight(.semibold))
                .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Open system statistics")
            .accessibilityHint("Opens the detailed system statistics sheet.")
            .help("Open system statistics")
          }
          Spacer()
          Text(windowText)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
      }

      Button(action: action) {
        Canvas { context, size in
          drawGrid(context: &context, size: size)
          drawLine(
            values: samples.map { SystemLoadFormat.cpuLoadPercent($0.cpuPercent) },
            maxValue: 100,
            color: .orange,
            context: &context,
            size: size
          )
          drawLine(
            values: samples.map { $0.gpuPercent ?? 0 },
            maxValue: 100,
            color: .green,
            context: &context,
            size: size
          )
          drawLine(
            values: samples.map { Double($0.residentMemoryBytes) },
            maxValue: max(1, Double(samples.map(\.residentMemoryBytes).max() ?? 1)),
            color: .cyan,
            context: &context,
            size: size
          )
          drawHover(context: &context, size: size)
        }
        .frame(
          minHeight: graphMinimumHeight,
          maxHeight: fillsAvailableHeight ? .infinity : graphMinimumHeight
        )
        .background(
          .black.opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(alignment: .topTrailing) {
          if showsSummary {
            Text(summaryText)
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.secondary)
              .padding(.horizontal, 8)
              .padding(.vertical, 5)
          }
        }
        .overlay(alignment: .topLeading) {
          GeometryReader { proxy in
            if hoverLocation != nil, let sample = selectedSample(width: proxy.size.width) {
              GraphHoverTooltip(sample: sample)
                .padding(8)
                .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.98)))
            }
          }
        }
        .onContinuousHover { phase in
          switch phase {
          case .active(let location):
            hoverLocation = location
          case .ended:
            hoverLocation = nil
          }
        }
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Open system statistics")
      .accessibilityHint(summaryText)
      .help("Open system statistics")
    }
    .frame(
      maxHeight: fillsAvailableHeight ? .infinity : nil,
      alignment: .topLeading
    )
  }

  private var graphMinimumHeight: CGFloat {
    density == .condensed ? 40 : 52
  }

  private var summaryText: String {
    guard let sample = selectedSample() else {
      return "waiting"
    }

    let gpu = ProcessMetricFormat.gpu(sample.gpuPercent)
    return
      "CPU \(SystemLoadFormat.cpuCapacityPercent(sample.cpuPercent))  GPU \(gpu)  MEM \(ProcessMetricFormat.memory(sample.residentMemoryBytes))"
  }

  private var windowText: String {
    guard let first = samples.first?.timestamp,
      let last = samples.last?.timestamp,
      last > first
    else {
      return "collecting"
    }
    return "\(Int(last.timeIntervalSince(first)))s"
  }

  private func drawGrid(context: inout GraphicsContext, size: CGSize) {
    var path = Path()
    for fraction in [0.25, 0.5, 0.75] {
      let y = size.height * fraction
      path.move(to: CGPoint(x: 0, y: y))
      path.addLine(to: CGPoint(x: size.width, y: y))
    }
    context.stroke(path, with: .color(.white.opacity(0.08)), lineWidth: 1)
  }

  private func drawHover(context: inout GraphicsContext, size: CGSize) {
    guard let hoverLocation, samples.count > 1 else {
      return
    }

    let x = min(max(hoverLocation.x, 0), size.width)
    var path = Path()
    path.move(to: CGPoint(x: x, y: 0))
    path.addLine(to: CGPoint(x: x, y: size.height))
    context.stroke(
      path, with: .color(.white.opacity(0.32)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
  }

  private func drawLine(
    values: [Double],
    maxValue: Double,
    color: Color,
    context: inout GraphicsContext,
    size: CGSize
  ) {
    guard values.count > 1, maxValue > 0 else {
      return
    }

    var path = Path()
    for index in values.indices {
      let progress = Double(index) / Double(values.count - 1)
      let normalizedValue = min(max(values[index] / maxValue, 0), 1)
      let point = CGPoint(
        x: progress * size.width,
        y: size.height - normalizedValue * size.height
      )
      if index == values.startIndex {
        path.move(to: point)
      } else {
        path.addLine(to: point)
      }
    }

    context.stroke(path, with: .color(color.opacity(0.88)), lineWidth: 1.7)
  }
}

private struct RuntimeMixTile: View {
  let runtimeCounts: [DevRuntimeKind: Int]

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Label("Activity Mix", systemImage: "square.grid.2x2")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)

      RuntimeMixBar(runtimeCounts: runtimeCounts, height: 8)

      HStack(spacing: 8) {
        ForEach(topRuntimes.prefix(3), id: \.key) { kind, count in
          HStack(spacing: 4) {
            Circle()
              .fill(DevScopePalette.color(for: kind))
              .frame(width: 6, height: 6)
            Text(kind.rawValue)
              .lineLimit(1)
            Text("\(count)")
              .monospacedDigit()
              .foregroundStyle(.tertiary)
          }
          .font(.caption2)
        }
      }
    }
    .frame(width: 168, alignment: .leading)
    .padding(10)
    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(.white.opacity(0.10), lineWidth: 1)
    }
  }

  private var topRuntimes: [(key: DevRuntimeKind, value: Int)] {
    runtimeCounts.sorted { lhs, rhs in
      if lhs.value != rhs.value {
        return lhs.value > rhs.value
      }
      return lhs.key.rawValue < rhs.key.rawValue
    }
  }
}

struct RuntimeMixBar: View {
  let runtimeCounts: [DevRuntimeKind: Int]
  let height: CGFloat

  var body: some View {
    GeometryReader { proxy in
      HStack(spacing: 2) {
        ForEach(sortedRuntimes, id: \.key) { kind, count in
          RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(DevScopePalette.color(for: kind))
            .frame(width: max(4, proxy.size.width * CGFloat(count) / CGFloat(max(1, totalCount))))
        }
      }
    }
    .frame(height: height)
    .accessibilityLabel("Activity mix")
  }

  private var sortedRuntimes: [(key: DevRuntimeKind, value: Int)] {
    runtimeCounts.sorted { lhs, rhs in
      if lhs.value != rhs.value {
        return lhs.value > rhs.value
      }
      return lhs.key.rawValue < rhs.key.rawValue
    }
  }

  private var totalCount: Int {
    runtimeCounts.values.reduce(0, +)
  }
}

private struct GraphHoverTooltip: View {
  let sample: DevProcessMetricSample

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(sample.timestamp, style: .time)
        .font(.caption2.weight(.semibold))
      Text("CPU \(SystemLoadFormat.cpuCapacityPercent(sample.cpuPercent))")
      Text("GPU \(ProcessMetricFormat.gpu(sample.gpuPercent))")
      Text("Memory \(ProcessMetricFormat.memory(sample.residentMemoryBytes))")
    }
    .font(.caption2.monospacedDigit())
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(.white.opacity(0.14), lineWidth: 1)
    }
  }
}

private struct SystemStatsSheet: View {
  let samples: [DevProcessMetricSample]
  let runtimeCounts: [DevRuntimeKind: Int]
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("System Statistics")
            .font(.title2.weight(.semibold))
          Text("Aggregate live samples across running items plus system GPU utilization.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }

        Spacer()

        Button("Done") {
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }

      HStack(spacing: 12) {
        SummaryPill(
          title: "CPU Avg", value: SystemLoadFormat.cpuCapacityPercent(averageCPU), tint: .orange)
        SummaryPill(title: "GPU Avg", value: ProcessMetricFormat.gpu(averageGPU), tint: .green)
        SummaryPill(
          title: "Memory Peak", value: ProcessMetricFormat.memory(peakMemory), tint: .cyan)
        SummaryPill(title: "Samples", value: "\(samples.count)", tint: DevScopePalette.accent)
      }

      DashboardMetricGraph(samples: samples, showsInspectButton: false) {}
        .frame(minHeight: 92)

      VStack(alignment: .leading, spacing: 10) {
        Text("Activity Mix")
          .font(.headline)
        RuntimeMixBar(runtimeCounts: runtimeCounts, height: 10)
        RuntimeBreakdown(runtimeCounts: runtimeCounts)
      }

      Spacer(minLength: 0)
    }
    .padding(20)
    .frame(width: 720, height: 430)
    .background(DevScopeBackground())
  }

  private var averageCPU: Double? {
    guard !samples.isEmpty else {
      return nil
    }
    return samples.reduce(0) { $0 + $1.cpuPercent } / Double(samples.count)
  }

  private var averageGPU: Double? {
    let values = samples.compactMap(\.gpuPercent)
    guard !values.isEmpty else {
      return nil
    }
    return values.reduce(0, +) / Double(values.count)
  }

  private var peakMemory: Int64? {
    samples.map(\.residentMemoryBytes).max()
  }
}

private struct SummaryPill: View {
  let title: String
  let value: String
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.callout.monospacedDigit().weight(.semibold))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(tint.opacity(0.18), lineWidth: 1)
    }
  }
}

private struct RuntimeBreakdown: View {
  let runtimeCounts: [DevRuntimeKind: Int]

  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
      ForEach(sortedRuntimes, id: \.key) { kind, count in
        HStack(spacing: 7) {
          Circle()
            .fill(DevScopePalette.color(for: kind))
            .frame(width: 8, height: 8)
          Text(kind.rawValue)
            .lineLimit(1)
          Spacer()
          Text("\(count)")
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
      }
    }
  }

  private var sortedRuntimes: [(key: DevRuntimeKind, value: Int)] {
    runtimeCounts.sorted { lhs, rhs in
      if lhs.value != rhs.value {
        return lhs.value > rhs.value
      }
      return lhs.key.rawValue < rhs.key.rawValue
    }
  }
}

private struct GraphLegendItem: View {
  let title: String
  let color: Color

  var body: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(color)
        .frame(width: 7, height: 7)
      Text(title)
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
    }
  }
}

private struct RuntimeStrip: View {
  let runtimeCounts: [DevRuntimeKind: Int]

  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 8) {
        ForEach(runtimeCounts.sorted(by: sortRuntime), id: \.key) { kind, count in
          HStack(spacing: 5) {
            Circle()
              .fill(DevScopePalette.color(for: kind))
              .frame(width: 7, height: 7)
            Text(kind.rawValue)
              .fixedSize(horizontal: true, vertical: false)
            Text("\(count)")
              .monospacedDigit()
              .foregroundStyle(.tertiary)
          }
          .font(.caption)
        }
      }
    }
    .scrollIndicators(.hidden)
    .frame(maxWidth: 360, alignment: .trailing)
  }

  private func sortRuntime(
    _ lhs: (key: DevRuntimeKind, value: Int),
    _ rhs: (key: DevRuntimeKind, value: Int)
  ) -> Bool {
    if lhs.value != rhs.value {
      return lhs.value > rhs.value
    }
    return lhs.key.rawValue < rhs.key.rawValue
  }
}
