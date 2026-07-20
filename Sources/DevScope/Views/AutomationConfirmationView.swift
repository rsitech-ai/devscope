import DevScopeCore
import SwiftUI

struct AutomationConfirmationView: View {
  @Environment(\.dismiss) private var dismiss
  let action: AutomationManagementAction
  let record: AutomationRecord
  let policy: AutomationConfirmationPolicy
  let confirm: () -> Void
  @State private var enteredLabel = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label(policy.title, systemImage: action.isDestructive ? "exclamationmark.triangle" : "checkmark.shield")
        .font(.title3.weight(.semibold))
        .foregroundStyle(action.isDestructive ? Color.orange : DevScopePalette.accent)

      Text(policy.consequence)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if let command = policy.displayedCommand {
        VStack(alignment: .leading, spacing: 6) {
          Text("Command")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Text(command)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
      }

      if let requiredLabel = policy.requiredLabel {
        VStack(alignment: .leading, spacing: 6) {
          Text("Enter \(requiredLabel) to confirm")
            .font(.callout.weight(.medium))
          TextField("Automation label", text: $enteredLabel)
            .textFieldStyle(.roundedBorder)
            .accessibilityHint("The Remove button is enabled only when this exactly matches the automation label.")
        }
      }

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(action.title, role: action.isDestructive ? .destructive : nil) {
          confirm()
          dismiss()
        }
        .disabled(!policy.isSatisfiedByLabel(enteredLabel))
        .keyboardShortcut(action.isDestructive ? nil : .defaultAction)
      }
    }
    .padding(20)
    .frame(width: 470)
    .accessibilityElement(children: .contain)
  }
}
