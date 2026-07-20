import AppKit
import DevScopeCore
import SwiftUI

@MainActor
final class LiveNotchPresentationModel: ObservableObject {
  @Published private(set) var state = LiveNotchPresentationState.collapsed

  func publish(_ state: LiveNotchPresentationState) {
    self.state = state
  }
}

@MainActor
struct LiveNotchPanelPresenter: NSViewRepresentable {
  let stats: ProcessDashboardStats
  let metricHistory: [DevProcessMetricSample]
  let selectedScope: String
  let isRefreshing: Bool
  let lastRefresh: Date?
  let refreshAction: @MainActor () -> Void
  let displayName: @MainActor (ClassifiedDevProcess) -> String

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    context.coordinator.update(from: self)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.update(from: self)
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.close()
  }

  @MainActor
  final class Coordinator {
    private static let screenTopInset: CGFloat = 3
    private static let visibleFrameLift: CGFloat = 6
    private static let activationBandHeight: CGFloat = 12
    private var panel: NSPanel?
    private var isClosed = false
    private var isApplyingPresentationState = false
    private let presentationModel = LiveNotchPresentationModel()

    func update(from presenter: LiveNotchPanelPresenter) {
      guard !isClosed else {
        return
      }

      let createdPanel = panel == nil
      let panel = panel ?? makePanel()
      self.panel = panel

      let rootView = DynamicIslandStatusView(
        stats: presenter.stats,
        metricHistory: presenter.metricHistory,
        selectedScope: presenter.selectedScope,
        isRefreshing: presenter.isRefreshing,
        lastRefresh: presenter.lastRefresh,
        refreshAction: presenter.refreshAction,
        displayName: presenter.displayName,
        presentationModel: presentationModel
      )

      if let hostingView = panel.contentView as? LiveNotchHostingView {
        hostingView.rootView = rootView
      } else {
        let hostingView = LiveNotchHostingView(rootView: rootView)
        hostingView.onPointerEvent = { [weak self] pointerEvent in
          self?.handle(pointerEvent)
        }
        panel.contentView = hostingView
      }

      if createdPanel || !panel.isVisible {
        panel.orderFrontRegardless()
      }
    }

    func close() {
      guard !isClosed else {
        return
      }

      if let hostingView = panel?.contentView as? LiveNotchHostingView {
        hostingView.tearDown()
      }
      applyPresentationState(.collapsed)
      isClosed = true
      panel?.orderOut(nil)
      panel?.close()
      panel = nil
    }

    private func makePanel() -> NSPanel {
      let panel = NSPanel(
        contentRect: frame(for: .collapsed),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
      )
      panel.backgroundColor = .clear
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
      panel.acceptsMouseMovedEvents = true
      panel.hasShadow = false
      panel.hidesOnDeactivate = false
      panel.ignoresMouseEvents = false
      panel.isMovable = false
      panel.isOpaque = false
      panel.isReleasedWhenClosed = false
      panel.level = .statusBar
      panel.title = "DevScope Live Notch"
      panel.titleVisibility = .hidden
      panel.titlebarAppearsTransparent = true
      return panel
    }

    private func handle(_ pointerEvent: LiveNotchPointerEvent) {
      guard !isClosed, !isApplyingPresentationState, let panel else {
        return
      }

      let pointerLocation = pointerEvent.screenLocation
      guard panel.frame.contains(pointerLocation) else {
        applyPresentationState(.collapsed)
        return
      }

      switch (presentationModel.state, pointerEvent.kind) {
      case (.collapsed, .entered), (.collapsed, .moved):
        applyPresentationState(.compact)
      case (.compact, .moved) where !isInActivationBand(pointerLocation, panelFrame: panel.frame):
        applyPresentationState(.expanded)
      case (.expanded, .moved) where isInActivationBand(pointerLocation, panelFrame: panel.frame):
        applyPresentationState(.compact)
      default:
        break
      }
    }

    private func applyPresentationState(_ state: LiveNotchPresentationState) {
      guard !isClosed, let panel else {
        return
      }

      let frame = frame(for: state)
      guard presentationModel.state != state || !panel.frame.nearlyEquals(frame) else {
        return
      }

      isApplyingPresentationState = true
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0
        context.allowsImplicitAnimation = false
        panel.setFrame(frame, display: true)
      }
      presentationModel.publish(state)
      isApplyingPresentationState = false

      let pointerLocation = NSEvent.mouseLocation
      if state != .collapsed, !frame.contains(pointerLocation) {
        applyPresentationState(.collapsed)
      }
    }

    private func isInActivationBand(_ pointerLocation: NSPoint, panelFrame: NSRect) -> Bool {
      pointerLocation.y >= panelFrame.maxY - Self.activationBandHeight
    }

    private func frame(for state: LiveNotchPresentationState) -> NSRect {
      let screen = NSScreen.main ?? NSScreen.screens.first
      let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
      let visibleFrame = screen?.visibleFrame ?? screenFrame
      let panelSize = state.panelSize
      let x = screenFrame.midX - panelSize.width / 2
      let topEdge = min(screenFrame.maxY - Self.screenTopInset, visibleFrame.maxY + Self.visibleFrameLift)
      let y = topEdge - panelSize.height
      return NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height)
    }
  }
}

@MainActor
private final class LiveNotchHostingView: NSHostingView<DynamicIslandStatusView> {
  var onPointerEvent: ((LiveNotchPointerEvent) -> Void)?
  private var pointerTrackingArea: NSTrackingArea?
  private var isTornDown = false

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    guard !isTornDown, pointerTrackingArea == nil else {
      return
    }

    let trackingArea = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(trackingArea)
    pointerTrackingArea = trackingArea
  }

  func tearDown() {
    isTornDown = true
    onPointerEvent = nil
    if let pointerTrackingArea {
      removeTrackingArea(pointerTrackingArea)
      self.pointerTrackingArea = nil
    }
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    onPointerEvent?(LiveNotchPointerEvent(kind: .entered, screenLocation: NSEvent.mouseLocation))
  }

  override func mouseMoved(with event: NSEvent) {
    super.mouseMoved(with: event)
    onPointerEvent?(LiveNotchPointerEvent(kind: .moved, screenLocation: NSEvent.mouseLocation))
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    onPointerEvent?(LiveNotchPointerEvent(kind: .exited, screenLocation: NSEvent.mouseLocation))
  }
}

private struct LiveNotchPointerEvent {
  enum Kind {
    case entered
    case exited
    case moved
  }

  let kind: Kind
  let screenLocation: NSPoint
}

private extension NSRect {
  func nearlyEquals(_ other: NSRect) -> Bool {
    abs(origin.x - other.origin.x) < 0.5 &&
      abs(origin.y - other.origin.y) < 0.5 &&
      abs(size.width - other.size.width) < 0.5 &&
      abs(size.height - other.size.height) < 0.5
  }
}

private extension LiveNotchPresentationState {
  var panelSize: NSSize {
    switch self {
    case .collapsed:
      NSSize(width: 128, height: 18)
    case .compact:
      NSSize(width: 640, height: 52)
    case .expanded:
      NSSize(width: 780, height: 178)
    }
  }

}
