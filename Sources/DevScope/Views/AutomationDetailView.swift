import DevScopeCore
import SwiftUI

struct AutomationDetailView: View {
  let record: AutomationRecord?
  let iconStore: AutomationApplicationIconStore
  let decision: AutomationCapabilityDecision?
  let linkedProcesses: [ClassifiedDevProcess]
  let sourceHealth: AutomationSourceHealth?
  let backups: [AutomationBackup]
  let pendingOperation: AutomationPendingOperation?
  let operationResult: AutomationOperationResult?
  let perform: (AutomationManagementAction) -> Void
  let dismissResult: () -> Void
  let saveExport: (AutomationExportArtifact) -> Void
  let openLoginItemsSettings: () -> Void

  var body: some View {
    Group {
      if let record {
        VStack(spacing: 0) {
          AutomationManagementBar(
            record: record,
            decision: decision,
            backups: backups,
            pendingOperation: pendingOperation,
            operationResult: operationResult,
            perform: perform,
            dismissResult: dismissResult,
            saveExport: saveExport,
            openLoginItemsSettings: openLoginItemsSettings
          )

          Divider()

          ScrollView {
            VStack(alignment: .leading, spacing: 18) {
              header(record)
              healthSection(record)
              overview(record)
              trigger(record)
              command(record)
              currentProcesses
              source(record)
              validation(record)
              operationResultSection
              history(record)
            }
            .padding(16)
          }
        }
      } else {
        ContentUnavailableView(
          "Select an automation",
          systemImage: "gearshape.2",
          description: Text("Choose a definition to inspect its trigger, source, live processes, validation, and supported management controls.")
        )
      }
    }
  }

  private func header(_ record: AutomationRecord) -> some View {
    HStack(alignment: .top, spacing: 12) {
      AutomationIdentityView(record: record, store: iconStore, size: 48)
      VStack(alignment: .leading, spacing: 6) {
        Text(record.displayName)
          .font(.title3.weight(.semibold))
          .fixedSize(horizontal: false, vertical: true)
        Text(record.label)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        Label(record.state.displayTitle, systemImage: record.state.symbolName)
          .font(.caption.weight(.semibold))
          .foregroundStyle(record.state.tint)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  @ViewBuilder
  private func healthSection(_ record: AutomationRecord) -> some View {
    if let sourceHealth, sourceHealth.state != .healthy {
      AutomationInspectorSection(title: "Source Status", systemImage: "exclamationmark.triangle") {
        Text(sourceHealth.message ?? "\(record.sourceKind.displayTitle) could not be fully inspected.")
          .font(.callout)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func overview(_ record: AutomationRecord) -> some View {
    AutomationInspectorSection(title: "Overview", systemImage: "info.circle") {
      inspectorGrid([
        ("Kind", record.kind.displayTitle),
        ("State", record.state.displayTitle),
        ("Ownership", record.ownership.displayTitle),
        ("Enabled", record.enabledState.rawValue.capitalized),
        ("Loaded", record.loadState.rawValue.capitalized),
        ("Approval", record.approvalState.rawValue.capitalized),
      ])
      if let provider = record.providerBundleIdentifier {
        field("Owning Application", provider)
      }
      ForEach(record.evidence, id: \.self) { evidence in
        Label("\(evidence.source): \(evidence.detail)", systemImage: evidence.strength == .strong ? "checkmark.seal" : "questionmark.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func trigger(_ record: AutomationRecord) -> some View {
    AutomationInspectorSection(title: "Trigger", systemImage: "calendar.badge.clock") {
      field("Schedule", record.schedule.summary)
      ForEach(Array(record.schedule.triggers.enumerated()), id: \.offset) { _, trigger in
        Text(String(describing: trigger))
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func command(_ record: AutomationRecord) -> some View {
    AutomationInspectorSection(title: "Command", systemImage: "terminal") {
      field("Executable", record.executable ?? "Unavailable")
      if !record.arguments.isEmpty {
        field("Arguments", ProcessPresentation.redactedCommand(record.arguments.joined(separator: " ")))
      }
      field("Working Directory", record.workingDirectory ?? "Not configured")
      if !record.environment.isEmpty {
        field("Environment Keys", record.environment.keys.sorted().joined(separator: ", "))
      }
    }
  }

  private var currentProcesses: some View {
    AutomationInspectorSection(title: "Current Processes", systemImage: "waveform.path.ecg") {
      if linkedProcesses.isEmpty {
        Text("No strongly linked process is currently running.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        ForEach(linkedProcesses, id: \.process.pid) { item in
          HStack {
            Text(item.classification.displayName).lineLimit(1)
            Spacer()
            Text("PID \(item.process.pid)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private func source(_ record: AutomationRecord) -> some View {
    AutomationInspectorSection(title: "Source", systemImage: "doc.text") {
      field("Provider", record.sourceKind.displayTitle)
      field("Path", record.sourceURL?.path ?? "Not exposed by macOS")
      field("Checksum", record.sourceChecksum ?? "Unavailable")
    }
  }

  private func validation(_ record: AutomationRecord) -> some View {
    AutomationInspectorSection(title: "Validation", systemImage: "checkmark.shield") {
      if record.validationFindings.isEmpty {
        Label("No validation findings", systemImage: "checkmark.circle")
          .font(.callout)
          .foregroundStyle(.green)
      } else {
        ForEach(record.validationFindings, id: \.self) { finding in
          Label(finding, systemImage: "exclamationmark.circle")
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  @ViewBuilder
  private var operationResultSection: some View {
    if let operationResult {
      let result = AutomationManagementPresentation.result(operationResult)
      let recoveryHandles = recoveryHandles(from: operationResult)
      AutomationInspectorSection(
        title: "Operation Result",
        systemImage: result.isFailure ? "exclamationmark.circle" : "checkmark.circle"
      ) {
        VStack(alignment: .leading, spacing: 6) {
          Text(result.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          resultEvidence("Applied", values: result.appliedEvidence)
          resultEvidence("Verified", values: result.verificationEvidence)
          resultEvidence("Rollback", values: [result.rollbackEvidence])
          if let backup = result.backupEvidence {
            resultEvidence("Recovery Backup", values: [backup])
          }
          resultEvidence("File Mutation", values: result.mutationEvidence)
          if let recovery = result.recoveryGuidance {
            Text(recovery).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
          }
          if !recoveryHandles.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              Text("Recovery Locations")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
              ForEach(recoveryHandles, id: \.fileURL.path) { handle in
                VStack(alignment: .leading, spacing: 5) {
                  Text(handle.fileURL.path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                  HStack(spacing: 8) {
                    Button("Reveal in Finder") {
                      NSWorkspace.shared.activateFileViewerSelecting([handle.fileURL])
                    }
                    Button("Copy Path") {
                      copyRecoveryPath(handle.fileURL)
                    }
                  }
                  .controlSize(.small)
                }
              }
            }
            .padding(.top, 4)
          }
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
      }
    }
  }

  private func history(_ record: AutomationRecord) -> some View {
    AutomationInspectorSection(title: "History & Recovery", systemImage: "clock.arrow.circlepath") {
      let matching = backups.filter { $0.recordID == record.id }.sorted { $0.createdAt > $1.createdAt }
      if matching.isEmpty {
        Text("No verified restoration backup is available for this automation.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        ForEach(matching) { backup in
          let restoreAvailable = pendingOperation == nil
            && decision?.capabilities.contains(.restore) == true
          let restoreHelp = restoreAvailable
            ? "Restore the verified backup from \(backup.createdAt.formatted(date: .abbreviated, time: .shortened)) after conflict and integrity checks"
            : pendingOperation != nil
              ? "Wait for the current automation operation to finish"
              : decision?.reason ?? "DevScope cannot verify that this backup may be restored safely"
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(backup.createdAt.formatted(date: .abbreviated, time: .shortened))
              Text("Verified backup · \(backup.checksum.prefix(12))")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restore") { perform(.restore(backup.id)) }
              .disabled(!restoreAvailable)
              .help(restoreHelp)
              .accessibilityLabel("Restore backup from \(backup.createdAt.formatted(date: .abbreviated, time: .shortened))")
              .accessibilityHint(restoreHelp)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func resultEvidence(_ title: String, values: [String]) -> some View {
    if !values.isEmpty {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
        ForEach(Array(values.enumerated()), id: \.offset) { _, value in
          Text(value)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.top, 2)
    }
  }

  private func recoveryHandles(from result: AutomationOperationResult) -> [AutomationFileAuthorization] {
    var handles: [AutomationFileAuthorization] = []
    for evidence in [result.fileMutationEvidence, result.rollbackFileMutationEvidence].compactMap({ $0 }) {
      for handle in evidence.recoveryHandles where !handles.contains(where: {
        $0.fileURL.standardizedFileURL == handle.fileURL.standardizedFileURL
      }) {
        handles.append(handle)
      }
    }
    return handles
  }

  private func copyRecoveryPath(_ url: URL) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.standardizedFileURL.path, forType: .string)
  }

  private func inspectorGrid(_ entries: [(String, String)]) -> some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
      ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
        VStack(alignment: .leading, spacing: 2) {
          Text(entry.0).font(.caption2).foregroundStyle(.secondary)
          Text(entry.1)
            .font(.caption.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
      }
    }
  }

  private func field(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
      Text(value).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct AutomationManagementBar: View {
  let record: AutomationRecord
  let decision: AutomationCapabilityDecision?
  let backups: [AutomationBackup]
  let pendingOperation: AutomationPendingOperation?
  let operationResult: AutomationOperationResult?
  let perform: (AutomationManagementAction) -> Void
  let dismissResult: () -> Void
  let saveExport: (AutomationExportArtifact) -> Void
  let openLoginItemsSettings: () -> Void

  private var resolvedDecision: AutomationCapabilityDecision {
    decision ?? AutomationCapabilityDecision(
      capabilities: [],
      reason: "DevScope has not verified source ownership and path safety yet."
    )
  }

  private var actions: [AutomationManagementAction] {
    AutomationManagementPresentation.actions(
      decision: resolvedDecision,
      backups: backups,
      record: record
    )
  }

  private var pinnedActions: [AutomationManagementAction] {
    actions.filter { $0.placement == .pinned }
  }

  private var overflowActions: [AutomationManagementAction] {
    actions.filter { $0.placement == .overflow }
  }

  private var operationIsPending: Bool {
    pendingOperation != nil
  }

  private var pendingHelp: String {
    operationIsPending
      ? "Wait for the current automation operation to finish"
      : ""
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Label("Management", systemImage: "slider.horizontal.3")
          .font(.subheadline.weight(.semibold))
          .accessibilityAddTraits(.isHeader)

        Spacer(minLength: 8)

        if let pendingOperation, pendingOperation.recordID == record.id {
          HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("\(pendingOperation.operation.displayTitle) in progress")
              .font(.caption.weight(.medium))
              .lineLimit(1)
          }
          .foregroundStyle(.secondary)
        } else {
          Label(record.state.displayTitle, systemImage: record.state.symbolName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(record.state.tint)
            .lineLimit(1)
        }
      }

      if hasVisibleControl {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 112, maximum: 180), spacing: 8)],
          spacing: 8
        ) {
          ForEach(pinnedActions, id: \.self) { action in
            managementButton(action)
          }

          if !overflowActions.isEmpty {
            Menu {
              ForEach(overflowActions, id: \.self) { action in
                let helpText = AutomationManagementPresentation.helpText(
                  for: action,
                  record: record
                )
                Button(role: action.isDestructive ? .destructive : nil) {
                  perform(action)
                } label: {
                  Label(action.title, systemImage: action.systemImage)
                }
                .accessibilityHint(helpText)
                .help(helpText)
              }
            } label: {
              Label("More Actions", systemImage: "ellipsis.circle")
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            }
            .menuStyle(.button)
            .tint(.accentColor)
            .controlSize(.small)
            .disabled(operationIsPending)
            .accessibilityLabel("More automation actions")
            .accessibilityHint(
              operationIsPending
                ? pendingHelp
                : "Edit, duplicate, import, export, or remove this automation when available."
            )
            .help(operationIsPending ? pendingHelp : "More automation actions")
          }

          if record.sourceKind == .serviceManagement {
            Button(action: openLoginItemsSettings) {
              Label("System Settings", systemImage: "gearshape")
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.accentColor)
            .controlSize(.small)
            .disabled(operationIsPending)
            .accessibilityHint(
              "Opens Login Items & Extensions, where macOS manages this background item."
            )
            .help("Open Login Items & Extensions in System Settings")
          }
        }
      }

      if let reason = resolvedDecision.reason {
        Text(reason)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      } else if !hasVisibleControl {
        Text("No management operation is available for this source.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let operationResult {
        operationStatus(operationResult)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(.bar)
    .accessibilityIdentifier("automation-management-bar")
  }

  private var hasVisibleControl: Bool {
    !pinnedActions.isEmpty
      || !overflowActions.isEmpty
      || record.sourceKind == .serviceManagement
  }

  private func managementButton(_ action: AutomationManagementAction) -> some View {
    let helpText = AutomationManagementPresentation.helpText(for: action, record: record)
    return Button(role: action.isDestructive ? .destructive : nil) {
      perform(action)
    } label: {
      Label(action.title, systemImage: action.systemImage)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(AutomationManagementActionButtonStyle(tint: actionTint(action)))
    .controlSize(.small)
    .disabled(operationIsPending)
    .accessibilityHint(operationIsPending ? pendingHelp : helpText)
    .help(operationIsPending ? pendingHelp : helpText)
  }

  private func actionTint(_ action: AutomationManagementAction) -> Color {
    switch action.emphasis {
    case .neutral: .accentColor
    case .positive: .green
    case .caution: .orange
    case .destructive: .red
    }
  }

  private func operationStatus(_ operationResult: AutomationOperationResult) -> some View {
    let result = AutomationManagementPresentation.result(operationResult)
    return HStack(spacing: 8) {
      Label(
        result.title,
        systemImage: result.isFailure ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
      )
      .font(.caption.weight(.semibold))
      .foregroundStyle(result.isFailure ? Color.red : Color.green)
      .lineLimit(1)

      Spacer(minLength: 4)

      if let artifact = operationResult.exportArtifact {
        Button(artifact.isRedacted ? "Save Redacted" : "Save Unredacted") {
          saveExport(artifact)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityHint(
          "Opens a save panel. DevScope does not place export contents in operation status or logs."
        )
        .help("Save the completed automation export")
      }

      Button(action: dismissResult) {
        Image(systemName: "xmark.circle.fill")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .accessibilityLabel("Dismiss operation result")
      .help("Dismiss operation result")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
  }
}

private struct AutomationManagementActionButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  let tint: Color

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.caption.weight(.medium))
      .foregroundStyle(tint)
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .background(
        tint.opacity(configuration.isPressed ? 0.22 : 0.12),
        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(tint.opacity(isEnabled ? 0.34 : 0.16), lineWidth: 1)
      }
      .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .opacity(isEnabled ? 1 : 0.55)
  }
}

private struct AutomationInspectorSection<Content: View>: View {
  let title: String
  let systemImage: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(title, systemImage: systemImage).font(.subheadline.weight(.semibold))
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
