import Darwin
import Foundation

public protocol ProcessProviding: Sendable {
  func snapshot(includeCurrentDirectories: Bool) throws -> [DevProcess]
}

protocol NativeProcessMetadataProviding: Sendable {
  func metadata(for processID: Int32) -> DevProcess?
}

protocol ProcessArgumentVectorProviding: Sendable {
  func argumentVector(for processID: Int32) -> [String]?
}

protocol ProcessBirthTokenProviding: Sendable {
  func birthToken(for processID: Int32) -> ProcessBirthToken?
}

struct KernelProcessBirthTokenProvider: ProcessBirthTokenProviding {
  func birthToken(for processID: Int32) -> ProcessBirthToken? {
    guard processID > 0 else { return nil }
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.stride
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: UInt8.self, capacity: size) { buffer in
        proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, buffer, Int32(size))
      }
    }
    guard result == Int32(size), info.pbi_pid > 0 else { return nil }
    return ProcessBirthToken(
      seconds: info.pbi_start_tvsec,
      microseconds: info.pbi_start_tvusec
    )
  }
}

struct KernelProcessArgumentVectorProvider: ProcessArgumentVectorProviding {
  private static let maximumBufferSize = 1_048_576
  private static let maximumArgumentCount: Int32 = 4_096

  func argumentVector(for processID: Int32) -> [String]? {
    guard processID > 0 else { return nil }
    var mib = [Int32(CTL_KERN), Int32(KERN_PROCARGS2), processID]
    var requiredSize = 0
    guard sysctl(&mib, u_int(mib.count), nil, &requiredSize, nil, 0) == 0,
          requiredSize >= MemoryLayout<Int32>.size,
          requiredSize <= Self.maximumBufferSize else { return nil }
    var buffer = [UInt8](repeating: 0, count: requiredSize)
    let status = buffer.withUnsafeMutableBytes { rawBuffer in
      sysctl(&mib, u_int(mib.count), rawBuffer.baseAddress, &requiredSize, nil, 0)
    }
    guard status == 0, requiredSize <= buffer.count else { return nil }
    return Self.parse(buffer: Array(buffer.prefix(requiredSize)))
  }

  static func parse(buffer: [UInt8]) -> [String]? {
    guard buffer.count >= MemoryLayout<Int32>.size,
          buffer.count <= maximumBufferSize else { return nil }
    var argumentCount: Int32 = 0
    withUnsafeMutableBytes(of: &argumentCount) { destination in
      buffer.prefix(MemoryLayout<Int32>.size).withUnsafeBytes { source in
        destination.copyBytes(from: source)
      }
    }
    guard argumentCount > 0, argumentCount <= maximumArgumentCount else { return nil }

    var cursor = MemoryLayout<Int32>.size
    guard let executableEnd = buffer[cursor...].firstIndex(of: 0),
          executableEnd > cursor,
          let executable = String(bytes: buffer[cursor..<executableEnd], encoding: .utf8),
          executable.hasPrefix("/") else { return nil }
    cursor = executableEnd + 1
    while cursor < buffer.count, buffer[cursor] == 0 { cursor += 1 }
    guard cursor < buffer.count else { return nil }

    var result: [String] = []
    result.reserveCapacity(Int(argumentCount))
    for _ in 0..<argumentCount {
      guard cursor < buffer.count,
            let end = buffer[cursor...].firstIndex(of: 0),
            let value = String(bytes: buffer[cursor..<end], encoding: .utf8) else { return nil }
      result.append(value)
      cursor = end + 1
    }
    // KERN_PROCARGS2 padding makes an empty argv0 indistinguishable from padding. Exact
    // strong evidence intentionally rejects every environment-assignment-shaped non-argv0
    // value, even at the end of the buffer; this ambiguous class may include legitimate
    // NAME=value arguments, but accepting one could expose environment data as exact argv.
    if result.dropFirst().contains(where: isEnvironmentAssignment) {
      return nil
    }
    return result
  }

  private static func isEnvironmentAssignment(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard let equals = bytes.firstIndex(of: 61), equals > 0 else { return false }
    let name = bytes[..<equals]
    guard let first = name.first,
          first == 95 || (65...90).contains(first) || (97...122).contains(first) else {
      return false
    }
    return name.dropFirst().allSatisfy { byte in
      byte == 95 || (48...57).contains(byte)
        || (65...90).contains(byte) || (97...122).contains(byte)
    }
  }
}

protocol ProcessBundleIdentityProviding: Sendable {
  func bundleIdentifier(forExecutableURL executableURL: URL, processID: Int32) -> String?
}

struct FoundationProcessBundleIdentityProvider: ProcessBundleIdentityProviding {
  func bundleIdentifier(forExecutableURL executableURL: URL, processID _: Int32) -> String? {
    let executable = executableURL.resolvingSymlinksInPath().standardizedFileURL
    var candidate = executable.deletingLastPathComponent()
    while candidate.path != "/" {
      if candidate.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
        if let bundle = Bundle(url: candidate),
           let bundleExecutable = bundle.executableURL?.resolvingSymlinksInPath().standardizedFileURL,
           bundleExecutable.path == executable.path,
           let identifier = bundle.bundleIdentifier,
           !identifier.isEmpty {
          return identifier
        }
      }
      candidate.deleteLastPathComponent()
    }
    return nil
  }
}

public enum ProcessScanner {
  static func bundleIdentifier(
    forExecutableURL executableURL: URL,
    processID: Int32,
    provider: any ProcessBundleIdentityProviding
  ) -> String? {
    provider.bundleIdentifier(forExecutableURL: executableURL, processID: processID)
  }

  public static func parsePSLine(_ line: String) -> DevProcess? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }

    let parts = trimmed.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true)
    guard parts.count >= 3,
          let pid = Int32(parts[0]),
          let parentPID = Int32(parts[1]) else {
      return nil
    }

    if parts.count >= 6,
       let cpuPercent = Double(parts[2]),
       let residentMemoryKilobytes = Int64(parts[3]) {
      let elapsedTime = String(parts[4])
      let executable = String(parts[5])
      let command = parts.count == 7 ? String(parts[6]) : executable
      return DevProcess(
        pid: pid,
        parentPID: parentPID,
        executable: executable,
        command: command,
        resourceUsage: DevProcessResourceUsage(
          cpuPercent: cpuPercent,
          residentMemoryBytes: residentMemoryKilobytes * 1024,
          elapsedTime: elapsedTime
        )
      )
    }

    let legacyParts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
    guard legacyParts.count >= 3 else {
      return nil
    }

    let executable = String(legacyParts[2])
    let command = legacyParts.count == 4 ? String(legacyParts[3]) : executable
    return DevProcess(pid: pid, parentPID: parentPID, executable: executable, command: command)
  }

  public static func parseLsofCurrentDirectories(_ output: String) -> [Int32: String] {
    var currentPID: Int32?
    var result: [Int32: String] = [:]

    for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
      if line.hasPrefix("p") {
        currentPID = Int32(line.dropFirst())
      } else if line.hasPrefix("n"), let currentPID {
        result[currentPID] = String(line.dropFirst())
      }
    }

    return result
  }

  static func excludingScannerHelper(
    from processes: [DevProcess],
    helperPID: Int32
  ) -> [DevProcess] {
    processes.filter { $0.pid != helperPID }
  }
}

public final class SystemProcessScanner: @unchecked Sendable, ProcessProviding {
  private struct NativeMetadataIdentity: Equatable {
    let parentPID: Int32
    let executable: String
    let command: String
    let birthToken: ProcessBirthToken?
  }

  private struct NativeMetadataCacheEntry {
    let identity: NativeMetadataIdentity
    let process: DevProcess?
    let attemptedAt: Date
  }

  private static let negativeMetadataRetryInterval: TimeInterval = 120
  private static let negativeMetadataRetryBudget = 8
  private let fallbackScanner: NativeProcessScanner
  private let nativeMetadataProvider: any NativeProcessMetadataProviding
  private let commandRunner: any SystemCommandRunning
  private let lock = NSLock()
  private var cachedNativeMetadata: [Int32: NativeMetadataCacheEntry] = [:]

  public init() {
    let nativeScanner = NativeProcessScanner()
    fallbackScanner = nativeScanner
    nativeMetadataProvider = nativeScanner
    commandRunner = BoundedSystemCommandRunner()
  }

  init(
    nativeMetadataProvider: any NativeProcessMetadataProviding,
    commandRunner: any SystemCommandRunning = BoundedSystemCommandRunner()
  ) {
    fallbackScanner = NativeProcessScanner()
    self.nativeMetadataProvider = nativeMetadataProvider
    self.commandRunner = commandRunner
  }

  public func snapshot(includeCurrentDirectories: Bool = true) throws -> [DevProcess] {
    let result: BoundedSystemCommandResult
    do {
      result = try commandRunner.run(
        executableURL: URL(fileURLWithPath: "/bin/ps"),
        arguments: ["-axo", "pid=,ppid=,%cpu=,rss=,etime=,comm=,args="]
      )
    } catch {
      return try fallbackScanner.snapshot(includeCurrentDirectories: false)
    }
    let output = String(decoding: result.standardOutput, as: UTF8.self)
    let errorOutput = String(decoding: result.standardError, as: UTF8.self)

    guard result.status == 0 else {
      if errorOutput.localizedCaseInsensitiveContains("operation not permitted") {
        return try fallbackScanner.snapshot(includeCurrentDirectories: false)
      }

      throw ProcessScannerError.psFailed(status: result.status, output: errorOutput)
    }

    let psProcesses = ProcessScanner.excludingScannerHelper(
      from: output
        .split(separator: "\n", omittingEmptySubsequences: true)
        .compactMap { ProcessScanner.parsePSLine(String($0)) },
      helperPID: result.processIdentifier ?? -1
    )
    guard !psProcesses.isEmpty else {
      return try fallbackScanner.snapshot(includeCurrentDirectories: false)
    }

    let processIDs = Set(psProcesses.map(\.pid))
    let birthTokens = fallbackScanner.birthTokens(for: processIDs)
    let nativeByPID = nativeMetadata(for: psProcesses, birthTokens: birthTokens)
    let currentDirectories = includeCurrentDirectories ? currentDirectoryMap() : [:]

    return psProcesses.map { process in
      ProcessScanner.mergedProcess(
        psProcess: process,
        nativeProcess: nativeByPID[process.pid],
        currentDirectory: currentDirectories[process.pid],
        birthToken: birthTokens[process.pid]
      )
    }
  }

  func nativeMetadata(
    for processes: [DevProcess],
    birthTokens: [Int32: ProcessBirthToken],
    now: Date = Date()
  ) -> [Int32: DevProcess] {
    lock.withLock {
      let activeProcessIDs = Set(processes.map(\.pid))
      let inactiveProcessIDs = cachedNativeMetadata.keys.filter { !activeProcessIDs.contains($0) }
      for processID in inactiveProcessIDs {
        cachedNativeMetadata.removeValue(forKey: processID)
      }

      let expiredNegativeRetries = processes.compactMap { process -> (processID: Int32, attemptedAt: Date)? in
        let identity = NativeMetadataIdentity(
          parentPID: process.parentPID,
          executable: process.executable,
          command: process.command,
          birthToken: birthTokens[process.pid]
        )
        guard let cached = cachedNativeMetadata[process.pid],
              cached.identity == identity,
              cached.process == nil,
              now.timeIntervalSince(cached.attemptedAt) >= Self.negativeMetadataRetryInterval else {
          return nil
        }
        return (process.pid, cached.attemptedAt)
      }
      .sorted { lhs, rhs in
        if lhs.attemptedAt != rhs.attemptedAt {
          return lhs.attemptedAt < rhs.attemptedAt
        }
        return lhs.processID < rhs.processID
      }
      let negativeRetryProcessIDs = Set(
        expiredNegativeRetries.prefix(Self.negativeMetadataRetryBudget).map(\.processID)
      )

      var result: [Int32: DevProcess] = [:]
      for process in processes {
        let identity = NativeMetadataIdentity(
          parentPID: process.parentPID,
          executable: process.executable,
          command: process.command,
          birthToken: birthTokens[process.pid]
        )
        let metadata: DevProcess?
        let cached = cachedNativeMetadata[process.pid]
        let hasStableCachedIdentity = cached.map { $0.identity == identity } ?? false
        let shouldQuery = !hasStableCachedIdentity ||
          negativeRetryProcessIDs.contains(process.pid)
        if shouldQuery {
          let candidate = nativeMetadataProvider.metadata(for: process.pid)
          metadata = candidate.flatMap { nativeProcess in
            guard nativeProcess.pid == process.pid,
                  let birthToken = birthTokens[process.pid],
                  nativeProcess.birthToken == birthToken else {
              return nil
            }
            return nativeProcess
          }
          cachedNativeMetadata[process.pid] = NativeMetadataCacheEntry(
            identity: identity,
            process: metadata,
            attemptedAt: now
          )
        } else {
          metadata = cached?.process
        }

        if let metadata {
          result[process.pid] = metadata
        }
      }
      return result
    }
  }

  private func currentDirectoryMap() -> [Int32: String] {
    let result: BoundedSystemCommandResult
    do {
      result = try commandRunner.run(
        executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
        arguments: ["-a", "-d", "cwd", "-n", "-w", "-F", "pcn"]
      )
    } catch {
      return [:]
    }

    guard result.status == 0 else {
      return [:]
    }

    return ProcessScanner.parseLsofCurrentDirectories(
      String(decoding: result.standardOutput, as: UTF8.self)
    )
  }
}

extension ProcessScanner {
  static func mergedProcess(
    psProcess: DevProcess,
    nativeProcess: DevProcess?,
    currentDirectory: String?,
    birthToken: ProcessBirthToken?
  ) -> DevProcess {
    let nativeProcess = nativeProcess.flatMap { nativeProcess -> DevProcess? in
      guard let birthToken,
            nativeProcess.birthToken == birthToken else {
        return nil
      }
      return nativeProcess
    }

    guard let nativeProcess else {
      return DevProcess(
        pid: psProcess.pid,
        parentPID: psProcess.parentPID,
        executable: psProcess.executable,
        command: psProcess.command,
        argumentVector: nil,
        currentDirectory: currentDirectory,
        resourceUsage: psProcess.resourceUsage,
        birthToken: birthToken,
        bundleIdentifier: nil,
        launchLabel: nil
      )
    }

    let nativeExecutable = nativeProcess.command.contains("/") ? nativeProcess.command : nativeProcess.executable
    let useNativeExecutable = shouldPreferNativeExecutable(
      psExecutable: psProcess.executable,
      nativeExecutable: nativeExecutable
    )
    let mergedCommand = shouldPreferNativeCommand(
      psCommand: psProcess.command,
      psExecutable: psProcess.executable
    ) && useNativeExecutable ? nativeExecutable : psProcess.command

    return DevProcess(
      pid: psProcess.pid,
      parentPID: psProcess.parentPID,
      executable: useNativeExecutable ? nativeExecutable : psProcess.executable,
      command: mergedCommand,
      argumentVector: nativeProcess.argumentVector,
      currentDirectory: currentDirectory,
      resourceUsage: psProcess.resourceUsage,
      birthToken: birthToken,
      bundleIdentifier: nativeProcess.bundleIdentifier,
      launchLabel: nativeProcess.launchLabel
    )
  }

  public static func carriedCurrentDirectory(
    from previousProcess: DevProcess,
    to currentProcess: DevProcess
  ) -> String? {
    guard let currentDirectory = previousProcess.currentDirectory,
          let previousBirthToken = previousProcess.birthToken,
          let currentBirthToken = currentProcess.birthToken,
          previousBirthToken == currentBirthToken else {
      return nil
    }
    return currentDirectory
  }

  static func shouldPreferNativeExecutable(psExecutable: String, nativeExecutable: String) -> Bool {
    let psExecutable = psExecutable.trimmingCharacters(in: .whitespacesAndNewlines)
    let nativeExecutable = nativeExecutable.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !nativeExecutable.isEmpty else {
      return false
    }

    let psName = lexicalLastPathComponent(psExecutable)
    guard !psName.isEmpty else {
      return true
    }

    if isGenericExecutableName(psName) {
      return true
    }

    let lowerPSName = psName.lowercased()
    let nativeName = lexicalLastPathComponent(nativeExecutable)
    let lowerNativeName = nativeName.lowercased()
    return lowerNativeName.hasPrefix(lowerPSName) && nativeName.count > psName.count
  }

  private static func shouldPreferNativeCommand(psCommand: String, psExecutable: String) -> Bool {
    let command = psCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    let executable = psExecutable.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !command.isEmpty else {
      return true
    }

    if command == executable {
      return true
    }

    if !command.contains("/"), command.split(whereSeparator: { $0.isWhitespace }).count == 1 {
      return true
    }

    return false
  }

  private static func lexicalLastPathComponent(_ path: String) -> String {
    path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
  }

  private static func isGenericExecutableName(_ name: String) -> Bool {
    [
      "a",
      "bin",
      "contents",
      "coreservices",
      "frameworks",
      "helpers",
      "library",
      "macos",
      "privateframeworks",
      "resources",
      "support",
      "versions",
      "xpcservices"
    ].contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
  }
}

public struct NativeProcessScanner: ProcessProviding, NativeProcessMetadataProviding {
  private let pathBufferSize = 4096
  private let bundleIdentityProvider: any ProcessBundleIdentityProviding
  private let argumentVectorProvider: any ProcessArgumentVectorProviding
  private let finalBirthTokenProvider: any ProcessBirthTokenProviding

  public init() {
    bundleIdentityProvider = FoundationProcessBundleIdentityProvider()
    argumentVectorProvider = KernelProcessArgumentVectorProvider()
    finalBirthTokenProvider = KernelProcessBirthTokenProvider()
  }

  init(
    bundleIdentityProvider: any ProcessBundleIdentityProviding,
    argumentVectorProvider: any ProcessArgumentVectorProviding = KernelProcessArgumentVectorProvider(),
    finalBirthTokenProvider: any ProcessBirthTokenProviding = KernelProcessBirthTokenProvider()
  ) {
    self.bundleIdentityProvider = bundleIdentityProvider
    self.argumentVectorProvider = argumentVectorProvider
    self.finalBirthTokenProvider = finalBirthTokenProvider
  }

  public func snapshot(includeCurrentDirectories: Bool = false) throws -> [DevProcess] {
    let pids = allProcessIDs()
    let processes = pids.compactMap(process)

    if processes.isEmpty {
      throw ProcessScannerError.nativeScannerEmpty
    }

    return processes
  }

  func birthTokens(for processIDs: Set<Int32>) -> [Int32: ProcessBirthToken] {
    Dictionary(
      uniqueKeysWithValues: processIDs.compactMap { pid in
        birthToken(for: pid).map { (pid, $0) }
      }
    )
  }

  func birthToken(for pid: Int32) -> ProcessBirthToken? {
    guard let info = bsdInfo(pid: pid) else {
      return nil
    }
    return birthToken(from: info)
  }

  func metadata(for processID: Int32) -> DevProcess? {
    process(pid: processID)
  }

  func argumentVector(for processID: Int32) -> [String]? {
    argumentVectorProvider.argumentVector(for: processID)
  }

  private func allProcessIDs() -> [pid_t] {
    let requiredBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
    guard requiredBytes > 0 else {
      return []
    }

    let capacity = max(1, Int(requiredBytes) / MemoryLayout<pid_t>.stride)
    let pids = UnsafeMutablePointer<pid_t>.allocate(capacity: capacity)
    defer { pids.deallocate() }

    let actualBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, pids, requiredBytes)
    guard actualBytes > 0 else {
      return []
    }

    let count = Int(actualBytes) / MemoryLayout<pid_t>.stride
    return (0..<count).compactMap { index in
      let pid = pids[index]
      return pid > 0 ? pid : nil
    }
  }

  private func process(pid: pid_t) -> DevProcess? {
    guard let info = bsdInfo(pid: pid) else {
      return nil
    }

    let initialBirthToken = birthToken(from: info)
    let executablePath = path(pid: pid)
    let executable = executableName(from: info) ?? executablePath?.lastPathComponent ?? "pid-\(pid)"
    let command = executablePath ?? executable
    let argumentVector = argumentVectorProvider.argumentVector(for: Int32(pid))
    let resourceUsage = resourceUsage(for: pid, startTime: TimeInterval(info.pbi_start_tvsec))
    let bundleIdentifier = executablePath.flatMap {
      ProcessScanner.bundleIdentifier(
        forExecutableURL: URL(fileURLWithPath: $0),
        processID: Int32(pid),
        provider: bundleIdentityProvider
      )
    }
    let launchLabel: String? = nil

    // This must remain the last metadata read. A recycled PID must not inherit path,
    // argv, bundle, or future trusted launch-label evidence gathered for its predecessor.
    guard finalBirthTokenProvider.birthToken(for: Int32(pid)) == initialBirthToken else {
      return nil
    }

    return DevProcess(
      pid: Int32(bitPattern: info.pbi_pid),
      parentPID: Int32(bitPattern: info.pbi_ppid),
      executable: executable,
      command: command,
      argumentVector: argumentVector,
      currentDirectory: nil,
      resourceUsage: resourceUsage,
      birthToken: initialBirthToken,
      bundleIdentifier: bundleIdentifier,
      launchLabel: launchLabel
    )
  }

  private func birthToken(from info: proc_bsdinfo) -> ProcessBirthToken {
    ProcessBirthToken(
      seconds: info.pbi_start_tvsec,
      microseconds: info.pbi_start_tvusec
    )
  }

  private func bsdInfo(pid: pid_t) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.stride
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: UInt8.self, capacity: size) { buffer in
        proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, buffer, Int32(size))
      }
    }

    guard result == Int32(size), info.pbi_pid > 0 else {
      return nil
    }

    return info
  }

  private func executableName(from info: proc_bsdinfo) -> String? {
    withUnsafePointer(to: info.pbi_name) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: info.pbi_name)) { buffer in
        let value = String(cString: buffer)
        return value.isEmpty ? nil : value
      }
    }
  }

  private func path(pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: pathBufferSize)
    let result = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard result > 0 else {
      return nil
    }

    let value = buffer.withUnsafeBufferPointer { pointer in
      guard let baseAddress = pointer.baseAddress else {
        return ""
      }
      return String(cString: baseAddress)
    }
    return value.isEmpty ? nil : value
  }

  private func resourceUsage(for pid: pid_t, startTime: TimeInterval) -> DevProcessResourceUsage {
    DevProcessResourceUsage(
      cpuPercent: 0,
      residentMemoryBytes: 0,
      elapsedTime: elapsedTime(since: startTime)
    )
  }

  private func elapsedTime(since startTime: TimeInterval) -> String {
    let elapsed = max(0, Int(Date().timeIntervalSince1970 - startTime))
    let hours = elapsed / 3600
    let minutes = (elapsed % 3600) / 60
    let seconds = elapsed % 60

    if hours >= 24 {
      let days = hours / 24
      return String(format: "%d-%02d:%02d:%02d", days, hours % 24, minutes, seconds)
    }

    if hours > 0 {
      return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    return String(format: "%02d:%02d", minutes, seconds)
  }
}

private extension String {
  var lastPathComponent: String {
    NSString(string: self).lastPathComponent
  }
}

public enum ProcessScannerError: LocalizedError, Equatable {
  case psFailed(status: Int32, output: String)
  case nativeScannerEmpty

  public var errorDescription: String? {
    switch self {
    case let .psFailed(status, output):
      "ps failed with status \(status): \(output)"
    case .nativeScannerEmpty:
      "Native process scanning returned no visible processes"
    }
  }
}
