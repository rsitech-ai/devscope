import Foundation

public struct ProcessMetricHistoryStore: Sendable {
  private struct Entry: Sendable {
    let identity: ProcessCacheIdentity
    var samples: [DevProcessMetricSample]
  }

  private let limit: Int
  private var entries: [Int32: Entry] = [:]

  public init(limit: Int) {
    precondition(limit > 0, "Metric history limit must be positive")
    self.limit = limit
  }

  public mutating func record(
    processes: [DevProcess],
    gpuMetric: DevGPUMetric?,
    timestamp: Date
  ) {
    let activeProcessIDs = Set(processes.map(\.pid))
    let inactiveProcessIDs = entries.keys.filter { !activeProcessIDs.contains($0) }
    for processID in inactiveProcessIDs {
      entries.removeValue(forKey: processID)
    }

    for process in processes {
      let identity = ProcessCacheIdentity(process: process)
      if entries[process.pid]?.identity != identity {
        entries[process.pid] = Entry(identity: identity, samples: [])
      }
      guard let usage = process.resourceUsage else {
        continue
      }

      let emptyEntry = Entry(identity: identity, samples: [])
      entries[process.pid, default: emptyEntry].samples.append(
        DevProcessMetricSample(
          timestamp: timestamp,
          cpuPercent: usage.cpuPercent,
          residentMemoryBytes: usage.residentMemoryBytes,
          gpuPercent: gpuMetric?.utilizationPercent
        )
      )
      let overflow = (entries[process.pid]?.samples.count ?? 0) - limit
      if overflow > 0 {
        entries[process.pid]?.samples.removeFirst(overflow)
      }
    }
  }

  public func history(for processID: Int32) -> [DevProcessMetricSample] {
    entries[processID]?.samples ?? []
  }
}
