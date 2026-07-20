import XCTest
@testable import DevScopeCore

final class ProcessClassifierTests: XCTestCase {
  func testCachedFlutterWorkspaceFactsAvoidRepeatedFileProbe() {
    var probeCount = 0
    let cache = WorkspaceFactsCache { path in
      probeCount += 1
      return path.hasSuffix("/pubspec.yaml")
    }
    let directory = NSHomeDirectory() + "/dev/example/app"

    XCTAssertTrue(cache.isFlutterWorkspace(directory))
    XCTAssertTrue(cache.isFlutterWorkspace(directory))
    XCTAssertEqual(probeCount, 1)
  }

  func testSuppliedWorkspaceFactsDriveFlutterClassification() throws {
    let process = DevProcess(
      pid: 99,
      parentPID: 1,
      executable: "workspace-runner",
      command: "workspace-runner serve",
      currentDirectory: NSHomeDirectory() + "/dev/example/app"
    )

    let classification = try XCTUnwrap(
      ProcessClassifier.classify(
        process,
        workspaceFacts: WorkspaceFacts(isFlutterWorkspace: true)
      )
    )

    XCTAssertEqual(classification.kind, .flutter)
  }

  func testSuppliedNonFlutterFactsOverridePathHeuristic() throws {
    let process = DevProcess(
      pid: 100,
      parentPID: 1,
      executable: "workspace-runner",
      command: "workspace-runner serve",
      currentDirectory: NSHomeDirectory() + "/dev/flutter/app"
    )

    let classification = try XCTUnwrap(
      ProcessClassifier.classify(
        process,
        workspaceFacts: WorkspaceFacts(isFlutterWorkspace: false)
      )
    )

    XCTAssertEqual(classification.kind, .other)
  }

  func testWorkspaceFactsInvalidationRefreshesFileProbe() {
    var manifestExists = false
    var probeCount = 0
    let cache = WorkspaceFactsCache { path in
      probeCount += 1
      return manifestExists && path.hasSuffix("/pubspec.yaml")
    }
    let directory = NSHomeDirectory() + "/dev/example/app"

    XCTAssertFalse(cache.isFlutterWorkspace(directory))
    manifestExists = true
    XCTAssertFalse(cache.isFlutterWorkspace(directory))
    cache.invalidateAll()
    XCTAssertTrue(cache.isFlutterWorkspace(directory))
    XCTAssertEqual(probeCount, 3)
  }

  func testWorkspaceFactsClassificationCacheReturnsFreshMetricsWithoutRepeatedProbe() throws {
    var probeCount = 0
    let workspaceFactsCache = WorkspaceFactsCache { path in
      probeCount += 1
      return path.hasSuffix("/pubspec.yaml")
    }
    var cache = ProcessClassificationCache()
    let directory = NSHomeDirectory() + "/dev/example/app"
    let first = DevProcess(
      pid: 101,
      parentPID: 1,
      executable: "workspace-runner",
      command: "workspace-runner serve",
      currentDirectory: directory,
      resourceUsage: DevProcessResourceUsage(cpuPercent: 1, residentMemoryBytes: 100, elapsedTime: "00:01")
    )
    let second = DevProcess(
      pid: 101,
      parentPID: 1,
      executable: "workspace-runner",
      command: "workspace-runner serve",
      currentDirectory: directory,
      resourceUsage: DevProcessResourceUsage(cpuPercent: 90, residentMemoryBytes: 100, elapsedTime: "00:03")
    )

    _ = cache.classified([first], workspaceFactsCache: workspaceFactsCache)
    let classified = cache.classified([second], workspaceFactsCache: workspaceFactsCache)

    XCTAssertEqual(probeCount, 1)
    XCTAssertEqual(try XCTUnwrap(classified.first).classification.kind, .flutter)
    XCTAssertEqual(classified.first?.process.resourceUsage?.cpuPercent, 90)
  }

  func testParsesPsRowsWithCommandContainingSpaces() throws {
    let row = "  4312   112 /opt/homebrew/bin/node node ./node_modules/.bin/next dev --port 3014"

    let process = try XCTUnwrap(ProcessScanner.parsePSLine(row))

    XCTAssertEqual(process.pid, 4312)
    XCTAssertEqual(process.parentPID, 112)
    XCTAssertEqual(process.executable, "/opt/homebrew/bin/node")
    XCTAssertEqual(process.command, "node ./node_modules/.bin/next dev --port 3014")
  }

  func testParsesPsRowsWithResourceMetrics() throws {
    let row = "  4312   112  12.5  65536 01:02:03 /opt/homebrew/bin/node node ./node_modules/.bin/vite --host 0.0.0.0"

    let process = try XCTUnwrap(ProcessScanner.parsePSLine(row))

    XCTAssertEqual(process.pid, 4312)
    XCTAssertEqual(process.parentPID, 112)
    XCTAssertEqual(process.executable, "/opt/homebrew/bin/node")
    XCTAssertEqual(process.command, "node ./node_modules/.bin/vite --host 0.0.0.0")
    XCTAssertEqual(process.resourceUsage?.cpuPercent, 12.5)
    XCTAssertEqual(process.resourceUsage?.residentMemoryBytes, 67_108_864)
    XCTAssertEqual(process.resourceUsage?.elapsedTime, "01:02:03")
  }

  func testClassifiesExpectedDevProcesses() throws {
    let samples: [(String, DevRuntimeKind)] = [
      ("node ./node_modules/.bin/next dev --port 3014", .javascript),
      ("npm run dev", .javascript),
      ("pnpm vite --host 0.0.0.0", .javascript),
      ("python scripts/smoke.py --watch", .python),
      ("python3 -m uvicorn app.main:app --reload", .python),
      ("pytest tests/test_api.py -v", .python),
      ("swift build", .swift),
      ("cargo watch -x run", .rust),
      ("go run ./cmd/server", .go),
      ("flutter run -d macos", .flutter),
      ("dart run build_runner watch", .flutter),
      ("basic-memory mcp --transport stdio", .mcp)
    ]

    for (command, expectedKind) in samples {
      let process = DevProcess(pid: 10, parentPID: 1, executable: command.split(separator: " ").first.map(String.init) ?? command, command: command)

      let classification = try XCTUnwrap(ProcessClassifier.classify(process))

      XCTAssertEqual(classification.kind, expectedKind, command)
    }
  }

  func testClassifiesFlutterWorkspaceProcessesWithoutLeavingThemAsOther() throws {
    let home = NSHomeDirectory()
    let samples = [
      DevProcess(
        pid: 11,
        parentPID: 1,
        executable: "/Applications/Xcode.app/Contents/MacOS/Xcode",
        command: "/Applications/Xcode.app/Contents/MacOS/Xcode",
        currentDirectory: "\(home)/dev/flutter/usafe"
      ),
      DevProcess(
        pid: 12,
        parentPID: 1,
        executable: "dart",
        command: "dart \(home)/dev/flutter/usafe/.dart_tool/flutter_build/frontend_server.dart.snapshot",
        currentDirectory: "\(home)/dev/flutter/usafe"
      )
    ]

    for process in samples {
      let classification = try XCTUnwrap(ProcessClassifier.classify(process), process.command)
      XCTAssertEqual(classification.kind, .flutter)
      XCTAssertEqual(classification.projectHint, "usafe")
    }
  }

  func testClassifiesSandboxNativeScannerAppPaths() throws {
    let samples: [(DevProcess, DevRuntimeKind)] = [
      (
        DevProcess(
          pid: 13,
          parentPID: 1,
          executable: "Cursor",
          command: "/Applications/Cursor.app/Contents/MacOS/Cursor"
        ),
        .javascript
      ),
      (
        DevProcess(
          pid: 14,
          parentPID: 1,
          executable: "Xcode",
          command: "/Applications/Xcode.app/Contents/MacOS/Xcode"
        ),
        .swift
      ),
      (
        DevProcess(
          pid: 15,
          parentPID: 1,
          executable: "Ollama",
          command: "/Applications/Ollama.app/Contents/MacOS/Ollama"
        ),
        .ai
      )
    ]

    for (process, expectedKind) in samples {
      let classification = try XCTUnwrap(ProcessClassifier.classify(process), process.command)
      XCTAssertEqual(classification.kind, expectedKind)
    }
  }

  func testClassifiesWholeMachineActivityInsteadOfDroppingNonDevRows() throws {
    let samples: [(DevProcess, DevRuntimeKind, String)] = [
      (
        DevProcess(
          pid: 20,
          parentPID: 1,
          executable: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
          command: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"
        ),
        .macApp,
        "Finder"
      ),
      (
        DevProcess(
          pid: 21,
          parentPID: 1,
          executable: "/Applications/Go",
          command: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper --type=renderer",
          currentDirectory: "/"
        ),
        .browser,
        "Google Chrome Helper"
      ),
      (
        DevProcess(
          pid: 22,
          parentPID: 1,
          executable: "/System/Library/PrivateFrameworks/CloudKitDaemon.framework/Support/cloudd",
          command: "/System/Library/PrivateFrameworks/CloudKitDaemon.framework/Support/cloudd"
        ),
        .backgroundAgent,
        "cloudd"
      ),
      (
        DevProcess(
          pid: 23,
          parentPID: 1,
          executable: "/usr/libexec/logd",
          command: "/usr/libexec/logd"
        ),
        .systemService,
        "logd"
      ),
      (
        DevProcess(
          pid: 24,
          parentPID: 1,
          executable: "/opt/custom/bin/worker",
          command: "/opt/custom/bin/worker --foreground"
        ),
        .other,
        "worker"
      )
    ]

    for (process, expectedKind, expectedDisplayName) in samples {
      let classification = try XCTUnwrap(ProcessClassifier.classify(process), process.command)
      XCTAssertEqual(classification.kind, expectedKind)
      XCTAssertEqual(classification.displayName, expectedDisplayName)
    }
  }

  func testDerivesSystemProcessNameFromCommandWhenExecutableIsGenericPathFragment() throws {
    let samples: [(DevProcess, DevRuntimeKind, String)] = [
      (
        DevProcess(
          pid: 25,
          parentPID: 1,
          executable: "Library",
          command: "/System/Library/PrivateFrameworks/EmailDaemon.framework/Versions/A/maild"
        ),
        .backgroundAgent,
        "maild"
      ),
      (
        DevProcess(
          pid: 26,
          parentPID: 1,
          executable: "Contents",
          command: "/System/Library/CoreServices/Spotlight.app/Contents/MacOS/Spotlight"
        ),
        .macApp,
        "Spotlight"
      ),
      (
        DevProcess(
          pid: 27,
          parentPID: 1,
          executable: "Versions",
          command: "/System/Library/PrivateFrameworks/CloudKitDaemon.framework/Versions/A/Support/cloudd"
        ),
        .backgroundAgent,
        "cloudd"
      )
    ]

    for (process, expectedKind, expectedDisplayName) in samples {
      let classification = try XCTUnwrap(ProcessClassifier.classify(process), process.command)
      XCTAssertEqual(classification.kind, expectedKind)
      XCTAssertEqual(classification.displayName, expectedDisplayName)
      XCTAssertNotEqual(classification.displayName.lowercased(), process.executable.lowercased())
    }
  }

  func testDerivesSystemProcessNameFromCommandWhenExecutableIsShortPrefix() throws {
    let samples: [(DevProcess, String)] = [
      (
        DevProcess(
          pid: 28,
          parentPID: 1,
          executable: "/usr/libexec/Use",
          command: "/usr/libexec/UserEventAgent (System)"
        ),
        "UserEventAgent"
      ),
      (
        DevProcess(
          pid: 29,
          parentPID: 1,
          executable: "/usr/libexec/con",
          command: "/usr/libexec/configd"
        ),
        "configd"
      ),
      (
        DevProcess(
          pid: 30,
          parentPID: 1,
          executable: "/usr/libexec/IOM",
          command: "/usr/libexec/IOMFB_bics_daemon"
        ),
        "IOMFB_bics_daemon"
      ),
      (
        DevProcess(
          pid: 31,
          parentPID: 1,
          executable: "/usr/libexec/log",
          command: "/usr/libexec/logd"
        ),
        "logd"
      )
    ]

    for (process, expectedDisplayName) in samples {
      let classification = try XCTUnwrap(ProcessClassifier.classify(process), process.command)
      XCTAssertEqual(classification.kind, .systemService)
      XCTAssertEqual(classification.displayName, expectedDisplayName)
    }
  }

  func testClassifiedSnapshotIncludesAllScannedRows() {
    let processes = [
      DevProcess(pid: 31, parentPID: 1, executable: "node", command: "node ./node_modules/.bin/vite"),
      DevProcess(pid: 32, parentPID: 1, executable: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", command: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"),
      DevProcess(pid: 33, parentPID: 1, executable: "/usr/libexec/logd", command: "/usr/libexec/logd"),
      DevProcess(pid: 34, parentPID: 1, executable: "/opt/custom/bin/worker", command: "/opt/custom/bin/worker --foreground")
    ]

    let classified = ProcessClassifier.classified(processes)

    XCTAssertEqual(classified.map(\.process.pid), [31, 32, 33, 34])
    XCTAssertEqual(classified.map(\.classification.kind), [.javascript, .macApp, .systemService, .other])
  }

  func testClassifiesSystemProcessesWhoseTruncatedExecutableLooksLikeADevToolByCommandPath() throws {
    let samples = [
      (
        DevProcess(
          pid: 25,
          parentPID: 1,
          executable: "/usr/libexec/Air",
          command: "/usr/libexec/AirPlayXPCHelper",
          currentDirectory: "/"
        ),
        DevRuntimeKind.systemService
      ),
      (
        DevProcess(
          pid: 26,
          parentPID: 1,
          executable: "/Applications/Go",
          command: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
          currentDirectory: "/"
        ),
        DevRuntimeKind.browser
      )
    ]

    for (process, expectedKind) in samples {
      let classification = try XCTUnwrap(ProcessClassifier.classify(process), process.command)
      XCTAssertEqual(classification.kind, expectedKind)
    }
  }

  func testDerivesReadableDisplayNameAndProjectHint() throws {
    let process = DevProcess(pid: 30, parentPID: 1, executable: "node", command: "node \(NSHomeDirectory())/dev/mission-control/node_modules/.bin/next dev --port 3010")

    let classification = try XCTUnwrap(ProcessClassifier.classify(process))

    XCTAssertEqual(classification.displayName, "next dev")
    XCTAssertEqual(classification.projectHint, "mission-control")
  }

  func testDerivesCodexPluginProjectHintFromCachePath() throws {
    let process = DevProcess(
      pid: 30,
      parentPID: 1,
      executable: "\(NSHomeDirectory())/.codex/plugins/cache/openai-bundled/computer-use/1.0.829/Codex",
      command: "\(NSHomeDirectory())/.codex/plugins/cache/openai-bundled/computer-use/1.0.829/Codex",
      currentDirectory: "\(NSHomeDirectory())/.codex/plugins/cache/openai-bundled/computer-use/1.0.829"
    )

    let classification = try XCTUnwrap(ProcessClassifier.classify(process))

    XCTAssertEqual(classification.projectHint, "computer-use")
  }

  func testDerivesReadablePythonAndNodeProcessNamesFromCommands() throws {
    let samples: [(DevProcess, String)] = [
      (
        DevProcess(
          pid: 31,
          parentPID: 1,
          executable: "\(NSHomeDirectory())/dev/job_hunt/.venv/bin/python3.11",
          command: "\(NSHomeDirectory())/dev/job_hunt/.venv/bin/python3.11 \(NSHomeDirectory())/dev/job_hunt/.venv/bin/uvicorn forge_app.app:app --host 127.0.0.1",
          currentDirectory: "\(NSHomeDirectory())/dev/job_hunt"
        ),
        "uvicorn forge_app"
      ),
      (
        DevProcess(
          pid: 32,
          parentPID: 1,
          executable: "\(NSHomeDirectory())/.hermes/hermes-agent/venv/bin/python",
          command: "\(NSHomeDirectory())/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main gateway run --replace",
          currentDirectory: "\(NSHomeDirectory())/.hermes/hermes-agent"
        ),
        "python module hermes_cli.main"
      ),
      (
        DevProcess(
          pid: 33,
          parentPID: 1,
          executable: "node",
          command: "node ./mcp/server.bundle.mjs",
          currentDirectory: "\(NSHomeDirectory())/.codex/plugins/cache/openai-curated"
        ),
        "MCP server"
      ),
      (
        DevProcess(
          pid: 34,
          parentPID: 1,
          executable: "node",
          command: "node \(NSHomeDirectory())/.npm/_npx/99336612077b7094/node_modules/.bin/xcodebuildmcp mcp",
          currentDirectory: "\(NSHomeDirectory())/.codex"
        ),
        "xcodebuildmcp"
      ),
      (
        DevProcess(
          pid: 35,
          parentPID: 1,
          executable: "/opt/homebrew/Cellar/python@3.14/3.14.6/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python",
          command: "/opt/homebrew/Cellar/python@3.14/3.14.6/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python \(NSHomeDirectory())/.cursor/extensions/ms-python.python-2025.6.1/python_files/run-jedi-language-server.py",
          currentDirectory: "\(NSHomeDirectory())/dev/example/sample-service"
        ),
        "python run-jedi-language-server"
      ),
      (
        DevProcess(
          pid: 36,
          parentPID: 1,
          executable: "/opt/homebrew/Cellar/python@3.14/3.14.6/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python",
          command: "/opt/homebrew/Cellar/python@3.14/3.14.6/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python -c from multiprocessing.resource_tracker import main",
          currentDirectory: "\(NSHomeDirectory())/dev/example/sample-service"
        ),
        "python command"
      )
    ]

    for (process, expectedDisplayName) in samples {
      let classification = try XCTUnwrap(ProcessClassifier.classify(process), process.command)
      XCTAssertEqual(classification.displayName, expectedDisplayName)
    }
  }

  func testDerivesReadableMCPAndToolLauncherNamesFromCommands() throws {
    let samples: [(DevProcess, String)] = [
      (
        DevProcess(
          pid: 38,
          parentPID: 1,
          executable: "npm",
          command: "npm exec xcodebuildmcp@latest mcp",
          currentDirectory: "\(NSHomeDirectory())/.codex"
        ),
        "xcodebuildmcp"
      ),
      (
        DevProcess(
          pid: 39,
          parentPID: 1,
          executable: "npm",
          command: "npm exec shadcn@latest mcp",
          currentDirectory: "\(NSHomeDirectory())/.codex"
        ),
        "shadcn MCP"
      ),
      (
        DevProcess(
          pid: 42,
          parentPID: 1,
          executable: "node",
          command: "node \(NSHomeDirectory())/.npm/_npx/99336612077b7094/node_modules/.bin/xcodebuildmcp mcp",
          currentDirectory: "\(NSHomeDirectory())/.codex"
        ),
        "xcodebuildmcp"
      ),
      (
        DevProcess(
          pid: 43,
          parentPID: 1,
          executable: "node",
          command: "node ./mcp/server.cjs --stdio",
          currentDirectory: "\(NSHomeDirectory())/dev/example/devscope"
        ),
        "MCP server"
      ),
      (
        DevProcess(
          pid: 44,
          parentPID: 1,
          executable: "basic-memory",
          command: "basic-memory mcp --transport stdio",
          currentDirectory: "\(NSHomeDirectory())/.codex"
        ),
        "basic-memory MCP"
      )
    ]

    for (process, expectedDisplayName) in samples {
      let classification = try XCTUnwrap(ProcessClassifier.classify(process), process.command)
      XCTAssertEqual(classification.displayName, expectedDisplayName)
    }
  }

  func testDerivesReadableNamesForTruncatedMacAppExecutablesInDevWorkspaces() throws {
    let samples: [(DevProcess, DevRuntimeKind, String)] = [
      (
        DevProcess(
          pid: 45,
          parentPID: 1,
          executable: "/Applications/Cu",
          command: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper.app/Contents/MacOS/Cursor Helper --type=renderer --clientProcessId=69096",
          currentDirectory: "\(NSHomeDirectory())/dev/example/sample-service"
        ),
        .other,
        "Cursor"
      ),
      (
        DevProcess(
          pid: 47,
          parentPID: 1,
          executable: "./Codex",
          command: "Computer ./Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient mcp",
          currentDirectory: "\(NSHomeDirectory())/.codex/plugins/cache/openai-bundled/computer-use/1.0.829"
        ),
        .mcp,
        "Computer Use MCP"
      )
    ]

    for (process, expectedKind, displayName) in samples {
      let classification = try XCTUnwrap(ProcessClassifier.classify(process))

      XCTAssertEqual(classification.kind, expectedKind)
      XCTAssertEqual(classification.displayName, displayName)
    }
  }

  func testDerivesReadableNamesForShellWrappedPythonCommands() throws {
    let process = DevProcess(
      pid: 46,
      parentPID: 1,
      executable: "/bin/zsh",
      command: "/bin/zsh -c snap=$(command cat <&3); builtin unalias -m '*' 2>/dev/null || true; cd \(NSHomeDirectory())/dev/example/sample-service/research-lab && PYTHONPATH=. conda run -n research-lab python3 -c \"print('pages')\"",
      currentDirectory: "\(NSHomeDirectory())/dev/example/sample-service/research-lab"
    )

    let classification = try XCTUnwrap(ProcessClassifier.classify(process))

    XCTAssertEqual(classification.kind, .shell)
    XCTAssertEqual(classification.displayName, "python command")
  }

  func testDerivesReadableAIProcessNamesWithoutModelGuessing() throws {
    let samples: [(DevProcess, String)] = [
      (
        DevProcess(
          pid: 35,
          parentPID: 1,
          executable: "/Applications/Ol",
          command: "ollama serve"
        ),
        "Ollama server"
      ),
      (
        DevProcess(
          pid: 36,
          parentPID: 1,
          executable: "/Applications/Ol",
          command: "/Applications/Ollama.app/Contents/Resources/ollama serve"
        ),
        "Ollama server"
      ),
      (
        DevProcess(
          pid: 37,
          parentPID: 1,
          executable: "lmstudio",
          command: "lmstudio --server"
        ),
        "LM Studio"
      )
    ]

    for (process, expectedDisplayName) in samples {
      let classification = try XCTUnwrap(ProcessClassifier.classify(process), process.command)
      XCTAssertEqual(classification.kind, .ai)
      XCTAssertEqual(classification.displayName, expectedDisplayName)
    }
  }

  func testTagsMachineLearningAndLLMDeveloperProcesses() throws {
    let samples: [(DevProcess, [DevProcessTag])] = [
      (
        DevProcess(pid: 50, parentPID: 1, executable: "python", command: "python -m ipykernel_launcher -f kernel.json"),
        [.notebook]
      ),
      (
        DevProcess(pid: 51, parentPID: 1, executable: "torchrun", command: "torchrun train_llama.py --model llama"),
        [.training, .inference, .llm]
      ),
      (
        DevProcess(pid: 52, parentPID: 1, executable: "uvicorn", command: "uvicorn fastapi_app:app --reload"),
        [.api]
      ),
      (
        DevProcess(pid: 53, parentPID: 1, executable: "python", command: "python -m qdrant_client.local"),
        [.vectorDB]
      ),
      (
        DevProcess(pid: 54, parentPID: 1, executable: "streamlit", command: "streamlit run dashboard.py"),
        [.dataApp]
      )
    ]

    for (process, expectedTags) in samples {
      let classification = try XCTUnwrap(ProcessClassifier.classify(process), process.command)
      for expectedTag in expectedTags {
        XCTAssertTrue(classification.tags.contains(expectedTag), "\(process.command) missing \(expectedTag.title)")
      }
    }
  }

  func testIncludesShellsWhoseCurrentDirectoryIsADevProject() throws {
    let samples: [(DevProcess, String)] = [
      (
        DevProcess(
          pid: 40,
          parentPID: 1,
          executable: "/bin/zsh",
          command: "-zsh",
          currentDirectory: "\(NSHomeDirectory())/dev/devscope"
        ),
        "devscope"
      ),
      (
        DevProcess(
          pid: 41,
          parentPID: 1,
          executable: "/bin/zsh",
          command: "-zsh",
          currentDirectory: "\(NSHomeDirectory())/.codex"
        ),
        "Codex"
      )
    ]

    for (process, projectHint) in samples {
      let classification = try XCTUnwrap(ProcessClassifier.classify(process))

      XCTAssertEqual(classification.kind, .shell)
      XCTAssertEqual(classification.displayName, "zsh")
      XCTAssertEqual(classification.projectHint, projectHint)
    }
  }

  func testDoesNotTreatCodexSiblingFoldersAsCodexWorkspaces() throws {
    let process = DevProcess(
      pid: 42,
      parentPID: 1,
      executable: "/bin/zsh",
      command: "-zsh",
      currentDirectory: "\(NSHomeDirectory())/.codex-backup"
    )

    let classification = try XCTUnwrap(ProcessClassifier.classify(process))

    XCTAssertEqual(classification.kind, .other)
    XCTAssertEqual(classification.displayName, "zsh")
    XCTAssertNil(classification.projectHint)
  }

  func testClassifiesShellsOutsideDevWorkspacesAsGenericActivity() throws {
    let process = DevProcess(
      pid: 41,
      parentPID: 1,
      executable: "/bin/zsh",
      command: "-zsh",
      currentDirectory: "\(NSHomeDirectory())/Downloads"
    )

    let classification = try XCTUnwrap(ProcessClassifier.classify(process))

    XCTAssertEqual(classification.kind, .other)
    XCTAssertEqual(classification.displayName, "zsh")
    XCTAssertNil(classification.projectHint)
  }
}
