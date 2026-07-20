import Foundation

public enum PersistentCopyStoreError: Error, Equatable, Sendable {
  case payloadTooLarge
}

public struct PersistedCopyPayload: Codable, Equatable, Sendable {
  public let label: String
  public let text: String
  public let timestamp: Date
  public let isTruncated: Bool

  public init(label: String, text: String, timestamp: Date = Date(), isTruncated: Bool = false) {
    self.label = label
    self.text = text
    self.timestamp = timestamp
    self.isTruncated = isTruncated
  }
}

public struct PersistentCopyStore: Sendable {
  public let directory: URL
  public let maxStoredBytes: Int
  private let maxReadablePayloadBytes: Int

  private var payloadURL: URL {
    directory.appendingPathComponent("last-copy.json", isDirectory: false)
  }

  public init(directory: URL? = nil, maxStoredBytes: Int = 2_000_000) {
    if let directory {
      self.directory = directory
    } else {
      let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
        FileManager.default.temporaryDirectory
      self.directory = baseDirectory
        .appendingPathComponent("DevScope", isDirectory: true)
        .appendingPathComponent("Clipboard", isDirectory: true)
    }
    self.maxStoredBytes = max(0, maxStoredBytes)
    let (escapedTextLimit, escapedTextOverflow) = self.maxStoredBytes.multipliedReportingOverflow(by: 6)
    let encodedTextLimit = escapedTextOverflow ? Int.max - 1 : escapedTextLimit
    let (readLimit, readLimitOverflow) = encodedTextLimit.addingReportingOverflow(64 * 1_024)
    self.maxReadablePayloadBytes = readLimitOverflow ? Int.max - 1 : readLimit
  }

  @discardableResult
  public func save(text: String, label: String, timestamp: Date = Date()) throws -> PersistedCopyPayload {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

    let bounded = boundedText(text)
    let payload = PersistedCopyPayload(
      label: label,
      text: bounded.text,
      timestamp: timestamp,
      isTruncated: bounded.isTruncated
    )
    let data = try JSONEncoder.devScopeCopyStore.encode(payload)
    guard data.count <= maxReadablePayloadBytes else {
      throw PersistentCopyStoreError.payloadTooLarge
    }
    try data.write(to: payloadURL, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: payloadURL.path)
    return payload
  }

  public func load() throws -> PersistedCopyPayload? {
    guard FileManager.default.fileExists(atPath: payloadURL.path) else {
      return nil
    }

    let handle = try FileHandle(forReadingFrom: payloadURL)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maxReadablePayloadBytes + 1) ?? Data()
    guard data.count <= maxReadablePayloadBytes else {
      throw PersistentCopyStoreError.payloadTooLarge
    }
    return try JSONDecoder.devScopeCopyStore.decode(PersistedCopyPayload.self, from: data)
  }

  public func clear() throws {
    guard FileManager.default.fileExists(atPath: payloadURL.path) else {
      return
    }

    try FileManager.default.removeItem(at: payloadURL)
  }

  private func boundedText(_ text: String) -> (text: String, isTruncated: Bool) {
    let data = Data(text.utf8)
    guard data.count > maxStoredBytes else {
      return (text, false)
    }

    let suffix = "\n[truncated for DevScope recovery cache]"
    let suffixData = Data(suffix.utf8).prefix(maxStoredBytes)
    let prefixLimit = max(0, maxStoredBytes - suffixData.count)
    var boundedData = validUTF8Prefix(of: data, maxBytes: prefixLimit)
    boundedData.append(suffixData)

    return (String(decoding: boundedData, as: UTF8.self), true)
  }

  private func validUTF8Prefix(of data: Data, maxBytes: Int) -> Data {
    var end = min(data.count, maxBytes)
    while end > 0 {
      let candidate = Data(data.prefix(end))
      if String(data: candidate, encoding: .utf8) != nil {
        return candidate
      }
      end -= 1
    }
    return Data()
  }
}

private extension JSONEncoder {
  static var devScopeCopyStore: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}

private extension JSONDecoder {
  static var devScopeCopyStore: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
