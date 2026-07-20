import Foundation

public enum ProcessActivityScope: String, CaseIterable, Identifiable, Sendable {
  case applications
  case processes
  case hierarchy
  case workflows

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .applications:
      "Applications"
    case .processes:
      "Processes"
    case .hierarchy:
      "Hierarchy"
    case .workflows:
      "Workflows"
    }
  }

  public var symbolName: String {
    switch self {
    case .applications:
      "macwindow.on.rectangle"
    case .processes:
      "list.bullet.rectangle"
    case .hierarchy:
      "point.3.connected.trianglepath.dotted"
    case .workflows:
      "square.stack.3d.up"
    }
  }
}
public enum ApplicationProcessRole: String, Equatable, Hashable, Sendable {
  case application
  case helper
  case worker

  public var title: String {
    switch self {
    case .application:
      "App"
    case .helper:
      "Helper"
    case .worker:
      "Worker"
    }
  }

  public var symbolName: String {
    switch self {
    case .application:
      "macwindow"
    case .helper:
      "gearshape.2"
    case .worker:
      "hammer"
    }
  }
}

public struct ApplicationProcessMember: Identifiable, Equatable, Sendable {
  public let item: ClassifiedDevProcess
  public let role: ApplicationProcessRole
  public let depth: Int

  public var id: Int32 { item.process.pid }

  public init(item: ClassifiedDevProcess, role: ApplicationProcessRole, depth: Int) {
    self.item = item
    self.role = role
    self.depth = depth
  }
}

public struct ProcessApplicationFamily: Identifiable, Equatable, Sendable {
  public let bundlePath: String
  public let title: String
  public let members: [ApplicationProcessMember]
  public let applicationCount: Int
  public let helperCount: Int
  public let workerCount: Int
  public let totalCPU: Double
  public let totalMemoryBytes: Int64

  public var id: String { bundlePath }
  public var processIDs: [Int32] { members.map(\.id).sorted() }

  public init(
    bundlePath: String,
    title: String,
    members: [ApplicationProcessMember],
    applicationCount: Int,
    helperCount: Int,
    workerCount: Int,
    totalCPU: Double,
    totalMemoryBytes: Int64
  ) {
    self.bundlePath = bundlePath
    self.title = title
    self.members = members
    self.applicationCount = applicationCount
    self.helperCount = helperCount
    self.workerCount = workerCount
    self.totalCPU = totalCPU
    self.totalMemoryBytes = totalMemoryBytes
  }
}

public struct ProcessHierarchyNode: Identifiable, Equatable, Sendable {
  public let item: ClassifiedDevProcess
  public let children: [ProcessHierarchyNode]

  public var id: Int32 { item.process.pid }
  public var outlineChildren: [ProcessHierarchyNode]? {
    children.isEmpty ? nil : children
  }

  public init(item: ClassifiedDevProcess, children: [ProcessHierarchyNode]) {
    self.item = item
    self.children = children
  }
}

public enum ProcessScopePresentation {
  public static func applicationFamilies<S: Sequence>(
    for items: S,
    searchText: String = ""
  ) -> [ProcessApplicationFamily] where S.Element == ClassifiedDevProcess {
    let items = canonicalItems(Array(items))
    let itemsByPID = Dictionary(uniqueKeysWithValues: items.map { ($0.process.pid, $0) })
    let directBundleByPID = Dictionary(
      uniqueKeysWithValues: items.compactMap { item in
        outerApplicationBundlePath(for: item.process).map { (item.process.pid, $0) }
      }
    )

    var groupedItems: [String: [ClassifiedDevProcess]] = [:]
    for item in items {
      guard
        let bundlePath = resolvedApplicationBundlePath(
          for: item.process.pid,
          itemsByPID: itemsByPID,
          directBundleByPID: directBundleByPID
        )
      else {
        continue
      }
      groupedItems[bundlePath, default: []].append(item)
    }

    let terms = searchTerms(searchText)
    return groupedItems.map { bundlePath, familyItems in
      makeFamily(
        bundlePath: bundlePath,
        items: familyItems,
        directBundleByPID: directBundleByPID
      )
    }
    .filter { family in
      terms.isEmpty || terms.allSatisfy { familySearchText(family).contains($0) }
    }
    .sorted { lhs, rhs in
      let titleComparison = lhs.title.localizedStandardCompare(rhs.title)
      if titleComparison != .orderedSame {
        return titleComparison == .orderedAscending
      }
      return lhs.bundlePath < rhs.bundlePath
    }
  }

  public static func hierarchy<S: Sequence>(
    for items: S,
    searchText: String = ""
  ) -> [ProcessHierarchyNode] where S.Element == ClassifiedDevProcess {
    let items = canonicalItems(Array(items))
    let itemsByPID = Dictionary(uniqueKeysWithValues: items.map { ($0.process.pid, $0) })
    let processIDs = Set(itemsByPID.keys)
    let childrenByParent = Dictionary(grouping: items, by: \.process.parentPID)
      .mapValues { $0.map(\.process.pid).sorted() }
    let rootIDs = items
      .filter {
        $0.process.parentPID == $0.process.pid
          || !processIDs.contains($0.process.parentPID)
      }
      .map(\.process.pid)
      .sorted()
    var visited = Set<Int32>()

    func makeNode(_ processID: Int32) -> ProcessHierarchyNode? {
      guard visited.insert(processID).inserted, let item = itemsByPID[processID] else {
        return nil
      }
      let children = childrenByParent[processID, default: []].compactMap(makeNode)
      return ProcessHierarchyNode(item: item, children: children)
    }

    var nodes = rootIDs.compactMap(makeNode)
    for processID in processIDs.sorted() where !visited.contains(processID) {
      if let node = makeNode(processID) {
        nodes.append(node)
      }
    }

    let terms = searchTerms(searchText)
    guard !terms.isEmpty else {
      return nodes
    }
    return nodes.compactMap { filteredHierarchyNode($0, terms: terms) }
  }

  public static func flattened(
    _ nodes: [ProcessHierarchyNode]
  ) -> [ProcessHierarchyNode] {
    nodes.flatMap { node in
      [node] + flattened(node.children)
    }
  }

  private static func makeFamily(
    bundlePath: String,
    items: [ClassifiedDevProcess],
    directBundleByPID: [Int32: String]
  ) -> ProcessApplicationFamily {
    let itemsByPID = Dictionary(uniqueKeysWithValues: items.map { ($0.process.pid, $0) })
    let members = orderedMembers(
      items: items,
      roleForPID: { processID in
        guard let item = itemsByPID[processID] else {
          return .worker
        }
        guard directBundleByPID[processID] == bundlePath else {
          return .worker
        }
        return isApplicationInstance(item.process, bundlePath: bundlePath)
          ? .application : .helper
      }
    )
    let roleCounts = Dictionary(grouping: members, by: \.role).mapValues(\.count)

    return ProcessApplicationFamily(
      bundlePath: bundlePath,
      title: familyTitle(bundlePath: bundlePath, items: items),
      members: members,
      applicationCount: roleCounts[.application, default: 0],
      helperCount: roleCounts[.helper, default: 0],
      workerCount: roleCounts[.worker, default: 0],
      totalCPU: items.reduce(0) { $0 + ($1.process.resourceUsage?.cpuPercent ?? 0) },
      totalMemoryBytes: items.reduce(0) {
        $0 + ($1.process.resourceUsage?.residentMemoryBytes ?? 0)
      }
    )
  }

  private static func orderedMembers(
    items: [ClassifiedDevProcess],
    roleForPID: (Int32) -> ApplicationProcessRole
  ) -> [ApplicationProcessMember] {
    let itemsByPID = Dictionary(uniqueKeysWithValues: items.map { ($0.process.pid, $0) })
    let processIDs = Set(itemsByPID.keys)
    let childrenByParent = Dictionary(grouping: items, by: \.process.parentPID)
      .mapValues { $0.map(\.process.pid).sorted() }
    let roots = items
      .filter { !processIDs.contains($0.process.parentPID) }
      .map(\.process.pid)
      .sorted()
    var visited = Set<Int32>()
    var result: [ApplicationProcessMember] = []

    func visit(_ processID: Int32, depth: Int) {
      guard visited.insert(processID).inserted, let item = itemsByPID[processID] else {
        return
      }
      result.append(
        ApplicationProcessMember(
          item: item,
          role: roleForPID(processID),
          depth: depth
        )
      )
      for childID in childrenByParent[processID, default: []] {
        visit(childID, depth: depth + 1)
      }
    }

    for rootID in roots {
      visit(rootID, depth: 0)
    }
    for processID in processIDs.sorted() where !visited.contains(processID) {
      visit(processID, depth: 0)
    }
    return result
  }

  private static func resolvedApplicationBundlePath(
    for processID: Int32,
    itemsByPID: [Int32: ClassifiedDevProcess],
    directBundleByPID: [Int32: String]
  ) -> String? {
    var currentProcessID = processID
    var visited = Set<Int32>()

    while visited.insert(currentProcessID).inserted {
      if let bundlePath = directBundleByPID[currentProcessID] {
        return bundlePath
      }
      guard let item = itemsByPID[currentProcessID] else {
        return nil
      }
      currentProcessID = item.process.parentPID
    }
    return nil
  }

  private static func outerApplicationBundlePath(for process: DevProcess) -> String? {
    outerApplicationBundlePath(in: process.executable)
      ?? outerApplicationBundlePath(in: process.command)
  }

  private static func outerApplicationBundlePath(in rawValue: String) -> String? {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    let roots = ["/Applications/", "/System/", "/Users/", "/private/", "/Volumes/"]
    let start = roots.compactMap { value.range(of: $0)?.lowerBound }.min()
      ?? (value.hasPrefix("/") ? value.startIndex : nil)
    guard let start else {
      return nil
    }

    var searchStart = start
    while searchStart < value.endIndex,
      let appRange = value.range(
        of: ".app",
        options: [.caseInsensitive],
        range: searchStart..<value.endIndex
      )
    {
      let end = appRange.upperBound
      let hasBundleBoundary = end == value.endIndex || value[end] == "/"
      if hasBundleBoundary {
        let path = String(value[start..<end])
        guard path.hasPrefix("/"), !path.contains("\n") else {
          return nil
        }
        return (path as NSString).standardizingPath
      }
      searchStart = end
    }
    return nil
  }

  private static func isApplicationInstance(
    _ process: DevProcess,
    bundlePath: String
  ) -> Bool {
    guard process.parentPID == 1 else {
      return false
    }
    let mainExecutablePrefix = bundlePath + "/Contents/MacOS/"
    return process.executable.hasPrefix(mainExecutablePrefix)
      || process.command.hasPrefix(mainExecutablePrefix)
  }

  private static func familyTitle(
    bundlePath: String,
    items: [ClassifiedDevProcess]
  ) -> String {
    let baseTitle = URL(fileURLWithPath: bundlePath)
      .deletingPathExtension()
      .lastPathComponent
    if baseTitle.caseInsensitiveCompare("ChatGPT") == .orderedSame,
      items.contains(where: {
        $0.process.executable.localizedCaseInsensitiveContains("codex")
          || $0.process.command.localizedCaseInsensitiveContains("codex")
      })
    {
      return "ChatGPT / Codex"
    }
    return baseTitle
  }

  private static func canonicalItems(
    _ items: [ClassifiedDevProcess]
  ) -> [ClassifiedDevProcess] {
    Dictionary(grouping: items, by: \.process.pid)
      .compactMap { _, candidates in
        candidates.sorted(by: stableItemOrder).first
      }
      .sorted(by: stableItemOrder)
  }

  private static func stableItemOrder(
    _ lhs: ClassifiedDevProcess,
    _ rhs: ClassifiedDevProcess
  ) -> Bool {
    let left = lhs.process
    let right = rhs.process
    if left.pid != right.pid { return left.pid < right.pid }
    if left.parentPID != right.parentPID { return left.parentPID < right.parentPID }
    if left.executable != right.executable { return left.executable < right.executable }
    if left.command != right.command { return left.command < right.command }
    return (left.currentDirectory ?? "") < (right.currentDirectory ?? "")
  }

  private static func searchTerms(_ searchText: String) -> [String] {
    searchText
      .lowercased()
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
  }

  private static func familySearchText(_ family: ProcessApplicationFamily) -> String {
    ([family.title, family.bundlePath]
      + family.members.flatMap { member in
        let item = member.item
        return [
          String(item.process.pid),
          item.classification.displayName,
          item.classification.projectHint ?? "",
          item.process.executable,
          item.process.command,
          item.process.currentDirectory ?? "",
        ]
      })
      .joined(separator: " ")
      .lowercased()
  }

  private static func filteredHierarchyNode(
    _ node: ProcessHierarchyNode,
    terms: [String]
  ) -> ProcessHierarchyNode? {
    let children = node.children.compactMap { filteredHierarchyNode($0, terms: terms) }
    guard terms.allSatisfy({ itemSearchText(node.item).contains($0) }) || !children.isEmpty else {
      return nil
    }
    return ProcessHierarchyNode(item: node.item, children: children)
  }

  private static func itemSearchText(_ item: ClassifiedDevProcess) -> String {
    [
      String(item.process.pid),
      String(item.process.parentPID),
      item.classification.displayName,
      item.classification.projectHint ?? "",
      item.process.executable,
      item.process.command,
      item.process.currentDirectory ?? "",
    ]
    .joined(separator: " ")
    .lowercased()
  }
}
