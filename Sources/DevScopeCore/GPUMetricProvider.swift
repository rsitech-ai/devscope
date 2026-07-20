import Foundation

public struct DevGPUMetric: Equatable, Sendable {
  public let utilizationPercent: Double
  public let modelName: String?

  public init(utilizationPercent: Double, modelName: String? = nil) {
    self.utilizationPercent = utilizationPercent
    self.modelName = modelName
  }
}

public protocol GPUMetricProviding: Sendable {
  func snapshot() throws -> DevGPUMetric?
}

public struct SystemGPUMetricProvider: GPUMetricProviding {
  private let executableURL: URL
  private let commandRunner: any SystemCommandRunning

  public init(executableURL: URL = URL(fileURLWithPath: "/usr/sbin/ioreg")) {
    self.executableURL = executableURL
    commandRunner = BoundedSystemCommandRunner()
  }

  init(
    executableURL: URL,
    commandRunner: any SystemCommandRunning
  ) {
    self.executableURL = executableURL
    self.commandRunner = commandRunner
  }

  public func snapshot() throws -> DevGPUMetric? {
    let result = try commandRunner.run(
      executableURL: executableURL,
      arguments: ["-r", "-c", "AGXAccelerator", "-d", "1"]
    )

    guard result.status == 0 else {
      return nil
    }

    return Self.parse(String(decoding: result.standardOutput, as: UTF8.self))
  }

  public static func parse(_ output: String) -> DevGPUMetric? {
    guard let utilization = number(after: #""Device Utilization %"\s*=\s*"#, in: output) else {
      return nil
    }

    return DevGPUMetric(
      utilizationPercent: min(max(utilization, 0), 100),
      modelName: quotedValue(after: #""model"\s*=\s*"#, in: output)
    )
  }

  private static func number(after prefixPattern: String, in output: String) -> Double? {
    guard let regex = try? NSRegularExpression(pattern: prefixPattern + #"([0-9]+(?:\.[0-9]+)?)"#) else {
      return nil
    }
    let range = NSRange(output.startIndex..<output.endIndex, in: output)
    guard let match = regex.firstMatch(in: output, range: range),
          match.numberOfRanges > 1,
          let matchRange = Range(match.range(at: 1), in: output) else {
      return nil
    }

    return Double(output[matchRange])
  }

  private static func quotedValue(after prefixPattern: String, in output: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: prefixPattern + #""([^"]+)""#) else {
      return nil
    }
    let range = NSRange(output.startIndex..<output.endIndex, in: output)
    guard let match = regex.firstMatch(in: output, range: range),
          match.numberOfRanges > 1,
          let matchRange = Range(match.range(at: 1), in: output) else {
      return nil
    }

    return String(output[matchRange])
  }
}
