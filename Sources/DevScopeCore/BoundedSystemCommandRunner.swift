import Darwin
import Foundation

struct BoundedSystemCommandResult: Equatable, Sendable {
  let status: Int32
  let standardOutput: Data
  let standardError: Data
  var processIdentifier: Int32? = nil
}

enum BoundedSystemCommandError: Error, Equatable {
  case invalidCommand
  case launchFailed
  case outputLimitExceeded
  case executionTimedOut
}

protocol SystemCommandRunning: Sendable {
  func run(executableURL: URL, arguments: [String]) throws -> BoundedSystemCommandResult
}

struct BoundedSystemCommandRunner: SystemCommandRunning {
  private static let defaultMaximumCapturedBytes = 8 * 1_024 * 1_024

  private let maximumCapturedBytes: Int
  private let executionTimeout: TimeInterval
  private let terminationGraceInterval: TimeInterval

  init(
    maximumCapturedBytes: Int = Self.defaultMaximumCapturedBytes,
    executionTimeout: TimeInterval = 10,
    terminationGraceInterval: TimeInterval = 0.5
  ) {
    self.maximumCapturedBytes = max(0, maximumCapturedBytes)
    self.executionTimeout = max(0, executionTimeout)
    self.terminationGraceInterval = max(0, terminationGraceInterval)
  }

  func run(executableURL: URL, arguments: [String]) throws -> BoundedSystemCommandResult {
    let executable = executableURL.path
    guard executable.hasPrefix("/"),
          !executable.contains("\0"),
          arguments.allSatisfy({ !$0.contains("\0") }) else {
      throw BoundedSystemCommandError.invalidCommand
    }

    let spawned = try Self.spawn(executable: executable, arguments: arguments)
    let group = DispatchGroup()
    let output = LockedBox<Result<CapturedStream, Error>?>(nil)
    let error = LockedBox<Result<CapturedStream, Error>?>(nil)
    let status = LockedBox<Result<Int32, Error>?>(nil)
    let outputLimitExceeded = LockedBox(false)

    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      output.value = Result {
        try Self.drain(
          spawned.standardOutput,
          maximumCapturedBytes: maximumCapturedBytes,
          onLimitExceeded: { outputLimitExceeded.value = true }
        )
      }
      group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      error.value = Result {
        try Self.drain(
          spawned.standardError,
          maximumCapturedBytes: maximumCapturedBytes,
          onLimitExceeded: { outputLimitExceeded.value = true }
        )
      }
      group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      status.value = Result { try Self.reap(spawned.pid) }
      group.leave()
    }

    var remainingWait = executionTimeout
    var completed = false
    while !completed, !outputLimitExceeded.value {
      if group.wait(timeout: .now()) == .success {
        completed = true
        break
      }
      guard remainingWait > 0 else { break }
      let interval = min(remainingWait, 0.01)
      completed = group.wait(timeout: .now() + interval) == .success
      remainingWait -= interval
    }
    guard completed else {
      Self.terminateAndDrain(
        spawned,
        group: group,
        terminationGraceInterval: terminationGraceInterval
      )
      throw outputLimitExceeded.value
        ? BoundedSystemCommandError.outputLimitExceeded
        : BoundedSystemCommandError.executionTimedOut
    }

    let capturedOutput = try output.value?.get() ?? { throw BoundedSystemCommandError.launchFailed }()
    let capturedError = try error.value?.get() ?? { throw BoundedSystemCommandError.launchFailed }()
    let waitStatus = try status.value?.get() ?? { throw BoundedSystemCommandError.launchFailed }()
    guard !capturedOutput.exceededLimit, !capturedError.exceededLimit else {
      throw BoundedSystemCommandError.outputLimitExceeded
    }
    return BoundedSystemCommandResult(
      status: Self.commandStatus(fromWaitStatus: waitStatus),
      standardOutput: capturedOutput.data,
      standardError: capturedError.data,
      processIdentifier: spawned.pid
    )
  }

  private struct SpawnedCommand: Sendable {
    let pid: pid_t
    let standardOutput: FileHandle
    let standardError: FileHandle
  }

  private struct CapturedStream: Sendable {
    let data: Data
    let exceededLimit: Bool
  }

  private static func spawn(executable: String, arguments: [String]) throws -> SpawnedCommand {
    var output = [Int32](repeating: -1, count: 2)
    var error = [Int32](repeating: -1, count: 2)
    guard output.withUnsafeMutableBufferPointer({ Darwin.pipe($0.baseAddress!) }) == 0 else {
      throw BoundedSystemCommandError.launchFailed
    }
    guard error.withUnsafeMutableBufferPointer({ Darwin.pipe($0.baseAddress!) }) == 0 else {
      close(output[0]); close(output[1])
      throw BoundedSystemCommandError.launchFailed
    }
    for descriptor in output + error {
      let existingFlags = fcntl(descriptor, F_GETFD)
      guard existingFlags >= 0,
            fcntl(descriptor, F_SETFD, existingFlags | FD_CLOEXEC) == 0 else {
        for descriptor in output + error { close(descriptor) }
        throw BoundedSystemCommandError.launchFailed
      }
    }

    var actions: posix_spawn_file_actions_t? = nil
    var attributes: posix_spawnattr_t? = nil
    guard posix_spawn_file_actions_init(&actions) == 0 else {
      for descriptor in output + error { close(descriptor) }
      throw BoundedSystemCommandError.launchFailed
    }
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard posix_spawnattr_init(&attributes) == 0 else {
      for descriptor in output + error { close(descriptor) }
      throw BoundedSystemCommandError.launchFailed
    }
    defer { posix_spawnattr_destroy(&attributes) }

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
    for signal in [SIGINT, SIGHUP, SIGQUIT, SIGTERM, SIGPIPE] {
      sigaddset(&defaultSignals, signal)
    }
    if result == 0 { result = posix_spawnattr_setsigmask(&attributes, &emptyMask) }
    if result == 0 { result = posix_spawnattr_setsigdefault(&attributes, &defaultSignals) }
    if result == 0 { result = posix_spawnattr_setpgroup(&attributes, 0) }
    let flags = Int16(
      POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        | POSIX_SPAWN_CLOEXEC_DEFAULT
    )
    if result == 0 { result = posix_spawnattr_setflags(&attributes, flags) }
    guard result == 0 else {
      for descriptor in output + error { close(descriptor) }
      throw BoundedSystemCommandError.launchFailed
    }

    let argv = [executable] + arguments
    let environment = [
      "HOME=\(FileManager.default.homeDirectoryForCurrentUser.path)",
      "LC_ALL=C",
      "LOGNAME=\(NSUserName())",
      "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
      "USER=\(NSUserName())",
    ]
    var pid: pid_t = 0
    let spawnResult = withMutableCStringArray(argv) { argvPointer in
      withMutableCStringArray(environment) { environmentPointer in
        posix_spawn(
          &pid,
          executable,
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
      throw BoundedSystemCommandError.launchFailed
    }
    return SpawnedCommand(
      pid: pid,
      standardOutput: FileHandle(fileDescriptor: output[0], closeOnDealloc: true),
      standardError: FileHandle(fileDescriptor: error[0], closeOnDealloc: true)
    )
  }

  private static func withMutableCStringArray<Result>(
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

  private static func drain(
    _ handle: FileHandle,
    maximumCapturedBytes: Int,
    onLimitExceeded: @Sendable () -> Void
  ) throws -> CapturedStream {
    defer { try? handle.close() }
    var captured = Data()
    var exceededLimit = false
    while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
      let available = maximumCapturedBytes - captured.count
      if available > 0 {
        captured.append(chunk.prefix(available))
      }
      if chunk.count > available, !exceededLimit {
        exceededLimit = true
        onLimitExceeded()
      }
    }
    return CapturedStream(data: captured, exceededLimit: exceededLimit)
  }

  private static func reap(_ pid: pid_t) throws -> Int32 {
    var status: Int32 = 0
    while true {
      let result = waitpid(pid, &status, 0)
      if result == pid { return status }
      if result == -1, errno == EINTR { continue }
      throw BoundedSystemCommandError.launchFailed
    }
  }

  private static func terminate(processGroupID: pid_t, signal: Int32) {
    guard processGroupID > 1 else { return }
    _ = Darwin.kill(-processGroupID, signal)
  }

  private static func terminateAndDrain(
    _ command: SpawnedCommand,
    group: DispatchGroup,
    terminationGraceInterval: TimeInterval
  ) {
    terminate(processGroupID: command.pid, signal: SIGTERM)
    if group.wait(timeout: .now() + terminationGraceInterval) == .timedOut {
      terminate(processGroupID: command.pid, signal: SIGKILL)
      _ = Darwin.kill(command.pid, SIGKILL)
    }
    if group.wait(timeout: .now() + 1) == .timedOut {
      try? command.standardOutput.close()
      try? command.standardError.close()
      _ = group.wait(timeout: .now() + 1)
    }
  }

  private static func commandStatus(fromWaitStatus status: Int32) -> Int32 {
    let signal = status & 0x7f
    return signal == 0 ? (status >> 8) & 0xff : 128 + signal
  }
}

private final class LockedBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValue: Value

  init(_ value: Value) {
    storedValue = value
  }

  var value: Value {
    get { lock.withLock { storedValue } }
    set { lock.withLock { storedValue = newValue } }
  }
}
