import AppKit
import DevScopeCore
import ServiceManagement
import SwiftUI

struct AutomationWorkspaceView: View {
  @ObservedObject var store: AutomationStore
  let inventory: AutomationInventorySnapshot
  let processes: [ClassifiedDevProcess]
  let linksByProcessID: [Int32: [AutomationProcessLink]]
  @Binding var searchText: String
  @Binding var sourceFilter: AutomationSourceFilter
  @Binding var stateFilter: AutomationState?
  @Binding var ownershipFilter: AutomationOwnershipFilter
  let includeAppleSystemServices: Bool
  let documentPanel: AutomationDocumentPanel

  @State private var pendingConfirmation: PendingAutomationConfirmation?
  @State private var pendingEditor: PendingAutomationEditor?
  @State private var pendingImport: PendingAutomationImport?
  @State private var documentError: String?
  @State private var automationSort = AutomationTableSortState()
  @StateObject private var applicationIconStore = AutomationApplicationIconStore()

  private var filteredRecords: [AutomationRecord] {
    AutomationPresentation.filtered(
      inventory.records,
      source: sourceFilter,
      state: stateFilter,
      ownership: ownershipFilter,
      searchText: searchText,
      includeAppleSystemServices: includeAppleSystemServices
    )
  }

  private var eligibleRecords: [AutomationRecord] {
    inventory.records.filter { includeAppleSystemServices || $0.ownership != .appleSystem }
  }

  private var inventoryCount: AutomationInventoryCountPresentation {
    AutomationPresentation.inventoryCount(
      visibleCount: filteredRecords.count,
      eligibleCount: eligibleRecords.count,
      totalCount: inventory.records.count
    )
  }

  private var selectedRecord: AutomationRecord? {
    guard let id = store.selectedRecordID else { return nil }
    return inventory.records.first { $0.id == id }
  }

  private var tableRows: [AutomationTableRow] {
    let linkCounts = Dictionary(
      grouping: linksByProcessID.values.flatMap { $0 },
      by: \.recordID
    ).mapValues(\.count)
    return automationSort.sorted(filteredRecords.map {
      AutomationTableRow(record: $0, linkedProcessCount: linkCounts[$0.id, default: 0])
    })
  }

  var body: some View {
    VStack(spacing: 10) {
      controlStrip
      healthBar
      GeometryReader { proxy in
        let pane = AutomationWorkspaceLayoutPolicy.constraints(availableWidth: proxy.size.width)

        HSplitView {
          AutomationRailView(
            source: $sourceFilter,
            state: $stateFilter,
            ownership: $ownershipFilter,
            counts: railCounts
          )
          .frame(minWidth: pane.railMinimum, idealWidth: pane.railPreferred)

          AutomationTableView(
            rows: tableRows,
            sourceHealthHasFailure: hasSourceFailure,
            selection: $store.selectedRecordID,
            sort: $automationSort,
            iconStore: applicationIconStore
          )
          .frame(minWidth: pane.tableMinimum, idealWidth: pane.tablePreferred)
          .layoutPriority(pane.tablePriority)
          .transaction { $0.animation = nil }

          AutomationDetailView(
            record: selectedRecord,
            iconStore: applicationIconStore,
            decision: selectedRecord.flatMap { store.capabilitySnapshot.decisionsByRecordID[$0.id] },
            linkedProcesses: selectedRecord.map(linkedProcesses(for:)) ?? [],
            sourceHealth: selectedRecord.flatMap { inventory.health[$0.sourceKind] },
            backups: store.backups,
            pendingOperation: store.pendingOperation,
            operationResult: store.operationResultRecordID == selectedRecord?.id ? store.operationResult : nil,
            perform: begin,
            dismissResult: store.dismissOperationResult,
            saveExport: saveExport,
            openLoginItemsSettings: openLoginItemsSettings
          )
          .frame(minWidth: pane.detailMinimum, idealWidth: pane.detailPreferred)
          .layoutPriority(pane.detailPriority)
        }
        .softPanel(cornerRadius: 18)
      }
    }
    .sheet(item: $pendingEditor) { pending in
        AutomationEditorView(
          record: pending.record,
          purpose: pending.purpose,
          duplicateDestination: { store.duplicateDestination(for: pending.record, label: $0) }
        ) { payload in
          let operation: AutomationOperation = pending.purpose == .edit ? .edit(payload) : .duplicate(payload)
          store.perform(operation, record: pending.record, expectedChecksum: pending.record.sourceChecksum, linkedProcesses: linkedProcesses(for: pending.record))
        }
    }
    .sheet(item: $pendingConfirmation) { pending in
      if let policy = AutomationManagementPresentation.confirmation(for: pending.action, record: pending.record, backups: pending.backups) {
        AutomationConfirmationView(action: pending.action, record: pending.record, policy: policy) {
          performConfirmed(pending.action, record: pending.record)
        }
      }
    }
    .sheet(item: $pendingImport) { pending in
      AutomationImportPreviewView(pending: pending) {
        store.perform(
          .importRecord(AutomationImportPayload(
            destination: pending.preview.destination,
            data: pending.document.data,
            expectedKind: pending.preview.expectedKind,
            expectedDestinationChecksum: pending.record.sourceChecksum
          )),
          record: pending.record,
          expectedChecksum: pending.record.sourceChecksum,
          linkedProcesses: linkedProcesses(for: pending.record)
        )
      }
    }
    .alert("Document operation failed", isPresented: Binding(
      get: { documentError != nil },
      set: { if !$0 { documentError = nil } }
    )) {
      Button("OK", role: .cancel) { documentError = nil }
    } message: {
      Text(documentError ?? "The document could not be opened or saved.")
    }
    .onChange(of: filteredRecords.map(\.id)) { _, ids in
      store.selectedRecordID = AutomationPresentation.resolvedSelection(
        current: store.selectedRecordID,
        visibleIDs: ids
      )
    }
  }

  private var controlStrip: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
      TextField("Search label, command, path, schedule, or owning app", text: $searchText)
        .textFieldStyle(.plain)
      if !searchText.isEmpty {
        Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
          .buttonStyle(.plain)
          .accessibilityLabel("Clear automation search")
          .help("Clear automation search")
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 1) {
        Text(inventoryCount.primaryText)
          .font(.callout.monospacedDigit())
        if let contextText = inventoryCount.contextText {
          Text(contextText)
            .font(.caption2.monospacedDigit())
        }
      }
      .foregroundStyle(.secondary)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(inventoryCount.accessibilityLabel)
      .help(inventoryCount.accessibilityLabel)
      if store.isRefreshing {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Refreshing automation inventory")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(.bar, in: RoundedRectangle(cornerRadius: 12))
  }

  @ViewBuilder private var healthBar: some View {
    let unhealthy = inventory.health.values.filter { $0.state != .healthy }.sorted { $0.kind.rawValue < $1.kind.rawValue }
    if !unhealthy.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(unhealthy, id: \.kind) { health in
          Label("\(health.kind.displayTitle): \(health.message ?? health.state.displayTitle)", systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(health.state == .permissionRequired ? .orange : .secondary)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
  }

  private var hasSourceFailure: Bool {
    inventory.health.values.contains { $0.state != .healthy }
  }

  private var railCounts: [String: Int] {
    let records = eligibleRecords
    var counts = ["source.all": records.count, "state.all": records.count, "owner.all": records.count]
    counts["source.launchd"] = records.filter { $0.sourceKind == .launchAgent || $0.sourceKind == .launchDaemon }.count
    counts["source.login"] = records.filter { $0.sourceKind == .serviceManagement || $0.sourceKind == .legacyLoginItem }.count
    counts["source.scheduled"] = records.filter { $0.sourceKind == .crontab }.count
    for state in AutomationState.allCases { counts["state.\(state.rawValue)"] = records.filter { $0.state == state }.count }
    counts["owner.user"] = records.filter { $0.ownership == .user }.count
    counts["owner.third"] = records.filter { $0.ownership == .thirdPartySystem || $0.ownership == .managed }.count
    counts["owner.apple"] = records.filter { $0.ownership == .appleSystem }.count
    return counts
  }

  private func linkedProcesses(for record: AutomationRecord) -> [ClassifiedDevProcess] {
    let identities = AutomationPresentation.uniquelyStrongLinkedProcessIdentities(
      for: record.id,
      linksByProcessID: linksByProcessID
    )
    return processes.filter { identities.contains(ProcessIdentity(process: $0.process)) }
  }

  private func begin(_ action: AutomationManagementAction) {
    guard let record = selectedRecord else { return }
    switch action {
    case .edit: pendingEditor = PendingAutomationEditor(record: record, purpose: .edit)
    case .duplicate: pendingEditor = PendingAutomationEditor(record: record, purpose: .duplicate)
    case .importRecord:
      beginImport(record)
    default:
      if AutomationManagementPresentation.confirmation(for: action, record: record, backups: store.backups) != nil {
        pendingConfirmation = PendingAutomationConfirmation(
          record: record,
          action: action,
          backups: store.backups.filter { $0.recordID == record.id }
        )
      } else {
        performConfirmed(action, record: record)
      }
    }
  }

  private func performConfirmed(_ action: AutomationManagementAction, record: AutomationRecord) {
    guard let operation = AutomationManagementPresentation.confirmedOperation(for: action, record: record) else { return }
    store.perform(operation, record: record, expectedChecksum: record.sourceChecksum, linkedProcesses: linkedProcesses(for: record))
  }

  private func openLoginItemsSettings() {
    if #available(macOS 13.0, *) {
      SMAppService.openSystemSettingsLoginItems()
    } else if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
      NSWorkspace.shared.open(url)
    }
  }

  private func beginImport(_ record: AutomationRecord) {
    do {
      guard let document = try documentPanel.openImport() else { return }
      guard let destination = store.importDestination(
        for: record,
        suggestedFilename: document.sourceURL.lastPathComponent
      ) else {
        documentError = "DevScope could not resolve an approved import destination for this automation source."
        return
      }
      pendingImport = PendingAutomationImport(
        document: document,
        record: record,
        preview: AutomationImportPresentation(
          data: document.data,
          expectedRecord: record,
          destination: destination
        )
      )
    } catch {
      documentError = ProcessPresentation.redactedCommand(error.localizedDescription)
    }
  }

  private func saveExport(_ artifact: AutomationExportArtifact) {
    do {
      _ = try documentPanel.save(artifact)
    } catch {
      documentError = "The export could not be saved. \(ProcessPresentation.redactedCommand(error.localizedDescription))"
    }
  }

}

private struct PendingAutomationConfirmation: Identifiable {
  let record: AutomationRecord
  let action: AutomationManagementAction
  let backups: [AutomationBackup]
  var id: String { "\(record.id.rawValue)-\(action.id)" }
}

private struct PendingAutomationEditor: Identifiable {
  let record: AutomationRecord
  let purpose: AutomationEditorView.Purpose
  var id: String { "\(record.id.rawValue)-\(purpose.id)" }
}

private struct PendingAutomationImport: Identifiable {
  let document: AutomationImportedDocument
  let record: AutomationRecord
  let preview: AutomationImportPresentation
  var id: UUID { document.id }
}

private struct AutomationImportPreviewView: View {
  @Environment(\.dismiss) private var dismiss
  let pending: PendingAutomationImport
  let apply: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Preview Import").font(.title2.weight(.semibold))
      LabeledContent("File", value: pending.document.sourceURL.lastPathComponent)
      LabeledContent("Expected Kind", value: pending.preview.expectedKind.displayTitle)
      LabeledContent("Detected Content", value: pending.preview.summary)
      LabeledContent("Replaces", value: pending.preview.targetLabel)
      LabeledContent("Target Ownership", value: pending.preview.targetOwnership)
      VStack(alignment: .leading, spacing: 4) {
        Text("Approved Destination").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        Text(pending.preview.destination.path)
          .font(.callout.monospaced())
          .textSelection(.enabled)
      }
      if let message = pending.preview.validationMessage {
        Label(message, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
      } else {
        Label(pending.preview.consequence, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
        Label("The transaction manager will revalidate kind, destination, ownership, and checksum before replacing the selected definition.", systemImage: "checkmark.shield")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Replace Definition", role: .destructive) {
          apply()
          dismiss()
        }
        .disabled(!pending.preview.canApply)
        .help(pending.preview.canApply
          ? "Replace the selected checksum-bound automation definition after manager validation"
          : pending.preview.validationMessage ?? "The import cannot be applied")
        .accessibilityHint("Replaces the selected automation source; it does not create an unrelated new definition.")
      }
    }
    .padding(20)
    .frame(width: 560)
  }
}

extension AutomationEditorView.Purpose: Identifiable {
  var id: String { self == .edit ? "edit" : "duplicate" }
}

extension AutomationManagementAction: Identifiable {
  public var id: String {
    switch self {
    case .restore(let id): "restore-\(id.rawValue.uuidString)"
    default: title
    }
  }
}

extension AutomationKind {
  var displayTitle: String {
    switch self {
    case .launchAgent: "LaunchAgent"
    case .launchDaemon: "LaunchDaemon"
    case .loginItem: "Login Item"
    case .backgroundItem: "Background Item"
    case .cron: "Scheduled"
    }
  }
  var symbolName: String {
    AutomationVisualIdentity.fallback(for: self).symbolName
  }
}

extension AutomationSourceKind {
  var displayTitle: String {
    switch self {
    case .launchAgent: "User LaunchAgents"
    case .launchDaemon: "LaunchDaemons"
    case .serviceManagement: "Background Items"
    case .legacyLoginItem: "Login Items"
    case .crontab: "Current-user crontab"
    }
  }
}

extension AutomationState {
  var displayTitle: String {
    AutomationStateLabelPresentation(state: self).title
  }
  var symbolName: String {
    AutomationVisualIdentity.state(for: self).symbolName
  }
  var tint: Color {
    AutomationVisualIdentity.state(for: self).color
  }
}

extension AutomationOwnership {
  var displayTitle: String {
    switch self {
    case .user: "User"
    case .thirdPartySystem: "Third Party"
    case .appleSystem: "Apple System"
    case .managed: "Managed"
    }
  }
}

extension AutomationSourceHealthState {
  var displayTitle: String {
    switch self {
    case .healthy: "Healthy"
    case .partial: "Partial"
    case .failed: "Failed"
    case .permissionRequired: "Permission required"
    }
  }
}

extension AutomationOperation {
  var displayTitle: String {
    switch self {
    case .startNow, .confirmedRunToCompletion: "Start Now"
    case .stopCurrentRun: "Stop Current Run"
    case .enable: "Enable"
    case .disable: "Disable"
    case .disableAndStop: "Disable and Stop"
    case .edit: "Edit"
    case .duplicate: "Duplicate"
    case .importRecord: "Import"
    case .exportRecord: "Export"
    case .remove: "Remove"
    case .restore: "Restore"
    }
  }
}
