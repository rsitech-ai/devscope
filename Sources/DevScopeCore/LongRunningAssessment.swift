import Foundation

public enum LongRunningAssessment {
  public static func isLongRunning(
    _ usage: DevProcessResourceUsage?,
    threshold: TimeInterval = 14_400
  ) -> Bool {
    guard let usage else {
      return false
    }

    let seconds = ProcessPresentation.elapsedSeconds(usage.elapsedTime)
    return seconds >= 0 && Double(seconds) >= threshold
  }
}
