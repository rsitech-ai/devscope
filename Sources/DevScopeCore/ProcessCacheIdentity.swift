public struct ProcessCacheIdentity: Equatable, Hashable, Sendable {
  private enum Lifecycle: Equatable, Hashable, Sendable {
    case knownBirth(ProcessBirthToken)
    case fallback(
      parentPID: Int32,
      executable: String,
      command: String
    )
  }

  public let pid: Int32
  private let lifecycle: Lifecycle

  public init(process: DevProcess) {
    pid = process.pid
    if let birthToken = process.birthToken {
      lifecycle = .knownBirth(birthToken)
    } else {
      lifecycle = .fallback(
        parentPID: process.parentPID,
        executable: process.executable,
        command: process.command
      )
    }
  }
}
