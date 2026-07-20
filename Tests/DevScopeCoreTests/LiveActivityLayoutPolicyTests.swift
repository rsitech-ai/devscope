import XCTest

@testable import DevScopeCore

final class LiveActivityLayoutPolicyTests: XCTestCase {
  func testUpdatedPreferredHeightPreservesCurrentValueInConstrainedWorkspace() {
    XCTAssertEqual(
      LiveActivityLayoutPolicy.updatedPreferredHeight(
        currentPreferredHeight: 244,
        measuredHeight: 132,
        workspaceHeight: 500
      ),
      244
    )
  }

  func testUpdatedPreferredHeightAcceptsValidDragMeasurement() {
    XCTAssertEqual(
      LiveActivityLayoutPolicy.updatedPreferredHeight(
        currentPreferredHeight: 190,
        measuredHeight: 244,
        workspaceHeight: 820
      ),
      244
    )
  }

  func testUpdatedPreferredHeightIgnoresSubpixelMeasurementNoise() {
    XCTAssertEqual(
      LiveActivityLayoutPolicy.updatedPreferredHeight(
        currentPreferredHeight: 244,
        measuredHeight: 244.25,
        workspaceHeight: 820
      ),
      244
    )
  }

  func testHeightUsesDefaultAndClampsToSupportedRange() {
    XCTAssertEqual(
      LiveActivityLayoutPolicy.resolvedHeight(preferredHeight: .nan, workspaceHeight: 900), 190)
    XCTAssertEqual(
      LiveActivityLayoutPolicy.resolvedHeight(preferredHeight: 80, workspaceHeight: 900), 120)
    XCTAssertEqual(
      LiveActivityLayoutPolicy.resolvedHeight(preferredHeight: 420, workspaceHeight: 900), 360)
  }

  func testShortWorkspaceProtectsProcessArea() {
    XCTAssertEqual(
      LiveActivityLayoutPolicy.resolvedHeight(preferredHeight: 300, workspaceHeight: 500), 132)
    XCTAssertFalse(
      LiveActivityLayoutPolicy.shouldPersist(measuredHeight: 132, workspaceHeight: 500))
  }

  func testComfortableWorkspacePersistsDraggedHeight() {
    XCTAssertTrue(LiveActivityLayoutPolicy.shouldPersist(measuredHeight: 244, workspaceHeight: 820))
  }

  func testWidthChoosesWideStackedAndCompactModes() {
    XCTAssertEqual(LiveActivityLayoutPolicy.mode(availableWidth: 1_200), .wide)
    XCTAssertEqual(LiveActivityLayoutPolicy.mode(availableWidth: 820), .stacked)
    XCTAssertEqual(LiveActivityLayoutPolicy.mode(availableWidth: 620), .compact)
  }

  func testAttainableWorkspaceWidthChoosesCompactMode() {
    XCTAssertEqual(LiveActivityLayoutPolicy.mode(availableWidth: 780), .compact)
  }

  func testMinimumHeightUsesCondensedVerticalContent() {
    XCTAssertEqual(
      LiveActivityLayoutPolicy.verticalMode(availableHeight: 120, layoutMode: .compact),
      .condensed
    )
  }

  func testDefaultHeightCondensesStackedContentToAvoidClipping() {
    XCTAssertEqual(
      LiveActivityLayoutPolicy.verticalMode(availableHeight: 190, layoutMode: .stacked),
      .condensed
    )
    XCTAssertEqual(
      LiveActivityLayoutPolicy.verticalMode(availableHeight: 240, layoutMode: .stacked),
      .normal
    )
  }
}
