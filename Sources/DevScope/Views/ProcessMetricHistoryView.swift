import DevScopeCore
import SwiftUI

struct ProcessMetricHistoryView: View {
  let samples: [DevProcessMetricSample]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Behavior")
          .font(.headline)
        Spacer()
        Text(windowText)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.tertiary)
      }

      MetricChart(samples: samples)
        .frame(height: 120)

      HStack(spacing: 12) {
        LegendSwatch(color: .cyan, label: "CPU")
        LegendSwatch(color: .purple, label: "Memory")
        if hasGPUSamples {
          LegendSwatch(color: .orange, label: "GPU")
        }
        Spacer()
        Text(summaryText)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .padding(12)
    .softPanel(cornerRadius: 12)
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

  private var summaryText: String {
    guard let latest = samples.last else {
      return "No samples yet"
    }

    return
      "\(ProcessMetricFormat.cpu(latest.cpuPercent)) · \(ProcessMetricFormat.memory(latest.residentMemoryBytes)) · GPU \(ProcessMetricFormat.gpu(latest.gpuPercent))"
  }

  private var hasGPUSamples: Bool {
    samples.contains { $0.gpuPercent != nil }
  }
}

private struct MetricChart: View {
  let samples: [DevProcessMetricSample]

  var body: some View {
    Canvas { context, size in
      let rect = CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)
      drawGrid(in: rect, context: &context)

      guard samples.count > 1 else {
        return
      }

      let cpuMax = max(100, samples.map(\.cpuPercent).max() ?? 100)
      let memoryMax = max(1, samples.map(\.residentMemoryBytes).max() ?? 1)

      context.stroke(
        path(for: samples.map(\.cpuPercent), maxValue: cpuMax, in: rect),
        with: .color(.cyan),
        style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
      )
      context.stroke(
        path(
          for: samples.map { Double($0.residentMemoryBytes) }, maxValue: Double(memoryMax), in: rect
        ),
        with: .color(.purple),
        style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
      )

      let gpuValues = samples.compactMap(\.gpuPercent)
      if gpuValues.count == samples.count {
        context.stroke(
          path(for: gpuValues, maxValue: 100, in: rect),
          with: .color(.orange),
          style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
        )
      }
    }
    .background(
      .quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .overlay {
      if samples.count < 2 {
        Text("Collecting live samples")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Process resource history")
    .accessibilityValue(accessibilitySummary)
  }

  private var accessibilitySummary: String {
    guard let first = samples.first, let last = samples.last else {
      return "No samples yet"
    }
    let cpuValues = samples.map(\.cpuPercent)
    let memoryValues = samples.map(\.residentMemoryBytes)
    let duration = max(0, Int(last.timestamp.timeIntervalSince(first.timestamp)))
    return
      "\(samples.count) samples over \(duration) seconds. CPU from \(ProcessMetricFormat.cpu(cpuValues.min())) to \(ProcessMetricFormat.cpu(cpuValues.max())). Memory from \(ProcessMetricFormat.memory(memoryValues.min())) to \(ProcessMetricFormat.memory(memoryValues.max()))."
  }

  private func drawGrid(in rect: CGRect, context: inout GraphicsContext) {
    var grid = Path()
    for fraction in stride(from: 0.25, through: 0.75, by: 0.25) {
      let y = rect.minY + rect.height * fraction
      grid.move(to: CGPoint(x: rect.minX, y: y))
      grid.addLine(to: CGPoint(x: rect.maxX, y: y))
    }
    context.stroke(grid, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
  }

  private func path(for values: [Double], maxValue: Double, in rect: CGRect) -> Path {
    var path = Path()
    let denominator = max(1, values.count - 1)

    for (index, value) in values.enumerated() {
      let x = rect.minX + rect.width * CGFloat(index) / CGFloat(denominator)
      let normalized = max(0, min(1, value / maxValue))
      let y = rect.maxY - rect.height * CGFloat(normalized)
      let point = CGPoint(x: x, y: y)

      if index == 0 {
        path.move(to: point)
      } else {
        path.addLine(to: point)
      }
    }

    return path
  }
}

private struct LegendSwatch: View {
  let color: Color
  let label: String

  var body: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(color)
        .frame(width: 7, height: 7)
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}
