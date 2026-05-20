import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: Tokens.Spacing.md) {
            Spacer(minLength: 0)

            Image(systemName: "cylinder.split.1x2.fill")
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Tokens.Brand.primary, Tokens.Brand.primaryDim],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .padding(.bottom, Tokens.Spacing.sm)

            Text("pgBrain")
                .font(.system(size: 26, weight: .bold, design: .rounded))

            Text("Version \(AppInfo.version) (\(AppInfo.build))")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("Pro PostgreSQL for macOS")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()
                .padding(.horizontal, Tokens.Spacing.xl)

            VStack(spacing: Tokens.Spacing.xs) {
                Text("by **Souris.CLOUD**")
                Link("apps.souris.cloud", destination: URL(string: "https://apps.souris.cloud")!)
                    .font(.callout)
            }

            HStack(spacing: Tokens.Spacing.sm) {
                Link(destination: URL(string: "https://apps.souris.cloud")!) {
                    Label("Website", systemImage: "globe")
                }
                .buttonStyle(.bordered)

                Link(destination: URL(string: "https://github.com/sponsors")!) {
                    Label("Donate", systemImage: "heart.fill")
                }
                .buttonStyle(.bordered)
                .tint(Tokens.Brand.danger)
            }
            .padding(.top, Tokens.Spacing.xs)

            Spacer(minLength: 0)

            Text("© \(Calendar.current.component(.year, from: Date())) Souris.CLOUD")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, Tokens.Spacing.sm)
        }
        .padding(Tokens.Spacing.lg)
        .frame(width: Tokens.Window.aboutSize.width, height: Tokens.Window.aboutSize.height)
    }
}

#Preview {
    AboutView()
}
