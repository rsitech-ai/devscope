import AppKit
import DevScopeCore
import SwiftUI

struct ProcessCommandBar: View {
  let process: ClassifiedDevProcess
  let displayName: String
  let isEnded: Bool
  let actionDecision: ProcessActionDecision
  let isFavorite: Bool
  let isWatched: Bool
  let favoriteAction: () -> Void
  let watchAction: () -> Void
  let exportAction: () -> Void
  let copyCommandAction: () -> Void
  let openFolderAction: () -> Void
  let killAction: () -> Void
  let killTreeAction: () -> Void
  let forceKillAction: () -> Void
  let forceKillTreeAction: () -> Void

  private var terminatePresentation: ProcessActionControlPresentation {
    ProcessActionPresentation.control(.terminate, isEnded: isEnded, actionDecision: actionDecision)
  }

  private var terminateTreePresentation: ProcessActionControlPresentation {
    ProcessActionPresentation.control(.terminateTree, isEnded: isEnded, actionDecision: actionDecision)
  }

  private var forceOptionsPresentation: ProcessActionControlPresentation {
    ProcessActionPresentation.control(.forceOptions, isEnded: isEnded, actionDecision: actionDecision)
  }

  var body: some View {
    HStack(spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "terminal")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(.secondary)

        VStack(alignment: .leading, spacing: 2) {
          Text(displayName)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
          Text("Command")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
      .frame(width: 132, alignment: .leading)

      Text(process.process.command)
        .font(.system(.caption, design: .monospaced).weight(.semibold))
        .textSelection(.enabled)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

      HStack(spacing: 6) {
        CommandBarButton(
          title: isFavorite ? "Unfavorite" : "Favorite",
          symbolName: isFavorite ? "star.fill" : "star",
          tint: .yellow,
          action: favoriteAction
        )
        CommandBarButton(
          title: isWatched ? "Unwatch" : "Watch",
          symbolName: isWatched ? "eye.fill" : "eye",
          tint: .cyan,
          action: watchAction
        )
        CommandBarButton(title: "Export", symbolName: "square.and.arrow.up", tint: .blue, action: exportAction)
        CommandBarButton(title: "Copy", symbolName: "doc.on.doc", tint: .blue, action: copyCommandAction)
        CommandBarButton(
          title: "Folder",
          symbolName: "folder",
          tint: .blue,
          isDisabled: process.process.currentDirectory == nil,
          action: openFolderAction
        )
      }

      Divider()
        .frame(height: 28)

      Menu {
        Button(role: .destructive, action: killAction) {
          Label("Terminate Process…", systemImage: "xmark.circle")
        }
        .disabled(terminatePresentation.isDisabled)
        .accessibilityHint(terminatePresentation.accessibilityHint)
        .help(terminatePresentation.help)

        Button(role: .destructive, action: killTreeAction) {
          Label("Terminate Process Tree…", systemImage: "point.3.connected.trianglepath.dotted")
        }
        .disabled(terminateTreePresentation.isDisabled)
        .accessibilityHint(terminateTreePresentation.accessibilityHint)
        .help(terminateTreePresentation.help)

        Divider()

        Button(role: .destructive, action: forceKillAction) {
          Label("Force Kill Process…", systemImage: "bolt.fill")
        }
        .disabled(forceOptionsPresentation.isDisabled)
        .accessibilityHint(forceOptionsPresentation.accessibilityHint)
        .help(forceOptionsPresentation.help)

        Button(role: .destructive, action: forceKillTreeAction) {
          Label("Force Kill Process Tree…", systemImage: "bolt.horizontal.fill")
        }
        .disabled(forceOptionsPresentation.isDisabled)
        .accessibilityHint(forceOptionsPresentation.accessibilityHint)
        .help(forceOptionsPresentation.help)
      } label: {
        Label("Terminate…", systemImage: "xmark.circle")
      }
      .menuStyle(.button)
      .tint(.red)
      .controlSize(.small)
      .disabled(
        terminatePresentation.isDisabled &&
        terminateTreePresentation.isDisabled &&
        forceOptionsPresentation.isDisabled
      )
      .accessibilityLabel("Process termination options")
      .accessibilityHint("Choose whether to terminate this process, its process tree, or use a force-kill option.")
      .help("Process termination options")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(.bar, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(.white.opacity(0.10), lineWidth: 1)
    }
    .transition(.move(edge: .top).combined(with: .opacity))
  }
}

private struct CommandBarButton: View {
  let title: String
  let symbolName: String
  let tint: Color
  var isDisabled = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: symbolName)
        .labelStyle(.iconOnly)
        .frame(width: 24)
    }
    .buttonStyle(.bordered)
    .tint(tint)
    .controlSize(.small)
    .disabled(isDisabled)
    .accessibilityLabel(title)
    .help(title)
  }
}
