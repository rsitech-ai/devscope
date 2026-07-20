import Darwin
import DevScopeCore
import Foundation

@MainActor
enum DevScopeComposition {
  struct Stores {
    let processStore: ProcessStore
    let automationStore: AutomationStore
    let automationNotifier: AutomationNotifier
  }

  static func make() -> Stores {
    let currentUID = getuid()
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    let applicationSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first?.appending(path: "DevScope", directoryHint: .isDirectory)
      ?? homeDirectory.appending(path: "Library/Application Support/DevScope", directoryHint: .isDirectory)
    let transactionRoot = applicationSupport.appending(
      path: "AutomationTransactions",
      directoryHint: .isDirectory
    )
    let recoveryRoot = applicationSupport.appending(
      path: "AutomationRecovery",
      directoryHint: .isDirectory
    )
    let launchAgentsRoot = homeDirectory.appending(
      path: "Library/LaunchAgents",
      directoryHint: .isDirectory
    )

    let runner = SystemAutomationCommandRunner()
    let fileSystem = LocalAutomationFileSystem()
    try? fileSystem.createDirectory(transactionRoot, permissions: 0o700)
    try? fileSystem.createDirectory(recoveryRoot, permissions: 0o700)
    let processScanner = SystemProcessScanner()
    let legacyListing = OSACommandLegacyLoginItemAdapter(runner: runner)
    let sources: [any AutomationSource] = [
      LaunchdAutomationSource(
        fileSystem: fileSystem,
        currentUID: currentUID,
        roots: LaunchdAutomationSource.defaultRoots(homeDirectory: homeDirectory),
        runtimeStateProvider: LaunchctlAutomationRuntimeStateProvider(runner: runner)
      ),
      BackgroundTaskAutomationSource(runner: runner),
      LegacyLoginItemAutomationSource(adapter: legacyListing, currentUID: currentUID),
      CronAutomationSource(
        commandRunner: runner,
        currentUID: currentUID,
        currentUsername: currentUsername(for: currentUID)
      ),
    ]
    let inventoryService = AutomationInventoryService(
      sources: sources,
      minimumRefreshInterval: 60
    )
    let executor = AutomationExecutorRouter(
      launchd: LaunchdAutomationExecutor(
        runner: runner,
        guiUID: currentUID,
        fileSystem: fileSystem
      ),
      cron: CronAutomationExecutor(
        runner: runner,
        fileSystem: fileSystem,
        currentUID: currentUID,
        processSnapshot: {
          try processScanner.snapshot(includeCurrentDirectories: false)
        }
      ),
      legacy: LegacyLoginItemAutomationExecutor(
        runner: runner,
        listing: legacyListing,
        currentUID: currentUID
      )
    )
    let recoverableSources = AutomationRecoverableSourceProvider(
      runner: runner,
      fileSystem: fileSystem,
      legacyListing: legacyListing,
      root: transactionRoot,
      currentUID: currentUID
    )
    let authority = AutomationAuthorityContextBuilder(
      fileSystem: fileSystem,
      currentUID: currentUID,
      launchAgentsRoot: launchAgentsRoot,
      transactionRoot: transactionRoot
    )
    let manager = AutomationManager(
      fileSystem: fileSystem,
      executor: executor,
      capabilityContext: { record in
        try authority.context(for: record)
      },
      destinationContext: { record, destination in
        try authority.context(for: record, destination: destination)
      },
      recoverableSource: { record in
        try await recoverableSources.capture(record)
      },
      refresh: {
        await inventoryService.refreshAfterCurrent()
      },
      refreshProcesses: {
        try processScanner.snapshot(includeCurrentDirectories: false)
      },
      backupDirectory: recoveryRoot,
      currentUID: currentUID
    )

    return Stores(
      processStore: ProcessStore(scanner: processScanner),
      automationStore: AutomationStore(
        inventoryService: inventoryService,
        manager: manager,
        capabilityDecisionProvider: AutomationAuthorityCapabilityDecisionProvider(
          authority: authority
        ),
        destinationProvider: AutomationManagementDestinationProvider(
          transactionRoot: transactionRoot
        )
      ),
      automationNotifier: AutomationNotifier()
    )
  }

  private static func currentUsername(for uid: uid_t) -> String {
    guard let passwordEntry = getpwuid(uid), let name = passwordEntry.pointee.pw_name else {
      return NSUserName()
    }
    return String(cString: name)
  }
}
