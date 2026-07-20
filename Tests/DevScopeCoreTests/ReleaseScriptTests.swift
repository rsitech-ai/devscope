import AppKit
import Foundation
import XCTest

final class ReleaseScriptTests: XCTestCase {
  func testMainInterfaceRetainsAutomationsAndTruthfulProcessScopes() throws {
    let content = try appSource(at: "Sources/DevScope/Views/ContentView.swift")
    let picker = try appSource(at: "Sources/DevScope/Views/ProcessScopePicker.swift")
    let family = try appSource(at: "Sources/DevScope/Views/ApplicationFamilyListView.swift")
    let hierarchy = try appSource(at: "Sources/DevScope/Views/ProcessHierarchyView.swift")

    XCTAssertTrue(content.contains("Text(\"Processes\").tag(DevScopeWorkspaceMode.processes)"))
    XCTAssertTrue(content.contains("Text(\"Automations\").tag(DevScopeWorkspaceMode.automations)"))
    XCTAssertTrue(content.contains("ProcessScopePicker(selection:"))
    XCTAssertTrue(content.contains("ApplicationFamilyListView("))
    XCTAssertTrue(content.contains("ProcessHierarchyView("))
    XCTAssertTrue(picker.contains("ProcessActivityScope.allCases"))
    XCTAssertTrue(family.contains("OS processes"))
    XCTAssertTrue(hierarchy.contains("ProcessHierarchyNode"))
  }

  func testAutomationWorkspaceUsesTheProcessProjectedInventoryWithItsLinks() throws {
    let content = try appSource(at: "Sources/DevScope/Views/ContentView.swift")
    let workspace = try appSource(at: "Sources/DevScope/Views/AutomationWorkspaceView.swift")

    XCTAssertTrue(content.contains("inventory: store.liveSnapshot.automationInventory"))
    XCTAssertTrue(workspace.contains("AutomationPresentation.filtered(\n      inventory.records,"))
    XCTAssertFalse(workspace.contains("AutomationPresentation.filtered(\n      store.snapshot.records,"))
  }

  func testMainWorkspaceRetainsOnlyTheAutomationLayerAcrossWorkspaceSwitches() throws {
    let content = try appSource(at: "Sources/DevScope/Views/ContentView.swift")
    let sanitized = sanitizedSwiftSource(content)
    let mainWorkspace = try sourceBlock(in: sanitized, startingWith: "private var mainWorkspace")
    let workspaceLayers = try sourceBlock(in: mainWorkspace, startingWith: "ZStack")
    let processConditional = try sourceBlock(
      in: workspaceLayers,
      startingWith: "if workspaceMode == .processes"
    )
    let layerModifier = try sourceBlock(in: sanitized, startingWith: "func workspaceLayer")
    let normalizedWorkspace = workspaceLayers.filter { !$0.isWhitespace }
    let normalizedModifier = layerModifier.filter { !$0.isWhitespace }
    let automationInitializer = try balancedRegion(
      in: normalizedWorkspace,
      startingWith: "AutomationWorkspaceView",
      opening: "(",
      closing: ")"
    )
    let automationLayer = "AutomationWorkspaceView\(automationInitializer)"
      + ".workspaceLayer(isActive:workspaceMode==.automations)"

    XCTAssertEqual(occurrenceCount(of: "ZStack", in: mainWorkspace), 1)
    XCTAssertEqual(occurrenceCount(of: "processModeWorkspace", in: workspaceLayers), 1)
    XCTAssertTrue(processConditional.filter { !$0.isWhitespace }.contains("processModeWorkspace"))
    XCTAssertEqual(
      topLevelOccurrenceCount(of: "AutomationWorkspaceView", in: workspaceLayers),
      1
    )
    XCTAssertEqual(
      occurrenceCount(of: ".workspaceLayer(isActive:workspaceMode==.processes)", in: normalizedWorkspace),
      0
    )
    XCTAssertEqual(topLevelOccurrenceCount(of: automationLayer, in: normalizedWorkspace), 1)
    XCTAssertEqual(
      occurrenceCount(
        of: ".workspaceLayer(isActive:workspaceMode==.automations)",
        in: normalizedWorkspace
      ),
      1
    )
    XCTAssertFalse(try containsRegex(#"\bswitch\b|\?"#, in: workspaceLayers))
    XCTAssertTrue(normalizedModifier.contains("opacity(isActive?1:0)"))
    XCTAssertTrue(normalizedModifier.contains(".disabled(!isActive)"))
    XCTAssertTrue(normalizedModifier.contains(".allowsHitTesting(isActive)"))
    XCTAssertTrue(normalizedModifier.contains(".accessibilityHidden(!isActive)"))
  }

  func testAutomationWorkspaceUsesAdaptiveNativePanesAndHorizontalContainment() throws {
    let workspace = try appSource(at: "Sources/DevScope/Views/AutomationWorkspaceView.swift")
    let table = try appSource(at: "Sources/DevScope/Views/AutomationTableView.swift")
    let processTable = try appSource(at: "Sources/DevScope/Views/ProcessTableView.swift")
    let workspaceCode = sanitizedSwiftSource(workspace)
    let tableCode = sanitizedSwiftSource(table)
    let processTableCode = sanitizedSwiftSource(processTable)
    let geometryRegion = try sourceBlock(in: workspaceCode, startingWith: "GeometryReader")
    let splitRegion = try sourceBlock(in: geometryRegion, startingWith: "HSplitView")
    let horizontalScrollRegion = try sourceBlock(
      in: tableCode,
      startingWith: "ScrollView(.horizontal)"
    )
    let normalizedGeometryCode = geometryRegion.filter { !$0.isWhitespace }
    let normalizedSplitCode = splitRegion.filter { !$0.isWhitespace }
    let normalizedHorizontalScrollCode = horizontalScrollRegion.filter { !$0.isWhitespace }
    let processHorizontalScrollRegion = try sourceBlock(
      in: processTableCode,
      startingWith: "ScrollView(.horizontal)"
    )
    let normalizedProcessHorizontalScrollCode = processHorizontalScrollRegion.filter { !$0.isWhitespace }
    let paneFrameSignatures = [
      ".frame(minWidth:pane.railMinimum,idealWidth:pane.railPreferred)",
      ".frame(minWidth:pane.tableMinimum,idealWidth:pane.tablePreferred)",
      ".frame(minWidth:pane.detailMinimum,idealWidth:pane.detailPreferred)",
    ]
    let panePrioritySignatures = [
      ".layoutPriority(pane.tablePriority)",
      ".layoutPriority(pane.detailPriority)",
    ]

    XCTAssertTrue(normalizedGeometryCode.contains("AutomationWorkspaceLayoutPolicy.constraints"))
    XCTAssertTrue(normalizedHorizontalScrollCode.contains("header"))
    for scrollCode in [normalizedHorizontalScrollCode, normalizedProcessHorizontalScrollCode] {
      XCTAssertTrue(scrollCode.contains(".scrollTargetLayout()"))
      XCTAssertTrue(scrollCode.contains(
        ".scrollPosition(id:$verticalScrollTargetID,anchor:.center)"
      ))
      XCTAssertFalse(scrollCode.contains("ScrollViewReader"))
      XCTAssertFalse(scrollCode.contains(".focusable()"))
      XCTAssertFalse(scrollCode.contains(".focused("))
    }
    XCTAssertTrue(normalizedHorizontalScrollCode.contains("ScrollView(.vertical)"))
    XCTAssertTrue(normalizedHorizontalScrollCode.contains(
      "ForEach(Array(rows.enumerated()),id:\\.element.id)"
    ))
    XCTAssertTrue(normalizedHorizontalScrollCode.contains(".id(row.id)"))
    for signature in paneFrameSignatures {
      XCTAssertEqual(occurrenceCount(of: signature, in: normalizedSplitCode), 1)
    }
    XCTAssertEqual(
      paneFrameSignatures.reduce(0) {
        $0 + occurrenceCount(of: $1, in: normalizedSplitCode)
      },
      3
    )
    for signature in panePrioritySignatures {
      XCTAssertEqual(occurrenceCount(of: signature, in: normalizedSplitCode), 1)
    }
    XCTAssertEqual(
      panePrioritySignatures.reduce(0) {
        $0 + occurrenceCount(of: $1, in: normalizedSplitCode)
      },
      2
    )
    XCTAssertFalse(normalizedSplitCode.contains("maxWidth:"))
    XCTAssertFalse(try containsRegex(
      #"idealWidth\s*:\s*[-+]?(?:\d+(?:\.\d*)?|\.\d+)"#,
      in: splitRegion
    ))
    XCTAssertFalse(try containsRegex(
      #"@State(?:\s*\([^)]*\))?\s+(?:private\s+)?var\s+\w*(?:divider|split(?:ter)?Position|pane(?:s)?Width|railWidth|tableWidth|detailWidth)\w*"#,
      in: workspaceCode,
      options: [.caseInsensitive]
    ))
    XCTAssertFalse(try containsRegex(
      #"\.onChange\s*\(\s*of\s*:\s*(?:(?:\w+\.)*size\.width|proxy\.size(?!\.)|(?:\w+\.)*\w*(?:width|divider|split(?:ter)?position|paneposition)\w*)\s*\)"#,
      in: workspaceCode,
      options: [.caseInsensitive]
    ))
    XCTAssertFalse(try containsRegex(
      #"\b(?:\w*(?:divider|split(?:ter)?position)\w*|(?:pane|rail|table|detail)\w*width\w*)\s*="#,
      in: workspaceCode,
      options: [.caseInsensitive]
    ))
  }

  func testProcessTerminationMenuKeepsForceActionsInOneNativeMenu() throws {
    let source = try appSource(at: "Sources/DevScope/Views/ProcessCommandBar.swift")

    XCTAssertTrue(source.contains("Label(\"Force Kill Process…\", systemImage: \"bolt.fill\")"))
    XCTAssertTrue(source.contains("Label(\"Force Kill Process Tree…\", systemImage: \"bolt.horizontal.fill\")"))
    XCTAssertFalse(source.contains("Menu(\"Force Kill\")"))
  }

  func testProcessTableCommandCopyUsesTheDurableRecoveryPath() throws {
    let table = try appSource(at: "Sources/DevScope/Views/ProcessTableView.swift")
    let content = try appSource(at: "Sources/DevScope/Views/ContentView.swift")

    XCTAssertTrue(table.contains("let copyCommand: (ClassifiedDevProcess) -> Void"))
    XCTAssertTrue(table.contains("copyCommand(item)"))
    XCTAssertFalse(table.contains("copy(item.process.command)"))
    XCTAssertTrue(content.contains("copyCommand: copyCommand"))
  }

  func testPartialMutationRecoveryLocationsOfferCopyAndFinderActions() throws {
    let detail = try appSource(at: "Sources/DevScope/Views/AutomationDetailView.swift")

    XCTAssertTrue(detail.contains("Button(\"Reveal in Finder\")"))
    XCTAssertTrue(detail.contains("Button(\"Copy Path\")"))
    XCTAssertTrue(detail.contains("recoveryHandles"))
  }

  func testSwiftSourceSanitizerPreservesStructureAroundLineCommentsAndEscapedStrings() {
    let source = ###"""
      GeometryReader {
        let url = "https://example.com/{ignored}"
        let escaped = "quote: \" }"
        // HSplitView { decoy }
        HSplitView { pane }
      }
      """###

    let sanitized = sanitizedSwiftSource(source)

    XCTAssertEqual(sanitized.count, source.count)
    XCTAssertEqual(
      sanitized.enumerated().compactMap { $0.element.isNewline ? $0.offset : nil },
      source.enumerated().compactMap { $0.element.isNewline ? $0.offset : nil }
    )
    XCTAssertFalse(sanitized.contains("https://example.com/{ignored}"))
    XCTAssertFalse(sanitized.contains("HSplitView { decoy }"))
    XCTAssertTrue(sanitized.contains("HSplitView { pane }"))
    XCTAssertEqual(sanitized.filter { $0 == "{" }.count, 2)
    XCTAssertEqual(sanitized.filter { $0 == "}" }.count, 2)
  }

  func testSwiftSourceSanitizerIgnoresNestedCommentsAndMultilineRawStrings() {
    let source = ####"""
      Root {
        /* outer { HSplitView { decoy } /* nested { } */ still ignored } */
        let multiline = """
          HSplitView { multilineDecoy }
          /* string content is not a comment */
          """
        let raw = ##"ScrollView(.horizontal) { rawDecoy } \##" escapedRawQuote { }"##
        let rawMultiline = #"""
          GeometryReader { rawMultilineDecoy }
          """#
        HSplitView { live }
      }
      """####

    let sanitized = sanitizedSwiftSource(source)

    XCTAssertEqual(sanitized.count, source.count)
    XCTAssertFalse(sanitized.contains("decoy"))
    XCTAssertFalse(sanitized.contains("multilineDecoy"))
    XCTAssertFalse(sanitized.contains("rawDecoy"))
    XCTAssertFalse(sanitized.contains("rawMultilineDecoy"))
    XCTAssertTrue(sanitized.contains("HSplitView { live }"))
    XCTAssertEqual(sanitized.filter { $0 == "{" }.count, 2)
    XCTAssertEqual(sanitized.filter { $0 == "}" }.count, 2)
  }

  func testSwiftSourceSanitizerIgnoresNormalAndMultilineNestedInterpolationStrings() throws {
    let source = ####"""
      Root {
        let value = "prefix \(flag
          ? "HSplitView { nestedMarker /* unmatched-looking }"
          : "ScrollView(.horizontal) { pane.tableMinimum }") suffix"
        let multiline = """
          prefix \(flag
            ? """
              ScrollView(.horizontal) { multilineNestedMarker /* unmatched-looking } */
              """
            : "pane.detailPreferred { multilineFallbackMarker }") suffix
          """
        HSplitView { live }
      }
      """####

    let sanitized = sanitizedSwiftSource(source)
    let block = try sanitizedSourceBlock(in: source, startingWith: "Root")

    XCTAssertEqual(sanitized.count, source.count)
    XCTAssertEqual(
      sanitized.enumerated().compactMap { $0.element.isNewline ? $0.offset : nil },
      source.enumerated().compactMap { $0.element.isNewline ? $0.offset : nil }
    )
    XCTAssertFalse(sanitized.contains("nestedMarker"))
    XCTAssertFalse(sanitized.contains("multilineNestedMarker"))
    XCTAssertFalse(sanitized.contains("multilineFallbackMarker"))
    XCTAssertFalse(sanitized.contains("ScrollView(.horizontal)"))
    XCTAssertFalse(sanitized.contains("pane.tableMinimum"))
    XCTAssertFalse(sanitized.contains("pane.detailPreferred"))
    XCTAssertTrue(sanitized.contains("HSplitView { live }"))
    XCTAssertEqual(sanitized.filter { $0 == "{" }.count, 2)
    XCTAssertEqual(sanitized.filter { $0 == "}" }.count, 2)
    XCTAssertTrue(block.contains("HSplitView { live }"))
    XCTAssertEqual(block.filter { $0 == "{" }.count, 2)
    XCTAssertEqual(block.filter { $0 == "}" }.count, 2)
  }

  func testSwiftSourceSanitizerIgnoresRawHashNestedInterpolationsAndComments() throws {
    let source = ######"""
      Root {
        let value = ###"""
          prefix \###(
            flag
              ? ###"""
                HSplitView { rawNestedMarker /* unmatched-looking } */
                \###("ScrollView(.horizontal) { nestedInterpolationMarker }")
                """###
              : {
                  // ScrollView(.horizontal) { lineCommentMarker }
                  /* pane.detailPreferred { outer /* HSplitView { nestedCommentMarker } */ } */
                  return "pane.tableMinimum { ordinaryNestedMarker }"
                }()
          ) suffix
          """###
        HSplitView { live }
      }
      """######

    let sanitized = sanitizedSwiftSource(source)
    let block = try sanitizedSourceBlock(in: source, startingWith: "Root")

    XCTAssertEqual(sanitized.count, source.count)
    XCTAssertEqual(
      sanitized.enumerated().compactMap { $0.element.isNewline ? $0.offset : nil },
      source.enumerated().compactMap { $0.element.isNewline ? $0.offset : nil }
    )
    for leakedMarker in [
      "rawNestedMarker",
      "nestedInterpolationMarker",
      "lineCommentMarker",
      "nestedCommentMarker",
      "pane.detailPreferred",
      "pane.tableMinimum",
      "ordinaryNestedMarker",
      "ScrollView(.horizontal)",
    ] {
      XCTAssertFalse(sanitized.contains(leakedMarker), "Leaked \(leakedMarker)")
    }
    XCTAssertTrue(sanitized.contains("HSplitView { live }"))
    XCTAssertEqual(sanitized.filter { $0 == "{" }.count, 2)
    XCTAssertEqual(sanitized.filter { $0 == "}" }.count, 2)
    XCTAssertTrue(block.contains("HSplitView { live }"))
    XCTAssertEqual(block.filter { $0 == "{" }.count, 2)
    XCTAssertEqual(block.filter { $0 == "}" }.count, 2)
  }

  func testSanitizedSourceBlockFindsLiveMarkerAfterCommentAndStringDecoys() throws {
    let source = ####"""
      // GeometryReader { commentedLineDecoy }
      let text = "GeometryReader { stringDecoy }"
      /* GeometryReader { commentedBlockDecoy /* nested { } */ } */
      GeometryReader {
        let closingBraceLiteral = "} stringInsideDecoy"
        HSplitView { live }
      }
      trailing { unrelated }
      """####

    let block = try sanitizedSourceBlock(in: source, startingWith: "GeometryReader")

    XCTAssertTrue(block.contains("HSplitView { live }"))
    XCTAssertFalse(block.contains("commentedLineDecoy"))
    XCTAssertFalse(block.contains("commentedBlockDecoy"))
    XCTAssertFalse(block.contains("stringInsideDecoy"))
    XCTAssertFalse(block.contains("trailing"))
    XCTAssertEqual(block.filter { $0 == "{" }.count, 2)
    XCTAssertEqual(block.filter { $0 == "}" }.count, 2)
  }

  func testBalancedRegionIgnoresSanitizedDelimiterDecoysAndStopsBeforeTrailingOverride() throws {
    let source = ####"""
      static func make() {
        let sources: [any AutomationSource] = [
          /* ] BackgroundTaskAutomationSource(diagnosticPolicy: .available) */
          "string ] ) BackgroundTaskAutomationSource(diagnosticPolicy: .available)",
          BackgroundTaskAutomationSource(
            runner: runner,
            metadata: nestedCall(values: [one, two])
          ),
        ]
        BackgroundTaskAutomationSource(runner: runner, diagnosticPolicy: .available)
      }
      """####
    let sanitized = sanitizedSwiftSource(source)
    let make = try sourceBlock(in: sanitized, startingWith: "static func make()")
    let sources = try balancedRegion(
      in: make,
      startingWith: "let sources: [any AutomationSource] =",
      opening: "[",
      closing: "]"
    )
    let initializer = try balancedRegion(
      in: sources,
      startingWith: "BackgroundTaskAutomationSource",
      opening: "(",
      closing: ")"
    )

    XCTAssertEqual(occurrenceCount(of: "BackgroundTaskAutomationSource", in: sources), 1)
    XCTAssertTrue(initializer.contains("nestedCall(values: [one, two])"))
    XCTAssertFalse(sources.contains("diagnosticPolicy: .available"))
  }

  func testAutomationSourceCompositionAcceptsValidCurrentArray() throws {
    let source = """
      [
        LaunchdAutomationSource(
          fileSystem: fileSystem
        ),
        BackgroundTaskAutomationSource(
          runner: runner,
          diagnosticPolicy: .currentSystem
        ),
        LegacyLoginItemAutomationSource(adapter: adapter, currentUID: 501),
        CronAutomationSource(commandRunner: runner),
      ]
      """

    XCTAssertTrue(try isSafeAutomationSourceComposition(sanitizedSwiftSource(source)))
    let omittedPolicy = source.replacingOccurrences(
      of: ",\n    diagnosticPolicy: .currentSystem",
      with: ""
    )
    XCTAssertTrue(try isSafeAutomationSourceComposition(sanitizedSwiftSource(omittedPolicy)))
  }

  func testAutomationSourceCompositionRejectsTernaryNestedBackgroundConstructor() throws {
    let source = """
      [
        LaunchdAutomationSource(fileSystem: fileSystem),
        useDiagnostic
          ? BackgroundTaskAutomationSource(runner: runner)
          : backgroundSource,
        LegacyLoginItemAutomationSource(adapter: adapter, currentUID: 501),
        CronAutomationSource(commandRunner: runner),
      ]
      """

    XCTAssertFalse(try isSafeAutomationSourceComposition(sanitizedSwiftSource(source)))
  }

  func testAutomationSourceCompositionRejectsClosureAndWrapperNestedBackgroundConstructors() throws {
    let source = """
      [
        LaunchdAutomationSource(fileSystem: fileSystem),
        makeSource { BackgroundTaskAutomationSource(runner: runner) },
        LegacyLoginItemAutomationSource(adapter: adapter, currentUID: 501),
        CronAutomationSource(commandRunner: runner),
      ]
      """

    XCTAssertFalse(try isSafeAutomationSourceComposition(sanitizedSwiftSource(source)))

    let wrapped = source.replacingOccurrences(
      of: "makeSource { BackgroundTaskAutomationSource(runner: runner) }",
      with: "wrapper(BackgroundTaskAutomationSource(runner: runner))"
    )
    XCTAssertFalse(try isSafeAutomationSourceComposition(sanitizedSwiftSource(wrapped)))
  }

  func testAutomationSourceCompositionRejectsParenthesizedAlias() throws {
    let source = """
      [
        LaunchdAutomationSource(fileSystem: fileSystem),
        (backgroundSource),
        LegacyLoginItemAutomationSource(adapter: adapter, currentUID: 501),
        CronAutomationSource(commandRunner: runner),
      ]
      """

    XCTAssertFalse(try isSafeAutomationSourceComposition(sanitizedSwiftSource(source)))
  }

  func testAutomationSourceCompositionRejectsFunctionCallAlias() throws {
    let source = """
      [
        LaunchdAutomationSource(fileSystem: fileSystem),
        unsafeBackgroundSource(),
        LegacyLoginItemAutomationSource(adapter: adapter, currentUID: 501),
        CronAutomationSource(commandRunner: runner),
      ]
      """

    XCTAssertFalse(try isSafeAutomationSourceComposition(sanitizedSwiftSource(source)))
  }

  func testAutomationSourceCompositionRejectsExtraFifthElement() throws {
    let source = """
      [
        LaunchdAutomationSource(fileSystem: fileSystem),
        BackgroundTaskAutomationSource(runner: runner),
        LegacyLoginItemAutomationSource(adapter: adapter, currentUID: 501),
        CronAutomationSource(commandRunner: runner),
        unsafeBackgroundSource(),
      ]
      """

    XCTAssertFalse(try isSafeAutomationSourceComposition(sanitizedSwiftSource(source)))
  }

  func testAutomationSourceCompositionRejectsAvailableAndIgnoresLexicalDecoys() throws {
    let source = ####"""
      [
        /* BackgroundTaskAutomationSource(runner: runner) */
        "BackgroundTaskAutomationSource(runner: runner)",
        LaunchdAutomationSource(fileSystem: fileSystem),
        BackgroundTaskAutomationSource(
          runner: runner,
          diagnosticPolicy: .available
        ),
        LegacyLoginItemAutomationSource(adapter: adapter, currentUID: 501),
        CronAutomationSource(commandRunner: runner),
      ]
      """####

    XCTAssertFalse(try isSafeAutomationSourceComposition(sanitizedSwiftSource(source)))
  }

  func testTopLevelOccurrenceCountRejectsNestedClosureAndArgumentDecoys() throws {
    let source = """
      ZStack {
        // processModeWorkspace
        processModeWorkspace
        Group { processModeWorkspace }
        wrapper(AutomationWorkspaceView())
        [AutomationWorkspaceView()]
        AutomationWorkspaceView()
      }
      """
    let sanitized = sanitizedSwiftSource(source)
    let block = try sourceBlock(in: sanitized, startingWith: "ZStack")

    XCTAssertEqual(topLevelOccurrenceCount(of: "processModeWorkspace", in: block), 1)
    XCTAssertEqual(topLevelOccurrenceCount(of: "AutomationWorkspaceView", in: block), 1)
  }

  func testAutomationCompositionCreatesBothTransactionAndRecoveryRoots() throws {
    let source = try appSource(at: "Sources/DevScope/App/AutomationComposition.swift")

    XCTAssertTrue(source.contains(
      "try? fileSystem.createDirectory(transactionRoot, permissions: 0o700)"
    ))
    XCTAssertTrue(source.contains(
      "try? fileSystem.createDirectory(recoveryRoot, permissions: 0o700)"
    ))
  }

  func testAutomationCompositionUsesSafeCurrentSystemBackgroundDiagnosticPolicy() throws {
    let source = try appSource(at: "Sources/DevScope/App/AutomationComposition.swift")
    let sanitized = sanitizedSwiftSource(source)
    let make = try sourceBlock(in: sanitized, startingWith: "static func make()")
    let sources = try balancedRegion(
      in: make,
      startingWith: "let sources: [any AutomationSource] =",
      opening: "[",
      closing: "]"
    )
    XCTAssertTrue(try isSafeAutomationSourceComposition(sources))
  }

  func testAccessSettingsExposeExactManualFullDiskAccessWorkflow() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/DevScope/Views/SettingsView.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("FullDiskAccessGuidance("))
    XCTAssertTrue(source.contains("Bundle.main.bundleURL"))
    XCTAssertTrue(source.contains("Reveal DevScope in Finder"))
    XCTAssertTrue(source.contains("activateFileViewerSelecting([Bundle.main.bundleURL])"))
    XCTAssertTrue(source.contains("Array(fullDiskAccessGuidance.steps.enumerated())"))
    XCTAssertTrue(source.contains("Text(\"\\(index + 1).\")"))
    XCTAssertTrue(source.contains("FullDiskAccessSettingsRoute.open("))
    XCTAssertTrue(source.contains("using: NSWorkspace.shared.open"))
    XCTAssertTrue(source.contains("fallback: openPrivacyAndSecurity"))
    XCTAssertTrue(source.contains("if !fullDiskAccessGuidance.isSandboxed"))
    XCTAssertFalse(source.contains("return [.fullDiskAccess, .privacySecurity]"))
    XCTAssertTrue(source.contains("if shouldShowFullDiskAccessGuidance"))
    XCTAssertTrue(source.contains("ProcessAccessStatus.isSandboxed"))
    XCTAssertTrue(source.contains("neededAccessActions.contains(.fullDiskAccess)"))
    let accessPanel = try XCTUnwrap(source.range(of: "SettingsPanel(title: \"Process Access\")"))
    let accessPrefix = source[..<accessPanel.lowerBound]
    let accessScroll = try XCTUnwrap(accessPrefix.range(of: "ScrollView {", options: .backwards))
    let generalTab = try XCTUnwrap(accessPrefix.range(of: "Label(\"General\""))
    XCTAssertGreaterThan(accessScroll.lowerBound, generalTab.upperBound)
  }

  func testExpandedLiveActivityUsesPersistentMeasuredSplitHeight() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let content = try String(
      contentsOf: repositoryRoot.appendingPathComponent("Sources/DevScope/Views/ContentView.swift"),
      encoding: .utf8
    )
    let settings = try String(
      contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/DevScope/Views/SettingsView.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(settings.contains("liveActivityPreferredHeight"))
    XCTAssertTrue(content.contains("LiveActivityHeightPreferenceKey"))
    XCTAssertTrue(content.contains("LiveActivityLayoutPolicy.resolvedHeight"))
    XCTAssertTrue(content.contains("LiveActivityLayoutPolicy.updatedPreferredHeight"))
    XCTAssertTrue(content.contains("guard updatedHeight != liveActivityPreferredHeight"))
    XCTAssertFalse(content.contains("maxHeight: 190"))
  }

  func testLiveActivityDockUsesWidthAwareLayoutsWithoutClippingMinimums() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/DevScope/Views/ProcessStatsPanelView.swift"),
      encoding: .utf8
    )
    let content = try String(
      contentsOf: repositoryRoot.appendingPathComponent("Sources/DevScope/Views/ContentView.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("LiveActivityLayoutPolicy.mode"))
    XCTAssertTrue(source.contains("LiveActivityLayoutPolicy.verticalMode"))
    XCTAssertTrue(source.contains("availableHeight: proxy.size.height"))
    XCTAssertTrue(source.contains("verticalMode == .condensed ? .condensed : .standard"))
    XCTAssertTrue(source.contains("ViewThatFits"))
    XCTAssertFalse(source.contains(".frame(minWidth: 480"))
    XCTAssertFalse(source.contains(".frame(minWidth: 260"))
    XCTAssertTrue(content.contains(".frame(minWidth: 620)"))
    XCTAssertFalse(content.contains(".frame(minWidth: 760)"))
  }

  func testExpandedLiveActivityGraphFillsPanelWithoutDuplicateUsageSummaries() throws {
    let source = try appSource(at: "Sources/DevScope/Views/ProcessStatsPanelView.swift")
    let sanitized = sanitizedSwiftSource(source)
    let dock = try sourceBlock(in: sanitized, startingWith: "struct LiveActivitiesDockView")
    let graph = try sourceBlock(
      in: sanitized,
      startingWith: "private struct DashboardMetricGraph"
    )

    XCTAssertTrue(dock.contains("showsLegend: false"))
    XCTAssertTrue(dock.contains("showsSummary: false"))
    XCTAssertTrue(dock.contains("fillsAvailableHeight: true"))
    XCTAssertTrue(dock.contains("maxHeight: .infinity"))
    XCTAssertFalse(dock.contains("private var pressureTile"))
    XCTAssertFalse(source.contains("private struct MachinePressureTile"))
    XCTAssertTrue(graph.contains("var showsLegend = true"))
    XCTAssertTrue(graph.contains("var showsSummary = true"))
    XCTAssertTrue(graph.contains("var fillsAvailableHeight = false"))
    XCTAssertTrue(graph.contains("maxHeight: fillsAvailableHeight ? .infinity"))
  }

  func testFolderOpenFeedbackReflectsWorkspaceResult() throws {
    let source = try appSource(at: "Sources/DevScope/Views/ContentView.swift")

    XCTAssertTrue(source.contains("let didOpen = NSWorkspace.shared.open"))
    XCTAssertTrue(source.contains("title: didOpen ? \"Folder opened\" : \"Folder unavailable\""))
  }

  func testRecoveryCopyIsLabeledAsRedacted() throws {
    let source = try appSource(at: "Sources/DevScope/Views/ContentView.swift")

    XCTAssertTrue(source.contains("title: \"Redacted recovery copy restored\""))
  }

  func testProcessMetricCanvasHasAccessibleTrendSummary() throws {
    let source = try appSource(at: "Sources/DevScope/Views/ProcessMetricHistoryView.swift")

    XCTAssertTrue(source.contains(".accessibilityLabel(\"Process resource history\")"))
    XCTAssertTrue(source.contains(".accessibilityValue(accessibilitySummary)"))
  }

  func testOptionalTransitionsRespectReduceMotion() throws {
    let detailSource = try appSource(at: "Sources/DevScope/Views/ProcessDetailView.swift")
    let contentSource = try appSource(at: "Sources/DevScope/Views/ContentView.swift")
    let statsSource = try appSource(at: "Sources/DevScope/Views/ProcessStatsPanelView.swift")

    XCTAssertTrue(detailSource.contains("reduceMotion ? .identity"))
    XCTAssertTrue(contentSource.contains("feedbackTransition"))
    XCTAssertTrue(statsSource.contains("reduceMotion ? .identity"))
  }

  func testReleaseBundleBuildsUniversalMacBinaryByDefault() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: repositoryRoot.appendingPathComponent("script/build_release_bundle.sh"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("DEVSCOPE_ARCHITECTURES:-arm64 x86_64"))
    XCTAssertTrue(source.contains("for architecture in $ARCHITECTURES"))
    XCTAssertTrue(source.contains("--scratch-path \"$scratchPath\""))
    XCTAssertTrue(source.contains("lipo -create"))
    XCTAssertTrue(source.contains("-verify_arch \"$architecture\""))
  }

  func testReleaseInfoPlistUsesPlutilAndIncludesAppleEventsPurposeText() throws {
    let source = try appSource(at: "script/build_release_bundle.sh")

    XCTAssertTrue(source.contains("plutil -create xml1"))
    XCTAssertTrue(source.contains("plutil -insert CFBundleIdentifier -string \"$BUNDLE_ID\""))
    XCTAssertTrue(source.contains("plutil -insert NSAppleEventsUsageDescription -string"))
    XCTAssertFalse(source.contains("<string>$BUNDLE_ID</string>"))
    XCTAssertFalse(source.contains("cat >\"$INFO_PLIST\" <<PLIST"))
  }

  func testReleaseBundleCarriesPublicLicenseNotices() throws {
    let source = try appSource(at: "script/build_release_bundle.sh")

    for filename in ["LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md"] {
      XCTAssertTrue(
        source.contains(#"cp "$ROOT_DIR/\#(filename)" "$APP_RESOURCES/\#(filename)""#),
        "release bundle must carry \(filename)"
      )
    }
  }

  func testReleaseBundlesUseThePublicCopyrightOwner() throws {
    let releaseSource = try appSource(at: "script/build_release_bundle.sh")
    let developmentSource = try appSource(at: "script/build_and_run.sh")
    let expectedCopyright = "Copyright © 2026 Rafal Sikora."

    XCTAssertTrue(releaseSource.contains(expectedCopyright))
    XCTAssertTrue(developmentSource.contains(expectedCopyright))
  }

  func testDistributionEntitlementsMatchFileAndAppleEventsBoundaries() throws {
    let sandbox = try entitlementDictionary(at: "config/DevScope.entitlements")
    let developerID = try entitlementDictionary(at: "config/DevScopeDeveloperID.entitlements")

    XCTAssertEqual(sandbox["com.apple.security.app-sandbox"] as? Bool, true)
    XCTAssertEqual(sandbox["com.apple.security.files.user-selected.read-write"] as? Bool, true)
    XCTAssertEqual(developerID["com.apple.security.automation.apple-events"] as? Bool, true)
    XCTAssertNil(developerID["com.apple.security.app-sandbox"])
  }

  func testFullDistributionValidationRequiresAppleEventsConfiguration() throws {
    let developerID = try appSource(at: "script/package_developer_id.sh")
    let localInstall = try appSource(at: "script/install_local_full_build.sh")
    let validator = try appSource(at: "script/validate_release_bundle.sh")

    for source in [developerID, localInstall] {
      XCTAssertTrue(source.contains("DEVSCOPE_REQUIRE_APPLE_EVENTS=1"))
    }
    XCTAssertTrue(validator.contains("com\\.apple\\.security\\.automation\\.apple-events"))
    XCTAssertTrue(validator.contains("NSAppleEventsUsageDescription"))
  }

  func testReleaseScriptsUseOneCanonicalDistApplicationBundle() throws {
    let buildSource = try appSource(at: "script/build_release_bundle.sh")
    let validationSource = try appSource(at: "script/validate_release_bundle.sh")

    XCTAssertTrue(buildSource.contains(#"DEVSCOPE_DIST_DIR:-$ROOT_DIR/dist}"#))
    XCTAssertTrue(validationSource.contains(#"$ROOT_DIR/dist/DevScope.app"#))
    XCTAssertFalse(buildSource.contains(#"$ROOT_DIR/dist/release"#))
    XCTAssertFalse(validationSource.contains(#"$ROOT_DIR/dist/release/DevScope.app"#))
    XCTAssertFalse(buildSource.contains(#"ICONSET_DIR="$DIST_DIR"#))
  }

  func testReleaseValidationUsesSupportedEntitlementExtractionSyntax() throws {
    let source = try appSource(at: "script/validate_release_bundle.sh")

    XCTAssertTrue(source.contains("codesign -dvvv --xml --entitlements -"))
    XCTAssertFalse(source.contains("--entitlements :-"))
  }

  func testDevelopmentRunScriptLaunchesAndVerifiesExactBuiltBundle() throws {
    let source = try appSource(at: "script/build_and_run.sh")

    XCTAssertTrue(source.contains(#"/usr/bin/open -n -a "$APP_BUNDLE""#))
    XCTAssertTrue(source.contains("verify_exact_app"))
    XCTAssertTrue(source.contains(#""$running_command" == "$APP_BINARY""#))
    XCTAssertTrue(source.contains("plutil -create xml1"))
    XCTAssertTrue(source.contains("plutil -insert CFBundleVersion -string \"$BUILD_VERSION\""))
    XCTAssertTrue(source.contains("plutil -insert NSAppleEventsUsageDescription -string"))
    XCTAssertTrue(source.contains(#"cp "$ROOT_DIR/Resources/PrivacyInfo.xcprivacy""#))
    XCTAssertTrue(source.contains(#"codesign --force --sign - "$APP_BUNDLE""#))
    XCTAssertTrue(source.contains(#"codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE""#))
    XCTAssertFalse(source.contains("cat >\"$INFO_PLIST\" <<PLIST"))
    XCTAssertFalse(source.contains(#"/usr/bin/open -n "$APP_BUNDLE""#))
    XCTAssertFalse(source.contains(#"pgrep -x "$APP_NAME" >/dev/null"#))
  }

  func testTransientActionFeedbackRequestsAnAccessibilityAnnouncement() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: repositoryRoot.appendingPathComponent("Sources/DevScope/Views/ContentView.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("notification: .announcementRequested"))
    XCTAssertTrue(source.contains(".announcement: announcement"))
  }

  func testSettingsTabsProvideScrollableContent() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/DevScope/Views/SettingsView.swift"),
      encoding: .utf8
    )
    let scrollViewCount = source.components(separatedBy: "ScrollView {").count - 1

    XCTAssertGreaterThanOrEqual(scrollViewCount, 3)
  }

  func testAppUsesSingleWindowSceneToAvoidDuplicateProcessScanners() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let appSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent("Sources/DevScope/App/DevScopeApp.swift"),
      encoding: .utf8
    )

    XCTAssertFalse(appSource.contains("WindowGroup("))
    XCTAssertTrue(appSource.contains("Window(\"DevScope\", id: \"main\")"))
  }

  func testGeneratedAppIconRepresentationsMatchFilenameDimensions() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let outputDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: outputDirectory) }

    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [
      "swift",
      repositoryRoot.appendingPathComponent("script/generate_app_icon.swift").path,
      outputDirectory.path,
    ]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let capturedOutput = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    XCTAssertEqual(
      process.terminationStatus,
      0,
      String(decoding: capturedOutput, as: UTF8.self)
    )

    let expectedDimensions = [
      "icon_16x16.png": 16,
      "icon_16x16@2x.png": 32,
      "icon_32x32.png": 32,
      "icon_32x32@2x.png": 64,
      "icon_128x128.png": 128,
      "icon_128x128@2x.png": 256,
      "icon_256x256.png": 256,
      "icon_256x256@2x.png": 512,
      "icon_512x512.png": 512,
      "icon_512x512@2x.png": 1024,
    ]

    for (filename, expectedPixels) in expectedDimensions {
      let data = try Data(contentsOf: outputDirectory.appendingPathComponent(filename))
      let representation = try XCTUnwrap(NSBitmapImageRep(data: data), filename)
      XCTAssertEqual(representation.pixelsWide, expectedPixels, filename)
      XCTAssertEqual(representation.pixelsHigh, expectedPixels, filename)
    }
  }

  func testReleaseScriptsReferenceTrackedEntitlementsDirectoryWithExactCase() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let scriptPaths = [
      "script/build_release_bundle.sh",
      "script/install_local_full_build.sh",
      "script/package_developer_id.sh",
    ]

    for scriptPath in scriptPaths {
      let contents = try String(
        contentsOf: repositoryRoot.appendingPathComponent(scriptPath),
        encoding: .utf8
      )
      XCTAssertFalse(
        contents.contains("$ROOT_DIR/Config/"),
        "\(scriptPath) must use the tracked lowercase config directory"
      )
      XCTAssertTrue(
        contents.contains("$ROOT_DIR/config/"),
        "\(scriptPath) must reference the tracked entitlement path"
      )
    }
  }

  func testNonSandboxValidationRejectsSandboxedBundle() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let appBundle = try makeSignedTestBundle(at: temporaryRoot, sandboxed: true)
    let result = try runValidation(for: appBundle, requiresSandbox: false)

    XCTAssertNotEqual(result.status, 0, result.output)
    XCTAssertTrue(result.output.contains("App Sandbox entitlement must be absent"), result.output)
  }

  func testSandboxValidationRejectsFalseSandboxValueBesideTrueEntitlement() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let appBundle = try makeSignedTestBundle(
      at: temporaryRoot,
      entitlementBody: """
        <key>com.apple.security.app-sandbox</key><false/>
        <key>com.apple.security.network.client</key><true/>
        """
    )
    let result = try runValidation(for: appBundle, requiresSandbox: true)

    XCTAssertNotEqual(result.status, 0, result.output)
    XCTAssertTrue(result.output.contains("App Sandbox entitlement is not true"), result.output)

    let source = try appSource(at: "script/validate_release_bundle.sh")
    XCTAssertTrue(source.contains("plutil -extract 'com\\.apple\\.security\\.app-sandbox' raw"))
    XCTAssertFalse(source.contains("grep -A3 \"com.apple.security.app-sandbox\""))
  }

  func testSandboxValidationRejectsMissingUserSelectedReadWriteEntitlement() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let appBundle = try makeSignedTestBundle(
      at: temporaryRoot,
      entitlementBody: """
        <key>com.apple.security.app-sandbox</key><true/>
        """
    )
    let result = try runValidation(for: appBundle, requiresSandbox: true)

    XCTAssertNotEqual(result.status, 0, result.output)
    XCTAssertTrue(
      result.output.contains("user-selected read-write entitlement missing"),
      result.output
    )
  }

  func testAppStorePackagingPinsSandboxEntitlementsAndValidation() throws {
    let source = try appSource(at: "script/package_app_store.sh")

    XCTAssertTrue(source.contains("security cms -D -i"))
    XCTAssertTrue(source.contains("ApplicationIdentifierPrefix.0"))
    XCTAssertTrue(source.contains("$PROFILE_PREFIX.$DEVSCOPE_BUNDLE_ID"))
    XCTAssertFalse(source.contains("$PROFILE_TEAM.$DEVSCOPE_BUNDLE_ID"))
    XCTAssertTrue(source.contains("com.apple.application-identifier"))
    XCTAssertTrue(source.contains("com.apple.developer.team-identifier"))
    XCTAssertTrue(source.contains("DEVSCOPE_ENTITLEMENTS=\"$APP_STORE_ENTITLEMENTS\""))
    XCTAssertTrue(source.contains("DEVSCOPE_REQUIRE_SANDBOX=1"))
  }

  func testReleaseWorkflowPinsThirdPartyActionsByCommit() throws {
    let source = try appSource(at: ".github/workflows/release-gates.yml")

    XCTAssertTrue(
      source.contains("actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd")
    )
    XCTAssertFalse(source.contains("actions/checkout@v6"))
  }

  func testOpenSourceReadinessCheckerRejectsRepositoryWithoutLicense() throws {
    let temporaryRoot = try makeOpenSourceReadinessFixture()
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    try FileManager.default.removeItem(at: temporaryRoot.appendingPathComponent("LICENSE"))

    let result = try runOpenSourceReadinessChecker(root: temporaryRoot)

    XCTAssertNotEqual(result.status, 0, result.output)
    XCTAssertTrue(result.output.contains("LICENSE"), result.output)
  }

  func testOpenSourceReadinessCheckerRejectsMissingPublicIdentity() throws {
    let temporaryRoot = try makeOpenSourceReadinessFixture()
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    try Data("DevScope\nCopyright 2026 unknown\n".utf8).write(
      to: temporaryRoot.appendingPathComponent("NOTICE")
    )

    let result = try runOpenSourceReadinessChecker(root: temporaryRoot)

    XCTAssertNotEqual(result.status, 0, result.output)
    XCTAssertTrue(result.output.contains("public identity"), result.output)
  }

  func testOpenSourceReadinessCheckerRejectsInternalPublicationMaterial() throws {
    let temporaryRoot = try makeOpenSourceReadinessFixture()
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let internalDirectory = temporaryRoot.appendingPathComponent(
      "docs/monetization",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: internalDirectory,
      withIntermediateDirectories: true
    )
    try Data("private economics".utf8).write(
      to: internalDirectory.appendingPathComponent("strategy.md")
    )

    let result = try runOpenSourceReadinessChecker(root: temporaryRoot)

    XCTAssertNotEqual(result.status, 0, result.output)
    XCTAssertTrue(result.output.contains("internal publication material"), result.output)
    XCTAssertTrue(result.output.contains("docs/monetization"), result.output)
  }

  func testOpenSourceReadinessCheckerRejectsUnpinnedGitHubAction() throws {
    let temporaryRoot = try makeOpenSourceReadinessFixture()
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let workflows = temporaryRoot.appendingPathComponent(
      ".github/workflows", isDirectory: true
    )
    try Data(
      """
      name: Unsafe fixture
      on: [push]
      permissions:
        contents: read
      jobs:
        fixture:
          runs-on: macos-latest
          steps:
            - uses: actions/checkout@v6
      """.utf8
    ).write(to: workflows.appendingPathComponent("unpinned-fixture.yml"))

    let result = try runOpenSourceReadinessChecker(root: temporaryRoot)

    XCTAssertNotEqual(result.status, 0, result.output)
    XCTAssertTrue(result.output.contains("not pinned to a full commit SHA"), result.output)
    XCTAssertTrue(result.output.contains("actions/checkout@v6"), result.output)
  }

  func testOpenSourceReadinessCheckerAcceptsCurrentPublicSurface() throws {
    let temporaryRoot = try makeOpenSourceReadinessFixture()
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let result = try runOpenSourceReadinessChecker(root: temporaryRoot)

    XCTAssertEqual(result.status, 0, result.output)
    XCTAssertTrue(result.output.contains("Open-source readiness check passed."), result.output)
  }

  func testOpenSourceReadinessCheckerRejectsWorkflowWriteAllPermission() throws {
    let temporaryRoot = try makeOpenSourceReadinessFixture()
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let workflow = temporaryRoot.appendingPathComponent(
      ".github/workflows/release-gates.yml"
    )
    try Data(
      """
      name: Unsafe permissions fixture
      on: [push]
      permissions: write-all
      jobs:
        fixture:
          runs-on: macos-latest
          steps: []
      """.utf8
    ).write(to: workflow)

    let result = try runOpenSourceReadinessChecker(root: temporaryRoot)

    XCTAssertNotEqual(result.status, 0, result.output)
    XCTAssertTrue(result.output.contains("permission"), result.output)
  }

  func testOpenSourceReadinessCheckerRejectsJobWritePermissionOverride() throws {
    let temporaryRoot = try makeOpenSourceReadinessFixture()
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let workflow = temporaryRoot.appendingPathComponent(
      ".github/workflows/release-gates.yml"
    )
    try Data(
      """
      name: Unsafe job permissions fixture
      on: [push]
      permissions:
        contents: read
      jobs:
        fixture:
          permissions:
            contents: write
          runs-on: macos-latest
          steps: []
      """.utf8
    ).write(to: workflow)

    let result = try runOpenSourceReadinessChecker(root: temporaryRoot)

    XCTAssertNotEqual(result.status, 0, result.output)
    XCTAssertTrue(result.output.contains("unexpected write permission"), result.output)
    XCTAssertTrue(result.output.contains("job fixture"), result.output)
  }

  func testProvisioningProfileValidationChecksReleaseSemantics() throws {
    let source = try appSource(at: "script/validate_release_bundle.sh")

    XCTAssertTrue(source.contains("security cms -D -i"))
    XCTAssertTrue(source.contains("ExpirationDate"))
    XCTAssertTrue(source.contains("application-identifier"))
    XCTAssertTrue(source.contains("ApplicationIdentifierPrefix.0"))
    XCTAssertTrue(source.contains("$PROFILE_PREFIX.$BUNDLE_ID"))
    XCTAssertFalse(source.contains("$PROFILE_TEAM.$BUNDLE_ID"))
    XCTAssertTrue(source.contains("Entitlements.com\\.apple\\.application-identifier"))
    XCTAssertTrue(source.contains("TeamIdentifier"))
    XCTAssertTrue(source.contains("DeveloperCertificates"))
    XCTAssertTrue(source.contains("--extract-certificates"))
    XCTAssertTrue(source.contains("profile App Sandbox entitlement is not true"))
  }

  func testDeveloperIDPackagingRequiresNotarizationUnlessExplicitlyOverridden() throws {
    let source = try appSource(at: "script/package_developer_id.sh")

    XCTAssertTrue(source.contains("DEVSCOPE_ALLOW_UNNOTARIZED"))
    XCTAssertTrue(source.contains("notary profile is required for a release artifact"))
    XCTAssertEqual(source.components(separatedBy: "--norsrc --noextattr").count - 1, 2)
  }

  func testCommunityPreviewPackagingIsExplicitlyUnnotarizedAndChecksummed() throws {
    let source = try appSource(at: "script/package_community_preview.sh")

    XCTAssertTrue(source.contains("DEVSCOPE_ACKNOWLEDGE_UNNOTARIZED_PREVIEW"))
    XCTAssertTrue(source.contains("UNNOTARIZED COMMUNITY PREVIEW"))
    XCTAssertTrue(source.contains("Do not disable Gatekeeper"))
    XCTAssertTrue(source.contains("DEVSCOPE_SIGN_IDENTITY=\"-\""))
    XCTAssertTrue(source.contains("DEVSCOPE_ENTITLEMENTS=\"$ROOT_DIR/config/DevScopeDeveloperID.entitlements\""))
    XCTAssertTrue(source.contains("DEVSCOPE_REQUIRE_SANDBOX=0"))
    XCTAssertTrue(source.contains("DEVSCOPE_REQUIRE_APPLE_EVENTS=1"))
    XCTAssertTrue(source.contains("--norsrc --noextattr"))
    XCTAssertTrue(source.contains("shasum -a 256"))
    XCTAssertTrue(source.contains("zipinfo -1"))
  }

  func testValidationRejectsBundleMissingRequiredArchitecture() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let appBundle = try makeSignedTestBundle(at: temporaryRoot, sandboxed: false)
    let result = try runValidation(
      for: appBundle,
      requiresSandbox: false,
      requiredArchitectures: "not-a-real-architecture"
    )

    XCTAssertNotEqual(result.status, 0, result.output)
    XCTAssertTrue(result.output.contains("required architecture missing"), result.output)
  }

  func testReleaseValidationRejectsMissingPublicLicenseNotice() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let appBundle = try makeSignedTestBundle(at: temporaryRoot, sandboxed: false)
    try FileManager.default.removeItem(
      at: appBundle.appendingPathComponent("Contents/Resources/LICENSE")
    )

    let result = try runValidation(for: appBundle, requiresSandbox: false)

    XCTAssertNotEqual(result.status, 0, result.output)
    XCTAssertTrue(result.output.contains("LICENSE missing"), result.output)
  }

  func testDeveloperIDPackageRebuildsArchiveAfterStapling() throws {
    let fileManager = FileManager.default
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let temporaryRoot = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryRoot) }

    let scriptDirectory = temporaryRoot.appendingPathComponent("script", isDirectory: true)
    let fakeBinDirectory = temporaryRoot.appendingPathComponent("bin", isDirectory: true)
    let distDirectory = temporaryRoot.appendingPathComponent("dist", isDirectory: true)
    try fileManager.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: fakeBinDirectory, withIntermediateDirectories: true)

    try fileManager.copyItem(
      at: repositoryRoot.appendingPathComponent("script/package_developer_id.sh"),
      to: scriptDirectory.appendingPathComponent("package_developer_id.sh")
    )
    try writeExecutable(
      """
      #!/usr/bin/env bash
      set -euo pipefail
      app="$DEVSCOPE_DIST_DIR/DevScope.app"
      mkdir -p "$app"
      echo "$app"
      """,
      to: scriptDirectory.appendingPathComponent("build_release_bundle.sh")
    )
    try writeExecutable(
      "#!/usr/bin/env bash\nexit 0\n",
      to: scriptDirectory.appendingPathComponent("validate_release_bundle.sh"))
    try writeExecutable(
      """
      #!/usr/bin/env bash
      echo "$DEVSCOPE_DEVELOPER_ID_SIGN_IDENTITY"
      """,
      to: fakeBinDirectory.appendingPathComponent("security")
    )
    try writeExecutable(
      """
      #!/usr/bin/env bash
      set -euo pipefail
      app="${@: -2:1}"
      archive="${@: -1}"
      if [[ -f "$app/stapled-ticket" ]]; then
        echo stapled >> "$MOCK_DITTO_LOG"
      else
        echo unstapled >> "$MOCK_DITTO_LOG"
      fi
      touch "$archive"
      """,
      to: fakeBinDirectory.appendingPathComponent("ditto")
    )
    try writeExecutable(
      """
      #!/usr/bin/env bash
      set -euo pipefail
      if [[ "${1:-}" == "stapler" && "${2:-}" == "staple" ]]; then
        touch "$3/stapled-ticket"
      fi
      """,
      to: fakeBinDirectory.appendingPathComponent("xcrun")
    )
    try writeExecutable(
      "#!/usr/bin/env bash\nexit 0\n", to: fakeBinDirectory.appendingPathComponent("spctl"))

    let logURL = temporaryRoot.appendingPathComponent("ditto.log")
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [scriptDirectory.appendingPathComponent("package_developer_id.sh").path]
    process.standardOutput = output
    process.standardError = output
    process.environment = ProcessInfo.processInfo.environment.merging([
      "PATH": "\(fakeBinDirectory.path):/usr/bin:/bin",
      "DEVSCOPE_DEVELOPER_ID_SIGN_IDENTITY": "Developer ID Application: Test",
      "DEVSCOPE_NOTARY_KEYCHAIN_PROFILE": "test-profile",
      "DEVSCOPE_DIST_DIR": distDirectory.path,
      "MOCK_DITTO_LOG": logURL.path,
    ]) { _, replacement in replacement }

    try process.run()
    let capturedOutput = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    XCTAssertEqual(
      process.terminationStatus,
      0,
      String(decoding: capturedOutput, as: UTF8.self)
    )
    let archiveStates = try String(contentsOf: logURL, encoding: .utf8)
      .split(whereSeparator: \.isNewline)
      .map(String.init)
    XCTAssertEqual(archiveStates, ["unstapled", "stapled"])
  }

  private func writeExecutable(_ contents: String, to url: URL) throws {
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }

  private func makeOpenSourceReadinessFixture() throws -> URL {
    let fileManager = FileManager.default
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let temporaryRoot = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

    let paths = [
      ".github", ".gitleaks.toml", "CHANGELOG.md", "CODE_OF_CONDUCT.md",
      "CONTRIBUTING.md", "GOVERNANCE.md", "LICENSE", "NOTICE", "PRIVACY.md",
      "README.md", "SECURITY.md", "SUPPORT.md", "THIRD_PARTY_NOTICES.md",
      "TRADEMARKS.md", "docs", "script",
    ]
    for path in paths {
      try fileManager.copyItem(
        at: repositoryRoot.appendingPathComponent(path),
        to: temporaryRoot.appendingPathComponent(path)
      )
    }
    return temporaryRoot
  }

  private func runOpenSourceReadinessChecker(
    root: URL,
    skipDependencyCheck: Bool = true
  ) throws -> (
    status: Int32, output: String
  ) {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let checker = repositoryRoot.appendingPathComponent(
      "script/check_open_source_readiness.sh"
    )
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [checker.path, "--root", root.path]
    if skipDependencyCheck {
      process.arguments?.append("--skip-dependency-check")
    }
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let capturedOutput = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (
      process.terminationStatus,
      String(decoding: capturedOutput, as: UTF8.self)
    )
  }

  private func appSource(at path: String) throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
  }

  private func entitlementDictionary(at path: String) throws -> [String: Any] {
    let data = try Data(appSource(at: path).utf8)
    return try XCTUnwrap(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    )
  }

  private func sanitizedSwiftSource(_ source: String) -> String {
    var sanitizer = SwiftSourceLexicalSanitizer(source: source)
    return sanitizer.sanitizedSource()
  }

  private func sourceBlock(in source: String, startingWith marker: String) throws -> String {
    let markerRange = try XCTUnwrap(source.range(of: marker))
    let openingBrace = try XCTUnwrap(source[markerRange.upperBound...].firstIndex(of: "{"))
    var depth = 0

    for index in source.indices[openingBrace...] {
      switch source[index] {
      case "{":
        depth += 1
      case "}":
        depth -= 1
        if depth == 0 {
          return String(source[openingBrace...index])
        }
      default:
        break
      }
    }

    throw NSError(
      domain: "ReleaseScriptTests",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Unterminated source block after \(marker)"]
    )
  }

  private func balancedRegion(
    in source: String,
    startingWith marker: String,
    opening: Character,
    closing: Character
  ) throws -> String {
    let markerRange = try XCTUnwrap(source.range(of: marker))
    let openingIndex = try XCTUnwrap(source[markerRange.upperBound...].firstIndex(of: opening))
    var depth = 0

    for index in source.indices[openingIndex...] {
      if source[index] == opening {
        depth += 1
      } else if source[index] == closing {
        depth -= 1
        if depth == 0 {
          return String(source[openingIndex...index])
        }
      }
    }

    throw NSError(
      domain: "ReleaseScriptTests",
      code: 2,
      userInfo: [NSLocalizedDescriptionKey: "Unterminated balanced region after \(marker)"]
    )
  }

  private func isSafeAutomationSourceComposition(
    _ sanitizedArray: String
  ) throws -> Bool {
    let elements = try topLevelArrayElements(in: sanitizedArray)
    let normalizedElements = elements.map { $0.filter { !$0.isWhitespace } }
    guard normalizedElements.count == 4 else { return false }
    let safeBackgroundExpressions: Set<String> = [
      "BackgroundTaskAutomationSource(runner:runner)",
      "BackgroundTaskAutomationSource(runner:runner,diagnosticPolicy:.currentSystem)",
    ]

    return normalizedElements.filter {
      isDirectInitializer($0, named: "LaunchdAutomationSource")
    }.count == 1
      && normalizedElements.filter(safeBackgroundExpressions.contains).count == 1
      && normalizedElements.filter {
        isDirectInitializer($0, named: "LegacyLoginItemAutomationSource")
      }.count == 1
      && normalizedElements.filter {
        isDirectInitializer($0, named: "CronAutomationSource")
      }.count == 1
  }

  private func isDirectInitializer(_ expression: String, named typeName: String) -> Bool {
    guard expression.hasPrefix("\(typeName)(") else { return false }
    let opening = expression.index(expression.startIndex, offsetBy: typeName.count)
    var depth = 0

    for index in expression.indices[opening...] {
      if expression[index] == "(" {
        depth += 1
      } else if expression[index] == ")" {
        depth -= 1
        if depth == 0 {
          return index == expression.index(before: expression.endIndex)
        }
      }
      if depth < 0 { return false }
    }
    return false
  }

  private func topLevelArrayElements(in sanitizedArray: String) throws -> [String] {
    let trimmed = sanitizedArray.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.first == "[", trimmed.last == "]" else {
      throw NSError(
        domain: "ReleaseScriptTests",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Expected one balanced array expression"]
      )
    }

    let contentStart = trimmed.index(after: trimmed.startIndex)
    let contentEnd = trimmed.index(before: trimmed.endIndex)
    let content = trimmed[contentStart..<contentEnd]
    var braceDepth = 0
    var parenthesisDepth = 0
    var bracketDepth = 0
    var elementStart = content.startIndex
    var elements: [String] = []

    func appendElement(endingAt end: Substring.Index) {
      let element = content[elementStart..<end]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !element.isEmpty { elements.append(element) }
    }

    for index in content.indices {
      switch content[index] {
      case "{":
        braceDepth += 1
      case "}":
        braceDepth -= 1
      case "(":
        parenthesisDepth += 1
      case ")":
        parenthesisDepth -= 1
      case "[":
        bracketDepth += 1
      case "]":
        bracketDepth -= 1
      case "," where braceDepth == 0 && parenthesisDepth == 0 && bracketDepth == 0:
        appendElement(endingAt: index)
        elementStart = content.index(after: index)
      default:
        break
      }

      guard braceDepth >= 0, parenthesisDepth >= 0, bracketDepth >= 0 else {
        throw NSError(
          domain: "ReleaseScriptTests",
          code: 4,
          userInfo: [NSLocalizedDescriptionKey: "Unbalanced top-level array element"]
        )
      }
    }

    guard braceDepth == 0, parenthesisDepth == 0, bracketDepth == 0 else {
      throw NSError(
        domain: "ReleaseScriptTests",
        code: 5,
        userInfo: [NSLocalizedDescriptionKey: "Unterminated top-level array element"]
      )
    }
    appendElement(endingAt: content.endIndex)
    return elements
  }

  private func topLevelOccurrenceCount(of needle: String, in block: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var braceDepth = 0
    var parenthesisDepth = 0
    var bracketDepth = 0
    var count = 0
    var index = block.startIndex

    while index < block.endIndex {
      switch block[index] {
      case "{":
        braceDepth += 1
      case "}":
        braceDepth -= 1
      case "(":
        parenthesisDepth += 1
      case ")":
        parenthesisDepth -= 1
      case "[":
        bracketDepth += 1
      case "]":
        bracketDepth -= 1
      default:
        if braceDepth == 1,
           parenthesisDepth == 0,
           bracketDepth == 0,
           block[index...].hasPrefix(needle)
        {
          count += 1
        }
      }
      index = block.index(after: index)
    }

    return count
  }

  private func sanitizedSourceBlock(in source: String, startingWith marker: String) throws -> String {
    try sourceBlock(in: sanitizedSwiftSource(source), startingWith: marker)
  }

  private func occurrenceCount(of needle: String, in source: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var searchStart = source.startIndex
    while let range = source.range(of: needle, range: searchStart..<source.endIndex) {
      count += 1
      searchStart = range.upperBound
    }
    return count
  }

  private func containsRegex(
    _ pattern: String,
    in source: String,
    options: NSRegularExpression.Options = []
  ) throws -> Bool {
    let expression = try NSRegularExpression(pattern: pattern, options: options)
    return expression.firstMatch(
      in: source,
      range: NSRange(source.startIndex..., in: source)
    ) != nil
  }

  private func makeSignedTestBundle(at root: URL, sandboxed: Bool) throws -> URL {
    let entitlementBody =
      sandboxed
        ? """
          <key>com.apple.security.app-sandbox</key><true/>
          <key>com.apple.security.files.user-selected.read-write</key><true/>
          """
        : ""
    return try makeSignedTestBundle(at: root, entitlementBody: entitlementBody)
  }

  private func makeSignedTestBundle(at root: URL, entitlementBody: String) throws -> URL {
    let fileManager = FileManager.default
    let appBundle = root.appendingPathComponent("DevScope.app", isDirectory: true)
    let contents = appBundle.appendingPathComponent("Contents", isDirectory: true)
    let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
    let resources = contents.appendingPathComponent("Resources", isDirectory: true)
    try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)

    try fileManager.copyItem(
      at: URL(fileURLWithPath: "/usr/bin/true"),
      to: macOS.appendingPathComponent("DevScope")
    )
    try Data("icon".utf8).write(to: resources.appendingPathComponent("AppIcon.icns"))
    for filename in ["LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md"] {
      try Data("test notice".utf8).write(to: resources.appendingPathComponent(filename))
    }
    try Data(
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>
        <key>NSPrivacyAccessedAPITypes</key><array><dict>
          <key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategoryUserDefaults</string>
          <key>NSPrivacyAccessedAPITypeReasons</key><array><string>CA92.1</string></array>
        </dict></array>
      </dict></plist>
      """.utf8
    ).write(to: resources.appendingPathComponent("PrivacyInfo.xcprivacy"))
    try Data(
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>com.example.DevScopeTests</string>
        <key>CFBundleShortVersionString</key><string>1.0</string>
        <key>CFBundleVersion</key><string>1</string>
        <key>CFBundleExecutable</key><string>DevScope</string>
      </dict></plist>
      """.utf8
    ).write(to: contents.appendingPathComponent("Info.plist"))

    let entitlements = root.appendingPathComponent("entitlements.plist")
    try Data(
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>\(entitlementBody)</dict></plist>
      """.utf8
    ).write(to: entitlements)

    let signing = Process()
    signing.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    signing.arguments = [
      "--force", "--sign", "-", "--entitlements", entitlements.path, appBundle.path,
    ]
    try signing.run()
    signing.waitUntilExit()
    XCTAssertEqual(signing.terminationStatus, 0)
    return appBundle
  }

  private func runValidation(
    for appBundle: URL,
    requiresSandbox: Bool,
    requiredArchitectures: String = ""
  ) throws -> (
    status: Int32, output: String
  ) {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [
      repositoryRoot.appendingPathComponent("script/validate_release_bundle.sh").path,
      appBundle.path,
    ]
    process.environment = ProcessInfo.processInfo.environment.merging([
      "DEVSCOPE_REQUIRE_SANDBOX": requiresSandbox ? "1" : "0",
      "DEVSCOPE_REQUIRE_GATEKEEPER": "0",
      "DEVSCOPE_REQUIRED_ARCHITECTURES": requiredArchitectures,
    ]) { _, replacement in replacement }
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }
}

private struct SwiftSourceLexicalSanitizer {
  private struct StringDelimiter {
    let hashCount: Int
    let quoteCount: Int

    var length: Int { hashCount + quoteCount }
  }

  private let characters: [Character]
  private var sanitized: [Character]
  private var index = 0

  init(source: String) {
    characters = Array(source)
    sanitized = Array(source)
  }

  mutating func sanitizedSource() -> String {
    scanCode()
    return String(sanitized)
  }

  private mutating func scanCode() {
    while index < characters.count {
      if hasPair("/", "/") {
        scanLineComment()
      } else if hasPair("/", "*") {
        scanBlockComment()
      } else if let delimiter = openingStringDelimiter() {
        scanString(delimiter)
      } else {
        index += 1
      }
    }
  }

  private mutating func scanString(_ delimiter: StringDelimiter) {
    eraseCurrentCharacters(delimiter.length)

    while index < characters.count {
      if isClosingStringDelimiter(delimiter) {
        eraseCurrentCharacters(delimiter.length)
        return
      }

      if let interpolationLength = interpolationStartLength(for: delimiter) {
        eraseCurrentCharacters(interpolationLength)
        scanInterpolation()
      } else if delimiter.hashCount == 0,
                characters[index] == "\\",
                index + 1 < characters.count {
        eraseCurrentCharacters(2)
      } else {
        eraseCurrentCharacter()
      }
    }
  }

  private mutating func scanInterpolation() {
    var parenthesisDepth = 1

    while index < characters.count, parenthesisDepth > 0 {
      if hasPair("/", "/") {
        scanLineComment()
      } else if hasPair("/", "*") {
        scanBlockComment()
      } else if let delimiter = openingStringDelimiter() {
        scanString(delimiter)
      } else if characters[index] == "(" {
        parenthesisDepth += 1
        eraseCurrentCharacter()
      } else if characters[index] == ")" {
        parenthesisDepth -= 1
        eraseCurrentCharacter()
      } else {
        eraseCurrentCharacter()
      }
    }
  }

  private mutating func scanLineComment() {
    while index < characters.count, !characters[index].isNewline {
      eraseCurrentCharacter()
    }
  }

  private mutating func scanBlockComment() {
    var depth = 1
    eraseCurrentCharacters(2)

    while index < characters.count, depth > 0 {
      if hasPair("/", "*") {
        depth += 1
        eraseCurrentCharacters(2)
      } else if hasPair("*", "/") {
        depth -= 1
        eraseCurrentCharacters(2)
      } else {
        eraseCurrentCharacter()
      }
    }
  }

  private func openingStringDelimiter() -> StringDelimiter? {
    var cursor = index
    while cursor < characters.count, characters[cursor] == "#" {
      cursor += 1
    }
    guard cursor < characters.count, characters[cursor] == "\"" else { return nil }
    let hasThreeQuotes = cursor + 2 < characters.count
      && characters[cursor + 1] == "\""
      && characters[cursor + 2] == "\""
    return StringDelimiter(
      hashCount: cursor - index,
      quoteCount: hasThreeQuotes ? 3 : 1
    )
  }

  private func isClosingStringDelimiter(_ delimiter: StringDelimiter) -> Bool {
    guard index + delimiter.length <= characters.count else { return false }
    for offset in 0..<delimiter.quoteCount where characters[index + offset] != "\"" {
      return false
    }
    for offset in 0..<delimiter.hashCount
    where characters[index + delimiter.quoteCount + offset] != "#" {
      return false
    }
    return true
  }

  private func interpolationStartLength(for delimiter: StringDelimiter) -> Int? {
    guard characters[index] == "\\" else { return nil }
    var cursor = index + 1
    for _ in 0..<delimiter.hashCount {
      guard cursor < characters.count, characters[cursor] == "#" else { return nil }
      cursor += 1
    }
    guard cursor < characters.count, characters[cursor] == "(" else { return nil }
    return cursor - index + 1
  }

  private func hasPair(_ first: Character, _ second: Character) -> Bool {
    index + 1 < characters.count
      && characters[index] == first
      && characters[index + 1] == second
  }

  private mutating func eraseCurrentCharacters(_ count: Int) {
    for _ in 0..<count where index < characters.count {
      eraseCurrentCharacter()
    }
  }

  private mutating func eraseCurrentCharacter() {
    if !characters[index].isNewline {
      sanitized[index] = " "
    }
    index += 1
  }
}
