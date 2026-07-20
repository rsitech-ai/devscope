import DevScopeCore
import SwiftUI

struct AutomationIdentityView: View {
  let record: AutomationRecord
  let store: AutomationApplicationIconStore
  let size: CGFloat
  @State private var resolvedIcon: ResolvedIcon?

  var body: some View {
    Group {
      if let icon = displayedIcon {
        Image(nsImage: icon)
          .resizable()
          .scaledToFit()
      } else {
        let fallback = AutomationVisualIdentity.fallback(for: record.kind)
        ZStack {
          RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(fallback.color.opacity(0.16))
          Image(systemName: fallback.symbolName)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(fallback.color)
        }
      }
    }
    .frame(width: size, height: size)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .task(id: cacheKey) {
      let requestedKey = cacheKey
      guard let icon = await store.resolve(record), !Task.isCancelled else {
        return
      }
      resolvedIcon = ResolvedIcon(key: requestedKey, image: icon)
    }
  }

  private var accessibilityLabel: String {
    if displayedIcon != nil {
      return record.providerBundleIdentifier.map { "Owning application \($0)" }
        ?? "Application icon for \(record.displayName)"
    }
    return AutomationVisualIdentity.fallback(for: record.kind).accessibilityTitle
  }

  private var cacheKey: AutomationApplicationIconKey {
    store.key(for: record)
  }

  private var displayedIcon: NSImage? {
    if resolvedIcon?.key == cacheKey {
      return resolvedIcon?.image
    }
    return store.icon(for: record)
  }
}

private struct ResolvedIcon {
  let key: AutomationApplicationIconKey
  let image: NSImage
}
