import SwiftUI

struct WelcomeView: View {
    var body: some View {
        HStack(spacing: 0) {
            // Left brand pane — JetBrains-style hero column.
            brandPane
                .frame(width: 280)
                .frame(maxHeight: .infinity)
                .background(
                    LinearGradient(
                        colors: [Tokens.Brand.primary, Tokens.Brand.primaryDim],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // Right pane — connection list (empty in iter-1).
            connectionPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: Tokens.Window.welcomeSize.width,
               minHeight: Tokens.Window.welcomeSize.height)
    }

    private var brandPane: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
            HStack(spacing: Tokens.Spacing.sm) {
                Image(systemName: "cylinder.split.1x2.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)
                Text("pgBrain")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            Text("Pro PostgreSQL for macOS")
                .font(.title3.weight(.medium))
                .foregroundStyle(.white.opacity(0.92))
            Text("Connect to your databases, edit data, run queries with inline results, and move data between schemas with confidence.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text("Version \(AppInfo.version)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                Text("by Souris.CLOUD")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(Tokens.Spacing.xl)
    }

    private var connectionPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Connections")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    // Wired up in iter-2 (Connection editor sheet).
                } label: {
                    Label("New Connection", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Tokens.Brand.primary)
                .disabled(true)
                .help("Connection editor lands in iter-2")
            }
            .padding(.horizontal, Tokens.Spacing.lg)
            .padding(.top, Tokens.Spacing.lg)
            .padding(.bottom, Tokens.Spacing.md)

            Divider()

            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Tokens.Spacing.md) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("No connections yet")
                .font(.headline)
            Text("Add your first PostgreSQL connection to begin.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(Tokens.Spacing.xl)
    }
}

#Preview {
    WelcomeView()
}
