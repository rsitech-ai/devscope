import DevScopeCore
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

actor ProcessNameEnhancer {
  private var cache: [ProcessCacheIdentity: String] = [:]

  func enhancedName(for item: ClassifiedDevProcess) async -> String? {
    guard shouldEnhance(item) else {
      return nil
    }
    let identity = ProcessCacheIdentity(process: item.process)

    if let cached = cache[identity] {
      if Self.isSafeDisplayName(cached, fallback: fallbackCandidate(for: item)) {
        return cached
      }
      cache[identity] = nil
    }

    guard let name = await generateName(for: item) else {
      return nil
    }

    cache[identity] = name
    return name
  }

  func retainOnly(identities: Set<ProcessCacheIdentity>) {
    cache = cache.filter { identities.contains($0.key) }
  }

  func isAvailable() -> Bool {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
      return SystemLanguageModel.default.isAvailable
    }
    #endif
    return false
  }

  private func fallbackCandidate(for item: ClassifiedDevProcess) -> String {
    item.classification.displayName
  }

  private func prompt(for item: ClassifiedDevProcess) -> String {
    """
    Rename this local development process for a macOS process monitor.
    Return only a short human-readable label, 2 to 5 words, no quotes, no punctuation unless needed.
    Prefer product/workload words like "Uvicorn API", "Next dev server", "Node MCP server", "Python research loop".
    Preserve known product names such as Ollama, Redis, Postgres, Docker, and LM Studio.
    Do not expose full paths.

    Runtime: \(item.classification.kind.rawValue)
    Current label: \(fallbackCandidate(for: item))
    Project: \(ProcessPresentation.projectName(for: item) ?? "Unknown")
    Executable: \(item.process.executableName)
    Command: \(ProcessPresentation.redactedCommand(item.process.command))
    """
  }

  nonisolated static func isSafeDisplayName(_ candidate: String, fallback: String) -> Bool {
    let cleaned = candidate
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let lowered = cleaned.lowercased()
    let blockedFragments = [
      "name convention",
      "product name",
      "return only",
      "human-readable",
      "macos process monitor"
    ]
    let blockedExactNames = [
      "bash",
      "go",
      "java",
      "javascript",
      "node",
      "python",
      "rust",
      "shell",
      "swift",
      "typescript",
      "zsh"
    ]

    guard cleaned.count >= 4,
          cleaned.count <= 42,
          cleaned.split(separator: " ").count <= 6,
          !cleaned.contains("/"),
          !cleaned.contains(","),
          !blockedExactNames.contains(lowered),
          !blockedFragments.contains(where: { lowered.contains($0) }) else {
      return false
    }

    return cleaned.localizedCaseInsensitiveCompare(fallback) != .orderedSame
  }

  private func sanitize(_ candidate: String, fallback: String) -> String? {
    let cleaned = candidate
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard Self.isSafeDisplayName(cleaned, fallback: fallback) else {
      return nil
    }

    return cleaned
  }

  private func generateName(for item: ClassifiedDevProcess) async -> String? {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
      let model = SystemLanguageModel.default
      guard model.isAvailable else {
        return nil
      }

      do {
        let session = LanguageModelSession(
          model: model,
          instructions: "You create concise labels for local development processes. Be literal, conservative, and never invent a product name that is not implied by the command."
        )
        let response = try await session.respond(
          to: prompt(for: item),
          options: .devScopeGreedy(maximumResponseTokens: 12)
        )
        return sanitize(response.content, fallback: fallbackCandidate(for: item))
      } catch {
        return nil
      }
    }
    #endif

    return nil
  }

  private func shouldEnhance(_ item: ClassifiedDevProcess) -> Bool {
    switch item.classification.kind {
    case .ai, .browser, .macApp, .backgroundAgent, .systemService, .shell, .other:
      return false
    case .javascript, .python, .swift, .rust, .go, .flutter, .java, .database, .container, .webServer, .mcp:
      return true
    }
  }
}
