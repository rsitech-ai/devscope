import Foundation

public struct DevProcessSnapshot: Equatable, Sendable {
  public let processes: [DevProcess]
  public let classified: [ClassifiedDevProcess]
  public let workflows: [DevWorkflow]
  public let liveProcessIDs: Set<Int32>

  public init(
    processes: [DevProcess],
    classified: [ClassifiedDevProcess],
    workflows: [DevWorkflow],
    liveProcessIDs: Set<Int32>
  ) {
    self.processes = processes
    self.classified = classified
    self.workflows = workflows
    self.liveProcessIDs = liveProcessIDs
  }
}

public struct ProcessSnapshotBuilder: Sendable {
  private var classificationCache = ProcessClassificationCache()
  private var stabilizer = ClassifiedProcessSnapshotStabilizer()
  private var workflowCache = ProcessWorkflowCache()
  private let workspaceFactsCache: WorkspaceFactsCache

  public init(workspaceFactsCache: WorkspaceFactsCache = WorkspaceFactsCache()) {
    self.workspaceFactsCache = workspaceFactsCache
  }

  public mutating func invalidateWorkspaceFacts() {
    workspaceFactsCache.invalidateAll()
    workflowCache.invalidate()
  }

  public mutating func build(
    processes: [DevProcess],
    now: Date,
    graceInterval: TimeInterval
  ) -> DevProcessSnapshot {
    let classified = classificationCache.classified(
      processes,
      workspaceFactsCache: workspaceFactsCache
    ).sorted { lhs, rhs in
      let leftProject = lhs.classification.projectHint ?? ""
      let rightProject = rhs.classification.projectHint ?? ""
      if leftProject != rightProject {
        return leftProject < rightProject
      }
      return lhs.classification.displayName < rhs.classification.displayName
    }
    let stabilized = stabilizer.merge(
      liveItems: classified,
      now: now,
      graceInterval: graceInterval
    )
    let workflows = workflowCache.workflows(for: stabilized, now: now)

    return DevProcessSnapshot(
      processes: stabilized.map(\.process),
      classified: stabilized,
      workflows: workflows,
      liveProcessIDs: stabilizer.liveProcessIDs
    )
  }
}
