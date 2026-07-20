import DevScopeCore
import SwiftUI

enum DevScopePalette {
  static let accent = Color(nsColor: .controlAccentColor)
  static let backgroundTop = Color(nsColor: .windowBackgroundColor)
  static let backgroundBottom = Color(nsColor: .underPageBackgroundColor)

  static func color(for kind: DevRuntimeKind) -> Color {
    switch kind {
    case .javascript:
      .yellow
    case .python:
      .green
    case .swift:
      .blue
    case .rust:
      .orange
    case .go:
      .cyan
    case .flutter:
      .blue
    case .java:
      .red
    case .database:
      .purple
    case .container:
      .mint
    case .webServer:
      .indigo
    case .ai:
      .pink
    case .mcp:
      .indigo
    case .browser:
      .teal
    case .macApp:
      .blue
    case .backgroundAgent:
      .gray
    case .systemService:
      .brown
    case .shell:
      .yellow
    case .other:
      .secondary
    }
  }

  static func color(for automationKind: AutomationKind) -> Color {
    AutomationVisualIdentity.fallback(for: automationKind).color
  }
}

extension AutomationColorToken {
  var color: Color {
    switch self {
    case .accent:
      DevScopePalette.accent
    case .blue:
      .blue
    case .indigo:
      .indigo
    case .cyan:
      .cyan
    case .purple:
      .purple
    case .green:
      .green
    case .orange:
      .orange
    case .red:
      .red
    case .secondary:
      .secondary
    }
  }
}

extension AutomationVisualIdentity {
  var color: Color { colorToken.color }
}

struct DevScopeGlassContainer<Content: View>: View {
  private let spacing: CGFloat
  private let content: Content

  init(spacing: CGFloat = 18, @ViewBuilder content: () -> Content) {
    self.spacing = spacing
    self.content = content()
  }

  var body: some View {
    if #available(macOS 26.0, *) {
      GlassEffectContainer(spacing: spacing) {
        content
      }
    } else {
      content
    }
  }
}

extension View {
  @ViewBuilder
  func devScopeGlass(cornerRadius: CGFloat = 14, interactive: Bool = false) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

    if #available(macOS 26.0, *) {
      if interactive {
        self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
      } else {
        self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
      }
    } else {
      self
        .background(.regularMaterial, in: shape)
        .overlay {
          shape.stroke(.white.opacity(0.14), lineWidth: 1)
        }
    }
  }

  func softPanel(cornerRadius: CGFloat = 14) -> some View {
    background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .stroke(.white.opacity(0.12), lineWidth: 1)
      }
  }
}
