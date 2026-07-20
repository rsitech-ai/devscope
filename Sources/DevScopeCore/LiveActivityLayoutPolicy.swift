import Foundation

public enum LiveActivityLayoutMode: Equatable, Sendable {
  case wide
  case stacked
  case compact
}

public enum LiveActivityVerticalMode: Equatable, Sendable {
  case normal
  case condensed
}

public enum LiveActivityLayoutPolicy {
  public static let defaultHeight = 190.0
  public static let minimumHeight = 120.0
  public static let maximumHeight = 360.0
  public static let minimumProcessHeight = 360.0
  private static let splitAllowance = 8.0
  private static let persistenceTolerance = 0.5
  private static let compactWidthThreshold = 800.0
  private static let condensedHeightThreshold = 160.0
  private static let stackedContentHeight = 225.0

  public static func resolvedHeight(preferredHeight: Double, workspaceHeight: Double) -> Double {
    let preferred = preferredHeight.isFinite ? preferredHeight : defaultHeight
    let clampedPreference = min(max(preferred, minimumHeight), maximumHeight)
    let available = max(minimumHeight, workspaceHeight - minimumProcessHeight - splitAllowance)
    return min(clampedPreference, available)
  }

  public static func shouldPersist(measuredHeight: Double, workspaceHeight: Double) -> Bool {
    measuredHeight >= minimumHeight
      && measuredHeight <= maximumHeight
      && workspaceHeight > minimumProcessHeight + measuredHeight + splitAllowance
  }

  public static func updatedPreferredHeight(
    currentPreferredHeight: Double,
    measuredHeight: Double,
    workspaceHeight: Double
  ) -> Double {
    guard shouldPersist(measuredHeight: measuredHeight, workspaceHeight: workspaceHeight) else {
      return currentPreferredHeight
    }
    guard
      !currentPreferredHeight.isFinite
        || abs(measuredHeight - currentPreferredHeight) >= persistenceTolerance
    else {
      return currentPreferredHeight
    }
    return measuredHeight
  }

  public static func mode(availableWidth: Double) -> LiveActivityLayoutMode {
    if availableWidth >= 1_000 { return .wide }
    if availableWidth >= compactWidthThreshold { return .stacked }
    return .compact
  }

  public static func verticalMode(
    availableHeight: Double,
    layoutMode: LiveActivityLayoutMode
  ) -> LiveActivityVerticalMode {
    if availableHeight < condensedHeightThreshold { return .condensed }
    if layoutMode == .stacked, availableHeight < stackedContentHeight { return .condensed }
    return .normal
  }
}
