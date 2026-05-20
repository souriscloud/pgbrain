import SwiftUI

struct SettingsPlaceholderView: View {
    var body: some View {
        VStack(spacing: Tokens.Spacing.md) {
            Image(systemName: "gear")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("Settings")
                .font(.title2.weight(.semibold))
            Text("Restore-on-launch, theme, default SSL mode, and more land in a later iteration.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(Tokens.Spacing.xl)
        .frame(width: 460, height: 280)
    }
}
