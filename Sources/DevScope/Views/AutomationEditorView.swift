import DevScopeCore
import Foundation
import SwiftUI

struct AutomationEditorView: View {
  enum Purpose {
    case edit
    case duplicate
  }

  @Environment(\.dismiss) private var dismiss
  let record: AutomationRecord
  let purpose: Purpose
  let duplicateDestination: (String) -> URL?
  let apply: (AutomationEditPayload) -> Void

  @State private var label: String
  @State private var executable: String
  @State private var argumentsText: String
  @State private var environmentText: String
  @State private var scheduleText: String
  @State private var workingDirectory: String
  @State private var rawText = ""
  @State private var usesRawRepresentation = false

  init(
    record: AutomationRecord,
    purpose: Purpose,
    duplicateDestination: @escaping (String) -> URL?,
    apply: @escaping (AutomationEditPayload) -> Void
  ) {
    self.record = record
    self.purpose = purpose
    self.duplicateDestination = duplicateDestination
    self.apply = apply
    _label = State(initialValue: purpose == .duplicate ? "\(record.label).copy" : record.label)
    _executable = State(initialValue: record.executable ?? "")
    _argumentsText = State(initialValue: record.arguments.joined(separator: "\n"))
    _environmentText = State(initialValue: AutomationEditorPresentation.environmentText(for: record.environment))
    _scheduleText = State(initialValue: AutomationEditorPresentation.scheduleText(for: record.schedule))
    _workingDirectory = State(initialValue: record.workingDirectory ?? "")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(purpose == .edit ? "Edit Automation" : "Duplicate Automation")
            .font(.title2.weight(.semibold))
          Text("Changes are validated again by the transaction manager before any source is written.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Toggle("Advanced Raw", isOn: $usesRawRepresentation)
          .toggleStyle(.switch)
      }

      if usesRawRepresentation {
        HSplitView {
          reviewedFields
            .frame(minWidth: 360, idealWidth: 430)
          VStack(alignment: .leading, spacing: 8) {
            Text("Complete Raw Source")
              .font(.headline)
            Text("Paste the complete property list or current-user crontab. The reviewed fields must describe the same command, environment, schedule, and working directory.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $rawText)
              .font(.system(.callout, design: .monospaced))
              .frame(minWidth: 360, minHeight: 360)
              .overlay {
                RoundedRectangle(cornerRadius: 8).stroke(.quaternary)
              }
              .accessibilityLabel("Complete raw automation source")
          }
          .padding(12)
        }
      } else {
        reviewedFields
      }

      if let validationMessage {
        Label(validationMessage, systemImage: "exclamationmark.circle")
          .font(.caption)
          .foregroundStyle(.orange)
      }

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(purpose == .edit ? "Apply" : "Create Copy") {
          guard let payload else { return }
          apply(payload)
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .disabled(payload == nil)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(minWidth: usesRawRepresentation ? 900 : 680, minHeight: 620)
  }

  private var reviewedFields: some View {
    Form {
      TextField("Label", text: $label)
      TextField("Executable", text: $executable)
      TextField("Working Directory", text: $workingDirectory)
      editorField("Arguments (one per line)", text: $argumentsText, minHeight: 80)
      editorField("Environment (one KEY=VALUE per line)", text: $environmentText, minHeight: 80)
      editorField(
        "Schedule (run-at-load, keep-alive, interval SECONDS, calendar DESCRIPTION, cron EXPRESSION, or on-demand)",
        text: $scheduleText,
        minHeight: 80
      )
    }
    .formStyle(.grouped)
  }

  private func editorField(
    _ title: String,
    text: Binding<String>,
    minHeight: CGFloat
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      TextEditor(text: text)
        .font(.system(.callout, design: .monospaced))
        .frame(minHeight: minHeight)
    }
  }

  private var payload: AutomationEditPayload? {
    let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedExecutable = executable.trimmingCharacters(in: .whitespacesAndNewlines)
    guard validationMessage == nil,
          let environment,
          let schedule else { return nil }
    return AutomationEditPayload(
      label: trimmedLabel,
      executable: trimmedExecutable,
      arguments: argumentsText.split(whereSeparator: \.isNewline).map(String.init),
      environment: environment,
      workingDirectory: workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
      schedule: schedule,
      rawRepresentation: rawData,
      destination: resolvedDestination,
      expectedDestinationChecksum: purpose == .duplicate ? nil : record.sourceChecksum
    )
  }

  private var validationMessage: String? {
    guard let environment else {
      return "Environment entries must use unique non-empty KEY=VALUE lines."
    }
    guard let schedule else {
      return "Enter at least one valid schedule line using the documented schedule syntax."
    }
    return AutomationEditorPresentation.validationMessage(
      record: record,
      purposeIsDuplicate: purpose == .duplicate,
      label: label.trimmingCharacters(in: .whitespacesAndNewlines),
      executable: executable.trimmingCharacters(in: .whitespacesAndNewlines),
      arguments: argumentsText.split(whereSeparator: \.isNewline).map(String.init),
      environment: environment,
      schedule: schedule,
      usesRawRepresentation: usesRawRepresentation,
      rawData: rawData,
      duplicateDestination: resolvedDestination,
      workingDirectory: workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    )
  }

  private var environment: [String: String]? {
    AutomationEditorPresentation.environment(from: environmentText)
  }

  private var schedule: AutomationSchedule? {
    AutomationEditorPresentation.schedule(from: scheduleText)
  }

  private var rawData: Data? {
    usesRawRepresentation ? Data(rawText.utf8) : nil
  }

  private var resolvedDestination: URL? {
    purpose == .duplicate
      ? duplicateDestination(label.trimmingCharacters(in: .whitespacesAndNewlines))
      : record.sourceURL
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
