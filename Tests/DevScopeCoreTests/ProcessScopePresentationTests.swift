import XCTest

@testable import DevScopeCore

final class ProcessScopePresentationTests: XCTestCase {
  func testGroupsHostAppNestedHelperAndExternalWorkerWithoutOverlap() throws {
    let items = [
      classified(
        pid: 100,
        parentPID: 1,
        executable: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
        cpu: 1,
        memory: 100
      ),
      classified(
        pid: 101,
        parentPID: 100,
        executable:
          "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Helpers/Codex (Renderer).app/Contents/MacOS/Codex (Renderer)",
        cpu: 2,
        memory: 200
      ),
      classified(
        pid: 102,
        parentPID: 101,
        executable: "/usr/local/bin/npm",
        command: "npm run dev",
        cpu: 3,
        memory: 300
      ),
      classified(
        pid: 200,
        parentPID: 1,
        executable: "/usr/bin/python3",
        command: "python3 unrelated.py",
        cpu: 50,
        memory: 5_000
      ),
    ]

    let family = try XCTUnwrap(
      ProcessScopePresentation.applicationFamilies(for: items).first {
        $0.bundlePath == "/Applications/ChatGPT.app"
      }
    )

    XCTAssertEqual(family.title, "ChatGPT / Codex")
    XCTAssertEqual(family.applicationCount, 1)
    XCTAssertEqual(family.helperCount, 1)
    XCTAssertEqual(family.workerCount, 1)
    XCTAssertEqual(family.processIDs, [100, 101, 102])
    XCTAssertEqual(family.members.map(\.role), [.application, .helper, .worker])
    XCTAssertEqual(family.members.map(\.depth), [0, 1, 2])
    XCTAssertEqual(family.totalCPU, 6)
    XCTAssertEqual(family.totalMemoryBytes, 600)
  }

  func testApplicationFamiliesAreDeterministicAcrossInputOrder() {
    let items = [
      classified(
        pid: 10,
        parentPID: 1,
        executable: "/Applications/Alpha.app/Contents/MacOS/Alpha"
      ),
      classified(
        pid: 11,
        parentPID: 10,
        executable: "/Applications/Alpha.app/Contents/Helpers/worker"
      ),
      classified(
        pid: 20,
        parentPID: 1,
        executable: "/Applications/Beta.app/Contents/MacOS/Beta"
      ),
    ]

    XCTAssertEqual(
      ProcessScopePresentation.applicationFamilies(for: items),
      ProcessScopePresentation.applicationFamilies(for: items.reversed())
    )
  }

  func testApplicationOwnershipTerminatesAcrossMalformedParentCycle() throws {
    let items = [
      classified(
        pid: 300,
        parentPID: 301,
        executable: "/Applications/Cycle.app/Contents/Helpers/cycle-helper"
      ),
      classified(
        pid: 301,
        parentPID: 300,
        executable: "/usr/local/bin/cycle-worker"
      ),
      classified(
        pid: 302,
        parentPID: 999,
        executable: "/usr/local/bin/orphan"
      ),
    ]

    let family = try XCTUnwrap(
      ProcessScopePresentation.applicationFamilies(for: items).first {
        $0.bundlePath == "/Applications/Cycle.app"
      }
    )

    XCTAssertEqual(family.processIDs, [300, 301])
    XCTAssertEqual(family.applicationCount, 0)
    XCTAssertEqual(family.helperCount, 1)
    XCTAssertEqual(family.workerCount, 1)
    XCTAssertFalse(family.processIDs.contains(302))
  }

  func testDoesNotTruncateAppExtensionsIntoFakeApplicationBundles() {
    let item = classified(
      pid: 350,
      parentPID: 1,
      executable:
        "/System/Library/ExtensionKit/Extensions/AccessibilitySettingsSearchExtension.appex/Contents/MacOS/AccessibilitySettingsSearchExtension"
    )

    XCTAssertTrue(ProcessScopePresentation.applicationFamilies(for: [item]).isEmpty)
  }

  func testActivityScopeUsesExplicitUserFacingLabels() {
    XCTAssertEqual(ProcessActivityScope.applications.title, "Applications")
    XCTAssertEqual(ProcessActivityScope.processes.title, "Processes")
    XCTAssertEqual(ProcessActivityScope.hierarchy.title, "Hierarchy")
    XCTAssertEqual(ProcessActivityScope.workflows.title, "Workflows")
  }

  func testHierarchySearchRetainsMatchingProcessAncestorPath() {
    let items = [
      classified(pid: 100, parentPID: 1, executable: "/usr/bin/zsh"),
      classified(pid: 101, parentPID: 100, executable: "/usr/local/bin/node"),
      classified(
        pid: 102,
        parentPID: 101,
        executable: "/usr/local/bin/node",
        command: "node worker.js"
      ),
      classified(pid: 200, parentPID: 1, executable: "/usr/bin/python3"),
    ]

    let filtered = ProcessScopePresentation.hierarchy(for: items, searchText: "worker.js")

    XCTAssertEqual(filtered.map(\.id), [100])
    XCTAssertEqual(filtered[0].children.map(\.id), [101])
    XCTAssertEqual(filtered[0].children[0].children.map(\.id), [102])
    XCTAssertEqual(ProcessScopePresentation.flattened(filtered).map(\.id), [100, 101, 102])
  }

  func testHierarchyKeepsMissingParentsAsRootsAndOrdersSiblingsByPID() {
    let items = [
      classified(pid: 12, parentPID: 10, executable: "/usr/bin/child-b"),
      classified(pid: 11, parentPID: 10, executable: "/usr/bin/child-a"),
      classified(pid: 10, parentPID: 999, executable: "/usr/bin/root"),
    ]

    let hierarchy = ProcessScopePresentation.hierarchy(for: items)

    XCTAssertEqual(hierarchy.map(\.id), [10])
    XCTAssertEqual(hierarchy[0].children.map(\.id), [11, 12])
  }

  func testHierarchyBreaksCyclesAndRepresentsEveryPIDOnce() {
    let items = [
      classified(pid: 30, parentPID: 32, executable: "/usr/bin/thirty"),
      classified(pid: 31, parentPID: 30, executable: "/usr/bin/thirty-one"),
      classified(pid: 32, parentPID: 31, executable: "/usr/bin/thirty-two"),
      classified(pid: 40, parentPID: 1, executable: "/usr/bin/forty"),
    ]

    let hierarchy = ProcessScopePresentation.hierarchy(for: items)
    let processIDs = ProcessScopePresentation.flattened(hierarchy).map(\.id)

    XCTAssertEqual(processIDs.sorted(), [30, 31, 32, 40])
    XCTAssertEqual(Set(processIDs).count, processIDs.count)
  }

  private func classified(
    pid: Int32,
    parentPID: Int32,
    executable: String,
    command: String? = nil,
    cpu: Double = 0,
    memory: Int64 = 0
  ) -> ClassifiedDevProcess {
    ClassifiedDevProcess(
      process: DevProcess(
        pid: pid,
        parentPID: parentPID,
        executable: executable,
        command: command ?? executable,
        resourceUsage: DevProcessResourceUsage(
          cpuPercent: cpu,
          residentMemoryBytes: memory,
          elapsedTime: "00:01"
        )
      ),
      classification: DevProcessClassification(
        kind: .macApp,
        displayName: URL(fileURLWithPath: executable).lastPathComponent,
        projectHint: nil
      )
    )
  }
}
