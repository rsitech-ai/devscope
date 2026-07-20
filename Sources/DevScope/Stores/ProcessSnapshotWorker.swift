import DevScopeCore
import Foundation

actor ProcessSnapshotWorker {
  private var builder = ProcessSnapshotBuilder()

  func invalidateWorkspaceFacts() {
    builder.invalidateWorkspaceFacts()
  }

  func build(
    processes: [DevProcess],
    now: Date,
    graceInterval: TimeInterval
  ) -> DevProcessSnapshot {
    builder.build(processes: processes, now: now, graceInterval: graceInterval)
  }
}
