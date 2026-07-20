import AppKit
import Combine
import DevScopeCore
import Foundation

@MainActor
protocol AutomationApplicationLocating: AnyObject {
  func applicationURL(forBundleIdentifier identifier: String) -> URL?
  func icon(forApplicationAt url: URL) -> NSImage?
}

@MainActor
final class WorkspaceAutomationApplicationLocator: AutomationApplicationLocating {
  func applicationURL(forBundleIdentifier identifier: String) -> URL? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
  }

  func icon(forApplicationAt url: URL) -> NSImage? {
    guard url.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame else {
      return nil
    }
    return NSWorkspace.shared.icon(forFile: url.path)
  }
}

struct AutomationApplicationIconKey: Hashable, Sendable {
  let bundleIdentifier: String?
  let sourcePath: String?
  let executablePath: String?
}

@MainActor
final class AutomationApplicationIconStore: ObservableObject {
  private enum Resolution {
    case image(NSImage)
    case missing

    var icon: NSImage? {
      guard case .image(let image) = self else {
        return nil
      }
      return image
    }
  }

  private let locator: AutomationApplicationLocating
  private let capacity: Int
  private var cache: [AutomationApplicationIconKey: Resolution] = [:]
  private var insertionOrder: [AutomationApplicationIconKey] = []
  private var pending: [AutomationApplicationIconKey: Task<Resolution, Never>] = [:]

  private(set) var revision = 0

  init(
    locator: AutomationApplicationLocating = WorkspaceAutomationApplicationLocator(),
    capacity: Int = 256
  ) {
    self.locator = locator
    self.capacity = max(1, capacity)
  }

  func key(for record: AutomationRecord) -> AutomationApplicationIconKey {
    AutomationApplicationIconKey(
      bundleIdentifier: record.providerBundleIdentifier,
      sourcePath: record.sourceURL?.standardizedFileURL.path,
      executablePath: record.executable.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    )
  }

  func icon(for record: AutomationRecord) -> NSImage? {
    guard case .image(let image) = cache[key(for: record)] else {
      return nil
    }
    return image
  }

  @discardableResult
  func resolve(_ record: AutomationRecord) async -> NSImage? {
    let cacheKey = key(for: record)
    if let cached = cache[cacheKey] {
      return cached.icon
    }

    let resolutionTask: Task<Resolution, Never>
    if let inFlight = pending[cacheKey] {
      resolutionTask = inFlight
    } else {
      let created = Task { @MainActor in
        await Task.yield()
        return resolveNow(record)
      }
      pending[cacheKey] = created
      resolutionTask = created
    }

    let resolution = await resolutionTask.value
    complete(resolution, for: cacheKey)
    return resolution.icon
  }

  private func resolveNow(_ record: AutomationRecord) -> Resolution {
    if let identifier = record.providerBundleIdentifier,
       let applicationURL = locator.applicationURL(forBundleIdentifier: identifier),
       let image = locator.icon(forApplicationAt: applicationURL) {
      return .image(image)
    }

    if let sourceURL = record.sourceURL,
       sourceURL.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame,
       let image = locator.icon(forApplicationAt: sourceURL) {
      return .image(image)
    }

    if let applicationURL = applicationBundleURL(containing: record.executable),
       let image = locator.icon(forApplicationAt: applicationURL) {
      return .image(image)
    }

    return .missing
  }

  private func applicationBundleURL(containing path: String?) -> URL? {
    guard let path else {
      return nil
    }

    var candidate = URL(fileURLWithPath: path).standardizedFileURL
    while candidate.path != "/" {
      if candidate.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame {
        return candidate
      }
      candidate.deleteLastPathComponent()
    }
    return nil
  }

  private func evictIfNeeded() {
    while cache.count > capacity,
          let index = insertionOrder.firstIndex(where: { pending[$0] == nil }) {
      cache.removeValue(forKey: insertionOrder.remove(at: index))
    }
  }

  private func complete(
    _ resolution: Resolution,
    for cacheKey: AutomationApplicationIconKey
  ) {
    pending.removeValue(forKey: cacheKey)
    guard cache[cacheKey] == nil else {
      return
    }
    cache[cacheKey] = resolution
    insertionOrder.removeAll { $0 == cacheKey }
    insertionOrder.append(cacheKey)
    evictIfNeeded()
    revision &+= 1
  }
}
