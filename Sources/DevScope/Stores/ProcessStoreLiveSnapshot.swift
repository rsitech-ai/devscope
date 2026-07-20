import DevScopeCore
import Foundation

struct ProcessStoreLiveSnapshot {
  static let emptyAutomationInventory = AutomationInventorySnapshot(
    generation: 0,
    records: [],
    health: [:],
    refreshedAt: Date(timeIntervalSince1970: 0)
  )

  var processes: [DevProcess] = []
  var classifiedProcesses: [ClassifiedDevProcess] = []
  var workflows: [DevWorkflow] = []
  var dashboardMetricHistory: [DevProcessMetricSample] = []
  var liveProcessIDs: Set<Int32> = []
  var automationInventory = Self.emptyAutomationInventory
  var automationLinksByProcessID: [Int32: AutomationProcessLink] = [:]
  var allAutomationLinksByProcessID: [Int32: [AutomationProcessLink]] = [:]
  var longRunningProcessIDs: Set<Int32> = []
  var statusMessage = "Ready"
  var lastRefresh: Date?

  func replacingAutomationProjection(
    _ projection: AutomationPresentationSnapshot
  ) -> ProcessStoreLiveSnapshot {
    var copy = self
    copy.automationInventory = projection.inventory
    copy.automationLinksByProcessID = projection.linksByProcessID
    copy.allAutomationLinksByProcessID = projection.allLinksByProcessID
    copy.longRunningProcessIDs = projection.longRunningProcessIDs
    return copy
  }
}
