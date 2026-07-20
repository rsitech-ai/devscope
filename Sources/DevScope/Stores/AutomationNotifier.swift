import DevScopeCore
import Foundation
import UserNotifications

protocol AutomationNotificationCenterClient: Sendable {
  func requestAuthorization() async throws -> Bool
  func deliver(_ content: AutomationNotificationContent) async throws
}

enum AutomationNotificationDeliveryState: Equatable, Sendable {
  case notRequested
  case requesting
  case enabled
  case denied
  case authorizationFailed
  case deliveryFailed
}

struct SystemAutomationNotificationCenter: AutomationNotificationCenterClient {
  func requestAuthorization() async throws -> Bool {
    try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
  }

  func deliver(_ content: AutomationNotificationContent) async throws {
    let notificationContent = UNMutableNotificationContent()
    notificationContent.title = content.title
    notificationContent.body = content.body
    notificationContent.sound = .default
    try await UNUserNotificationCenter.current().add(UNNotificationRequest(
      identifier: UUID().uuidString,
      content: notificationContent,
      trigger: nil
    ))
  }
}

@MainActor
final class AutomationNotifier: ObservableObject {
  typealias Sleep = @Sendable (Duration) async throws -> Void

  @Published private(set) var preferences: AutomationNotificationPreferences
  @Published private(set) var deliveryState: AutomationNotificationDeliveryState = .notRequested

  private let notificationCenter: any AutomationNotificationCenterClient
  private let retryDelay: Duration
  private let sleep: Sleep
  private var policy: AutomationNotificationPolicy
  private var deliveryTask: Task<Void, Never>?
  private var deliveryGeneration: UInt64 = 0

  init(
    notificationCenter: any AutomationNotificationCenterClient = SystemAutomationNotificationCenter(),
    maximumRetainedEventIdentities: Int = 256,
    retryDelay: Duration = .seconds(2),
    sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
  ) {
    self.notificationCenter = notificationCenter
    self.retryDelay = max(.zero, retryDelay)
    self.sleep = sleep
    policy = AutomationNotificationPolicy(
      maximumRetainedEventIdentities: maximumRetainedEventIdentities
    )
    preferences = policy.preferences
  }

  func setPreference(
    _ preference: AutomationNotificationPreference,
    isEnabled: Bool
  ) async {
    let action = policy.setPreference(preference, isEnabled: isEnabled)
    preferences = policy.preferences
    guard action == .requestAuthorization else { return }
    await requestAuthorization()
  }

  func synchronize(_ persisted: AutomationNotificationPreferences) async {
    var shouldRequest = false
    for preference in AutomationNotificationPreference.allCases {
      if policy.setPreference(preference, isEnabled: persisted[preference]) == .requestAuthorization {
        shouldRequest = true
      }
    }
    preferences = policy.preferences
    if shouldRequest {
      await requestAuthorization()
    }
  }

  private func requestAuthorization() async {
    deliveryState = .requesting
    do {
      let granted = try await notificationCenter.requestAuthorization()
      policy.recordAuthorizationResult(granted: granted)
      deliveryState = granted ? .enabled : .denied
    } catch {
      policy.recordAuthorizationResult(granted: false)
      deliveryState = .authorizationFailed
    }
  }

  func consume(_ events: [AutomationEvent]) async {
    deliveryGeneration &+= 1
    let generation = deliveryGeneration
    let priorDelivery = deliveryTask
    let task = Task { @MainActor [weak self] in
      await priorDelivery?.value
      await self?.consumeBatch(events)
    }
    deliveryTask = task
    await task.value
    if deliveryGeneration == generation {
      deliveryTask = nil
    }
  }

  private func consumeBatch(_ events: [AutomationEvent]) async {
    var attemptedDelivery = false
    var deliveryFailed = false
    for event in events {
      guard let content = policy.notification(for: event) else { continue }
      attemptedDelivery = true
      if !(await deliverWithOneRetry(event, content: content)) {
        deliveryFailed = true
      }
    }
    if attemptedDelivery {
      if deliveryFailed {
        deliveryState = .deliveryFailed
      } else if deliveryState != .deliveryFailed {
        deliveryState = .enabled
      }
    }
  }

  private func deliverWithOneRetry(
    _ event: AutomationEvent,
    content: AutomationNotificationContent
  ) async -> Bool {
    do {
      try await notificationCenter.deliver(content)
      return true
    } catch {
      policy.recordDeliveryFailure(for: event)
    }

    do {
      try await sleep(retryDelay)
      guard let retryContent = policy.notification(for: event) else { return false }
      try await notificationCenter.deliver(retryContent)
      return true
    } catch {
      policy.recordDeliveryFailure(for: event)
      return false
    }
  }
}
