import DevScopeCore
import Foundation

struct LaunchctlAutomationRuntimeStateProvider: LaunchdRuntimeStateProviding {
  static let maximumConcurrentPrintQueries = 4

  private let runner: any AutomationCommandRunning

  init(runner: any AutomationCommandRunning) {
    self.runner = runner
  }

  func states(
    for labels: [String],
    guiUID: uid_t
  ) async -> [String: LaunchdRuntimeState] {
    let domain = "gui/\(guiUID)"
    let enabledStates: [String: AutomationEnabledState]?
    do {
      let result = try await runner.run(
        AutomationCommand(
          executable: "/bin/launchctl",
          arguments: ["print-disabled", domain],
          environment: ["LC_ALL": "C"]
        ))
      enabledStates = result.status == 0 ? Self.parseEnabledStates(result.standardOutput) : nil
    } catch {
      enabledStates = nil
    }

    let uniqueLabels = Array(Set(labels)).sorted {
      $0.utf8.lexicographicallyPrecedes($1.utf8)
    }
    let stateForLabel: @Sendable (String) async -> (String, LaunchdRuntimeState) = { label in
      let loadState: AutomationLoadState
      do {
        let result = try await runner.run(
          AutomationCommand(
            executable: "/bin/launchctl",
            arguments: ["print", "\(domain)/\(label)"],
            environment: ["LC_ALL": "C"]
          ))
        switch LaunchctlServiceTargetClassifier.classify(
          result,
          label: label,
          guiUID: guiUID
        ) {
        case .loaded:
          loadState = .loaded
        case .absent:
          loadState = .unloaded
        case .unknown:
          loadState = .unknown
        }
      } catch {
        loadState = .unknown
      }
      let enabledState =
        enabledStates?[label]
        ?? (enabledStates == nil ? .unknown : .enabled)
      return (
        label,
        LaunchdRuntimeState(
          enabledState: enabledState,
          loadState: loadState
        )
      )
    }

    return await withTaskGroup(
      of: (String, LaunchdRuntimeState).self,
      returning: [String: LaunchdRuntimeState].self
    ) { group in
      let initialCount = min(Self.maximumConcurrentPrintQueries, uniqueLabels.count)
      for label in uniqueLabels.prefix(initialCount) {
        group.addTask {
          await stateForLabel(label)
        }
      }

      var states: [String: LaunchdRuntimeState] = [:]
      var nextIndex = initialCount
      while let (label, state) = await group.next() {
        states[label] = state
        if nextIndex < uniqueLabels.count {
          let nextLabel = uniqueLabels[nextIndex]
          nextIndex += 1
          group.addTask {
            await stateForLabel(nextLabel)
          }
        }
      }
      return states
    }
  }

  static func parseEnabledStates(
    _ data: Data
  ) -> [String: AutomationEnabledState]? {
    guard let output = String(data: data, encoding: .utf8) else { return nil }
    var states: [String: AutomationEnabledState] = [:]
    for rawLine in output.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard line.first == "\"",
        let closingQuote = line.dropFirst().firstIndex(of: "\"")
      else { continue }
      let label = String(line[line.index(after: line.startIndex)..<closingQuote])
      let suffix = line[line.index(after: closingQuote)...]
      guard let arrow = suffix.range(of: "=>") else { continue }
      let value = suffix[arrow.upperBound...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      let state: AutomationEnabledState
      switch value {
      case "disabled", "true":
        state = .disabled
      case "enabled", "false":
        state = .enabled
      default:
        continue
      }
      if let existing = states[label], existing != state { return nil }
      states[label] = state
    }
    return states
  }
}
