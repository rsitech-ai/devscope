import XCTest
@testable import DevScopeCore

final class ProcessIntelligenceTests: XCTestCase {
  func testWorkflowSubtitlesUseExplicitOSProcessLanguage() throws {
    let item = classified(
      pid: 100,
      kind: .javascript,
      displayName: "vite",
      project: "devscope",
      command: "pnpm vite"
    )

    let workflow = try XCTUnwrap(ProcessIntelligence.workflows(for: [item]).first)

    XCTAssertTrue(workflow.subtitle.contains("1 OS process"))
    XCTAssertFalse(workflow.subtitle.contains("proc ·"))
  }

  func testBuildsAIMLLabAndProjectWorkflows() {
    let items = [
      classified(pid: 101, kind: .python, displayName: "torchrun train", project: "research", command: "torchrun train_llama.py", cpu: 92, memory: 900_000_000, tags: [.training, .llm]),
      classified(pid: 102, kind: .python, displayName: "ipykernel", project: "research", command: "python -m ipykernel_launcher", cpu: 5, memory: 300_000_000, tags: [.notebook]),
      classified(pid: 103, kind: .ai, displayName: "Ollama server", project: "research", command: "ollama serve", cpu: 12, memory: 5_000_000_000, tags: [.llmServer]),
      classified(pid: 201, kind: .javascript, displayName: "vite", project: "web", command: "pnpm vite", cpu: 3, memory: 200_000_000)
    ]

    let workflows = ProcessIntelligence.workflows(for: items)

    XCTAssertTrue(workflows.contains { $0.id == "workflow:ai-ml-lab" })
    XCTAssertTrue(workflows.contains { $0.id == "workflow:local-llm-stack" })
    XCTAssertTrue(workflows.contains { $0.title == "Research Training" })
    XCTAssertEqual(workflows.first?.risk, .heavy)
  }

  func testCanonicalizesNoisyCacheAndOwnerWorkspaceNames() {
    let home = NSHomeDirectory()
    let items = [
      classified(
        pid: 401,
        kind: .javascript,
        displayName: "MCP server",
        project: "0.1.23",
        command: "node \(home)/.codex/plugins/cache/openai-curated-remote/computer-use/0.1.23/mcp/server.bundle.mjs",
        currentDirectory: "\(home)/.codex/plugins/cache/openai-curated-remote/computer-use/0.1.23/mcp"
      ),
      classified(
        pid: 402,
        kind: .javascript,
        displayName: "MCP server",
        project: "3fdeeb49",
        command: "node \(home)/.codex/plugins/cache/openai-curated/build-web-apps/3fdeeb49/skills/server.mjs",
        currentDirectory: "\(home)/.codex/plugins/cache/openai-curated/build-web-apps/3fdeeb49/skills"
      ),
      classified(
        pid: 403,
        kind: .swift,
        displayName: "swift build",
        project: "example",
        command: "swift build",
        currentDirectory: "\(home)/dev/example/devscope"
      )
    ]

    let workflows = ProcessIntelligence.workflows(for: items)
    let titles = workflows.map(\.title)

    XCTAssertTrue(titles.contains("Computer Use Web"))
    XCTAssertTrue(titles.contains("Build Web Apps Web"))
    XCTAssertTrue(titles.contains("DevScope Build"))
    XCTAssertFalse(titles.contains { $0.contains("0.1.23") })
    XCTAssertFalse(titles.contains { $0.contains("3fdeeb49") })
    XCTAssertFalse(titles.contains("example Build"))
  }

  func testWorkflowOrderStaysStableWhenCpuChangesWithinSameRiskBand() {
    let items = [
      classified(pid: 201, kind: .javascript, displayName: "vite", project: "alpha", command: "pnpm vite", cpu: 1, memory: 200_000_000),
      classified(pid: 202, kind: .javascript, displayName: "vite", project: "beta", command: "pnpm vite", cpu: 19, memory: 200_000_000)
    ]

    let workflows = ProcessIntelligence.workflows(for: items)

    XCTAssertEqual(workflows.map(\.title), ["Alpha Web", "Beta Web"])
  }

  func testPunctuationCollidingProjectsHaveDistinctDeterministicWorkflows() {
    let home = NSHomeDirectory()
    let dotted = classified(
      pid: 220,
      kind: .javascript,
      displayName: "vite",
      project: "foo.bar",
      command: "pnpm vite",
      currentDirectory: "\(home)/dev/foo.bar"
    )
    let dashed = classified(
      pid: 221,
      kind: .javascript,
      displayName: "vite",
      project: "foo-bar",
      command: "pnpm vite",
      currentDirectory: "\(home)/dev/foo-bar"
    )
    let dottedWorker = classified(
      pid: 222,
      kind: .javascript,
      displayName: "vite worker",
      project: "foo.bar",
      command: "pnpm vite --worker",
      currentDirectory: "\(home)/dev/foo.bar"
    )

    let items = [dotted, dashed, dottedWorker]
    let forward = ProcessIntelligence.workflows(for: items)
    let reversed = ProcessIntelligence.workflows(for: Array(items.reversed()))

    XCTAssertEqual(forward, reversed)
    XCTAssertEqual(Set(forward.map(\.title)), Set(["Foo.bar Web", "Foo Bar Web"]))
    XCTAssertEqual(Set(forward.map(\.id)).count, 2)
    XCTAssertEqual(Set(forward.flatMap(\.processIDs)), Set([220, 221, 222]))
    XCTAssertEqual(forward.first { $0.title == "Foo.bar Web" }?.processIDs, [220, 222])
  }

  func testProjectWorkflowAggregationIsDeterministicAcrossInputOrder() throws {
    let items = [
      classified(
        pid: 903,
        kind: .javascript,
        displayName: "experiment worker",
        project: "determinism",
        command: "node experiment.js",
        cpu: 10_000_000_000_000_000,
        tags: [.experiment]
      ),
      classified(
        pid: 901,
        kind: .javascript,
        displayName: "API worker",
        project: "determinism",
        command: "node api.js",
        cpu: 1,
        tags: [.api]
      ),
      classified(
        pid: 902,
        kind: .javascript,
        displayName: "MCP worker",
        project: "determinism",
        command: "node mcp.js",
        cpu: 1,
        tags: [.mcp]
      ),
    ]

    let forward = try XCTUnwrap(
      ProcessIntelligence.workflows(for: items).first { $0.title == "Determinism API" }
    )
    let reversed = try XCTUnwrap(
      ProcessIntelligence.workflows(for: Array(items.reversed())).first { $0.title == "Determinism API" }
    )

    XCTAssertEqual(forward, reversed)
    XCTAssertEqual(forward.tags.map(\.id), ["api", "experiment", "mcp"])
  }

  func testAIMLAggregationIsDeterministicAcrossInputOrder() throws {
    let items = [
      classified(
        pid: 913,
        kind: .python,
        displayName: "experiment worker",
        project: "gamma",
        command: "python experiment.py",
        cpu: 10_000_000_000_000_000,
        tags: [.experiment]
      ),
      classified(
        pid: 911,
        kind: .python,
        displayName: "training worker",
        project: "alpha",
        command: "python train.py",
        cpu: 1,
        tags: [.training]
      ),
      classified(
        pid: 912,
        kind: .python,
        displayName: "notebook worker",
        project: "beta",
        command: "python notebook.py",
        cpu: 1,
        tags: [.notebook]
      ),
    ]

    let forward = try XCTUnwrap(
      ProcessIntelligence.workflows(for: items).first { $0.id == "workflow:ai-ml-lab" }
    )
    let reversed = try XCTUnwrap(
      ProcessIntelligence.workflows(for: Array(items.reversed())).first { $0.id == "workflow:ai-ml-lab" }
    )

    XCTAssertEqual(forward, reversed)
    XCTAssertEqual(forward.tags.map(\.id), ["experiment", "notebook", "training"])
  }

  func testAvoidsDuplicateKindWordsAndNoisySingleProcessFocusGroups() {
    let items = [
      classified(
        pid: 301,
        kind: .python,
        displayName: "streamlit",
        project: "data",
        command: "streamlit run app.py",
        cpu: 4,
        memory: 200_000_000,
        tags: [.dataApp],
        currentDirectory: "\(NSHomeDirectory())/dev/example/data"
      ),
      classified(
        pid: 302,
        kind: .python,
        displayName: "(python3.12)",
        project: "(python3.12)",
        command: "(python3.12)",
        cpu: 0,
        memory: 12_000_000,
        currentDirectory: nil
      ),
      classified(
        pid: 303,
        kind: .swift,
        displayName: "CalendarThumbnailExtension Launcher",
        project: "CalendarThumbnailExtension Launcher",
        command: "/System/Library/ExtensionKit/Extensions/CalendarThumbnailExtension.appex",
        cpu: 0,
        memory: 10_000_000,
        currentDirectory: "/System/Library/ExtensionKit/Extensions"
      )
    ]

    let workflows = ProcessIntelligence.workflows(for: items)

    XCTAssertTrue(workflows.contains { $0.title == "Data App" })
    XCTAssertFalse(workflows.contains { $0.title.contains("Data Data") })
    XCTAssertFalse(workflows.contains { $0.title.contains("python3.12") })
    XCTAssertFalse(workflows.contains { $0.title.contains("CalendarThumbnail") })
  }

  func testRejectsBrowserRendererCommandsAsFocusWorkflows() {
    let command = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper --type=renderer --origin-trial-disabled-features=CanvasTextNG --lang=en-US --renderer-client-id=3645"
    let items = [
      classified(pid: 501, kind: .browser, displayName: "Google Chrome Helper", project: "Google Chrome Helper", command: command, cpu: 45, memory: 2_000_000_000, currentDirectory: "/"),
      classified(pid: 502, kind: .browser, displayName: "Google Chrome Helper", project: "Google Chrome Helper", command: command + " --renderer-client-id=3646", cpu: 30, memory: 1_500_000_000, currentDirectory: "/")
    ]

    let workflows = ProcessIntelligence.workflows(for: items)

    XCTAssertTrue(workflows.isEmpty)
    XCTAssertFalse(workflows.contains { $0.title.contains("renderer") || $0.title.count > 72 })
  }

  func testCommandPathCandidateBuildsADevelopmentWorkflow() {
    let home = NSHomeDirectory()
    let command = "node \(home)/dev/example/devscope/node_modules/.bin/vite --host 127.0.0.1"
    let item = ClassifiedDevProcess(
      process: DevProcess(
        pid: 503,
        parentPID: 1,
        executable: "node",
        command: command,
        currentDirectory: nil,
        resourceUsage: DevProcessResourceUsage(cpuPercent: 0, residentMemoryBytes: 0, elapsedTime: "00:01")
      ),
      classification: DevProcessClassification(
        kind: .javascript,
        displayName: "vite",
        projectHint: "devscope",
        tags: []
      )
    )

    XCTAssertTrue(ProcessIntelligence.workflows(for: [item]).contains { $0.title == "DevScope Web" })
  }

  func testConfiguredOwnerDirectoryKeepsDeepSiblingRepositoriesDistinct() {
    let home = NSHomeDirectory()
    let items = [
      classified(
        pid: 504,
        kind: .javascript,
        displayName: "vite",
        project: "fallback",
        command: "pnpm vite",
        currentDirectory: "\(home)/dev/acme-labs/alpha-app/feature-one/task"
      ),
      classified(
        pid: 505,
        kind: .javascript,
        displayName: "vite",
        project: "fallback",
        command: "pnpm vite",
        currentDirectory: "\(home)/dev/acme-labs/beta-app/feature-two/task"
      ),
    ]

    XCTAssertEqual(
      ProcessIntelligence.workflows(
        for: items,
        workspaceOwnerComponents: ["acme-labs"]
      ).map(\.title),
      ["Alpha App Web", "Beta App Web"]
    )
  }

  func testDirectProjectNestedDirectoryKeepsRepositoryIdentity() {
    let item = classified(
      pid: 506,
      kind: .javascript,
      displayName: "vite",
      project: "devscope",
      command: "pnpm vite",
      currentDirectory: "\(NSHomeDirectory())/dev/devscope/feature-one"
    )

    XCTAssertEqual(
      ProcessIntelligence.workflows(for: [item]).map(\.title),
      ["DevScope Web"]
    )
  }

  func testLexicalAbsolutePathNormalizationDoesNotDependOnFilesystemState() {
    let home = NSHomeDirectory()

    XCTAssertEqual(
      ProcessIntelligence.lexicallyNormalizedAbsolutePath(
        "\(home)//dev/./example/../devscope/"
      ),
      "\(home)/dev/devscope"
    )
    XCTAssertEqual(
      ProcessIntelligence.lexicallyNormalizedAbsolutePath("/Users/example/../../tmp"),
      "/tmp"
    )
    XCTAssertNil(ProcessIntelligence.lexicallyNormalizedAbsolutePath("../../tmp"))
    XCTAssertNil(ProcessIntelligence.lexicallyNormalizedAbsolutePath("/../../tmp"))
  }

  func testLexicalProjectPathsPreserveDevRootsAndRejectHomeEscape() throws {
    let home = NSHomeDirectory()
    let homeName = try XCTUnwrap(home.split(separator: "/").last.map(String.init))
    let items = [
      classified(
        pid: 550,
        kind: .javascript,
        displayName: "vite",
        project: "fallback",
        command: "pnpm vite",
        currentDirectory: "\(home)//dev/./example/scratch/../devscope//"
      ),
      classified(
        pid: 551,
        kind: .javascript,
        displayName: "vite",
        project: "escaped",
        command: "pnpm vite",
        currentDirectory: "\(home)/dev/../../\(homeName)/dev/example/escaped"
      ),
      classified(
        pid: 552,
        kind: .javascript,
        displayName: "vite",
        project: "nested",
        command: "pnpm vite",
        currentDirectory: "\(home)/Downloads/../Documents/dev/nested"
      ),
    ]

    XCTAssertEqual(ProcessIntelligence.workflows(for: items).map(\.title), ["DevScope Web"])
  }

  func testRejectsHomeLibraryPathsAsDevelopmentWorkflows() {
    let directory = "\(NSHomeDirectory())/Library/Application Support/Acme Helper"
    let items = [
      classified(
        pid: 601,
        kind: .javascript,
        displayName: "helper",
        project: "Acme Helper",
        command: "/usr/bin/node helper.js",
        currentDirectory: directory
      ),
      classified(
        pid: 602,
        kind: .javascript,
        displayName: "helper",
        project: "Acme Helper",
        command: "/usr/bin/node helper.js --worker",
        currentDirectory: directory
      ),
    ]

    XCTAssertTrue(ProcessIntelligence.workflows(for: items).isEmpty)
  }

  func testAcceptsKnownDevelopmentRootsAndSkipsNestedRootBuckets() {
    let home = NSHomeDirectory()
    let fixtures = [
      ("dev/apps/meeting_vault", "Meeting Vault Web"),
      ("apps/clip_vault", "Clip Vault Web"),
      ("projects/alpha", "Alpha Web"),
      ("workspaces/beta", "Beta Web"),
      ("source/gamma", "Gamma Web"),
      ("src/delta", "Delta Web"),
    ]
    let items = fixtures.enumerated().map { index, fixture in
      classified(
        pid: Int32(620 + index),
        kind: .javascript,
        displayName: "vite",
        project: "fallback-\(index)",
        command: "pnpm vite",
        currentDirectory: "\(home)/\(fixture.0)"
      )
    }

    let titles = Set(ProcessIntelligence.workflows(for: items).map(\.title))

    XCTAssertEqual(titles, Set(fixtures.map(\.1)))
  }

  func testRejectsDevelopmentMarkerNestedUnderDownloads() {
    let item = classified(
      pid: 640,
      kind: .javascript,
      displayName: "vite",
      project: "helper",
      command: "pnpm vite",
      currentDirectory: "\(NSHomeDirectory())/Downloads/dev/helper"
    )

    XCTAssertTrue(ProcessIntelligence.workflows(for: [item]).isEmpty)
  }

  func testRejectsProjectsMarkerNestedUnderDesktop() {
    let item = classified(
      pid: 641,
      kind: .javascript,
      displayName: "vite",
      project: "tool",
      command: "pnpm vite",
      currentDirectory: "\(NSHomeDirectory())/Desktop/projects/tool"
    )

    XCTAssertTrue(ProcessIntelligence.workflows(for: [item]).isEmpty)
  }

  func testRejectsCodexMarkerNestedUnderDocuments() {
    let item = classified(
      pid: 642,
      kind: .mcp,
      displayName: "MCP server",
      project: "codex",
      command: "node server.mjs",
      currentDirectory: "\(NSHomeDirectory())/Documents/.codex/plugins/tool"
    )

    XCTAssertTrue(ProcessIntelligence.workflows(for: [item]).isEmpty)
  }

  func testQuotedCommandPathWithSpacesBuildsADevelopmentWorkflow() {
    let home = NSHomeDirectory()
    let command = "node \"\(home)/dev/My Great App/node_modules/.bin/vite\" --host 127.0.0.1"
    let item = ClassifiedDevProcess(
      process: DevProcess(
        pid: 603,
        parentPID: 1,
        executable: "node",
        command: command,
        resourceUsage: DevProcessResourceUsage(cpuPercent: 0, residentMemoryBytes: 0, elapsedTime: "00:01")
      ),
      classification: DevProcessClassification(
        kind: .javascript,
        displayName: "vite",
        projectHint: "fallback",
        tags: []
      )
    )

    XCTAssertTrue(
      ProcessIntelligence.workflows(for: [item]).contains { $0.title == "My Great App Web" }
    )
  }

  func testRejectsMalformedQuotedAssignmentsAndRawCommandIdentifiers() {
    let home = NSHomeDirectory()
    let items = [
      classifiedWithoutCurrentDirectory(
        pid: 604,
        command: "node \"\(home)/dev/alpha/server.js"
      ),
      classifiedWithoutCurrentDirectory(
        pid: 605,
        command: "node PROJECT=\(home)/dev/beta/server.js"
      ),
      classifiedWithoutCurrentDirectory(
        pid: 606,
        command: "node devscope-worker"
      ),
      classifiedWithoutCurrentDirectory(
        pid: 607,
        command: "node \"\(home)/dev/gamma/server.js\"suffix"
      ),
    ]

    XCTAssertTrue(ProcessIntelligence.workflows(for: items).isEmpty)
  }

  func testCapsWorkflowsWhilePreservingAIMLAggregates() {
    var items = (0..<15).map { index in
      classified(
        pid: Int32(700 + index),
        kind: .javascript,
        displayName: "vite",
        project: "project-\(index)",
        command: "pnpm vite"
      )
    }
    items.append(
      classified(
        pid: 799,
        kind: .ai,
        displayName: "Ollama server",
        project: "research",
        command: "ollama serve",
        tags: [.llmServer]
      )
    )

    let workflows = ProcessIntelligence.workflows(for: items)

    XCTAssertLessThanOrEqual(workflows.count, 12)
    XCTAssertTrue(workflows.contains { $0.id == "workflow:ai-ml-lab" })
    XCTAssertTrue(workflows.contains { $0.id == "workflow:local-llm-stack" })
    XCTAssertEqual(workflows.map(\.id), ProcessIntelligence.workflows(for: items).map(\.id))
  }

  func testProcessInsightExplainsRoleAndSafeAction() {
    let item = classified(pid: 101, kind: .python, displayName: "torchrun train", project: "research", command: "torchrun train_llama.py", cpu: 92, memory: 900_000_000, tags: [.training, .llm])
    let workflow = ProcessIntelligence.workflows(for: [item]).first
    let family = ProcessFamilySummary(parentPID: 1, childCount: 1, descendantCount: 2)

    let insight = ProcessIntelligence.insight(
      for: item,
      workflow: workflow,
      familySummary: family,
      metricHistory: []
    )

    XCTAssertEqual(insight.title, "Training workload")
    XCTAssertEqual(insight.role, "Training or fine-tuning workload")
    XCTAssertTrue(insight.resourceBehavior.contains("High CPU"))
    XCTAssertTrue(insight.safeAction.contains("TERM Tree"))
  }

  func testProtectedProcessInsightNeverRecommendsTermTree() {
    let item = classified(
      pid: 1,
      kind: .systemService,
      displayName: "launchd",
      project: "system",
      command: "/sbin/launchd"
    )
    let family = ProcessFamilySummary(parentPID: 0, childCount: 700, descendantCount: 890)

    let insight = ProcessIntelligence.insight(
      for: item,
      workflow: nil,
      familySummary: family,
      metricHistory: [],
      actionDecision: .protected(reason: "macOS launch infrastructure is protected")
    )

    XCTAssertEqual(insight.safeAction, "Protected: macOS launch infrastructure is protected.")
    XCTAssertFalse(insight.safeAction.contains("TERM"))
  }

  private func classified(
    pid: Int32,
    kind: DevRuntimeKind,
    displayName: String,
    project: String,
    command: String,
    cpu: Double = 0,
    memory: Int64 = 0,
    tags: [DevProcessTag] = [],
    currentDirectory: String? = nil
  ) -> ClassifiedDevProcess {
    ClassifiedDevProcess(
      process: DevProcess(
        pid: pid,
        parentPID: 1,
        executable: command.split(separator: " ").first.map(String.init) ?? command,
        command: command,
        currentDirectory: currentDirectory ?? "\(NSHomeDirectory())/dev/example/\(project)",
        resourceUsage: DevProcessResourceUsage(cpuPercent: cpu, residentMemoryBytes: memory, elapsedTime: "00:01")
      ),
      classification: DevProcessClassification(
        kind: kind,
        displayName: displayName,
        projectHint: project,
        tags: tags
      )
    )
  }

  private func classifiedWithoutCurrentDirectory(
    pid: Int32,
    command: String
  ) -> ClassifiedDevProcess {
    ClassifiedDevProcess(
      process: DevProcess(
        pid: pid,
        parentPID: 1,
        executable: "node",
        command: command,
        resourceUsage: DevProcessResourceUsage(cpuPercent: 0, residentMemoryBytes: 0, elapsedTime: "00:01")
      ),
      classification: DevProcessClassification(
        kind: .javascript,
        displayName: "node",
        projectHint: "fallback",
        tags: []
      )
    )
  }
}
