import DevScopeCore

struct ProcessSelectionResolution: Equatable {
  let selectedProcessID: Int32?
  let retainedProcess: ClassifiedDevProcess?
}

enum ProcessSelectionPolicy {
  static func reconcile(
    selectedProcessID: Int32?,
    retainedProcess: ClassifiedDevProcess?,
    currentProcesses: [ClassifiedDevProcess]
  ) -> ProcessSelectionResolution {
    guard let selectedProcessID else {
      return ProcessSelectionResolution(selectedProcessID: nil, retainedProcess: nil)
    }
    guard let current = currentProcesses.first(where: { $0.process.pid == selectedProcessID }) else {
      return ProcessSelectionResolution(
        selectedProcessID: selectedProcessID,
        retainedProcess: retainedProcess
      )
    }
    if let retainedProcess,
       retainedProcess.process.pid == selectedProcessID {
      guard let retainedBirth = retainedProcess.process.birthToken,
            let currentBirth = current.process.birthToken,
            retainedBirth == currentBirth else {
        return ProcessSelectionResolution(selectedProcessID: nil, retainedProcess: nil)
      }
    }
    return ProcessSelectionResolution(
      selectedProcessID: selectedProcessID,
      retainedProcess: current
    )
  }
}
