import Foundation

public struct ClassifiedProcessSnapshotStabilizer: Sendable {
  private struct Entry: Sendable {
    var item: ClassifiedDevProcess
    let firstSeen: Date
    var lastSeen: Date
  }

  private var entriesByPID: [Int32: Entry] = [:]
  public private(set) var liveProcessIDs: Set<Int32> = []

  public init() {}

  public mutating func merge(
    liveItems: [ClassifiedDevProcess],
    now: Date,
    graceInterval: TimeInterval
  ) -> [ClassifiedDevProcess] {
    liveProcessIDs = Set(liveItems.map(\.process.pid))

    for item in liveItems {
      let previous = entriesByPID[item.process.pid]
      entriesByPID[item.process.pid] = Entry(
        item: item,
        firstSeen: previous?.firstSeen ?? now,
        lastSeen: now
      )
    }

    entriesByPID = entriesByPID.filter { pid, entry in
      liveProcessIDs.contains(pid) || now.timeIntervalSince(entry.lastSeen) <= graceInterval
    }

    return entriesByPID.values
      .sorted { lhs, rhs in
        if lhs.firstSeen != rhs.firstSeen {
          return lhs.firstSeen < rhs.firstSeen
        }
        return lhs.item.process.pid < rhs.item.process.pid
      }
      .map(\.item)
  }
}
