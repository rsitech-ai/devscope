import Foundation

/// Runs synchronous system I/O without occupying Swift's cooperative executor.
enum BlockingSystemWork {
  static func run<Value: Sendable>(
    _ operation: @escaping @Sendable () throws -> Value
  ) async throws -> Value {
    try Task.checkCancellation()
    let value = try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        continuation.resume(with: Result { try operation() })
      }
    }
    try Task.checkCancellation()
    return value
  }
}
