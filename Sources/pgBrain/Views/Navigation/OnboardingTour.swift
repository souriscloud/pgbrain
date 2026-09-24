import SwiftUI

// MARK: - Onboarding tour
//
// A short guided tour of a connection window, shown the first time a window
// finishes loading its schema and any time from Help ▸ Show Tour. Each step
// dims the window except the element it talks about and explains it in a card
// beside it. Elements opt in with `.onboardingAnchor(_:)`; a step whose
// element isn't on screen falls back to a centred card, so the tour never
// points at nothing.

enum OnboardingAnchor: Hashable {
    case sidebar, schemaPicker, tabs, grid, tableHeader, newTab, database, statusFooter
}

struct OnboardingStep: Identifiable {
    let id: Int
    let title: String
    let message: String
    let systemImage: String
    let anchor: OnboardingAnchor?
    /// Keyboard shortcuts worth learning at this step, shown as key caps.
    var keys: [(keys: String, label: String)] = []
}

enum OnboardingTour {
    static let seenKey = "pgbrain.onboardingSeen.v1"

    static var hasBeenSeen: Bool { UserDefaults.standard.bool(forKey: seenKey) }

    static let steps: [OnboardingStep] = [
        OnboardingStep(id: 0, title: "Welcome to pgBrain",
                       message: "A one-minute tour of your connection window. Use the arrow keys or the buttons; Esc skips. Help ▸ Show Tour brings it back any time.",
                       systemImage: "hand.wave", anchor: nil),
        OnboardingStep(id: 1, title: "Your database at a glance",
                       message: "Schemas, tables, views and functions. Pinned and Recent tables stay at the top. Single-click previews a table, double-click or Return keeps it open. The filter is fuzzy — pub.us finds public.users.",
                       systemImage: "sidebar.left", anchor: .sidebar,
                       keys: [("⌥⌘F", "filter the tree"), ("↩ / Space", "open / preview"), ("⌘D", "pin a table")]),
        OnboardingStep(id: 2, title: "Focus on what matters",
                       message: "Show one schema, hide the ones you never touch, or bring extension objects like PostGIS back. The tree remembers what you expanded.",
                       systemImage: "line.3.horizontal.decrease.circle", anchor: .schemaPicker),
        OnboardingStep(id: 3, title: "Tabs and breadcrumbs",
                       message: "Italic tabs are previews the next click replaces. Pin the ones you live in. The breadcrumb's menus hop to a sibling schema or table, and back / forward retrace your steps — foreign-key jumps included.",
                       systemImage: "rectangle.stack", anchor: .tabs,
                       keys: [("⌘[  ⌘]", "back / forward"), ("⌘1–9", "switch tab")]),
        OnboardingStep(id: 4, title: "Go anywhere",
                       message: "Go to Table finds any table, view or function — recent ones first. The command palette also runs every action in the app.",
                       systemImage: "magnifyingglass", anchor: nil,
                       keys: [("⌘O", "go to table"), ("⌘K", "everything")]),
        OnboardingStep(id: 5, title: "A grid that edits like a spreadsheet",
                       message: "Select cells or ranges, copy and paste them, or just start typing to edit. ⌘-click a foreign key to jump to the row it points at.",
                       systemImage: "tablecells", anchor: .grid,
                       keys: [("↩ / type", "edit a cell"), ("⌫", "set NULL"), ("⌘C  ⌘V", "copy / paste cells")]),
        OnboardingStep(id: 6, title: "Nothing changes until you say so",
                       message: "Edits, inserts and deletes are staged. Preview the exact SQL, then apply it in one transaction — pgBrain refuses to overwrite a row someone else changed, and asks before throwing edits away.",
                       systemImage: "checkmark.shield", anchor: .tableHeader,
                       keys: [("⌘S", "apply"), ("⌘Z  ⌘⇧Z", "undo / redo")]),
        OnboardingStep(id: 7, title: "Scratchpads with a real session",
                       message: "Write SQL and see results inline, with charts and pivots. Each scratchpad keeps its own session, so SET, temp tables and BEGIN carry over — with Commit and Roll Back one click away.",
                       systemImage: "doc.text", anchor: .newTab,
                       keys: [("⌘T", "new scratchpad"), ("⌘↩", "run"), ("⌘.", "stop")]),
        OnboardingStep(id: 8, title: "Databases and connection health",
                       message: "Switch to another database on this server — it opens in its own window. The status bar shows when a connection drops; pgBrain reconnects on its own after sleep or a network change.",
                       systemImage: "cylinder.split.1x2", anchor: .database),
    ]
}

// MARK: - Anchors

struct OnboardingAnchorKey: PreferenceKey {
    static let defaultValue: [OnboardingAnchor: Anchor<CGRect>] = [:]
    static func reduce(value: inout [OnboardingAnchor: Anchor<CGRect>],
                       nextValue: () -> [OnboardingAnchor: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Make this view something the onboarding tour can point at.
    /// Merges with anchors inside it: a plain `anchorPreference` would
    /// replace them, so the sidebar hid the schema picker and the tab strip
    /// hid the new-tab button.
    func onboardingAnchor(_ anchor: OnboardingAnchor) -> some View {
        transformAnchorPreference(key: OnboardingAnchorKey.self, value: .bounds) { $0[anchor] = $1 }
    }
}

// MARK: - Overlay

struct OnboardingOverlay: View {
    @Bindable var service: ConnectionService
    let anchors: [OnboardingAnchor: Anchor<CGRect>]
    @FocusState private var focused: Bool

    private var workspace: WorkspaceState { service.workspace }

    var body: some View {
        if let index = workspace.onboardingStep, OnboardingTour.steps.indices.contains(index) {
            let step = OnboardingTour.steps[index]
            GeometryReader { geo in
                let target = step.anchor.flatMap { anchors[$0] }.map { geo[$0].insetBy(dx: -6, dy: -6) }
                ZStack(alignment: .topLeading) {
                    // Dim everything except the target.
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: geo.size))
                        if let target { path.addRoundedRect(in: target, cornerSize: CGSize(width: 10, height: 10)) }
                    }
                    .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                    .contentShape(Rectangle())
                    .onTapGesture {}   // swallow clicks meant for the dimmed window

                    if let target {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Tokens.Brand.primary, lineWidth: 2)
                            .frame(width: target.width, height: target.height)
                            .offset(x: target.minX, y: target.minY)
                            .allowsHitTesting(false)
                    }

                    card(step, index: index)
                        .frame(width: 340)
                        .fixedSize(horizontal: false, vertical: true)
                        .position(cardPosition(for: target, in: geo.size))
                }
            }
            .transition(.opacity)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onAppear { focused = true }
            .onKeyPress(.rightArrow) { advance(); return .handled }
            .onKeyPress(.return) { advance(); return .handled }
            .onKeyPress(.leftArrow) { back(); return .handled }
            .onKeyPress(.escape) { finish(); return .handled }
        }
    }

    private func card(_ step: OnboardingStep, index: Int) -> some View {
        let isLast = index == OnboardingTour.steps.count - 1
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: step.systemImage)
                    .font(.title2)
                    .foregroundStyle(Tokens.Brand.primary)
                    .frame(width: 28)
                Text(step.title).font(.headline)
                Spacer()
                Text("\(index + 1) of \(OnboardingTour.steps.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(step.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !step.keys.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(step.keys, id: \.keys) { key in
                        HStack(spacing: 8) {
                            Text(key.keys)
                                .font(.caption.monospaced().weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                            Text(key.label).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack {
                if !isLast {
                    Button("Skip Tour") { finish() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                Spacer()
                if index > 0 {
                    Button("Back") { back() }
                }
                Button(isLast ? "Done" : "Next") { advance() }
                    .buttonStyle(.borderedProminent)
                    .tint(Tokens.Brand.primary)
            }
            .controlSize(.small)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tour step \(index + 1) of \(OnboardingTour.steps.count): \(step.title)")
    }

    /// Beside the target — right, left, below, then above — clamped to the
    /// window; centred when there's no target.
    private func cardPosition(for target: CGRect?, in size: CGSize) -> CGPoint {
        OnboardingLayout.cardCenter(for: target, in: size)
    }

    private func advance() {
        guard let index = workspace.onboardingStep else { return }
        if index + 1 < OnboardingTour.steps.count {
            prepare(OnboardingTour.steps[index + 1])
            withAnimation(.easeInOut(duration: 0.2)) { workspace.onboardingStep = index + 1 }
        } else {
            finish()
        }
    }

    private func back() {
        guard let index = workspace.onboardingStep, index > 0 else { return }
        prepare(OnboardingTour.steps[index - 1])
        withAnimation(.easeInOut(duration: 0.2)) { workspace.onboardingStep = index - 1 }
    }

    private func prepare(_ step: OnboardingStep) {
        OnboardingTour.prepare(step, in: service)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: OnboardingTour.seenKey)
        withAnimation(.easeInOut(duration: 0.2)) { workspace.onboardingStep = nil }
    }
}

extension OnboardingTour {
    /// Start (or restart) the tour in `service`'s window.
    @MainActor
    static func start(in service: ConnectionService) {
        if !service.workspace.sidebarVisible { service.workspace.sidebarVisible = true }
        withAnimation(.easeInOut(duration: 0.2)) { service.workspace.onboardingStep = 0 }
    }

    /// Put the window in a state where the step's element exists: the tab /
    /// breadcrumb and grid steps need a table tab, so open a preview of one
    /// if none is showing.
    @MainActor
    static func prepare(_ step: OnboardingStep, in service: ConnectionService) {
        switch step.anchor {
        case .tabs, .grid, .tableHeader:
            ensureTableTab(in: service)
        case .sidebar, .schemaPicker:
            if !service.workspace.sidebarVisible { service.workspace.sidebarVisible = true }
        default:
            break
        }
    }

    /// Opens a preview tab of a table when the active tab isn't one, preferring
    /// a recent table, then the first table of `public`, then any table.
    @MainActor
    static func ensureTableTab(in service: ConnectionService) {
        if service.workspace.selectedTab?.tableNode != nil { return }
        let schemas = service.visibleSchema.schemas
        let tables = schemas.flatMap(\.tables).filter { $0.partitionOf == nil && !$0.isExtensionOwned }
        let recents = NavigationHistoryStore.shared.recents(for: service.navigationScope)
        let pick = recents.lazy.compactMap { id in tables.first { $0.id == id } }.first
            ?? tables.first { $0.schema == "public" }
            ?? tables.first
        if let pick { service.workspace.openTable(pick, preview: true) }
    }
}

#if DEBUG
extension OnboardingTour {
    /// Anchors each window last laid out, so the smoke suite can check that
    /// every anchored step has something on screen to point at.
    @MainActor static var anchorsSeen: [UUID: Set<OnboardingAnchor>] = [:]

    @MainActor static func recordAnchors(_ anchors: Set<OnboardingAnchor>, window: UUID) {
        guard ShowcaseEnvironment.isActive else { return }
        anchorsSeen[window] = anchors
    }
}
#endif

/// Pure card placement, kept apart from the view so it can be tested.
enum OnboardingLayout {
    static let cardSize = CGSize(width: 340, height: 250)

    static func cardCenter(for target: CGRect?, in size: CGSize) -> CGPoint {
        let width = cardSize.width, height = cardSize.height, gap: CGFloat = 18, margin: CGFloat = 16
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        guard let t = target else { return centre }
        let candidates: [CGPoint] = [
            CGPoint(x: t.maxX + gap + width / 2, y: t.midY),
            CGPoint(x: t.minX - gap - width / 2, y: t.midY),
            CGPoint(x: t.midX, y: t.maxY + gap + height / 2),
            CGPoint(x: t.midX, y: t.minY - gap - height / 2),
        ]
        let fits: (CGPoint) -> Bool = { p in
            p.x - width / 2 >= margin && p.x + width / 2 <= size.width - margin
                && p.y - height / 2 >= margin && p.y + height / 2 <= size.height - margin
        }
        // A big target (the grid) leaves no room beside it: sit inside its
        // lower-right corner rather than on top of the middle of it.
        let chosen = candidates.first(where: fits)
            ?? CGPoint(x: t.maxX - margin - width / 2, y: t.maxY - margin - height / 2)
        return CGPoint(x: min(max(chosen.x, width / 2 + margin), size.width - width / 2 - margin),
                       y: min(max(chosen.y, height / 2 + margin), size.height - height / 2 - margin))
    }
}
