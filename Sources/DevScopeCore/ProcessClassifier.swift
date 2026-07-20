import Foundation

public enum ProcessClassifier {
  public static func classify(
    _ process: DevProcess,
    workspaceFacts: WorkspaceFacts? = nil
  ) -> DevProcessClassification? {
    let command = process.command.trimmingCharacters(in: .whitespacesAndNewlines)
    let tokens = tokenize(command)
    let lowerTokens = tokens.map { $0.lowercased() }
    let executableName = process.executableName.lowercased()
    let haystack = ([executableName] + lowerTokens).joined(separator: " ")

    if isJavaScriptProcess(executableName: executableName, tokens: lowerTokens, haystack: haystack) {
      let kind = DevRuntimeKind.javascript
      return DevProcessClassification(
        kind: kind,
        displayName: displayName(for: tokens, lowerTokens: lowerTokens, fallback: process.executableName),
        projectHint: projectHint(from: command),
        tags: tags(for: kind, executableName: executableName, tokens: lowerTokens, haystack: haystack)
      )
    }

    if isPythonProcess(executableName: executableName, tokens: lowerTokens, haystack: haystack) {
      let kind = DevRuntimeKind.python
      return DevProcessClassification(
        kind: kind,
        displayName: displayName(for: tokens, lowerTokens: lowerTokens, fallback: process.executableName),
        projectHint: projectHint(from: command),
        tags: tags(for: kind, executableName: executableName, tokens: lowerTokens, haystack: haystack)
      )
    }

    if isNativeBuildProcess(
      executableName: executableName,
      tokens: lowerTokens,
      haystack: haystack,
      currentDirectory: process.currentDirectory,
      workspaceFacts: workspaceFacts
    ) {
      let kind = nativeBuildKind(executableName: executableName, tokens: lowerTokens)
      return DevProcessClassification(
        kind: kind,
        displayName: displayName(for: tokens, lowerTokens: lowerTokens, fallback: process.executableName),
        projectHint: projectHint(from: process.currentDirectory ?? command),
        tags: tags(for: kind, executableName: executableName, tokens: lowerTokens, haystack: haystack)
      )
    }

    if isFlutterProcess(
      executableName: executableName,
      tokens: lowerTokens,
      haystack: haystack,
      currentDirectory: process.currentDirectory,
      workspaceFacts: workspaceFacts
    ) {
      let kind = DevRuntimeKind.flutter
      return DevProcessClassification(
        kind: kind,
        displayName: flutterDisplayName(tokens: tokens, lowerTokens: lowerTokens, fallback: process.executableName),
        projectHint: projectHint(from: process.currentDirectory ?? command),
        tags: tags(for: kind, executableName: executableName, tokens: lowerTokens, haystack: haystack)
      )
    }

    if isDatabaseProcess(executableName: executableName, tokens: lowerTokens, haystack: haystack) {
      let kind = DevRuntimeKind.database
      return DevProcessClassification(
        kind: kind,
        displayName: displayName(for: tokens, lowerTokens: lowerTokens, fallback: process.executableName),
        projectHint: projectHint(from: process.currentDirectory ?? command),
        tags: tags(for: kind, executableName: executableName, tokens: lowerTokens, haystack: haystack)
      )
    }

    if isContainerProcess(executableName: executableName, tokens: lowerTokens, haystack: haystack) {
      let kind = DevRuntimeKind.container
      return DevProcessClassification(
        kind: kind,
        displayName: displayName(for: tokens, lowerTokens: lowerTokens, fallback: process.executableName),
        projectHint: projectHint(from: process.currentDirectory ?? command),
        tags: tags(for: kind, executableName: executableName, tokens: lowerTokens, haystack: haystack)
      )
    }

    if isWebServerProcess(executableName: executableName, tokens: lowerTokens, haystack: haystack) {
      let kind = DevRuntimeKind.webServer
      return DevProcessClassification(
        kind: kind,
        displayName: displayName(for: tokens, lowerTokens: lowerTokens, fallback: process.executableName),
        projectHint: projectHint(from: process.currentDirectory ?? command),
        tags: tags(for: kind, executableName: executableName, tokens: lowerTokens, haystack: haystack)
      )
    }

    if isAIProcess(executableName: executableName, tokens: lowerTokens, haystack: haystack) {
      let kind = DevRuntimeKind.ai
      return DevProcessClassification(
        kind: kind,
        displayName: aiDisplayName(executableName: executableName, tokens: lowerTokens, haystack: haystack, fallback: process.executableName),
        projectHint: projectHint(from: process.currentDirectory ?? command),
        tags: tags(for: kind, executableName: executableName, tokens: lowerTokens, haystack: haystack)
      )
    }

    if isMCPProcess(tokens: lowerTokens, haystack: haystack) {
      let kind = DevRuntimeKind.mcp
      return DevProcessClassification(
        kind: kind,
        displayName: displayName(for: tokens, lowerTokens: lowerTokens, fallback: process.executableName),
        projectHint: projectHint(from: process.currentDirectory ?? command),
        tags: tags(for: kind, executableName: executableName, tokens: lowerTokens, haystack: haystack)
      )
    }

    if isDevShellProcess(executableName: executableName, currentDirectory: process.currentDirectory) {
      let kind = DevRuntimeKind.shell
      return DevProcessClassification(
        kind: kind,
        displayName: shellDisplayName(executableName, tokens: tokens, lowerTokens: lowerTokens),
        projectHint: projectHint(from: process.currentDirectory ?? command),
        tags: tags(for: kind, executableName: executableName, tokens: lowerTokens, haystack: haystack)
      )
    }

    if isDevWorkspace(process.currentDirectory) {
      let kind = DevRuntimeKind.other
      return DevProcessClassification(
        kind: kind,
        displayName: displayName(for: tokens, lowerTokens: lowerTokens, fallback: process.executableName),
        projectHint: projectHint(from: process.currentDirectory ?? command),
        tags: tags(for: kind, executableName: executableName, tokens: lowerTokens, haystack: haystack)
      )
    }

    return generalActivityClassification(
      process: process,
      executableName: executableName,
      tokens: tokens,
      lowerTokens: lowerTokens,
      haystack: haystack
    )
  }

  public static func classified(_ processes: [DevProcess]) -> [ClassifiedDevProcess] {
    processes.compactMap { process in
      guard let classification = classify(process) else {
        return nil
      }
      return ClassifiedDevProcess(process: process, classification: classification)
    }
  }

  private static func isJavaScriptProcess(executableName: String, tokens: [String], haystack: String) -> Bool {
    let executableMatches = ["node", "npm", "pnpm", "yarn", "bun", "deno", "tsx", "ts-node", "next", "vite", "electron"].contains(executableName)
    let commandMatches = tokens.contains("next") || tokens.contains("vite") || tokens.contains("tsx") || tokens.contains("ts-node") || haystack.contains("/.bin/next") || haystack.contains("/.bin/vite")
    let appMatches = haystack.contains("visual studio code.app/contents/macos/electron") ||
      haystack.contains("visual studio code.app/contents/macos/code") ||
      haystack.contains("cursor.app/contents/macos/cursor") ||
      haystack.contains("zed.app/contents/macos/zed")
    return executableMatches || commandMatches || appMatches
  }

  private static func isPythonProcess(executableName: String, tokens: [String], haystack: String) -> Bool {
    let executableMatches = [
      "python",
      "pytest",
      "uvicorn",
      "gunicorn",
      "jupyter",
      "ipykernel",
      "torchrun",
      "accelerate",
      "streamlit",
      "gradio",
      "mlflow",
      "tensorboard"
    ].contains(executableName) || executableName.hasPrefix("python3") || executableName.contains("python")
    let commandMatches = tokens.contains("pytest") ||
      tokens.contains("uvicorn") ||
      tokens.contains("gunicorn") ||
      tokens.contains("jupyter") ||
      tokens.contains("torchrun") ||
      tokens.contains("accelerate") ||
      tokens.contains("streamlit") ||
      tokens.contains("gradio") ||
      tokens.contains("mlflow") ||
      tokens.contains("tensorboard") ||
      haystack.contains("ipykernel_launcher") ||
      haystack.contains(".py")
    return executableMatches || commandMatches
  }

  private static func isNativeBuildProcess(
    executableName: String,
    tokens: [String],
    haystack: String,
    currentDirectory: String?,
    workspaceFacts: WorkspaceFacts?
  ) -> Bool {
    let trustedExecutableMatches = ["swift", "swift-frontend", "sourcekit-lsp", "xcodebuild", "cargo", "rustc", "rustup"].contains(executableName)
    let workspaceExecutableMatches = ["go", "air"].contains(executableName) && isDevWorkspace(currentDirectory)
    let trustedCommandMatches = tokenIndex(matching: "swift", in: tokens) != nil || tokenIndex(matching: "xcodebuild", in: tokens) != nil || tokenIndex(matching: "cargo", in: tokens) != nil || tokenIndex(matching: "rustc", in: tokens) != nil || haystack.contains("cargo watch")
    let appMatches = !isFlutterWorkspace(currentDirectory, workspaceFacts: workspaceFacts) &&
      (
        haystack.contains("xcode.app") ||
        haystack.contains("android studio.app")
      )
    let workspaceCommandMatches = (isDirectToolInvocation("go", in: tokens) || isDirectToolInvocation("air", in: tokens) || ((tokenIndex(matching: "go", in: tokens) != nil || tokenIndex(matching: "air", in: tokens) != nil) && isDevWorkspace(currentDirectory)))
    let executableMatches = trustedExecutableMatches || workspaceExecutableMatches
    let commandMatches = trustedCommandMatches || workspaceCommandMatches
    return executableMatches || commandMatches || appMatches
  }

  private static func nativeBuildKind(executableName: String, tokens: [String]) -> DevRuntimeKind {
    if executableName == "swift" || executableName == "swift-frontend" || executableName == "sourcekit-lsp" || executableName == "xcodebuild" || executableName == "xcode" || tokenIndex(matching: "swift", in: tokens) != nil || tokenIndex(matching: "xcodebuild", in: tokens) != nil {
      return .swift
    }
    if executableName == "cargo" || executableName == "rustc" || executableName == "rustup" || tokenIndex(matching: "cargo", in: tokens) != nil || tokenIndex(matching: "rustc", in: tokens) != nil {
      return .rust
    }
    if executableName == "go" || executableName == "air" || tokenIndex(matching: "go", in: tokens) != nil || tokenIndex(matching: "air", in: tokens) != nil {
      return .go
    }
    return .other
  }

  private static func isFlutterProcess(
    executableName: String,
    tokens: [String],
    haystack: String,
    currentDirectory: String?,
    workspaceFacts: WorkspaceFacts?
  ) -> Bool {
    let executableMatches = ["flutter", "dart", "dartvm"].contains(executableName)
    let commandMatches = tokenIndex(matching: "flutter", in: tokens) != nil ||
      tokenIndex(matching: "dart", in: tokens) != nil ||
      haystack.contains("flutter_tools.snapshot") ||
      haystack.contains("frontend_server.dart.snapshot") ||
      haystack.contains("dartdevc") ||
      haystack.contains(".dart_tool/") ||
      haystack.contains("flutter") ||
      haystack.contains("dart")
    let workspaceMatches = isFlutterWorkspace(currentDirectory, workspaceFacts: workspaceFacts)
    return executableMatches || commandMatches || workspaceMatches
  }

  private static func flutterDisplayName(tokens: [String], lowerTokens: [String], fallback: String) -> String {
    if let flutterIndex = tokenIndex(matching: "flutter", in: lowerTokens) {
      let command = lowerTokens.dropFirst(flutterIndex + 1).first { !$0.hasPrefix("-") }
      return command.map { "flutter \($0)" } ?? "flutter"
    }
    if let dartIndex = tokenIndex(matching: "dart", in: lowerTokens) {
      let command = lowerTokens.dropFirst(dartIndex + 1).first { !$0.hasPrefix("-") }
      return command.map { "dart \($0)" } ?? "dart"
    }
    if let appName = macOSAppDisplayName(in: tokens) {
      return appName
    }
    return fallback
  }

  private static func isDatabaseProcess(executableName: String, tokens: [String], haystack: String) -> Bool {
    ["postgres", "postmaster", "redis-server", "mongod", "mysql", "mysqld", "mariadbd", "clickhouse", "influxd"].contains(executableName) || tokens.contains("postgres") || tokens.contains("redis-server") || haystack.contains("/postgres") || haystack.contains("/redis")
  }

  private static func isContainerProcess(executableName: String, tokens: [String], haystack: String) -> Bool {
    ["docker", "dockerd", "containerd", "colima", "podman", "kubectl"].contains(executableName) || tokens.contains("docker") || tokens.contains("kubectl") || haystack.contains("/docker") || haystack.contains("docker.app") || haystack.contains("orbstack.app")
  }

  private static func isWebServerProcess(executableName: String, tokens: [String], haystack: String) -> Bool {
    ["nginx", "caddy", "httpd", "apache2"].contains(executableName) || tokens.contains("nginx") || tokens.contains("caddy") || haystack.contains("apache")
  }

  private static func isAIProcess(executableName: String, tokens: [String], haystack: String) -> Bool {
    ["ollama", "llama-server", "lmstudio"].contains(executableName) || tokens.contains("ollama") || haystack.contains("llama") || haystack.contains("lm studio.app") || haystack.contains("ollama.app")
  }

  private static func isMCPProcess(tokens: [String], haystack: String) -> Bool {
    (tokens.contains("mcp") || tokens.contains("--stdio") || tokens.contains("stdio") || haystack.contains("/mcp/")) &&
    (
      tokenIndex(matching: "basic-memory", in: tokens) != nil ||
      tokenIndex(matching: "gk", in: tokens) != nil ||
      tokenIndex(matching: "node", in: tokens) != nil ||
      tokenIndex(matching: "npm", in: tokens) != nil ||
      haystack.contains("skycomputeruseclient") ||
      haystack.contains("computer use.app") ||
      haystack.contains("/.codex/") ||
      haystack.contains("/mcp/")
    )
  }

  private static func generalActivityClassification(
    process: DevProcess,
    executableName: String,
    tokens: [String],
    lowerTokens: [String],
    haystack: String
  ) -> DevProcessClassification {
    let kind: DevRuntimeKind
    if isBrowserProcess(executableName: executableName, haystack: haystack) {
      kind = .browser
    } else if isMacOSAppProcess(tokens: tokens, haystack: haystack) {
      kind = .macApp
    } else if isBackgroundAgentProcess(executableName: executableName, haystack: haystack) {
      kind = .backgroundAgent
    } else if isSystemServiceProcess(haystack: haystack) {
      kind = .systemService
    } else {
      kind = .other
    }

    return DevProcessClassification(
      kind: kind,
      displayName: activityDisplayName(
        executableName: executableName,
        command: process.command,
        tokens: tokens,
        lowerTokens: lowerTokens,
        fallback: process.executableName
      ),
      projectHint: isDevWorkspace(process.currentDirectory) ? projectHint(from: process.currentDirectory ?? process.command) : nil,
      tags: tags(for: kind, executableName: executableName, tokens: lowerTokens, haystack: haystack)
    )
  }

  private static func isBrowserProcess(executableName: String, haystack: String) -> Bool {
    let browsers = [
      "safari",
      "google chrome",
      "google chrome helper",
      "firefox",
      "firefox helper",
      "arc",
      "arc helper",
      "brave browser",
      "brave browser helper",
      "microsoft edge",
      "microsoft edge helper"
    ]

    return browsers.contains(executableName) ||
      haystack.contains("safari.app") ||
      haystack.contains("google chrome.app") ||
      haystack.contains("google chrome helper.app") ||
      haystack.contains("firefox.app") ||
      haystack.contains("firefox helper.app") ||
      haystack.contains("arc.app") ||
      haystack.contains("arc helper.app") ||
      haystack.contains("brave browser.app") ||
      haystack.contains("brave browser helper.app") ||
      haystack.contains("microsoft edge.app") ||
      haystack.contains("microsoft edge helper.app")
  }

  private static func isMacOSAppProcess(tokens: [String], haystack: String) -> Bool {
    macOSAppDisplayName(in: tokens) != nil || haystack.contains(".app/contents/macos/")
  }

  private static func isBackgroundAgentProcess(executableName: String, haystack: String) -> Bool {
    executableName.contains("agent") ||
      executableName.contains("helper") ||
      haystack.contains("/launchagents/") ||
      haystack.contains("/launchdaemons/") ||
      haystack.contains("daemon.framework") ||
      haystack.contains("agent.app") ||
      haystack.contains("helper.app")
  }

  private static func isSystemServiceProcess(haystack: String) -> Bool {
    haystack.contains("/system/library/") ||
      haystack.contains("/usr/libexec/") ||
      haystack.contains("/usr/sbin/") ||
      haystack.contains("/sbin/")
  }

  private static func activityDisplayName(
    executableName: String,
    command: String,
    tokens: [String],
    lowerTokens: [String],
    fallback: String
  ) -> String {
    if isBrowserProcess(executableName: executableName, haystack: ([executableName] + lowerTokens).joined(separator: " ")),
       let appName = macOSAppDisplayName(inCommand: command, preferLast: true) ?? lastMacOSAppDisplayName(in: tokens) {
      return appName
    }
    if let appName = macOSAppDisplayName(inCommand: command) ?? macOSAppDisplayName(in: tokens) {
      return appName
    }

    let commandDisplayName = commandExecutableDisplayName(tokens: tokens)
    let fallbackDisplayName = URL(fileURLWithPath: fallback).lastPathComponent

    if let commandDisplayName,
       shouldPreferCommandDisplayName(commandDisplayName, over: fallbackDisplayName) {
      return commandDisplayName
    }

    if !fallbackDisplayName.isEmpty && !isGenericExecutableName(fallbackDisplayName) {
      return fallbackDisplayName
    }

    if let commandDisplayName {
      return commandDisplayName
    }

    let executableDisplayName = URL(fileURLWithPath: executableName).lastPathComponent
    if !executableDisplayName.isEmpty && !isGenericExecutableName(executableDisplayName) {
      return executableDisplayName
    }

    return fallbackDisplayName.isEmpty ? fallback : fallbackDisplayName
  }

  private static func commandExecutableDisplayName(tokens: [String]) -> String? {
    for token in tokens.prefix(4) {
      let candidate = URL(fileURLWithPath: token).lastPathComponent
      guard !candidate.isEmpty,
            !candidate.hasPrefix("-"),
            !isGenericExecutableName(candidate) else {
        continue
      }
      return candidate
    }

    return nil
  }

  private static func shouldPreferCommandDisplayName(_ commandDisplayName: String, over fallbackDisplayName: String) -> Bool {
    let fallback = fallbackDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !fallback.isEmpty else {
      return true
    }

    let command = commandDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowerFallback = fallback.lowercased()
    let lowerCommand = command.lowercased()

    if lowerFallback == lowerCommand {
      return false
    }

    if isGenericExecutableName(fallback) {
      return true
    }

    if fallback.count <= 3 && command.count > fallback.count {
      return true
    }

    return lowerCommand.hasPrefix(lowerFallback) && command.count > fallback.count
  }

  private static func isGenericExecutableName(_ name: String) -> Bool {
    let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return [
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
    ].contains(normalized)
  }

  private static func aiDisplayName(executableName: String, tokens: [String], haystack: String, fallback: String) -> String {
    if executableName == "ollama" || tokens.contains("ollama") || haystack.contains("ollama.app") || haystack.contains("/ollama") {
      if tokens.contains("serve") {
        return "Ollama server"
      }
      return "Ollama"
    }
    if executableName == "lmstudio" || tokens.contains("lmstudio") || haystack.contains("lm studio") {
      return "LM Studio"
    }
    if executableName == "llama-server" || tokens.contains("llama-server") {
      return "Llama server"
    }
    return fallback
  }

  private static func tags(
    for kind: DevRuntimeKind,
    executableName: String,
    tokens: [String],
    haystack: String
  ) -> [DevProcessTag] {
    var result: [DevProcessTag] = []

    func add(_ tag: DevProcessTag) {
      if !result.contains(tag) {
        result.append(tag)
      }
    }

    if tokens.contains("jupyter") || tokens.contains("ipykernel") || haystack.contains("ipykernel") || haystack.contains("notebook") {
      add(.notebook)
    }
    if tokens.contains("torchrun") || tokens.contains("accelerate") || haystack.contains("train") || haystack.contains("trainer") || haystack.contains("finetune") || haystack.contains("fine-tune") {
      add(.training)
    }
    if haystack.contains("llm") || haystack.contains("llama") || haystack.contains("mistral") || haystack.contains("qwen") || haystack.contains("gemma") || haystack.contains("transformers") || haystack.contains("vllm") || haystack.contains("ollama") || haystack.contains("mlx") {
      add(.llm)
    }
    if haystack.contains("vllm") || haystack.contains("llama") || haystack.contains("ollama") || haystack.contains("mlx") || haystack.contains("transformers") {
      add(.inference)
    }
    if haystack.contains("vllm") || haystack.contains("ollama") || haystack.contains("llama-server") || haystack.contains("llama.cpp") {
      add(.llmServer)
    }
    if haystack.contains("qdrant") || haystack.contains("chroma") || haystack.contains("milvus") || haystack.contains("weaviate") || haystack.contains("faiss") {
      add(.vectorDB)
    }
    if tokens.contains("uvicorn") || tokens.contains("gunicorn") || haystack.contains("fastapi") || haystack.contains("flask") {
      add(.api)
    }
    if tokens.contains("mcp") || haystack.contains("/mcp/") {
      add(.mcp)
    }
    if haystack.contains("mlflow") || haystack.contains("wandb") || haystack.contains("tensorboard") || haystack.contains("optuna") {
      add(.experiment)
    }
    if haystack.contains("streamlit") || haystack.contains("gradio") || haystack.contains("dash") {
      add(.dataApp)
    }
    if kind == .ai && result.isEmpty {
      add(.inference)
    }

    return result
  }

  private static func isDevShellProcess(executableName: String, currentDirectory: String?) -> Bool {
    let shellNames = ["zsh", "bash", "fish", "sh", "tmux"]
    guard shellNames.contains(executableName), let currentDirectory else {
      return false
    }

    return isDevWorkspace(currentDirectory)
  }

  private static func isDevWorkspace(_ currentDirectory: String?) -> Bool {
    guard let currentDirectory else {
      return false
    }

    let home = NSHomeDirectory()
    guard currentDirectory.hasPrefix(home) else {
      return false
    }

    let workspaceMarkers = [
      "\(home)/dev/",
      "\(home)/Developer/",
      "\(home)/code/",
      "\(home)/Code/",
      "\(home)/src/",
      "\(home)/workspace/",
      "\(home)/.codex/"
    ]
    return currentDirectory == "\(home)/.codex" || workspaceMarkers.contains { currentDirectory.hasPrefix($0) }
  }

  private static func isFlutterWorkspace(
    _ currentDirectory: String?,
    workspaceFacts: WorkspaceFacts?
  ) -> Bool {
    if let workspaceFacts {
      return workspaceFacts.isFlutterWorkspace
    }

    guard let currentDirectory else {
      return false
    }

    let components = URL(fileURLWithPath: currentDirectory).pathComponents.map { $0.lowercased() }
    if components.contains("flutter") || components.contains(".dart_tool") {
      return isDevWorkspace(currentDirectory)
    }

    return FileManager.default.fileExists(atPath: "\(currentDirectory)/pubspec.yaml") ||
      FileManager.default.fileExists(atPath: "\(currentDirectory)/.dart_tool/package_config.json")
  }

  private static func displayName(for tokens: [String], lowerTokens: [String], fallback: String) -> String {
    if let mcpName = mcpDisplayName(tokens: tokens, lowerTokens: lowerTokens) {
      return mcpName
    }
    if let nextIndex = tokenIndex(matching: "next", in: lowerTokens), lowerTokens.dropFirst(nextIndex + 1).contains("dev") {
      return "next dev"
    }
    if lowerTokens.contains("vite") {
      return "vite"
    }
    if let uvicornIndex = tokenIndex(matching: "uvicorn", in: lowerTokens) {
      return serverDisplayName(prefix: "uvicorn", tokens: tokens, after: uvicornIndex)
    }
    if let gunicornIndex = tokenIndex(matching: "gunicorn", in: lowerTokens) {
      return serverDisplayName(prefix: "gunicorn", tokens: tokens, after: gunicornIndex)
    }
    if lowerTokens.contains("pytest") {
      return "pytest"
    }
    if lowerTokens.contains("torchrun") {
      return toolScriptDisplayName(prefix: "torchrun", tokens: tokens, lowerTokens: lowerTokens)
    }
    if lowerTokens.contains("accelerate") {
      return toolScriptDisplayName(prefix: "accelerate", tokens: tokens, lowerTokens: lowerTokens)
    }
    if lowerTokens.contains("streamlit") {
      return toolScriptDisplayName(prefix: "streamlit", tokens: tokens, lowerTokens: lowerTokens)
    }
    if lowerTokens.contains("gradio") {
      return toolScriptDisplayName(prefix: "gradio", tokens: tokens, lowerTokens: lowerTokens)
    }
    if lowerTokens.contains("jupyter") {
      return "jupyter"
    }
    if lowerTokens.contains("mlflow") {
      return "mlflow"
    }
    if lowerTokens.contains("tensorboard") {
      return "tensorboard"
    }
    if lowerTokens.first == "npm", lowerTokens.dropFirst().prefix(2) == ["run", "dev"] {
      return "npm run dev"
    }
    if lowerTokens.first == "pnpm", lowerTokens.contains("dev") {
      return "pnpm dev"
    }
    if lowerTokens.first == "yarn", lowerTokens.contains("dev") {
      return "yarn dev"
    }
    if let moduleName = pythonModuleName(in: tokens, lowerTokens: lowerTokens) {
      return "python module \(moduleName)"
    }
    if isPythonCommand(tokens: lowerTokens) {
      return "python command"
    }
    if let scriptName = pythonScriptName(in: tokens) {
      return "python \(scriptName)"
    }
    if let nodeName = nodeScriptName(in: tokens, lowerTokens: lowerTokens) {
      return "node \(nodeName)"
    }
    if let appName = macOSAppDisplayName(in: tokens) {
      return appName
    }
    if lowerTokens.first == "swift" {
      return lowerTokens.dropFirst().first.map { "swift \($0)" } ?? "swift"
    }
    if lowerTokens.first == "cargo" {
      return lowerTokens.dropFirst().first.map { "cargo \($0)" } ?? "cargo"
    }
    if lowerTokens.first == "go" {
      return lowerTokens.dropFirst().first.map { "go \($0)" } ?? "go"
    }
    return fallback
  }

  private static func serverDisplayName(prefix: String, tokens: [String], after index: Int) -> String {
    let appToken = tokens.dropFirst(index + 1).first { token in
      !token.hasPrefix("-") && !token.contains("/")
    }

    guard let appToken else {
      return prefix
    }

    let appName = appToken
      .split(separator: ":")
      .first
      .map(String.init)?
      .split(separator: ".")
      .first
      .map(String.init)

    return appName.map { "\(prefix) \($0)" } ?? prefix
  }

  private static func toolScriptDisplayName(prefix: String, tokens: [String], lowerTokens: [String]) -> String {
    guard let toolIndex = tokenIndex(matching: prefix, in: lowerTokens) else {
      return prefix
    }

    let scriptToken = tokens.dropFirst(toolIndex + 1).first { token in
      !token.hasPrefix("-") &&
      token != "run" &&
      (token.hasSuffix(".py") || token.hasSuffix(".ipynb") || token.contains("/"))
    }

    guard let scriptToken else {
      return prefix
    }

    let scriptName = URL(fileURLWithPath: scriptToken).deletingPathExtension().lastPathComponent
    return scriptName.isEmpty ? prefix : "\(prefix) \(scriptName)"
  }

  private static func pythonScriptName(in tokens: [String]) -> String? {
    tokens.dropFirst().first { token in
      token.hasSuffix(".py")
    }
    .map { token in
      URL(fileURLWithPath: token).deletingPathExtension().lastPathComponent
    }
  }

  private static func nodeScriptName(in tokens: [String], lowerTokens: [String]) -> String? {
    guard let first = lowerTokens.first,
          first == "node" || first.hasSuffix("/node") else {
      return nil
    }

    return tokens.dropFirst().first { token in
      !token.hasPrefix("-")
    }
    .map { token in
      URL(fileURLWithPath: token).deletingPathExtension().lastPathComponent
    }
  }

  private static func mcpDisplayName(tokens: [String], lowerTokens: [String]) -> String? {
    let hasMCPSignal = lowerTokens.contains("mcp") ||
      lowerTokens.contains("--stdio") ||
      lowerTokens.contains("stdio") ||
      lowerTokens.contains { $0.contains("/mcp/") }
    guard hasMCPSignal else {
      return nil
    }

    if lowerTokens.first == "npm",
       let execIndex = lowerTokens.firstIndex(of: "exec"),
       execIndex + 1 < tokens.count {
      let packageName = packageName(from: tokens[execIndex + 1])
      return mcpToolName(packageName)
    }

    if let basicMemoryIndex = tokenIndex(matching: "basic-memory", in: lowerTokens),
       lowerTokens.dropFirst(basicMemoryIndex + 1).contains("mcp") {
      return "basic-memory MCP"
    }

    if let toolToken = tokens.dropFirst().first(where: { token in
      let name = URL(fileURLWithPath: token).lastPathComponent.lowercased()
      return name == "xcodebuildmcp" || name == "shadcn" || name == "basic-memory" || name == "gk" || name == "skycomputeruseclient"
    }) {
      return mcpToolName(URL(fileURLWithPath: toolToken).lastPathComponent)
    }

    if lowerTokens.contains(where: { token in
      token.contains("/mcp/server") || token == "server.cjs" || token == "server.mjs" || token == "server.bundle.mjs"
    }) {
      return "MCP server"
    }

    return nil
  }

  private static func packageName(from token: String) -> String {
    let rawName = URL(fileURLWithPath: token).lastPathComponent
    if rawName.hasPrefix("@") {
      let components = rawName.split(separator: "@", omittingEmptySubsequences: false)
      guard components.count > 2 else {
        return rawName
      }
      return components.dropLast().joined(separator: "@")
    }

    return rawName.split(separator: "@").first.map(String.init) ?? rawName
  }

  private static func mcpToolName(_ packageName: String) -> String {
    switch packageName.lowercased() {
    case "xcodebuildmcp":
      return "xcodebuildmcp"
    case "shadcn":
      return "shadcn MCP"
    case "basic-memory":
      return "basic-memory MCP"
    case "gk":
      return "GitKraken MCP"
    case "skycomputeruseclient":
      return "Computer Use MCP"
    default:
      return packageName.lowercased().contains("mcp") ? packageName : "\(packageName) MCP"
    }
  }

  private static func pythonModuleName(in tokens: [String], lowerTokens: [String]) -> String? {
    guard let moduleIndex = lowerTokens.firstIndex(of: "-m"),
          moduleIndex + 1 < tokens.count else {
      return nil
    }

    let moduleName = tokens[moduleIndex + 1]
    guard moduleName.range(of: #"^[A-Za-z_][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil else {
      return nil
    }

    return moduleName
  }

  private static func isPythonCommand(tokens: [String]) -> Bool {
    guard tokens.contains("-c") else {
      return false
    }

    return tokens.contains("python") ||
      tokens.contains("python3") ||
      tokens.contains(where: { token in
        token.hasSuffix("/python") ||
        token.hasSuffix("/python3") ||
        token.contains("/python3.") ||
        token.hasPrefix("python3.")
      })
  }

  private static func macOSAppDisplayName(in tokens: [String]) -> String? {
    for token in tokens where token.contains(".app/") || token.hasSuffix(".app") {
      let components = URL(fileURLWithPath: token).pathComponents
      if let appComponent = components.first(where: { $0.hasSuffix(".app") }) {
        let appName = String(appComponent.dropLast(4))
        if !appName.isEmpty {
          return appName
        }
      }
    }

    return nil
  }

  private static func macOSAppDisplayName(inCommand command: String, preferLast: Bool = false) -> String? {
    let appNames = command.split(separator: "/").compactMap { component -> String? in
      guard component.hasSuffix(".app") else {
        return nil
      }

      let appName = component.dropLast(4)
      return appName.isEmpty ? nil : String(appName)
    }

    return preferLast ? appNames.last : appNames.first
  }

  private static func lastMacOSAppDisplayName(in tokens: [String]) -> String? {
    for token in tokens.reversed() where token.contains(".app/") || token.hasSuffix(".app") {
      let components = URL(fileURLWithPath: token).pathComponents
      if let appComponent = components.last(where: { $0.hasSuffix(".app") }) {
        let appName = String(appComponent.dropLast(4))
        if !appName.isEmpty {
          return appName
        }
      }
    }

    return nil
  }

  private static func shellDisplayName(
    _ executableName: String,
    tokens: [String],
    lowerTokens: [String]
  ) -> String {
    if lowerTokens.contains("python") || lowerTokens.contains("python3") || lowerTokens.contains(where: { $0.hasPrefix("python3.") }) {
      if isPythonCommand(tokens: lowerTokens) {
        return "python command"
      }
      if let scriptName = pythonScriptName(in: tokens) {
        return "python \(scriptName)"
      }
      return "python"
    }

    let baseName = executableName.hasPrefix("-") ? String(executableName.dropFirst()) : executableName
    return URL(fileURLWithPath: baseName).lastPathComponent
  }

  private static func tokenIndex(matching needle: String, in tokens: [String]) -> Int? {
    tokens.firstIndex { token in
      token == needle || token.hasSuffix("/\(needle)") || token.hasSuffix("/.bin/\(needle)")
    }
  }

  private static func isDirectToolInvocation(_ needle: String, in tokens: [String]) -> Bool {
    guard let first = tokens.first else {
      return false
    }

    return first == needle || first.hasSuffix("/\(needle)") || first.hasSuffix("/.bin/\(needle)")
  }

  private static func projectHint(from command: String) -> String? {
    let home = NSHomeDirectory()
    guard let homeRange = command.range(of: home) else {
      return nil
    }

    let path = String(command[homeRange.lowerBound...])
    let components = URL(fileURLWithPath: path).pathComponents
    if let codexPluginName = codexPluginName(from: components) {
      return codexPluginName
    }
    let markers = ["dev", "Developer", "code", "Code", "src", "workspace"]

    for marker in markers {
      guard let index = components.firstIndex(of: marker),
            index + 1 < components.count else {
        continue
      }
      let remaining = components[(index + 1)...].filter { !$0.isEmpty && $0 != "/" }
      guard let first = remaining.first else {
        continue
      }
      if remaining.count >= 2, ["work", "personal", "github", "projects", "flutter"].contains(first.lowercased()) {
        return remaining.dropFirst().first
      }
      return first
    }

    return components.last { !$0.isEmpty && $0 != "/" && !$0.hasPrefix(".") }
  }

  private static func codexPluginName(from components: [String]) -> String? {
    guard let codexIndex = components.firstIndex(of: ".codex") else {
      return nil
    }

    if let cacheIndex = components[codexIndex...].firstIndex(of: "cache") {
      let pluginComponents = components.dropFirst(cacheIndex + 1).filter { !$0.isEmpty && $0 != "/" }
      if pluginComponents.count >= 2,
         pluginComponents[0].hasPrefix("openai-") {
        return String(pluginComponents[1])
      }
      return pluginComponents.first.map { String($0) }
    }

    return "Codex"
  }

  private static func tokenize(_ command: String) -> [String] {
    command
      .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
      .map(String.init)
  }
}
