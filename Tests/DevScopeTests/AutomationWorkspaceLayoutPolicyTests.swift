import XCTest

@testable import DevScope

final class AutomationWorkspaceLayoutPolicyTests: XCTestCase {
  func testConstraintsFitEverySupportedWindowWidth() {
    for width in [1080.0, 1280.0, 1728.0] {
      let value = AutomationWorkspaceLayoutPolicy.constraints(availableWidth: width)

      XCTAssertLessThanOrEqual(value.minimumTotal, width)
      XCTAssertGreaterThan(value.tableMinimum, value.railMinimum)
      XCTAssertEqual(value.detailPriority, value.tablePriority)
    }
  }

  func testWiderWindowsIncreasePreferenceWithoutMakingPanelsFixed() {
    let compact = AutomationWorkspaceLayoutPolicy.constraints(availableWidth: 1080)
    let wide = AutomationWorkspaceLayoutPolicy.constraints(availableWidth: 1728)

    XCTAssertGreaterThan(wide.tablePreferred, compact.tablePreferred)
    XCTAssertNotEqual(compact.railPreferred, wide.railPreferred)
    XCTAssertNotEqual(compact.detailPreferred, wide.detailPreferred)
  }

  func testMinimumsProtectSplitterAllowanceAcrossBoundaryWidths() {
    let widths: [CGFloat] = [0, 17, 18, 19, 797, 798, 799]

    for width in widths {
      let value = AutomationWorkspaceLayoutPolicy.constraints(availableWidth: width)
      let usableWidth = max(0, width - 18)
      let expectedMinimumTotal = min(usableWidth, 780)

      XCTAssertEqual(value.minimumTotal, expectedMinimumTotal, accuracy: 0.000_001)
      XCTAssertLessThanOrEqual(value.minimumTotal, usableWidth + 0.000_001)
      for minimum in [value.railMinimum, value.tableMinimum, value.detailMinimum] {
        XCTAssertTrue(minimum.isFinite, "minimum must be finite at width \(width)")
        XCTAssertGreaterThanOrEqual(minimum, 0, "minimum must be nonnegative at width \(width)")
      }
    }
  }

  func testPreferencesRemainValidDuringTransientBoundaryWidths() {
    let widths: [CGFloat] = [0, 1, 17, 18, 19, 400, 797, 798, 808, 828, 1080]

    for width in widths {
      let value = AutomationWorkspaceLayoutPolicy.constraints(availableWidth: width)
      let usableWidth = max(0, width - 18)
      let preferences = [value.railPreferred, value.tablePreferred, value.detailPreferred]
      let minimums = [value.railMinimum, value.tableMinimum, value.detailMinimum]

      XCTAssertLessThanOrEqual(
        preferences.reduce(0, +),
        usableWidth + 0.000_001,
        "preferred widths must fit at width \(width)"
      )
      for (preferred, minimum) in zip(preferences, minimums) {
        XCTAssertTrue(preferred.isFinite, "preference must be finite at width \(width)")
        XCTAssertGreaterThanOrEqual(preferred, 0, "preference must be nonnegative at width \(width)")
        XCTAssertGreaterThanOrEqual(
          preferred + 0.000_001,
          minimum,
          "preference must not undercut its minimum at width \(width)"
        )
      }
    }
  }

  func testMinimumScalingUsesUsableWidthUntilItCaps() {
    for width: CGFloat in [19, 797] {
      let value = AutomationWorkspaceLayoutPolicy.constraints(availableWidth: width)
      let expectedScale = (width - 18) / 780

      XCTAssertEqual(value.railMinimum, 150 * expectedScale, accuracy: 0.000_001)
      XCTAssertEqual(value.tableMinimum, 360 * expectedScale, accuracy: 0.000_001)
      XCTAssertEqual(value.detailMinimum, 270 * expectedScale, accuracy: 0.000_001)
    }

    for width: CGFloat in [798, 799, 1728] {
      let value = AutomationWorkspaceLayoutPolicy.constraints(availableWidth: width)

      XCTAssertEqual(value.railMinimum, 150, accuracy: 0.000_001)
      XCTAssertEqual(value.tableMinimum, 360, accuracy: 0.000_001)
      XCTAssertEqual(value.detailMinimum, 270, accuracy: 0.000_001)
      XCTAssertEqual(value.minimumTotal, 780, accuracy: 0.000_001)
    }
  }
}
