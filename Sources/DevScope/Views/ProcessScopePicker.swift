import DevScopeCore
import SwiftUI

struct ProcessScopePicker: View {
  @Binding var selection: ProcessActivityScope

  var body: some View {
    Picker("Activity scope", selection: $selection) {
      ForEach(ProcessActivityScope.allCases) { scope in
        Label(scope.title, systemImage: scope.symbolName)
          .tag(scope)
      }
    }
    .pickerStyle(.segmented)
    .controlSize(.small)
    .fixedSize()
    .accessibilityHint(
      "Switches between application families, flat OS processes, parent-child hierarchy, and project workflows."
    )
    .help("Choose how running OS processes are grouped")
  }
}
