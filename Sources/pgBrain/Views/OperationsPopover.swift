import SwiftUI

/// Compact popover anchored to the status footer's "N running" indicator.
/// Lists every operation tracked by the connection's `OperationsCenter`,
/// running first, with a Cancel button per live row and a "Clear finished"
/// affordance at the bottom.
struct OperationsPopover: View {
    @Bindable var operations: OperationsCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if operations.operations.isEmpty {
                empty
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(width: 380, height: 280)
    }

    private var header: some View {
        HStack {
            Text("Operations")
                .font(.headline)
            Spacer()
            Text("\(operations.runningCount) running · \(operations.operations.count) total")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "bolt.slash")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No operations yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sortedOps) { op in
                    OperationRow(op: op) {
                        operations.cancel(op)
                    }
                    Divider().opacity(0.4)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Clear Finished") {
                operations.clearFinished()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .disabled(operations.operations.allSatisfy { !$0.isFinished })
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var sortedOps: [OperationsCenter.Operation] {
        // Running first (newest first within each group), finished last.
        operations.operations.sorted { a, b in
            if a.isFinished == b.isFinished {
                return a.startedAt > b.startedAt
            }
            return !a.isFinished && b.isFinished
        }
    }
}

private struct OperationRow: View {
    @Bindable var op: OperationsCenter.Operation
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            statusGlyph
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: op.kind.symbolName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(op.kind.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let pid = op.backendPID, pid != 0 {
                        Text("pid \(pid)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(elapsedLabel)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Text(op.summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if case .failed(let msg) = op.status {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            if !op.isFinished {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch op.status {
        case .running:
            ProgressView().controlSize(.mini)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "stop.circle.fill")
                .foregroundStyle(.secondary)
        }
    }

    private var elapsedLabel: String {
        let secs = op.elapsed
        if secs < 1 { return String(format: "%.0fms", secs * 1000) }
        if secs < 60 { return String(format: "%.1fs", secs) }
        return String(format: "%dm %ds", Int(secs / 60), Int(secs.truncatingRemainder(dividingBy: 60)))
    }
}
