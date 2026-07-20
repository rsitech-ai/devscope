public struct ProcessIdentity: Equatable, Hashable, Sendable {
  public let pid: Int32
  public let executable: String
  public let command: String
  public let birthToken: ProcessBirthToken?

  public init(process: DevProcess) {
    pid = process.pid
    executable = process.executable
    command = process.command
    birthToken = process.birthToken
  }

  public init(
    pid: Int32,
    executable: String = "",
    command: String = "",
    birthToken: ProcessBirthToken?
  ) {
    self.pid = pid
    self.executable = executable
    self.command = command
    self.birthToken = birthToken
  }

  public func hasSameBirthIdentity(as other: ProcessIdentity) -> Bool {
    guard let birthToken, let otherBirthToken = other.birthToken else {
      return false
    }
    return pid == other.pid && birthToken == otherBirthToken
  }
}

public enum ProcessSignalObservation {
  public static func observe(
    targets: [ProcessIdentity],
    in currentProcesses: [DevProcess]
  ) -> ProcessSignalObservationSummary {
    let currentByPID = Dictionary(
      currentProcesses.map { ($0.pid, $0) },
      uniquingKeysWith: { _, latest in latest }
    )
    let observations = targets.map { target in
      let state: ProcessSignalObservationState
      guard let expectedBirthToken = target.birthToken else {
        state = .unverifiable
        return ProcessSignalTargetObservation(target: target, state: state)
      }
      guard let current = currentByPID[target.pid] else {
        state = .exitedOrReplaced
        return ProcessSignalTargetObservation(target: target, state: state)
      }
      guard let currentBirthToken = current.birthToken else {
        state = .unverifiable
        return ProcessSignalTargetObservation(target: target, state: state)
      }
      state = currentBirthToken == expectedBirthToken ? .stillRunning : .exitedOrReplaced
      return ProcessSignalTargetObservation(target: target, state: state)
    }
    return ProcessSignalObservationSummary(observations: observations)
  }
}

public enum ProcessSignalObservationState: Equatable, Sendable {
  case stillRunning
  case exitedOrReplaced
  case unverifiable
}

public struct ProcessSignalTargetObservation: Equatable, Sendable {
  public let target: ProcessIdentity
  public let state: ProcessSignalObservationState

  public init(target: ProcessIdentity, state: ProcessSignalObservationState) {
    self.target = target
    self.state = state
  }
}

public struct ProcessSignalObservationSummary: Equatable, Sendable {
  public let observations: [ProcessSignalTargetObservation]

  public init(observations: [ProcessSignalTargetObservation]) {
    self.observations = observations
  }

  public var verifiesAllTargetsStopped: Bool {
    !observations.isEmpty && observations.allSatisfy { $0.state == .exitedOrReplaced }
  }

  public var stillRunning: [ProcessIdentity] {
    targets(with: .stillRunning)
  }

  public var exitedOrReplaced: [ProcessIdentity] {
    targets(with: .exitedOrReplaced)
  }

  public var unverifiable: [ProcessIdentity] {
    targets(with: .unverifiable)
  }

  private func targets(with state: ProcessSignalObservationState) -> [ProcessIdentity] {
    observations.compactMap { observation in
      observation.state == state ? observation.target : nil
    }
  }
}

public struct ProcessPartialSignalVerificationPresentation: Equatable, Sendable {
  public let title: String
  public let statusMessage: String
  public let detail: String
  public let symbolName: String

  public static func make(
    signalName: String,
    observation: ProcessSignalObservationSummary,
    failedTarget: ProcessIdentity,
    reason: String
  ) -> ProcessPartialSignalVerificationPresentation {
    let stopped = observation.exitedOrReplaced
    let stillRunning = observation.stillRunning
    let unverifiable = observation.unverifiable
    let stoppedText = "\(stopped.count) signaled process\(stopped.count == 1 ? "" : "es") stopped"
    let failedText = "PID \(failedTarget.pid) failed: \(reason)"
    let unsignaledText = "The failed target and all remaining tree targets were not signaled"

    if stillRunning.isEmpty, unverifiable.isEmpty {
      return ProcessPartialSignalVerificationPresentation(
        title: "Partial result verified",
        statusMessage: "\(signalName) partial result verified",
        detail: "\(stoppedText). \(failedText). \(unsignaledText).",
        symbolName: "exclamationmark.triangle.fill"
      )
    }

    var details: [String] = []
    if !stopped.isEmpty {
      details.append(stoppedText)
    }
    if !stillRunning.isEmpty {
      details.append("Still running: \(pidList(stillRunning))")
    }
    if !unverifiable.isEmpty {
      details.append("Could not verify: \(pidList(unverifiable))")
    }
    details.append(failedText)
    details.append(unsignaledText)
    return ProcessPartialSignalVerificationPresentation(
      title: "Partial result not fully verified",
      statusMessage: "\(signalName) partial result remains unresolved",
      detail: details.joined(separator: ". ") + ".",
      symbolName: "exclamationmark.triangle.fill"
    )
  }

  private static func pidList(_ identities: [ProcessIdentity]) -> String {
    identities.map(\.pid).sorted().map(String.init).joined(separator: ", ")
  }
}
