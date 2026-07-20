import Foundation

public enum DevWorkflowKind: String, CaseIterable, Sendable {
  case aiMLLab = "AI / ML Lab"
  case localLLMStack = "Local LLM Stack"
  case notebookSession = "Notebook Session"
  case trainingRun = "Training Run"
  case apiService = "API Service"
  case dataApp = "Data App"
  case vectorDatabase = "Vector Database"
  case buildWorkspace = "Build Workspace"
  case webWorkspace = "Web Workspace"
  case projectWorkspace = "Project Workspace"
  case runtimeGroup = "Runtime Group"

  public var symbolName: String {
    switch self {
    case .aiMLLab:
      "brain"
    case .localLLMStack:
      "text.bubble"
    case .notebookSession:
      "book"
    case .trainingRun:
      "chart.line.uptrend.xyaxis"
    case .apiService:
      "network"
    case .dataApp:
      "chart.bar"
    case .vectorDatabase:
      "square.stack.3d.up"
    case .buildWorkspace:
      "hammer"
    case .webWorkspace:
      "curlybraces"
    case .projectWorkspace:
      "folder"
    case .runtimeGroup:
      "square.grid.2x2"
    }
  }
}

public enum DevWorkflowRisk: String, Comparable, Sendable {
  case normal = "Normal"
  case busy = "Busy"
  case heavy = "Heavy"

  public static func < (lhs: DevWorkflowRisk, rhs: DevWorkflowRisk) -> Bool {
    lhs.rank < rhs.rank
  }

  private var rank: Int {
    switch self {
    case .normal:
      0
    case .busy:
      1
    case .heavy:
      2
    }
  }
}

public struct DevWorkflow: Identifiable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let subtitle: String
  public let kind: DevWorkflowKind
  public let processIDs: [Int32]
  public let primaryProject: String?
  public let tags: [DevProcessTag]
  public let totalCPU: Double
  public let totalMemoryBytes: Int64
  public let risk: DevWorkflowRisk
  public let confidence: Double
  public let summary: String
  public let suggestedAction: String

  public var processCount: Int {
    processIDs.count
  }

  public init(
    id: String,
    title: String,
    subtitle: String,
    kind: DevWorkflowKind,
    processIDs: [Int32],
    primaryProject: String?,
    tags: [DevProcessTag],
    totalCPU: Double,
    totalMemoryBytes: Int64,
    risk: DevWorkflowRisk,
    confidence: Double,
    summary: String,
    suggestedAction: String
  ) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.kind = kind
    self.processIDs = processIDs
    self.primaryProject = primaryProject
    self.tags = tags
    self.totalCPU = totalCPU
    self.totalMemoryBytes = totalMemoryBytes
    self.risk = risk
    self.confidence = confidence
    self.summary = summary
    self.suggestedAction = suggestedAction
  }
}

public struct DevProcessInsight: Equatable, Sendable {
  public let title: String
  public let role: String
  public let resourceBehavior: String
  public let workflowContext: String
  public let safeAction: String
  public let confidence: Double
}

public enum ProcessIntelligence {
  public static let workflowIDPrefix = "workflow:"
  private static let maximumWorkflowTitleLength = 72
  private static let maximumWorkflowCount = 12

  private struct WorkflowProject: Hashable {
    let id: String
    let title: String
  }

  public static func workflows(for items: [ClassifiedDevProcess]) -> [DevWorkflow] {
    workflows(for: items, workspaceOwnerComponents: configuredWorkspaceOwnerComponents)
  }

  static func uncappedWorkflows(for items: [ClassifiedDevProcess]) -> [DevWorkflow] {
    uncappedWorkflows(for: items, workspaceOwnerComponents: configuredWorkspaceOwnerComponents)
  }

  static func workflows(
    for items: [ClassifiedDevProcess],
    workspaceOwnerComponents: Set<String>
  ) -> [DevWorkflow] {
    presentedWorkflows(
      uncappedWorkflows(for: items, workspaceOwnerComponents: workspaceOwnerComponents)
    )
  }

  private static func uncappedWorkflows(
    for items: [ClassifiedDevProcess],
    workspaceOwnerComponents: Set<String>
  ) -> [DevWorkflow] {
    let aiItems = items.filter(isAIMLRelated)
    var workflows: [DevWorkflow] = []

    if !aiItems.isEmpty {
      workflows.append(makeWorkflow(
        id: "\(workflowIDPrefix)ai-ml-lab",
        title: "AI / ML Lab",
        kind: .aiMLLab,
        items: aiItems,
        primaryProject: primaryProject(
          for: aiItems,
          workspaceOwnerComponents: workspaceOwnerComponents
        ),
        summary: "Notebook kernels, training jobs, LLM services, vector stores, APIs, and data apps detected in the current local development session.",
        suggestedAction: "Use this view to inspect related AI/ML processes before terminating model servers or kernels."
      ))
    }

    let llmItems = items.filter { item in
      item.classification.kind == .ai ||
      item.classification.tags.contains(.llmServer) ||
      item.classification.tags.contains(.vectorDB)
    }
    if !llmItems.isEmpty {
      workflows.append(makeWorkflow(
        id: "\(workflowIDPrefix)local-llm-stack",
        title: "Local LLM Stack",
        kind: .localLLMStack,
        items: llmItems,
        primaryProject: primaryProject(
          for: llmItems,
          workspaceOwnerComponents: workspaceOwnerComponents
        ),
        summary: "Local model servers, inference runtimes, or vector database processes are active.",
        suggestedAction: "Check memory pressure before closing model servers; they can be expensive to restart."
      ))
    }

    let projectGroups = Dictionary(grouping: items) { item in
      canonicalProject(
        for: item,
        workspaceOwnerComponents: workspaceOwnerComponents
      ) ?? WorkflowProject(id: "unassigned", title: "Unassigned")
    }

    for (project, groupedItems) in projectGroups where shouldCreateProjectWorkflow(project: project, items: groupedItems) {
      let kind = workflowKind(for: groupedItems)
      workflows.append(makeWorkflow(
        id: "\(workflowIDPrefix)project-\(project.id)-\(kind.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))",
        title: workflowTitle(project: project.title, kind: kind),
        kind: kind,
        items: groupedItems,
        primaryProject: project.id == "unassigned" ? nil : project.title,
        summary: workflowSummary(project: project.title, kind: kind, items: groupedItems),
        suggestedAction: "Inspect the process tree before terminating this workflow; grouped rows may depend on each other."
      ))
    }

    return unique(workflows).filter {
      let title = $0.title.trimmingCharacters(in: .whitespacesAndNewlines)
      return !title.isEmpty && title.count <= maximumWorkflowTitleLength
    }
  }

  static func presentedWorkflows(_ workflows: [DevWorkflow]) -> [DevWorkflow] {
    let sortedWorkflows = workflows
      .sorted { lhs, rhs in
        if lhs.risk != rhs.risk {
          return lhs.risk > rhs.risk
        }
        let lhsKindPriority = workflowKindPriority(lhs.kind)
        let rhsKindPriority = workflowKindPriority(rhs.kind)
        if lhsKindPriority != rhsKindPriority {
          return lhsKindPriority < rhsKindPriority
        }
        if lhs.primaryProject != rhs.primaryProject {
          let projectComparison = (lhs.primaryProject ?? "")
            .localizedStandardCompare(rhs.primaryProject ?? "")
          if projectComparison != .orderedSame {
            return projectComparison == .orderedAscending
          }
        }
        let titleComparison = lhs.title.localizedStandardCompare(rhs.title)
        if titleComparison != .orderedSame {
          return titleComparison == .orderedAscending
        }
        return lhs.id < rhs.id
      }

    guard sortedWorkflows.count > maximumWorkflowCount else {
      return sortedWorkflows
    }

    let aggregateWorkflows = sortedWorkflows.filter {
      $0.kind == .aiMLLab || $0.kind == .localLLMStack
    }
    let projectWorkflows = sortedWorkflows.filter {
      $0.kind != .aiMLLab && $0.kind != .localLLMStack
    }
    let retainedIDs = Set(
      (aggregateWorkflows + projectWorkflows)
        .prefix(maximumWorkflowCount)
        .map(\.id)
    )
    return sortedWorkflows.filter { retainedIDs.contains($0.id) }
  }

  public static func workflow(containing item: ClassifiedDevProcess, in workflows: [DevWorkflow]) -> DevWorkflow? {
    workflows.first { $0.processIDs.contains(item.process.pid) }
  }

  static func rehydratedWorkflows(
    _ workflows: [DevWorkflow],
    for items: [ClassifiedDevProcess]
  ) -> [DevWorkflow] {
    let itemsByPID = Dictionary(
      items.map { ($0.process.pid, $0) },
      uniquingKeysWith: { _, latest in latest }
    )

    return workflows.map { workflow in
      let workflowItems = workflow.processIDs.compactMap { itemsByPID[$0] }
      let totalCPU = workflowItems.reduce(0) {
        $0 + ($1.process.resourceUsage?.cpuPercent ?? 0)
      }
      let totalMemory = workflowItems.reduce(Int64(0)) {
        $0 + ($1.process.resourceUsage?.residentMemoryBytes ?? 0)
      }
      return DevWorkflow(
        id: workflow.id,
        title: workflow.title,
        subtitle: workflowSubtitle(
          count: workflow.processIDs.count,
          cpu: totalCPU,
          memory: totalMemory
        ),
        kind: workflow.kind,
        processIDs: workflow.processIDs,
        primaryProject: workflow.primaryProject,
        tags: workflow.tags,
        totalCPU: totalCPU,
        totalMemoryBytes: totalMemory,
        risk: workflowRisk(totalCPU: totalCPU, totalMemoryBytes: totalMemory),
        confidence: workflow.confidence,
        summary: workflow.summary,
        suggestedAction: workflow.suggestedAction
      )
    }
  }

  public static func insight(
    for item: ClassifiedDevProcess,
    workflow: DevWorkflow?,
    familySummary: ProcessFamilySummary?,
    metricHistory: [DevProcessMetricSample],
    actionDecision: ProcessActionDecision = .allowed
  ) -> DevProcessInsight {
    let tags = item.classification.tags
    let role = processRole(for: item)
    let behavior = resourceBehavior(for: item, metricHistory: metricHistory)
    let workflowContext = workflow.map {
      "\($0.title) includes \($0.processCount) related process\($0.processCount == 1 ? "" : "es")."
    } ?? "No larger workflow was detected for this process yet."
    let safeAction: String
    if let reason = actionDecision.reason {
      safeAction = "Protected: \(reason)."
    } else if let familySummary, familySummary.descendantCount > 0 {
      safeAction = "Prefer TERM Tree only when you intend to stop this entire user workflow; \(familySummary.descendantCount) descendants were detected."
    } else if tags.contains(.llmServer) || item.classification.kind == .ai {
      safeAction = "Model servers can hold large memory allocations; confirm no clients are active before stopping it."
    } else {
      safeAction = "TERM is the safest first signal. Use force only when the process ignores TERM."
    }

    return DevProcessInsight(
      title: processInsightTitle(for: item),
      role: role,
      resourceBehavior: behavior,
      workflowContext: workflowContext,
      safeAction: safeAction,
      confidence: tags.isEmpty ? 0.72 : 0.88
    )
  }

  private static func isAIMLRelated(_ item: ClassifiedDevProcess) -> Bool {
    item.classification.kind == .ai || !item.classification.tags.isEmpty
  }

  private static func makeWorkflow(
    id: String,
    title: String,
    kind: DevWorkflowKind,
    items: [ClassifiedDevProcess],
    primaryProject: String?,
    summary: String,
    suggestedAction: String
  ) -> DevWorkflow {
    let items = orderedAggregationItems(items)
    let processIDs = items.map(\.process.pid).sorted()
    let totalCPU = items.reduce(0) { $0 + ($1.process.resourceUsage?.cpuPercent ?? 0) }
    let totalMemory = items.reduce(Int64(0)) { $0 + ($1.process.resourceUsage?.residentMemoryBytes ?? 0) }
    let tags = uniqueTags(items.flatMap(\.classification.tags))
    let risk = workflowRisk(totalCPU: totalCPU, totalMemoryBytes: totalMemory)

    return DevWorkflow(
      id: id,
      title: title,
      subtitle: workflowSubtitle(count: processIDs.count, cpu: totalCPU, memory: totalMemory),
      kind: kind,
      processIDs: processIDs,
      primaryProject: primaryProject,
      tags: tags,
      totalCPU: totalCPU,
      totalMemoryBytes: totalMemory,
      risk: risk,
      confidence: tags.isEmpty ? 0.78 : 0.9,
      summary: summary,
      suggestedAction: suggestedAction
    )
  }

  private static func orderedAggregationItems(
    _ items: [ClassifiedDevProcess]
  ) -> [ClassifiedDevProcess] {
    items.sorted { lhs, rhs in
      let left = lhs.process
      let right = rhs.process
      if left.pid != right.pid {
        return left.pid < right.pid
      }
      if left.birthToken != right.birthToken {
        switch (left.birthToken, right.birthToken) {
        case let (.some(leftBirth), .some(rightBirth)):
          if leftBirth.seconds != rightBirth.seconds {
            return leftBirth.seconds < rightBirth.seconds
          }
          return leftBirth.microseconds < rightBirth.microseconds
        case (.none, .some):
          return true
        case (.some, .none):
          return false
        case (.none, .none):
          break
        }
      }
      if left.parentPID != right.parentPID {
        return left.parentPID < right.parentPID
      }
      if left.executable != right.executable {
        return left.executable < right.executable
      }
      if left.command != right.command {
        return left.command < right.command
      }
      return (left.currentDirectory ?? "") < (right.currentDirectory ?? "")
    }
  }

  private static func workflowKind(for items: [ClassifiedDevProcess]) -> DevWorkflowKind {
    let tags = Set(items.flatMap(\.classification.tags))
    let kinds = Set(items.map(\.classification.kind))

    if tags.contains(.training) {
      return .trainingRun
    }
    if tags.contains(.notebook) {
      return .notebookSession
    }
    if tags.contains(.dataApp) {
      return .dataApp
    }
    if tags.contains(.api) {
      return .apiService
    }
    if tags.contains(.vectorDB) {
      return .vectorDatabase
    }
    if kinds.contains(.swift) || kinds.contains(.rust) || kinds.contains(.go) || kinds.contains(.flutter) {
      return .buildWorkspace
    }
    if kinds.contains(.javascript) || kinds.contains(.webServer) {
      return .webWorkspace
    }
    return .projectWorkspace
  }

  private static func workflowTitle(project: String, kind: DevWorkflowKind) -> String {
    if project == "Unassigned" {
      return kind.rawValue
    }

    let lowerProject = project.lowercased()
    switch kind {
    case .trainingRun:
      if lowerProject == "training" {
        return "Training Run"
      }
      return "\(project) Training"
    case .notebookSession:
      if lowerProject == "notebook" {
        return "Notebook Session"
      }
      return "\(project) Notebook"
    case .apiService:
      if lowerProject == "api" {
        return "API Service"
      }
      return "\(project) API"
    case .dataApp:
      if lowerProject == "data" || lowerProject == "data app" {
        return "Data App"
      }
      return "\(project) Data App"
    case .vectorDatabase:
      if lowerProject == "vector" || lowerProject == "vector db" || lowerProject == "vector database" {
        return "Vector Database"
      }
      return "\(project) Vector DB"
    case .buildWorkspace:
      if lowerProject == "build" {
        return "Build Workspace"
      }
      return "\(project) Build"
    case .webWorkspace:
      if lowerProject == "web" {
        return "Web Workspace"
      }
      return "\(project) Web"
    case .projectWorkspace:
      return "\(project) Workspace"
    case .aiMLLab, .localLLMStack, .runtimeGroup:
      return kind.rawValue
    }
  }

  private static func workflowSummary(project: String, kind: DevWorkflowKind, items: [ClassifiedDevProcess]) -> String {
    let processWord = items.count == 1 ? "process" : "processes"
    if project == "Unassigned" {
      return "\(items.count) related \(processWord) detected without a stable project folder."
    }

    return "\(items.count) \(processWord) in \(project) are grouped as \(kind.rawValue.lowercased())."
  }

  private static func workflowSubtitle(count: Int, cpu: Double, memory: Int64) -> String {
    let memoryMB = Double(memory) / 1_048_576
    let memoryText = memoryMB >= 1024
      ? String(format: "%.1f GB", memoryMB / 1024)
      : String(format: "%.0f MB", memoryMB)
    let processWord = count == 1 ? "OS process" : "OS processes"
    return "\(count) \(processWord) · \(String(format: "%.0f%%", cpu)) CPU · \(memoryText)"
  }

  private static func workflowRisk(totalCPU: Double, totalMemoryBytes: Int64) -> DevWorkflowRisk {
    if totalCPU >= 80 || totalMemoryBytes >= 4_294_967_296 {
      return .heavy
    }
    if totalCPU >= 25 || totalMemoryBytes >= 1_073_741_824 {
      return .busy
    }
    return .normal
  }

  private static func shouldCreateProjectWorkflow(project: WorkflowProject, items: [ClassifiedDevProcess]) -> Bool {
    guard project.id != "unassigned",
          !isNoisyProjectComponent(project.title),
          items.contains(where: isDevelopmentWorkflowCandidate) else {
      return false
    }

    if items.count > 1 {
      return true
    }

    guard let item = items.first else {
      return false
    }

    let totalCPU = item.process.resourceUsage?.cpuPercent ?? 0
    let totalMemory = item.process.resourceUsage?.residentMemoryBytes ?? 0
    if totalCPU >= 25 || totalMemory >= 1_073_741_824 || !item.classification.tags.isEmpty {
      return true
    }

    if isDevelopmentWorkflowCandidate(item) {
      return hasDevelopmentContext(item)
    }

    return false
  }

  private static func isDevelopmentWorkflowCandidate(_ item: ClassifiedDevProcess) -> Bool {
    switch item.classification.kind {
    case .javascript, .python, .swift, .rust, .go, .flutter, .java,
         .database, .container, .webServer, .ai, .mcp:
      return true
    case .browser, .macApp, .backgroundAgent, .systemService, .shell, .other:
      return false
    }
  }

  private static func hasDevelopmentContext(_ item: ClassifiedDevProcess) -> Bool {
    if let currentDirectory = item.process.currentDirectory,
       canonicalProject(fromPath: currentDirectory) != nil {
      return true
    }
    return canonicalProject(fromCommand: item.process.command) != nil
  }

  private static func workflowKindPriority(_ kind: DevWorkflowKind) -> Int {
    switch kind {
    case .aiMLLab:
      0
    case .localLLMStack:
      1
    case .trainingRun:
      2
    case .notebookSession:
      3
    case .dataApp:
      4
    case .apiService:
      5
    case .vectorDatabase:
      6
    case .buildWorkspace:
      7
    case .webWorkspace:
      8
    case .projectWorkspace:
      9
    case .runtimeGroup:
      10
    }
  }

  private static func processRole(for item: ClassifiedDevProcess) -> String {
    let tags = item.classification.tags
    if tags.contains(.training) {
      return "Training or fine-tuning workload"
    }
    if tags.contains(.notebook) {
      return "Notebook kernel or interactive research session"
    }
    if tags.contains(.llmServer) {
      return "Local LLM serving process"
    }
    if tags.contains(.vectorDB) {
      return "Vector storage or retrieval service"
    }
    if tags.contains(.api) {
      return "Local API server"
    }
    if tags.contains(.dataApp) {
      return "Interactive data application"
    }
    if item.classification.kind == .ai {
      return "Local AI runtime"
    }
    return "\(item.classification.kind.rawValue) development process"
  }

  private static func processInsightTitle(for item: ClassifiedDevProcess) -> String {
    let tags = item.classification.tags
    if tags.contains(.training) {
      return "Training workload"
    }
    if tags.contains(.notebook) {
      return "Notebook session"
    }
    if tags.contains(.llmServer) {
      return "LLM server"
    }
    if tags.contains(.vectorDB) {
      return "Vector database"
    }
    if tags.contains(.api) {
      return "API service"
    }
    return item.classification.displayName
  }

  private static func resourceBehavior(for item: ClassifiedDevProcess, metricHistory: [DevProcessMetricSample]) -> String {
    let cpu = item.process.resourceUsage?.cpuPercent ?? 0
    let memory = item.process.resourceUsage?.residentMemoryBytes ?? 0
    if cpu >= 80 {
      return "High CPU now; this process is actively consuming compute."
    }
    if memory >= 4_294_967_296 {
      return "High memory footprint; check whether this is a model, notebook, or build cache."
    }
    if metricHistory.count >= 3,
       let first = metricHistory.first,
       let last = metricHistory.last,
       last.residentMemoryBytes > first.residentMemoryBytes + 536_870_912 {
      return "Memory increased by more than 512 MB during the visible history window."
    }
    return "Resource usage is within the normal range for the current sample."
  }

  private static func primaryProject(
    for items: [ClassifiedDevProcess],
    workspaceOwnerComponents: Set<String>
  ) -> String? {
    let counts = Dictionary(
      grouping: items.compactMap {
        canonicalProject(
          for: $0,
          workspaceOwnerComponents: workspaceOwnerComponents
        )?.title
      },
      by: { $0 }
    )
      .mapValues(\.count)
    return counts.sorted { lhs, rhs in
      if lhs.value != rhs.value {
        return lhs.value > rhs.value
      }
      return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
    }
    .first?
    .key
  }

  private static func canonicalProject(
    for item: ClassifiedDevProcess,
    workspaceOwnerComponents: Set<String> = configuredWorkspaceOwnerComponents
  ) -> WorkflowProject? {
    if let currentDirectory = item.process.currentDirectory,
       let project = canonicalProject(
         fromPath: currentDirectory,
         workspaceOwnerComponents: workspaceOwnerComponents
       ) {
      return project
    }

    if let project = canonicalProject(
      fromCommand: item.process.command,
      workspaceOwnerComponents: workspaceOwnerComponents
    ) {
      return project
    }

    return nil
  }

  private static func commandPathCandidates(_ command: String) -> [String] {
    let home = NSHomeDirectory()
    return commandTokens(command)
      .filter { token in
        token.hasPrefix(home + "/") &&
        !token.contains("=") &&
        !token.contains(".app/Contents/")
      }
  }

  private static func commandTokens(_ command: String) -> [String] {
    var tokens: [String] = []
    var token = ""
    var quote: Character?
    var requiresBoundary = false

    for character in command {
      if let activeQuote = quote {
        if character == activeQuote {
          quote = nil
          requiresBoundary = true
        } else {
          token.append(character)
        }
      } else if requiresBoundary {
        guard character.isWhitespace else {
          return []
        }
        appendCommandToken(&token, to: &tokens)
        requiresBoundary = false
      } else if character == "\"" || character == "'" {
        guard token.isEmpty else {
          return []
        }
        quote = character
      } else if character.isWhitespace {
        appendCommandToken(&token, to: &tokens)
      } else {
        token.append(character)
      }
    }

    guard quote == nil else {
      return []
    }
    appendCommandToken(&token, to: &tokens)
    return tokens
  }

  private static func appendCommandToken(_ token: inout String, to tokens: inout [String]) {
    guard !token.isEmpty else {
      return
    }
    tokens.append(token)
    token.removeAll(keepingCapacity: true)
  }

  private static func canonicalProject(
    fromCommand command: String,
    workspaceOwnerComponents: Set<String> = configuredWorkspaceOwnerComponents
  ) -> WorkflowProject? {
    commandPathCandidates(command).lazy.compactMap {
      canonicalProject(
        fromPath: $0,
        workspaceOwnerComponents: workspaceOwnerComponents
      )
    }.first
  }

  static func lexicallyNormalizedAbsolutePath(
    _ rawValue: String,
    constrainedTo root: String? = nil
  ) -> String? {
    guard rawValue.hasPrefix("/") else {
      return nil
    }

    let requiredComponents: [Substring]
    if let root {
      guard let normalizedRoot = lexicallyNormalizedAbsolutePath(root) else {
        return nil
      }
      requiredComponents = normalizedRoot.split(separator: "/")
    } else {
      requiredComponents = []
    }

    var components: [Substring] = []
    for component in rawValue.split(separator: "/", omittingEmptySubsequences: true) {
      switch component {
      case ".":
        continue
      case "..":
        guard components.count > requiredComponents.count else {
          return nil
        }
        components.removeLast()
      default:
        components.append(component)
        let componentIndex = components.count - 1
        if componentIndex < requiredComponents.count,
           component != requiredComponents[componentIndex] {
          return nil
        }
      }
    }

    guard components.count >= requiredComponents.count else {
      return nil
    }
    guard !components.isEmpty else {
      return "/"
    }
    return "/" + components.joined(separator: "/")
  }

  private static func canonicalProject(
    fromPath rawValue: String,
    workspaceOwnerComponents: Set<String> = configuredWorkspaceOwnerComponents
  ) -> WorkflowProject? {
    guard let home = lexicallyNormalizedAbsolutePath(NSHomeDirectory()),
          let path = lexicallyNormalizedAbsolutePath(rawValue, constrainedTo: home) else {
      return nil
    }
    guard path.hasPrefix(home + "/") else {
      return nil
    }

    let relativePath = String(path.dropFirst(home.count + 1))
    let components = relativePath.split(separator: "/").map(String.init)
    guard !components.isEmpty else {
      return nil
    }

    let lowerComponents = components.map { $0.lowercased() }
    guard !lowerComponents.contains(where: { $0.hasSuffix(".app") }) else {
      return nil
    }

    let root = lowerComponents[0]
    if root == ".codex" {
      return canonicalCodexProject(from: components)
    }

    guard devWorkspaceMarkers.contains(root) else {
      return nil
    }
    let remaining = Array(components.dropFirst())
    if let component = stableWorkspaceComponent(
      from: remaining,
      workspaceOwnerComponents: workspaceOwnerComponents
    ) {
      return WorkflowProject(id: stableID(component), title: readableProjectTitle(component))
    }

    return nil
  }

  private static func canonicalCodexProject(from components: [String]) -> WorkflowProject {
    if let cacheIndex = components.firstIndex(of: "cache") {
      let remaining = Array(components.dropFirst(cacheIndex + 1))
        .filter { !isGenericProjectComponent($0) && !isNoisyProjectComponent($0) }
      let pluginComponent = remaining.first { !$0.hasPrefix("openai-") } ?? "codex"
      return WorkflowProject(id: "codex-\(stableID(pluginComponent))", title: readableProjectTitle(pluginComponent))
    }

    if components.contains(".agents") {
      return WorkflowProject(id: "codex-agents", title: "Codex Agents")
    }

    return WorkflowProject(id: "codex", title: "Codex")
  }

  private static func stableWorkspaceComponent<S: Sequence>(
    from components: S,
    workspaceOwnerComponents: Set<String>
  ) -> String? where S.Element == String {
    let values = Array(components)
    let ownerComponents = Set(workspaceOwnerComponents.map { $0.lowercased() })
      .union(workspaceBucketComponents)
    for (index, component) in values.enumerated() {
      let lowered = component.lowercased()
      if (ownerComponents.contains(lowered) || devWorkspaceMarkers.contains(lowered)),
         index + 1 < values.count {
        continue
      }
      if let stableComponent = stableProjectComponent(component) {
        return stableComponent
      }
    }
    return nil
  }

  private static var devWorkspaceMarkers: Set<String> {
    ["apps", "code", "dev", "developer", "projects", "source", "src", "workspace", "workspaces"]
  }

  private static var workspaceBucketComponents: Set<String> {
    ["example", "github", "personal", "repos", "team", "work"]
  }

  private static func stableProjectComponent(_ value: String) -> String? {
    guard !isGenericProjectComponent(value), !isNoisyProjectComponent(value) else {
      return nil
    }
    return value
  }

  private static var configuredWorkspaceOwnerComponents: Set<String> {
    let configured = ProcessInfo.processInfo.environment["DEVSCOPE_WORKSPACE_OWNER_COMPONENTS"] ?? ""
    return Set(
      configured
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .filter { !$0.isEmpty }
    )
  }

  private static func isGenericProjectComponent(_ value: String) -> Bool {
    let lowered = value.lowercased()
    return [
      "cache", "plugins", "skills", "runtime", "runtimes", "node_modules",
      "dist", "build", ".build", "target", "tmp", "temp", "logs", "lib",
      "library", "application support", "contents", "resources"
    ].contains(lowered)
  }

  private static func isNoisyProjectComponent(_ value: String) -> Bool {
    let lowered = value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}"))
      .lowercased()
    if lowered.range(of: #"^\d+\.\d+(\.\d+)?([.-][a-z0-9]+)?$"#, options: .regularExpression) != nil {
      return true
    }
    if lowered.range(of: #"^(python|python3|node|ruby|perl|java|swift|bash|zsh|sh)(\d+(\.\d+)*)?$"#, options: .regularExpression) != nil {
      return true
    }
    if lowered.range(of: #"^[a-f0-9]{7,40}$"#, options: .regularExpression) != nil {
      return true
    }
    if lowered.range(of: #"^kernel-[a-f0-9-]{12,}$"#, options: .regularExpression) != nil {
      return true
    }
    if lowered.count >= 22, lowered.range(of: #"^[a-z0-9_-]+$"#, options: .regularExpression) != nil {
      return true
    }
    return false
  }

  private static func readableProjectTitle(_ value: String) -> String {
    let words = value
      .replacingOccurrences(of: #"[_-]+"#, with: " ", options: .regularExpression)
      .split(separator: " ")
      .map(String.init)

    guard !words.isEmpty else {
      return value
    }

    return words.map { word in
      let lower = word.lowercased()
      switch lower {
      case "ai", "ml", "llm", "mcp", "api", "ios", "ui", "gpu", "cpu":
        return lower.uppercased()
      case "xcodebuildmcp":
        return "XcodeBuildMCP"
      case "devscope":
        return "DevScope"
      case "codex":
        return "Codex"
      default:
        return lower.prefix(1).uppercased() + String(lower.dropFirst())
      }
    }
    .joined(separator: " ")
  }

  private static func stableID(_ value: String) -> String {
    let canonical = value
      .precomposedStringWithCanonicalMapping
      .lowercased()
    let slug = canonical
      .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

    guard slug != canonical else {
      return slug
    }

    let escaped = canonical.utf8
      .map { String(format: "%02x", $0) }
      .joined()
    return "\(slug.isEmpty ? "project" : slug)--\(escaped)"
  }

  private static func unique(_ workflows: [DevWorkflow]) -> [DevWorkflow] {
    var seen = Set<String>()
    return workflows.filter { workflow in
      seen.insert(workflow.id).inserted
    }
  }

  private static func uniqueTags(_ tags: [DevProcessTag]) -> [DevProcessTag] {
    var seen = Set<String>()
    return tags
      .sorted { lhs, rhs in
        if lhs.id != rhs.id {
          return lhs.id < rhs.id
        }
        if lhs.title != rhs.title {
          return lhs.title < rhs.title
        }
        return lhs.symbolName < rhs.symbolName
      }
      .filter { tag in
        seen.insert(tag.id).inserted
      }
  }
}
