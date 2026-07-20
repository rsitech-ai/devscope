import DevScopeCore
import SwiftUI

struct AutomationRailView: View {
  @Binding var source: AutomationSourceFilter
  @Binding var state: AutomationState?
  @Binding var ownership: AutomationOwnershipFilter
  let counts: [String: Int]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        filterSection("Sources") {
          filterButton(
            "All",
            symbol: "tray.full",
            tint: DevScopePalette.accent,
            key: "source.all",
            selected: source == .all
          ) {
            source = .all
          }
          filterButton(
            "LaunchAgents",
            symbol: "bolt.horizontal",
            tint: AutomationVisualIdentity.fallback(for: .launchAgent).color,
            key: "source.launchd",
            selected: source == .launchd
          ) {
            source = .launchd
          }
          filterButton(
            "Login Items",
            symbol: "person.crop.circle.badge.clock",
            tint: AutomationVisualIdentity.fallback(for: .loginItem).color,
            key: "source.login",
            selected: source == .loginItems
          ) {
            source = .loginItems
          }
          filterButton(
            "Scheduled",
            symbol: "calendar.badge.clock",
            tint: AutomationVisualIdentity.fallback(for: .cron).color,
            key: "source.scheduled",
            selected: source == .scheduled
          ) {
            source = .scheduled
          }
        }

        filterSection("State") {
          filterButton(
            "All",
            symbol: "circle.grid.2x2",
            tint: DevScopePalette.accent,
            key: "state.all",
            selected: state == nil
          ) { state = nil }
          ForEach(AutomationState.allCases, id: \.self) { value in
            filterButton(
              value.displayTitle,
              symbol: value.symbolName,
              tint: AutomationVisualIdentity.state(for: value).color,
              key: "state.\(value.rawValue)",
              selected: state == value
            ) {
              state = value
            }
          }
        }

        filterSection("Ownership") {
          filterButton(
            "All",
            symbol: "person.2",
            tint: DevScopePalette.accent,
            key: "owner.all",
            selected: ownership == .all
          ) { ownership = .all }
          filterButton(
            "User",
            symbol: "person.crop.circle",
            tint: .blue,
            key: "owner.user",
            selected: ownership == .user
          ) { ownership = .user }
          filterButton(
            "Third Party",
            symbol: "shippingbox",
            tint: .purple,
            key: "owner.third",
            selected: ownership == .thirdParty
          ) { ownership = .thirdParty }
          filterButton(
            "Apple System",
            symbol: "apple.logo",
            tint: .secondary,
            key: "owner.apple",
            selected: ownership == .appleSystem
          ) { ownership = .appleSystem }
        }
      }
      .padding(12)
    }
    .background(.ultraThinMaterial)
    .accessibilityLabel("Automation filters")
  }

  private func filterSection<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title.uppercased())
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
      content()
    }
  }

  private func filterButton(
    _ title: String,
    symbol: String,
    tint: Color,
    key: String,
    selected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: symbol)
          .frame(width: 18)
          .foregroundStyle(tint)
        Text(title)
          .lineLimit(1)
        Spacer(minLength: 4)
        if let count = counts[key] {
          Text("\(count)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background(selected ? DevScopePalette.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityHint("Filters the automation inventory by \(title).")
    .help("Filter automations by \(title)")
  }
}
