import CryptoKit
import Foundation

public struct DevProcessCategory: Identifiable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let symbolName: String
  public let count: Int

  public static func all(count: Int) -> DevProcessCategory {
    DevProcessCategory(id: "all", title: "All", symbolName: "scope", count: count)
  }
}

public struct ProcessPresentationSummary: Equatable, Sendable {
  public let totalCount: Int
  public let countsByKind: [DevRuntimeKind: Int]
  public let projectCounts: [String: Int]

  public var projectCount: Int {
    projectCounts.count
  }

  public var primaryProject: String? {
    projectCounts.sorted { lhs, rhs in
      if lhs.value != rhs.value {
        return lhs.value > rhs.value
      }
      return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
    }
    .first?
    .key
  }

  public func count(for kind: DevRuntimeKind) -> Int {
    countsByKind[kind, default: 0]
  }
}

public struct ProcessFamilySummary: Equatable, Sendable {
  public let parentPID: Int32
  public let childCount: Int
  public let descendantCount: Int

  public init(parentPID: Int32, childCount: Int, descendantCount: Int) {
    self.parentPID = parentPID
    self.childCount = childCount
    self.descendantCount = descendantCount
  }
}

public struct ProcessDashboardStats: Equatable, Sendable {
  public let visibleCount: Int
  public let totalCount: Int
  public let aiMLCount: Int
  public let runtimeCounts: [DevRuntimeKind: Int]
  public let topCPU: ClassifiedDevProcess?
  public let topMemory: ClassifiedDevProcess?
  public let latestGPUPercent: Double?

  public init(
    visibleCount: Int,
    totalCount: Int,
    aiMLCount: Int,
    runtimeCounts: [DevRuntimeKind: Int],
    topCPU: ClassifiedDevProcess?,
    topMemory: ClassifiedDevProcess?,
    latestGPUPercent: Double?
  ) {
    self.visibleCount = visibleCount
    self.totalCount = totalCount
    self.aiMLCount = aiMLCount
    self.runtimeCounts = runtimeCounts
    self.topCPU = topCPU
    self.topMemory = topMemory
    self.latestGPUPercent = latestGPUPercent
  }
}

public enum ProcessSortOption: String, CaseIterable, Identifiable, Sendable {
  case cpuDescending
  case memoryDescending
  case processNameAscending
  case runtimeAscending
  case pidAscending

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .cpuDescending:
      "CPU"
    case .memoryDescending:
      "Memory"
    case .processNameAscending:
      "Name"
    case .runtimeAscending:
      "Kind"
    case .pidAscending:
      "PID"
    }
  }

  public var symbolName: String {
    switch self {
    case .cpuDescending:
      "cpu"
    case .memoryDescending:
      "memorychip"
    case .processNameAscending:
      "textformat"
    case .runtimeAscending:
      "square.grid.2x2"
    case .pidAscending:
      "number"
    }
  }
}

public enum ProcessPresentation {
  public static let allCategoryID = "all"
  public static let favoritesCategoryID = "favorites"
  public static let watchedCategoryID = "watched"

  public static func filtered(
    _ items: [ClassifiedDevProcess],
    categoryID: String,
    searchText: String,
    favoriteKeys: Set<String> = [],
    watchedKeys: Set<String> = []
  ) -> [ClassifiedDevProcess] {
    let terms = searchTerms(from: searchText)

    return items.filter { item in
      let categoryMatches =
        switch categoryID {
        case allCategoryID:
          true
        case favoritesCategoryID:
          isSaved(item, in: favoriteKeys)
        case watchedCategoryID:
          isSaved(item, in: watchedKeys)
        default:
          categoryID == item.classification.kind.id
        }

      guard categoryMatches else {
        return false
      }

      guard !terms.isEmpty else {
        return true
      }

      let searchableText = searchableText(for: item)
      return terms.allSatisfy { searchableText.contains($0) }
    }
  }

  public static func categories(
    for items: [ClassifiedDevProcess],
    favoriteKeys: Set<String> = [],
    watchedKeys: Set<String> = []
  ) -> [DevProcessCategory] {
    let grouped = Dictionary(grouping: items, by: \.classification.kind)
    let favoriteCount = savedCount(in: items, keys: favoriteKeys)
    let watchedCount = savedCount(in: items, keys: watchedKeys)
    let savedCategories = [
      DevProcessCategory(
        id: favoritesCategoryID, title: "Favorites", symbolName: "star.fill", count: favoriteCount),
      DevProcessCategory(
        id: watchedCategoryID, title: "Watched", symbolName: "eye.fill", count: watchedCount),
    ].filter { $0.count > 0 }
    let detected = grouped.map { kind, groupedItems in
      DevProcessCategory(
        id: kind.id,
        title: kind.rawValue,
        symbolName: kind.symbolName,
        count: groupedItems.count
      )
    }
    .sorted { lhs, rhs in
      if lhs.count != rhs.count {
        return lhs.count > rhs.count
      }
      return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    return [.all(count: items.count)] + savedCategories + detected
  }

  static func savedCount(
    in items: [ClassifiedDevProcess],
    keys: Set<String>,
    matching: (ClassifiedDevProcess, Set<String>) -> Bool = ProcessPresentation.isSaved
  ) -> Int {
    guard !keys.isEmpty else { return 0 }
    return items.filter { matching($0, keys) }.count
  }

  public static func sorted(
    _ items: [ClassifiedDevProcess],
    by option: ProcessSortOption
  ) -> [ClassifiedDevProcess] {
    items.sorted { lhs, rhs in
      switch option {
      case .cpuDescending:
        if cpu(lhs) != cpu(rhs) {
          return cpu(lhs) > cpu(rhs)
        }
      case .memoryDescending:
        if memory(lhs) != memory(rhs) {
          return memory(lhs) > memory(rhs)
        }
      case .processNameAscending:
        let comparison = lhs.classification.displayName.localizedStandardCompare(
          rhs.classification.displayName)
        if comparison != .orderedSame {
          return comparison == .orderedAscending
        }
      case .runtimeAscending:
        let comparison = lhs.classification.kind.rawValue.localizedStandardCompare(
          rhs.classification.kind.rawValue)
        if comparison != .orderedSame {
          return comparison == .orderedAscending
        }
      case .pidAscending:
        if lhs.process.pid != rhs.process.pid {
          return lhs.process.pid < rhs.process.pid
        }
      }

      return stableFallback(lhs, rhs)
    }
  }

  public static func summary(for items: [ClassifiedDevProcess]) -> ProcessPresentationSummary {
    var countsByKind: [DevRuntimeKind: Int] = [:]
    var projectCounts: [String: Int] = [:]

    for item in items {
      countsByKind[item.classification.kind, default: 0] += 1
      if let projectName = projectName(for: item) {
        projectCounts[projectName, default: 0] += 1
      }
    }

    return ProcessPresentationSummary(
      totalCount: items.count,
      countsByKind: countsByKind,
      projectCounts: projectCounts
    )
  }

  public static func dashboardStats(
    visibleItems: [ClassifiedDevProcess],
    totalItems: [ClassifiedDevProcess],
    dashboardMetricHistory: [DevProcessMetricSample] = []
  ) -> ProcessDashboardStats {
    let runtimeCounts = Dictionary(grouping: totalItems, by: \.classification.kind)
      .mapValues(\.count)
    let aiMLCount = totalItems.filter { item in
      item.classification.kind == .ai || !item.classification.tags.isEmpty
    }
    .count
    let topCPU = totalItems.max { lhs, rhs in
      cpu(lhs) < cpu(rhs)
    }
    let topMemory = totalItems.max { lhs, rhs in
      memory(lhs) < memory(rhs)
    }
    let latestGPUPercent = dashboardMetricHistory.last { $0.gpuPercent != nil }?.gpuPercent

    return ProcessDashboardStats(
      visibleCount: visibleItems.count,
      totalCount: totalItems.count,
      aiMLCount: aiMLCount,
      runtimeCounts: runtimeCounts,
      topCPU: topCPU,
      topMemory: topMemory,
      latestGPUPercent: latestGPUPercent
    )
  }

  public static func familySummary(
    for process: DevProcess,
    in processes: [DevProcess]
  ) -> ProcessFamilySummary {
    ProcessFamilySummary(
      parentPID: process.parentPID,
      childCount: processes.filter { $0.parentPID == process.pid }.count,
      descendantCount: ProcessTree.descendants(of: process.pid, in: processes).count
    )
  }

  public static func searchableText(for item: ClassifiedDevProcess) -> String {
    [
      item.classification.displayName,
      item.classification.kind.rawValue,
      item.classification.projectHint ?? "",
      item.process.executable,
      item.process.executableName,
      item.process.command,
      item.process.currentDirectory ?? "",
      "\(item.process.pid)",
      "\(item.process.parentPID)",
    ]
    .joined(separator: " ")
    .lowercased()
  }

  public static func projectName(for item: ClassifiedDevProcess) -> String? {
    if let projectHint = item.classification.projectHint, !projectHint.isEmpty {
      return projectHint
    }

    guard let currentDirectory = item.process.currentDirectory else {
      return nil
    }

    let name = URL(fileURLWithPath: currentDirectory).lastPathComponent
    return name.isEmpty || name == "/" ? nil : name
  }

  public static func contextLabel(for item: ClassifiedDevProcess) -> String {
    if let projectName = projectName(for: item) {
      return projectName
    }

    let executableName = item.process.executableName.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayName = item.classification.displayName.trimmingCharacters(
      in: .whitespacesAndNewlines)

    if executableName.isEmpty
      || shouldHideExecutableContext(executableName, displayName: displayName)
    {
      return item.classification.kind.rawValue
    }

    return executableName
  }

  public static func executablePath(for item: ClassifiedDevProcess) -> String {
    let executableName = item.process.executableName.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayName = item.classification.displayName.trimmingCharacters(
      in: .whitespacesAndNewlines)

    if shouldHideExecutableContext(executableName, displayName: displayName),
      let commandPath = leadingAbsoluteCommandPath(item.process.command)
    {
      return commandPath
    }

    return item.process.executable
  }

  public static func identityKey(for item: ClassifiedDevProcess) -> String {
    hashedIdentityKey(
      executableName: item.process.executableName,
      currentDirectory: item.process.currentDirectory ?? "",
      command: item.process.command
    )
  }

  public static func identityKeys(for item: ClassifiedDevProcess) -> Set<String> {
    let fallback = hashedIdentityKey(
      executableName: item.process.executableName,
      currentDirectory: "",
      command: item.process.command
    )

    return [identityKey(for: item), fallback]
  }

  private static func hashedIdentityKey(
    executableName: String,
    currentDirectory: String,
    command: String
  ) -> String {
    let source = [executableName, currentDirectory, command]
      .joined(separator: "\u{1F}")
      .lowercased()
    return hashedIdentityKey(source: source)
  }

  private static func hashedIdentityKey(source: String) -> String {
    let digest = SHA256.hash(data: Data(source.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return "v2:\(digest)"
  }

  public static func isSaved(_ item: ClassifiedDevProcess, in keys: Set<String>) -> Bool {
    isSaved(item, in: keys, identityKeys: identityKeys(for:))
  }

  static func isSaved(
    _ item: ClassifiedDevProcess,
    in keys: Set<String>,
    identityKeys: (ClassifiedDevProcess) -> Set<String>
  ) -> Bool {
    guard !keys.isEmpty else { return false }
    return !identityKeys(item).isDisjoint(with: keys)
  }

  public static func sanitizedSavedIdentityKeys(_ keys: Set<String>) -> Set<String> {
    Set(
      keys.compactMap { key in
        if key.hasPrefix("v2:"), key.count == 67,
          key.dropFirst(3).allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        {
          return key
        }

        let legacyComponents = key.split(
          separator: "\u{1F}", omittingEmptySubsequences: false)
        guard legacyComponents.count == 3 else {
          return nil
        }
        return hashedIdentityKey(source: key.lowercased())
      })
  }

  public static func elapsedSeconds(_ value: String) -> Int64 {
    let dayAndTime = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard dayAndTime.count <= 2 else {
      return -1
    }

    let days: Int64
    let time: Substring
    if dayAndTime.count == 2 {
      guard let parsedDays = Int64(dayAndTime[0]),
        parsedDays >= 0,
        parsedDays <= Int64.max / 86_400
      else {
        return -1
      }
      days = parsedDays
      time = dayAndTime[1]
    } else {
      days = 0
      time = dayAndTime[0]
    }

    let components = time.split(separator: ":", omittingEmptySubsequences: false)
    guard (2...3).contains(components.count),
      let seconds = Int64(components[components.count - 1]),
      let minutes = Int64(components[components.count - 2]),
      seconds >= 0, seconds < 60,
      minutes >= 0, minutes < 60
    else {
      return -1
    }
    let hours = components.count == 3 ? Int64(components[0]) : 0
    guard let hours, hours >= 0, hours < 24 else {
      return -1
    }
    return days * 86_400 + hours * 3_600 + minutes * 60 + seconds
  }

  public static func redactedCommand(_ command: String) -> String {
    let commandWithRedactedHeaders = redactingSensitiveHeaderValues(in: command)
    let sensitiveReplacements = [
      (
        #"(?i)(?<![A-Za-z0-9_.-])(-{0,2}[A-Za-z0-9_.-]*(?:password|passwd|pwd|token|api[_-]?key|secret|credential)[A-Za-z0-9_.-]*)=("[^"]*"|'[^']*'|[^\s]+)"#,
        "$1=<redacted>"
      ),
      (
        #"(?i)(?<![A-Za-z0-9_.-])(--(?:password|passwd|pwd|token|api[-_]?key|secret|credential|client[-_]?secret|access[-_]?token|refresh[-_]?token))(\s+)("[^"]*"|'[^']*'|[^\s]+)"#,
        "$1$2<redacted>"
      ),
      (
        #"(?i)\b(bearer)(\s+)([A-Za-z0-9._~+/\-=]+)"#,
        "$1$2<redacted>"
      ),
      (
        #"([A-Za-z][A-Za-z0-9+.-]*://)([^/\s:@]+):([^/\s@]+)@"#,
        "$1<redacted>@"
      ),
      (
        #"(?i)(\bredis-cli\b[^\r\n]*?\s-a)(\s+).*?(?=[\r\n]|$)"#,
        "$1$2<redacted>"
      ),
      (#"(?i)(\bmysql\b[^\r\n]*?\s-p).*?(?=[\r\n]|$)"#, "$1<redacted>"),
      (
        #"(?i)(\bcurl\b[^\r\n]*?\s--(?:user|proxy-user))(=|\s+).*?(?=[\r\n]|$)"#,
        "$1$2<redacted>"
      ),
      (
        #"(?i)(\bcurl\b[^\r\n]*?\s-u)(\s+).*?(?=[\r\n]|$)"#,
        "$1$2<redacted>"
      ),
    ]

    return sensitiveReplacements.reduce(commandWithRedactedHeaders) { partial, replacement in
      partial.replacingOccurrences(
        of: replacement.0,
        with: replacement.1,
        options: .regularExpression
      )
    }
  }

  private static func redactingSensitiveHeaderValues(in command: String) -> String {
    let headerPattern = #"(?i)\b((?:proxy-)?authorization|cookie|set-cookie|[A-Za-z0-9_-]*(?:token|api[-_]?key|secret|credential)[A-Za-z0-9_-]*)(\s*:\s*)((?:basic|bearer|digest|negotiate|aws4-hmac-sha256)\s+)?"#
    guard let regex = try? NSRegularExpression(pattern: headerPattern) else {
      return command
    }

    let redacted = NSMutableString(string: command)
    let replacement = "<redacted>"
    var searchLocation = 0

    while searchLocation < redacted.length {
      let current = redacted as String
      let searchRange = NSRange(location: searchLocation, length: redacted.length - searchLocation)
      guard let match = regex.firstMatch(in: current, range: searchRange) else {
        break
      }

      let valueStart = NSMaxRange(match.range)
      let enclosingQuote = activeShellQuote(at: match.range.location, in: redacted)
      let valueEnd = sensitiveHeaderValueEnd(
        from: valueStart,
        enclosingQuote: enclosingQuote,
        in: redacted
      )
      redacted.replaceCharacters(
        in: NSRange(location: valueStart, length: valueEnd - valueStart),
        with: replacement
      )
      searchLocation = valueStart + replacement.utf16.count
      if enclosingQuote != nil, searchLocation < redacted.length {
        searchLocation += 1
      }
    }

    return redacted as String
  }

  private static func activeShellQuote(at location: Int, in value: NSString) -> unichar? {
    var quote: unichar?
    var index = 0

    while index < location {
      let character = value.character(at: index)
      if quote == 0x27 {
        if character == 0x27 {
          quote = nil
        }
        index += 1
        continue
      }
      if character == 0x5C {
        index += 2
        continue
      }
      if character == 0x22 {
        quote = quote == 0x22 ? nil : 0x22
      } else if character == 0x27, quote == nil {
        quote = 0x27
      }
      index += 1
    }

    return quote
  }

  private static func sensitiveHeaderValueEnd(
    from start: Int,
    enclosingQuote: unichar?,
    in value: NSString
  ) -> Int {
    var index = start
    while index < value.length {
      let character = value.character(at: index)
      if let enclosingQuote {
        if enclosingQuote == 0x22, character == 0x5C {
          index += 2
          continue
        }
        if character == enclosingQuote {
          return index
        }
      } else {
        if character == 0x5C {
          index += 2
          continue
        }
        if character == 0x09 || character == 0x0A || character == 0x0D || character == 0x20 {
          return index
        }
      }
      index += 1
    }
    return value.length
  }

  public static func exportRows(_ items: [ClassifiedDevProcess]) -> String {
    let header = "pid\tppid\tkind\tcpu\tmemory\tproject\tprocess\tcommand"
    let rows = items.map { item in
      [
        "\(item.process.pid)",
        "\(item.process.parentPID)",
        item.classification.kind.rawValue,
        String(format: "%.1f", item.process.resourceUsage?.cpuPercent ?? 0),
        "\(item.process.resourceUsage?.residentMemoryBytes ?? 0)",
        exportCell(projectName(for: item) ?? ""),
        exportCell(item.classification.displayName),
        exportCell(redactedCommand(item.process.command)),
      ].joined(separator: "\t")
    }

    return ([header] + rows).joined(separator: "\n")
  }

  private static func exportCell(_ value: String) -> String {
    let singleLine =
      value
      .replacingOccurrences(of: "\t", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
    guard let first = singleLine.first, "=+-@".contains(first) else {
      return singleLine
    }
    return "'" + singleLine
  }

  private static func shouldHideExecutableContext(_ executableName: String, displayName: String)
    -> Bool
  {
    let executable = executableName.lowercased()
    let display = displayName.lowercased()

    if [
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
      "xpcservices",
    ].contains(executable) {
      return true
    }

    return executable.count <= 3 && display.hasPrefix(executable)
      && display.count > executable.count
  }

  private static func leadingAbsoluteCommandPath(_ command: String) -> String? {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("/") else {
      return nil
    }

    return trimmed.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
  }

  private static func searchTerms(from searchText: String) -> [String] {
    searchText
      .split(whereSeparator: { $0.isWhitespace })
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { !$0.isEmpty }
  }

  private static func cpu(_ item: ClassifiedDevProcess) -> Double {
    item.process.resourceUsage?.cpuPercent ?? 0
  }

  private static func memory(_ item: ClassifiedDevProcess) -> Int64 {
    item.process.resourceUsage?.residentMemoryBytes ?? 0
  }

  private static func stableFallback(_ lhs: ClassifiedDevProcess, _ rhs: ClassifiedDevProcess)
    -> Bool
  {
    let nameComparison = lhs.classification.displayName.localizedStandardCompare(
      rhs.classification.displayName)
    if nameComparison != .orderedSame {
      return nameComparison == .orderedAscending
    }
    return lhs.process.pid < rhs.process.pid
  }
}
