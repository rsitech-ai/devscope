import Foundation

public struct ProcessBirthToken: Equatable, Hashable, Sendable {
  public let seconds: UInt64
  public let microseconds: UInt64

  public init(seconds: UInt64, microseconds: UInt64) {
    self.seconds = seconds
    self.microseconds = microseconds
  }
}

public struct DevProcess: Identifiable, Equatable, Hashable, Sendable {
  public let pid: Int32
  public let parentPID: Int32
  public let executable: String
  public let command: String
  public let argumentVector: [String]?
  public let currentDirectory: String?
  public let resourceUsage: DevProcessResourceUsage?
  public let birthToken: ProcessBirthToken?
  public let bundleIdentifier: String?
  /// Exact service-manager metadata when supplied by a trusted scanner boundary.
  /// Nil does not imply a label and callers must never infer one from names or paths.
  public let launchLabel: String?

  public var id: Int32 { pid }

  public init(
    pid: Int32,
    parentPID: Int32,
    executable: String,
    command: String,
    argumentVector: [String]? = nil,
    currentDirectory: String? = nil,
    resourceUsage: DevProcessResourceUsage? = nil,
    birthToken: ProcessBirthToken? = nil,
    bundleIdentifier: String? = nil,
    launchLabel: String? = nil
  ) {
    self.pid = pid
    self.parentPID = parentPID
    self.executable = executable
    self.command = command
    self.argumentVector = argumentVector
    self.currentDirectory = currentDirectory
    self.resourceUsage = resourceUsage
    self.birthToken = birthToken
    self.bundleIdentifier = bundleIdentifier
    self.launchLabel = launchLabel
  }

  public var executableName: String {
    URL(fileURLWithPath: executable).lastPathComponent
  }
}

enum ProcessSnapshotNormalization {
  static func newestUnambiguous(_ processes: [DevProcess]) -> [DevProcess] {
    let grouped = Dictionary(grouping: processes, by: \.pid)
    return grouped.keys.sorted().compactMap { processID in
      guard let rows = grouped[processID] else { return nil }
      let newestBirth = rows.compactMap(\.birthToken).max(by: birthPrecedes)
      let candidates = rows.filter { $0.birthToken == newestBirth }
      guard let first = candidates.first,
            candidates.dropFirst().allSatisfy({ $0 == first }) else { return nil }
      return first
    }
  }

  private static func birthPrecedes(_ lhs: ProcessBirthToken, _ rhs: ProcessBirthToken) -> Bool {
    (lhs.seconds, lhs.microseconds) < (rhs.seconds, rhs.microseconds)
  }
}

public struct DevProcessResourceUsage: Equatable, Hashable, Sendable {
  public let cpuPercent: Double
  public let residentMemoryBytes: Int64
  public let elapsedTime: String

  public init(cpuPercent: Double, residentMemoryBytes: Int64, elapsedTime: String) {
    self.cpuPercent = cpuPercent
    self.residentMemoryBytes = residentMemoryBytes
    self.elapsedTime = elapsedTime
  }
}

public struct DevProcessMetricSample: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let timestamp: Date
  public let cpuPercent: Double
  public let residentMemoryBytes: Int64
  public let gpuPercent: Double?

  public init(
    id: UUID = UUID(),
    timestamp: Date,
    cpuPercent: Double,
    residentMemoryBytes: Int64,
    gpuPercent: Double? = nil
  ) {
    self.id = id
    self.timestamp = timestamp
    self.cpuPercent = cpuPercent
    self.residentMemoryBytes = residentMemoryBytes
    self.gpuPercent = gpuPercent
  }
}

public struct DevProcessTag: Identifiable, Equatable, Hashable, Sendable {
  public let id: String
  public let title: String
  public let symbolName: String

  public init(id: String, title: String, symbolName: String) {
    self.id = id
    self.title = title
    self.symbolName = symbolName
  }

  public static let notebook = DevProcessTag(id: "notebook", title: "Notebook", symbolName: "book")
  public static let training = DevProcessTag(id: "training", title: "Training", symbolName: "chart.line.uptrend.xyaxis")
  public static let llm = DevProcessTag(id: "llm", title: "LLM", symbolName: "brain.head.profile")
  public static let inference = DevProcessTag(id: "inference", title: "Inference", symbolName: "brain")
  public static let llmServer = DevProcessTag(id: "llm-server", title: "LLM Server", symbolName: "text.bubble")
  public static let vectorDB = DevProcessTag(id: "vector-db", title: "Vector DB", symbolName: "square.stack.3d.up")
  public static let api = DevProcessTag(id: "api", title: "API", symbolName: "network")
  public static let mcp = DevProcessTag(id: "mcp", title: "MCP", symbolName: "point.3.connected.trianglepath.dotted")
  public static let experiment = DevProcessTag(id: "experiment", title: "Experiment", symbolName: "flask")
  public static let dataApp = DevProcessTag(id: "data-app", title: "Data App", symbolName: "chart.bar")
}

public enum DevRuntimeKind: String, CaseIterable, Identifiable, Sendable {
  case javascript = "JavaScript"
  case python = "Python"
  case swift = "Swift"
  case rust = "Rust"
  case go = "Go"
  case flutter = "Flutter"
  case java = "Java"
  case database = "Database"
  case container = "Container"
  case webServer = "Web Server"
  case ai = "AI"
  case mcp = "MCP"
  case browser = "Browser"
  case macApp = "App"
  case backgroundAgent = "Background Agent"
  case systemService = "System Service"
  case shell = "Shell"
  case other = "Other"

  public var id: String { rawValue }

  public var symbolName: String {
    switch self {
    case .javascript:
      "curlybraces"
    case .python:
      "terminal"
    case .swift:
      "swift"
    case .rust:
      "hammer"
    case .go:
      "bolt.horizontal"
    case .flutter:
      "iphone.and.arrow.forward"
    case .java:
      "cup.and.saucer"
    case .database:
      "cylinder"
    case .container:
      "shippingbox"
    case .webServer:
      "network"
    case .ai:
      "brain"
    case .mcp:
      "point.3.connected.trianglepath.dotted"
    case .browser:
      "safari"
    case .macApp:
      "macwindow"
    case .backgroundAgent:
      "gearshape.2"
    case .systemService:
      "server.rack"
    case .shell:
      "terminal.fill"
    case .other:
      "questionmark.circle"
    }
  }
}

public struct DevProcessClassification: Equatable, Sendable {
  public let kind: DevRuntimeKind
  public let displayName: String
  public let projectHint: String?
  public let tags: [DevProcessTag]

  public init(kind: DevRuntimeKind, displayName: String, projectHint: String?, tags: [DevProcessTag] = []) {
    self.kind = kind
    self.displayName = displayName
    self.projectHint = projectHint
    self.tags = tags
  }
}

public struct ClassifiedDevProcess: Identifiable, Equatable, Sendable {
  public let process: DevProcess
  public let classification: DevProcessClassification

  public var id: Int32 { process.pid }

  public init(process: DevProcess, classification: DevProcessClassification) {
    self.process = process
    self.classification = classification
  }
}
