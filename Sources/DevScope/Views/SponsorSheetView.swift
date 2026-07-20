import AppKit
import SwiftUI

struct SponsorSheetView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var didCopySupportURL = false

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top, spacing: 14) {
        ZStack {
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.pink.opacity(0.16))
          Image(systemName: "cup.and.saucer.fill")
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(.pink)
        }
        .frame(width: 62, height: 62)
        .devScopeGlass(cornerRadius: 16)

        VStack(alignment: .leading, spacing: 5) {
          Text("Buy Me a Coffee")
            .font(.title2.weight(.semibold))
          Text("Support DevScope development, open-source maintenance, and faster macOS polish.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      VStack(alignment: .leading, spacing: 10) {
        SponsorPoint(symbolName: "bolt.fill", title: "Realtime polish", detail: "Support work on lower-latency process metrics and smoother charts.")
        SponsorPoint(symbolName: "brain.head.profile", title: "Apple Intelligence", detail: "Fund safer local naming and process insight features.")
        SponsorPoint(symbolName: "checkmark.seal", title: "Open source quality", detail: "Keep tests, docs, and release hardening part of every feature.")
      }

      HStack {
        Button("Close") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)

        Spacer()

        Button {
          copySupportURL()
        } label: {
          Label(didCopySupportURL ? "Copied" : "Copy Link", systemImage: didCopySupportURL ? "checkmark" : "doc.on.doc")
        }
        .accessibilityLabel("Copy Buy Me a Coffee link")
        .accessibilityHint("Copies the DevScope support link.")

        Button {
          openSponsorURL()
        } label: {
          Label("Open Buy Me a Coffee", systemImage: "safari")
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel("Open Buy Me a Coffee")
        .accessibilityHint("Opens the DevScope Buy Me a Coffee support page.")
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(22)
    .frame(width: 480)
  }

  private func openSponsorURL() {
    NSWorkspace.shared.open(DevScopeSupport.buyMeACoffeeURL)
  }

  private func copySupportURL() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(DevScopeSupport.buyMeACoffeeURLString, forType: .string)
    didCopySupportURL = true
  }
}

private struct SponsorPoint: View {
  let symbolName: String
  let title: String
  let detail: String

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: symbolName)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(DevScopePalette.accent)
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.callout.weight(.semibold))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
