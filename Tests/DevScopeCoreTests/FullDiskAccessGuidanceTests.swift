import XCTest

@testable import DevScopeCore

final class FullDiskAccessGuidanceTests: XCTestCase {
  func testFullDiskAccessSettingsRouteStopsAfterAcceptedDeepLink() {
    var openedURL: URL?
    var fallbackCount = 0

    let didOpen = FullDiskAccessSettingsRoute.open(
      using: { url in
        openedURL = url
        return true
      },
      fallback: { fallbackCount += 1 }
    )

    XCTAssertTrue(didOpen)
    XCTAssertEqual(
      openedURL?.absoluteString,
      "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )
    XCTAssertEqual(fallbackCount, 0)
  }

  func testFullDiskAccessSettingsRouteFallsBackWhenDeepLinkIsRejected() {
    var fallbackCount = 0

    let didOpen = FullDiskAccessSettingsRoute.open(
      using: { _ in false },
      fallback: { fallbackCount += 1 }
    )

    XCTAssertFalse(didOpen)
    XCTAssertEqual(fallbackCount, 1)
  }

  func testFullDiskAccessSettingsRouteFallsBackWhenDeepLinkIsInvalid() {
    var openerCount = 0
    var fallbackCount = 0

    let didOpen = FullDiskAccessSettingsRoute.open(
      deepLink: "http://[",
      using: { _ in
        openerCount += 1
        return true
      },
      fallback: { fallbackCount += 1 }
    )

    XCTAssertFalse(didOpen)
    XCTAssertEqual(openerCount, 0)
    XCTAssertEqual(fallbackCount, 1)
  }

  func testFullInstalledBuildProvidesSixManualAddSteps() {
    let guidance = FullDiskAccessGuidance(
      appPath: "/Applications/DevScope.app",
      isSandboxed: false
    )

    XCTAssertTrue(guidance.isInstalledInApplications)
    XCTAssertEqual(guidance.title, "Add DevScope to Full Disk Access")
    XCTAssertEqual(guidance.steps.count, 6)
    XCTAssertTrue(guidance.steps[0].contains("Open Full Disk Access"))
    XCTAssertTrue(guidance.steps[1].contains("+"))
    XCTAssertTrue(guidance.steps[2].contains("/Applications/DevScope.app"))
    XCTAssertTrue(guidance.steps[3].contains("Enable"))
    XCTAssertTrue(guidance.steps[4].contains("reopen DevScope"))
    XCTAssertTrue(guidance.steps[5].contains("Check Access"))
  }

  func testFullBuildOutsideApplicationsWarnsBeforeManualStepsAndRetainsExactPath() {
    let appPath = "/Users/test/Downloads/DevScope Preview.app"
    let guidance = FullDiskAccessGuidance(appPath: appPath, isSandboxed: false)

    XCTAssertFalse(guidance.isInstalledInApplications)
    XCTAssertTrue(guidance.detail.contains("Install DevScope in Applications first"))
    XCTAssertEqual(guidance.steps.count, 6)
    XCTAssertTrue(guidance.steps[2].contains(appPath))
  }

  func testSandboxBuildRefusesToDescribeFullDiskAccessAsFix() {
    let guidance = FullDiskAccessGuidance(
      appPath: "/tmp/DevScope.app",
      isSandboxed: true
    )

    XCTAssertFalse(guidance.isInstalledInApplications)
    XCTAssertEqual(guidance.title, "This sandbox build cannot use Full Disk Access")
    XCTAssertTrue(guidance.detail.contains("Install the full DevScope build"))
    XCTAssertTrue(guidance.steps.isEmpty)
  }

  func testSandboxBuildOutsideApplicationsIsNamedAsValidationDevelopmentBuild() {
    let appPath = "/tmp/DevScope.app"
    let guidance = FullDiskAccessGuidance(appPath: appPath, isSandboxed: true)

    XCTAssertTrue(guidance.detail.contains("validation/development build"))
    XCTAssertTrue(guidance.detail.contains(appPath))
    XCTAssertTrue(guidance.detail.contains("App Sandbox"))
  }

  func testApplicationsPathDetectionRequiresDirectoryBoundary() {
    XCTAssertTrue(
      FullDiskAccessGuidance(
        appPath: "/Applications/Utilities/DevScope.app",
        isSandboxed: false
      ).isInstalledInApplications
    )
    XCTAssertFalse(
      FullDiskAccessGuidance(
        appPath: "/ApplicationsBackup/DevScope.app",
        isSandboxed: false
      ).isInstalledInApplications
    )
  }
}
