import Darwin
import Foundation

public enum ProcessTree {
  public static func descendants(of rootPID: Int32, in processes: [DevProcess]) -> [DevProcess] {
    var childrenByParent: [Int32: [DevProcess]] = [:]
    for process in processes {
      childrenByParent[process.parentPID, default: []].append(process)
    }

    var result: [DevProcess] = []
    var queue = childrenByParent[rootPID] ?? []
    var cursor = 0
    var visited = Set<Int32>([rootPID])

    while cursor < queue.count {
      let next = queue[cursor]
      cursor += 1
      guard visited.insert(next.pid).inserted else {
        continue
      }
      result.append(next)
      queue.append(contentsOf: childrenByParent[next.pid] ?? [])
    }

    return result
  }
}

public struct ProcessSignalTarget: Equatable, Sendable {
  public let expectedIdentity: ProcessIdentity
  public let classifiedProcess: ClassifiedDevProcess

  init(classifiedProcess: ClassifiedDevProcess) {
    expectedIdentity = ProcessIdentity(process: classifiedProcess.process)
    self.classifiedProcess = classifiedProcess
  }

  init(expectedProcess: DevProcess, classifiedProcess: ClassifiedDevProcess) {
    expectedIdentity = ProcessIdentity(process: expectedProcess)
    self.classifiedProcess = classifiedProcess
  }
}

public struct ProcessSignalPlan: Equatable, Sendable {
  public let targets: [ProcessSignalTarget]

  public static func single(
    _ item: ClassifiedDevProcess,
    currentProcessID: Int32
  ) throws -> ProcessSignalPlan {
    try validated(
      targets: [ProcessSignalTarget(classifiedProcess: item)],
      currentProcessID: currentProcessID
    )
  }

  public static func tree(
    root: ClassifiedDevProcess,
    processes: [DevProcess],
    classifiedProcesses: [ClassifiedDevProcess],
    currentProcessID: Int32
  ) throws -> ProcessSignalPlan {
    let classifiedByPID = Dictionary(
      classifiedProcesses.map { ($0.process.pid, $0) },
      uniquingKeysWith: { _, latest in latest }
    )
    let descendants = ProcessTree.descendants(of: root.process.pid, in: processes)
    let descendantTargets = try descendants.reversed().map { process in
      guard let classifiedProcess = classifiedByPID[process.pid] else {
        throw ProcessKillError.targetClassificationUnavailable(pid: process.pid)
      }
      let target = ProcessSignalTarget(
        expectedProcess: process,
        classifiedProcess: classifiedProcess
      )
      if target.expectedIdentity.birthToken != nil,
         !target.expectedIdentity.hasSameBirthIdentity(
           as: ProcessIdentity(process: classifiedProcess.process)
         ) {
        throw ProcessKillError.targetClassificationMismatch(pid: process.pid)
      }
      return target
    }
    return try validated(
      targets: descendantTargets + [ProcessSignalTarget(classifiedProcess: root)],
      currentProcessID: currentProcessID
    )
  }

  private static func validated(
    targets: [ProcessSignalTarget],
    currentProcessID: Int32
  ) throws -> ProcessSignalPlan {
    for target in targets {
      guard target.expectedIdentity.birthToken != nil else {
        throw ProcessKillError.expectedIdentityUnavailable(
          pid: target.expectedIdentity.pid
        )
      }
      let decision = ProcessActionPolicy.decision(
        for: target.classifiedProcess,
        currentProcessID: currentProcessID
      )
      if let reason = decision.reason {
        throw ProcessKillError.protectedTarget(
          pid: target.expectedIdentity.pid,
          reason: reason
        )
      }
    }
    return ProcessSignalPlan(targets: targets)
  }
}

public struct ProcessKiller: Sendable {
  public typealias IdentityResolver = @Sendable (Int32) -> ProcessLiveIdentityResolution
  public typealias SignalSender = @Sendable (Int32, Int32) throws -> Void

  private let identityResolver: IdentityResolver
  private let signalSender: SignalSender

  public init() {
    identityResolver = Self.resolveLiveIdentity
    signalSender = Self.sendDarwinSignal
  }

  public init(
    identityResolver: @escaping IdentityResolver,
    signalSender: @escaping SignalSender
  ) {
    self.identityResolver = identityResolver
    self.signalSender = signalSender
  }

  public func terminate(
    _ item: ClassifiedDevProcess,
    currentProcessID: Int32
  ) throws -> [ProcessIdentity] {
    let plan = try ProcessSignalPlan.single(
      item,
      currentProcessID: currentProcessID
    )
    return try execute(plan, signal: SIGTERM)
  }

  public func forceTerminate(
    _ item: ClassifiedDevProcess,
    currentProcessID: Int32
  ) throws -> [ProcessIdentity] {
    let plan = try ProcessSignalPlan.single(
      item,
      currentProcessID: currentProcessID
    )
    return try execute(plan, signal: SIGKILL)
  }

  public func terminateTree(
    root: ClassifiedDevProcess,
    processes: [DevProcess],
    classifiedProcesses: [ClassifiedDevProcess],
    currentProcessID: Int32
  ) throws -> [ProcessIdentity] {
    let plan = try ProcessSignalPlan.tree(
      root: root,
      processes: processes,
      classifiedProcesses: classifiedProcesses,
      currentProcessID: currentProcessID
    )
    return try execute(plan, signal: SIGTERM)
  }

  public func forceTerminateTree(
    root: ClassifiedDevProcess,
    processes: [DevProcess],
    classifiedProcesses: [ClassifiedDevProcess],
    currentProcessID: Int32
  ) throws -> [ProcessIdentity] {
    let plan = try ProcessSignalPlan.tree(
      root: root,
      processes: processes,
      classifiedProcesses: classifiedProcesses,
      currentProcessID: currentProcessID
    )
    return try execute(plan, signal: SIGKILL)
  }

  private func validateLiveIdentity(_ expected: ProcessIdentity) throws {
    guard expected.birthToken != nil else {
      throw ProcessKillError.expectedIdentityUnavailable(pid: expected.pid)
    }
    switch identityResolver(expected.pid) {
    case let .identity(liveIdentity):
      guard liveIdentity.birthToken != nil else {
        throw ProcessKillError.liveIdentityUnavailable(pid: expected.pid)
      }
      guard expected.hasSameBirthIdentity(as: liveIdentity) else {
        throw ProcessKillError.identityMismatch(pid: expected.pid)
      }
    case .notRunning:
      throw ProcessKillError.targetNotRunning(pid: expected.pid)
    case .unverifiable:
      throw ProcessKillError.liveIdentityUnavailable(pid: expected.pid)
    }
  }

  private func execute(_ plan: ProcessSignalPlan, signal: Int32) throws -> [ProcessIdentity] {
    let targets = plan.targets.map(\.expectedIdentity)
    for target in targets {
      try validateLiveIdentity(target)
    }
    var signaledIdentities: [ProcessIdentity] = []
    for target in targets {
      do {
        try validateLiveIdentity(target)
        try signalSender(target.pid, signal)
        signaledIdentities.append(target)
      } catch {
        guard !signaledIdentities.isEmpty else {
          throw error
        }
        throw ProcessSignalExecutionFailure(
          signaledIdentities: signaledIdentities,
          failedTarget: target,
          underlyingError: error
        )
      }
    }
    return targets
  }

  static func resolveLiveIdentity(pid: Int32) -> ProcessLiveIdentityResolution {
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.stride
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: UInt8.self, capacity: size) { buffer in
        proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, buffer, Int32(size))
      }
    }

    if result == Int32(size), info.pbi_pid > 0 {
      return .identity(
        ProcessIdentity(
          pid: Int32(bitPattern: info.pbi_pid),
          birthToken: ProcessBirthToken(
            seconds: info.pbi_start_tvsec,
            microseconds: info.pbi_start_tvusec
          )
        )
      )
    }

    if kill(pid, 0) == 0 || errno == EPERM {
      return .unverifiable
    }
    return errno == ESRCH ? .notRunning : .unverifiable
  }

  private static func sendDarwinSignal(pid: Int32, signal: Int32) throws {
    guard kill(pid, signal) == 0 else {
      throw ProcessKillError.signalFailed(pid: pid, errnoCode: errno)
    }
  }
}

public enum ProcessLiveIdentityResolution: Equatable, Sendable {
  case identity(ProcessIdentity)
  case notRunning
  case unverifiable
}

public struct ProcessSignalExecutionFailure: LocalizedError {
  public let signaledIdentities: [ProcessIdentity]
  public let failedTarget: ProcessIdentity
  public let underlyingError: any Error

  public init(
    signaledIdentities: [ProcessIdentity],
    failedTarget: ProcessIdentity,
    underlyingError: any Error
  ) {
    self.signaledIdentities = signaledIdentities
    self.failedTarget = failedTarget
    self.underlyingError = underlyingError
  }

  public var errorDescription: String? {
    "Signaled \(signaledIdentities.count) process\(signaledIdentities.count == 1 ? "" : "es") before PID \(failedTarget.pid) failed: \(underlyingError.localizedDescription)"
  }
}

public enum ProcessKillError: LocalizedError, Equatable {
  case protectedTarget(pid: Int32, reason: String)
  case targetClassificationUnavailable(pid: Int32)
  case targetClassificationMismatch(pid: Int32)
  case expectedIdentityUnavailable(pid: Int32)
  case liveIdentityUnavailable(pid: Int32)
  case targetNotRunning(pid: Int32)
  case identityMismatch(pid: Int32)
  case signalFailed(pid: Int32, errnoCode: Int32)

  public var errorDescription: String? {
    switch self {
    case let .protectedTarget(pid, reason):
      "Refused to signal PID \(pid): \(reason)"
    case let .targetClassificationUnavailable(pid):
      "Refused to signal process tree because PID \(pid) has no current classification"
    case let .targetClassificationMismatch(pid):
      "Refused to signal process tree because PID \(pid) has a stale classification identity"
    case let .expectedIdentityUnavailable(pid):
      "Refused to signal PID \(pid) because its original birth identity is unknown"
    case let .liveIdentityUnavailable(pid):
      "Refused to signal PID \(pid) because its current birth identity could not be read"
    case let .targetNotRunning(pid):
      "Refused to signal PID \(pid) because the selected process is no longer running"
    case let .identityMismatch(pid):
      "PID \(pid) no longer belongs to the selected process"
    case let .signalFailed(pid, errnoCode):
      "Could not signal PID \(pid): \(String(cString: strerror(errnoCode)))"
    }
  }
}
