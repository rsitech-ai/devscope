import CoreGraphics

struct AutomationWorkspacePaneConstraints: Equatable, Sendable {
  let railMinimum: CGFloat
  let railPreferred: CGFloat
  let tableMinimum: CGFloat
  let tablePreferred: CGFloat
  let detailMinimum: CGFloat
  let detailPreferred: CGFloat
  let tablePriority: Double
  let detailPriority: Double

  var minimumTotal: CGFloat {
    railMinimum + tableMinimum + detailMinimum
  }
}

enum AutomationWorkspaceLayoutPolicy {
  static func constraints(availableWidth: CGFloat) -> AutomationWorkspacePaneConstraints {
    let usableWidth = max(0, availableWidth - 18)
    let minimumScale = min(1, usableWidth / 780)
    let railMinimum = 150 * minimumScale
    let tableMinimum = 360 * minimumScale
    let detailMinimum = 270 * minimumScale

    let railPreferred: CGFloat
    let tablePreferred: CGFloat
    let detailPreferred: CGFloat
    if usableWidth < 810 {
      railPreferred = railMinimum
      tablePreferred = tableMinimum
      detailPreferred = detailMinimum
    } else {
      railPreferred = min(280, max(170, usableWidth * 0.18))
      detailPreferred = min(440, max(280, usableWidth * 0.30))
      tablePreferred = usableWidth - railPreferred - detailPreferred
    }

    return AutomationWorkspacePaneConstraints(
      railMinimum: railMinimum,
      railPreferred: railPreferred,
      tableMinimum: tableMinimum,
      tablePreferred: tablePreferred,
      detailMinimum: detailMinimum,
      detailPreferred: detailPreferred,
      tablePriority: 1,
      detailPriority: 1
    )
  }
}
