import Darwin
import DevScopeCore
import Foundation

enum SystemAutomationCommandError: Error {
  case invalidExecutable
  case launchFailed
  case outputLimitExceeded
  case executionTimedOut
}

struct SystemAutomationCommandRunnerHooks: Sendable {
  var afterSpawnBeforeInstall: (@Sendable (pid_t) -> Void)?
  var afterInstall: (@Sendable (pid_t) -> Void)?
  var afterLeaderExitObserved: (@Sendable (pid_t) -> Void)?

  init(
    afterSpawnBeforeInstall: (@Sendable (pid_t) -> Void)? = nil,
    afterInstall: (@Sendable (pid_t) -> Void)? = nil,
    afterLeaderExitObserved: (@Sendable (pid_t) -> Void)? = nil
  ) {
    self.afterSpawnBeforeInstall = afterSpawnBeforeInstall
    self.afterInstall = afterInstall
    self.afterLeaderExitObserved = afterLeaderExitObserved
  }
}

private final class AutomationChildProcessController: @unchecked Sendable {
  private let lock = NSLock()
  private var processGroupID: pid_t?
  private var cancellationRequested = false
  private var escalationTask: Task<Void, Never>?

  func install(processGroupID: pid_t) {
    let shouldCancel = lock.withLock {
      self.processGroupID = processGroupID
      return cancellationRequested
    }
    if shouldCancel { scheduleEscalationIfNeeded(for: processGroupID) }
  }

  func clear() {
    lock.withLock { processGroupID = nil }
  }

  func cancel() {
    let group = lock.withLock { () -> pid_t? in
      cancellationRequested = true
      return processGroupID
    }
    if let group { scheduleEscalationIfNeeded(for: group) }
  }

  func awaitCancellationEscalationIfNeeded() async {
    let task = lock.withLock { cancellationRequested ? escalationTask : nil }
    await task?.value
  }

  private func scheduleEscalationIfNeeded(for group: pid_t) {
    lock.withLock {
      guard escalationTask == nil else { return }
      terminate(group, signal: SIGTERM)
      escalationTask = Task.detached {
      try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }
        _ = Darwin.kill(-group, SIGKILL)
      }
    }
  }

  private func terminate(_ group: pid_t, signal: Int32) {
    guard group > 0 else { return }
    _ = Darwin.kill(-group, signal)
  }
}

actor SystemAutomationCommandRunner: AutomationCommandRunning {
  private static let maximumCapturedBytes = 8 * 1_024 * 1_024
  private let hooks: SystemAutomationCommandRunnerHooks
  private let maximumCapturedBytes: Int
  private let executionTimeout: Duration

  init(
    hooks: SystemAutomationCommandRunnerHooks = .init(),
    maximumCapturedBytes: Int = SystemAutomationCommandRunner.maximumCapturedBytes,
    executionTimeout: Duration = .seconds(30)
  ) {
    self.hooks = hooks
    self.maximumCapturedBytes = max(0, maximumCapturedBytes)
    self.executionTimeout = executionTimeout
  }

  func run(_ command: AutomationCommand) async throws -> AutomationCommandResult {
    guard command.executable.hasPrefix("/"),
          !command.executable.contains("\0"),
          command.arguments.allSatisfy({ !$0.contains("\0") }),
          command.environment.allSatisfy({ key, value in
            !key.isEmpty && !key.contains("=") && !key.contains("\0") && !value.contains("\0")
          })
    else { throw SystemAutomationCommandError.invalidExecutable }

    try Task.checkCancellation()
    let controller = AutomationChildProcessController()
    return try await withTaskCancellationHandler {
      let spawned = try Self.spawn(command)
      hooks.afterSpawnBeforeInstall?(spawned.pid)
      controller.install(processGroupID: spawned.pid)
      hooks.afterInstall?(spawned.pid)

      let outputTask = Task.detached {
        try Self.drain(spawned.standardOutput, maximumCapturedBytes: self.maximumCapturedBytes)
      }
      let errorTask = Task.detached {
        try Self.drain(spawned.standardError, maximumCapturedBytes: self.maximumCapturedBytes)
      }
      let leaderTask = Task.detached {
        try Self.observeLeaderExitWithoutReaping(spawned.pid)
      }
      let timeoutTask = Task.detached { [executionTimeout] in
        do {
          try await Task.sleep(for: executionTimeout)
        } catch {
          return false
        }
        controller.cancel()
        return true
      }

      do {
        try await leaderTask.value
        hooks.afterLeaderExitObserved?(spawned.pid)
        let output = try await outputTask.value
        let error = try await errorTask.value
        timeoutTask.cancel()
        if await timeoutTask.value {
          throw SystemAutomationCommandError.executionTimedOut
        }
        let status = try Self.reap(spawned.pid)
        controller.clear()
        try Task.checkCancellation()
        return AutomationCommandResult(
          status: Self.commandStatus(fromWaitStatus: status),
          standardOutput: output,
          standardError: error
        )
      } catch {
        timeoutTask.cancel()
        controller.cancel()
        _ = try? await outputTask.value
        _ = try? await errorTask.value
        await controller.awaitCancellationEscalationIfNeeded()
        _ = try? Self.reap(spawned.pid)
        controller.clear()
        throw error
      }
    } onCancel: {
      controller.cancel()
    }
  }

  private struct SpawnedCommand: Sendable {
    let pid: pid_t
    let standardOutput: FileHandle
    let standardError: FileHandle
  }

  nonisolated private static func spawn(_ command: AutomationCommand) throws -> SpawnedCommand {
    var output = [Int32](repeating: -1, count: 2)
    var error = [Int32](repeating: -1, count: 2)
    guard output.withUnsafeMutableBufferPointer({ Darwin.pipe($0.baseAddress!) }) == 0 else {
      throw SystemAutomationCommandError.launchFailed
    }
    guard error.withUnsafeMutableBufferPointer({ Darwin.pipe($0.baseAddress!) }) == 0 else {
      close(output[0]); close(output[1])
      throw SystemAutomationCommandError.launchFailed
    }
    for descriptor in output + error {
      let existingFlags = fcntl(descriptor, F_GETFD)
      guard existingFlags >= 0,
            fcntl(descriptor, F_SETFD, existingFlags | FD_CLOEXEC) == 0
      else {
        for descriptor in output { close(descriptor) }
        for descriptor in error { close(descriptor) }
        throw SystemAutomationCommandError.launchFailed
      }
    }

    var actions: posix_spawn_file_actions_t? = nil
    var attributes: posix_spawnattr_t? = nil
    guard posix_spawn_file_actions_init(&actions) == 0 else {
      for descriptor in output { close(descriptor) }
      for descriptor in error { close(descriptor) }
      throw SystemAutomationCommandError.launchFailed
    }
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard posix_spawnattr_init(&attributes) == 0 else {
      for descriptor in output { close(descriptor) }
      for descriptor in error { close(descriptor) }
      throw SystemAutomationCommandError.launchFailed
    }
    defer {
      posix_spawnattr_destroy(&attributes)
    }

    var result = posix_spawn_file_actions_addopen(
      &actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0
    )
    if result == 0 { result = posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO) }
    if result == 0 { result = posix_spawn_file_actions_adddup2(&actions, error[1], STDERR_FILENO) }
    if result == 0 { result = posix_spawn_file_actions_addclose(&actions, output[0]) }
    if result == 0 { result = posix_spawn_file_actions_addclose(&actions, error[0]) }
    if result == 0 { result = posix_spawn_file_actions_addclose(&actions, output[1]) }
    if result == 0 { result = posix_spawn_file_actions_addclose(&actions, error[1]) }

    var emptyMask = sigset_t()
    var defaultSignals = sigset_t()
    sigemptyset(&emptyMask)
    sigemptyset(&defaultSignals)
    sigaddset(&defaultSignals, SIGINT)
    sigaddset(&defaultSignals, SIGHUP)
    sigaddset(&defaultSignals, SIGQUIT)
    sigaddset(&defaultSignals, SIGTERM)
    sigaddset(&defaultSignals, SIGPIPE)
    if result == 0 { result = posix_spawnattr_setsigmask(&attributes, &emptyMask) }
    if result == 0 { result = posix_spawnattr_setsigdefault(&attributes, &defaultSignals) }
    if result == 0 { result = posix_spawnattr_setpgroup(&attributes, 0) }
    let flags = Int16(
      POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        | POSIX_SPAWN_CLOEXEC_DEFAULT
    )
    if result == 0 { result = posix_spawnattr_setflags(&attributes, flags) }
    guard result == 0 else {
      for descriptor in output { close(descriptor) }
      for descriptor in error { close(descriptor) }
      throw SystemAutomationCommandError.launchFailed
    }

    var environment = [
      "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
      "LOGNAME": NSUserName(),
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "USER": NSUserName(),
    ]
    environment.merge(command.environment) { _, explicit in explicit }
    let argv = [command.executable] + command.arguments
    let envp = environment.keys.sorted().map { "\($0)=\(environment[$0]!)" }
    var pid: pid_t = 0
    let spawnResult = withMutableCStringArray(argv) { argvPointer in
      withMutableCStringArray(envp) { environmentPointer in
        posix_spawn(
          &pid,
          command.executable,
          &actions,
          &attributes,
          argvPointer,
          environmentPointer
        )
      }
    }
    close(output[1])
    close(error[1])
    guard spawnResult == 0, pid > 1 else {
      close(output[0])
      close(error[0])
      throw SystemAutomationCommandError.launchFailed
    }
    return SpawnedCommand(
      pid: pid,
      standardOutput: FileHandle(fileDescriptor: output[0], closeOnDealloc: true),
      standardError: FileHandle(fileDescriptor: error[0], closeOnDealloc: true)
    )
  }

  nonisolated private static func withMutableCStringArray<Result>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
  ) -> Result {
    let pointers = strings.map { strdup($0)! }
    defer {
      for pointer in pointers { free(pointer) }
    }
    var terminated = pointers.map(Optional.some)
    terminated.append(nil)
    return terminated.withUnsafeMutableBufferPointer { buffer in
      body(buffer.baseAddress!)
    }
  }

  nonisolated private static func observeLeaderExitWithoutReaping(_ pid: pid_t) throws {
    var information = siginfo_t()
    while true {
      if waitid(P_PID, id_t(pid), &information, WEXITED | WNOWAIT) == 0 { return }
      if errno != EINTR { throw SystemAutomationCommandError.launchFailed }
    }
  }

  nonisolated private static func reap(_ pid: pid_t) throws -> Int32 {
    var status: Int32 = 0
    while true {
      let result = waitpid(pid, &status, 0)
      if result == pid { return status }
      if result == -1, errno == EINTR { continue }
      throw SystemAutomationCommandError.launchFailed
    }
  }

  nonisolated private static func commandStatus(fromWaitStatus status: Int32) -> Int32 {
    let signal = status & 0x7f
    return signal == 0 ? (status >> 8) & 0xff : 128 + signal
  }

  nonisolated private static func drain(
    _ handle: FileHandle,
    maximumCapturedBytes: Int
  ) throws -> Data {
    defer { try? handle.close() }
    var captured = Data()
    var exceededLimit = false
    while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
      let available = maximumCapturedBytes - captured.count
      if available > 0 {
        captured.append(chunk.prefix(available))
      }
      if chunk.count > available { exceededLimit = true }
    }
    if exceededLimit { throw SystemAutomationCommandError.outputLimitExceeded }
    return captured
  }
}
