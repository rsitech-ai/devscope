import DevScopeCore
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

struct WorkflowAINote: Equatable {
  let workflowID: String
  let text: String
}

struct WorkflowNoteCacheKey: Equatable, Sendable {
  private struct ProcessFacts: Equatable, Sendable {
    let identity: ProcessCacheIdentity
    let kind: DevRuntimeKind
    let displayName: String
    let projectName: String?
    let tags: [String]
    let cpuPercent: Double?
    let residentMemoryBytes: Int64?
    let redactedCommand: String
  }

  private let workflowID: String
  private let title: String
  private let kind: DevWorkflowKind
  private let processIDs: [Int32]
  private let primaryProject: String?
  private let tags: [String]
  private let totalCPU: Double
  private let totalMemoryBytes: Int64
  private let risk: DevWorkflowRisk
  private let summary: String
  private let processFacts: [ProcessFacts]

  init(workflow: DevWorkflow, items: [ClassifiedDevProcess]) {
    workflowID = workflow.id
    title = workflow.title
    kind = workflow.kind
    processIDs = workflow.processIDs
    primaryProject = workflow.primaryProject
    tags = workflow.tags.map(\.title)
    totalCPU = workflow.totalCPU
    totalMemoryBytes = workflow.totalMemoryBytes
    risk = workflow.risk
    summary = workflow.summary
    processFacts = items.map { item in
      ProcessFacts(
        identity: ProcessCacheIdentity(process: item.process),
        kind: item.classification.kind,
        displayName: item.classification.displayName,
        projectName: ProcessPresentation.projectName(for: item),
        tags: item.classification.tags.map(\.title),
        cpuPercent: item.process.resourceUsage?.cpuPercent,
        residentMemoryBytes: item.process.resourceUsage?.residentMemoryBytes,
        redactedCommand: ProcessPresentation.redactedCommand(item.process.command)
      )
    }
  }
}

actor WorkflowIntelligenceEnhancer {
  private struct CacheEntry {
    let key: WorkflowNoteCacheKey
    let note: WorkflowAINote
  }

  private var cache: [String: CacheEntry] = [:]

  func notes(for workflows: [DevWorkflow], items: [ClassifiedDevProcess]) async -> [String: WorkflowAINote] {
    guard await isAvailable() else {
      return [:]
    }

    let itemsByPID = Dictionary(uniqueKeysWithValues: items.map { ($0.process.pid, $0) })
    var notes: [String: WorkflowAINote] = [:]

    for workflow in workflows.prefix(4) {
      let relatedItems = workflow.processIDs.compactMap { itemsByPID[$0] }
      let cacheKey = WorkflowNoteCacheKey(workflow: workflow, items: relatedItems)
      if let cached = cache[workflow.id], cached.key == cacheKey {
        notes[workflow.id] = cached.note
        continue
      }

      guard let note = await generateNote(for: workflow, items: relatedItems) else {
        continue
      }

      cache[workflow.id] = CacheEntry(key: cacheKey, note: note)
      notes[workflow.id] = note
    }

    cache = cache.filter { entry in
      workflows.contains { $0.id == entry.key }
    }

    return notes
  }

  func isAvailable() async -> Bool {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
      return SystemLanguageModel.default.isAvailable
    }
    #endif
    return false
  }

  private func prompt(for workflow: DevWorkflow, items: [ClassifiedDevProcess]) -> String {
    let processFacts = items.prefix(10).map { item in
      let tags = item.classification.tags.map(\.title).joined(separator: ", ")
      let project = workflow.primaryProject ?? ProcessPresentation.projectName(for: item) ?? "Unknown"
      return """
      - PID \(item.process.pid), \(item.classification.kind.rawValue), label: \(item.classification.displayName), project: \(project), CPU: \(item.process.resourceUsage?.cpuPercent ?? 0), memory bytes: \(item.process.resourceUsage?.residentMemoryBytes ?? 0), tags: \(tags.isEmpty ? "none" : tags), command: \(ProcessPresentation.redactedCommand(item.process.command))
      """
    }
    .joined(separator: "\n")

    return """
    Create one concise operator note for this local developer workflow.
    Return only one sentence, max 24 words.
    Do not invent facts. Do not mention private paths. Do not suggest force kill.

    Workflow: \(workflow.title)
    Kind: \(workflow.kind.rawValue)
    Summary: \(workflow.summary)
    Total CPU: \(workflow.totalCPU)
    Total memory bytes: \(workflow.totalMemoryBytes)
    Processes:
    \(processFacts)
    """
  }

  private func generateNote(for workflow: DevWorkflow, items: [ClassifiedDevProcess]) async -> WorkflowAINote? {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
      let model = SystemLanguageModel.default
      guard model.isAvailable else {
        return nil
      }

      do {
        let session = LanguageModelSession(
          model: model,
          instructions: "You summarize local development process workflows. Be factual, conservative, and concise."
        )
        let response = try await session.respond(
          to: prompt(for: workflow, items: items),
          options: .devScopeGreedy(maximumResponseTokens: 40)
        )
        return sanitize(response.content, workflowID: workflow.id)
      } catch {
        return nil
      }
    }
    #endif

    return nil
  }

  private func sanitize(_ text: String, workflowID: String) -> WorkflowAINote? {
    let cleaned = text
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let lowered = cleaned.lowercased()

    guard cleaned.count >= 8,
          cleaned.count <= 180,
          !cleaned.contains("/Users/"),
          !cleaned.contains("force kill"),
          !lowered.contains("i think"),
          !lowered.contains("probably") else {
      return nil
    }

    return WorkflowAINote(workflowID: workflowID, text: cleaned)
  }
}
