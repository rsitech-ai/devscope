import Foundation

struct ProcessWorkflowCache: Sendable {
  typealias Build = @Sendable ([ClassifiedDevProcess]) -> [DevWorkflow]

  private struct Fingerprint: Equatable, Sendable {
    let processes: [Process]

    init(_ items: [ClassifiedDevProcess]) {
      processes = items.map(Process.init)
    }
  }

  private struct Process: Equatable, Sendable {
    let pid: Int32
    let birthToken: ProcessBirthToken?
    let parentPID: Int32
    let executable: String
    let command: String
    let currentDirectory: String?
    let kind: DevRuntimeKind
    let displayName: String
    let projectHint: String?
    let tags: [DevProcessTag]

    init(_ item: ClassifiedDevProcess) {
      pid = item.process.pid
      birthToken = item.process.birthToken
      parentPID = item.process.parentPID
      executable = item.process.executable
      command = item.process.command
      currentDirectory = item.process.currentDirectory
      kind = item.classification.kind
      displayName = item.classification.displayName
      projectHint = item.classification.projectHint
      tags = item.classification.tags
    }
  }

  private let build: Build
  private var cachedFingerprint: Fingerprint?
  private var cachedWorkflows: [DevWorkflow] = []

  init(
    build: @escaping Build = { ProcessIntelligence.uncappedWorkflows(for: $0) }
  ) {
    self.build = build
  }

  mutating func workflows(
    for items: [ClassifiedDevProcess],
    now _: Date
  ) -> [DevWorkflow] {
    let workflowItems = items.filter(Self.isWorkflowRelevant)
    let fingerprint = Fingerprint(workflowItems)
    if fingerprint == cachedFingerprint {
      let rehydrated = ProcessIntelligence.rehydratedWorkflows(cachedWorkflows, for: items)
      return ProcessIntelligence.presentedWorkflows(rehydrated)
    }

    let workflows = build(workflowItems)
    cachedFingerprint = fingerprint
    cachedWorkflows = workflows
    return ProcessIntelligence.presentedWorkflows(workflows)
  }

  mutating func invalidate() {
    cachedFingerprint = nil
    cachedWorkflows = []
  }

  private static func isWorkflowRelevant(_ item: ClassifiedDevProcess) -> Bool {
    if item.classification.projectHint != nil || !item.classification.tags.isEmpty {
      return true
    }

    switch item.classification.kind {
    case .javascript, .python, .swift, .rust, .go, .flutter, .java,
         .database, .container, .webServer, .ai, .mcp:
      return true
    case .browser, .macApp, .backgroundAgent, .systemService, .shell, .other:
      return false
    }
  }
}
