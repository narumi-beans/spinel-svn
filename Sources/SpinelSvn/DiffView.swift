import SwiftUI

enum DiffDisplayMode: String, CaseIterable {
    case unified, sideBySide
}

struct DiffControls: View {
    @Binding var mode: DiffDisplayMode
    @Binding var compact: Bool
    @Binding var ignoreWS: Bool
    @Binding var ignoreEOL: Bool

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $mode) {
                Text(L("Unified")).tag(DiffDisplayMode.unified)
                Text(L("Side by Side")).tag(DiffDisplayMode.sideBySide)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Toggle(L("Compact"), isOn: $compact).toggleStyle(.button)
            Toggle(L("Ignore WS"), isOn: $ignoreWS).toggleStyle(.button)
            Toggle(L("Ignore EOL"), isOn: $ignoreEOL).toggleStyle(.button)
                .help(L("Ignore line-ending changes (CR/LF)"))
        }
        .controlSize(.small)
    }
}

struct DiffTextView: View {
    var left: String
    var right: String
    var mode: DiffDisplayMode
    var compact: Bool
    var options: DiffOptions
    var leftTitle: String
    var rightTitle: String

    @State private var rows: [DiffRow] = []
    @State private var changeCount = 0

    private struct Key: Equatable {
        var left: String, right: String, mode: DiffDisplayMode, compact: Bool, options: DiffOptions
    }

    var body: some View {
        VStack(spacing: 0) {
            if mode == .sideBySide {
                HStack(spacing: 0) {
                    header(leftTitle)
                    Divider()
                    header(rightTitle)
                }
                .fixedSize(horizontal: false, vertical: true)
                Divider()
            }
            ScrollView(mode == .sideBySide ? [.vertical] : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        if mode == .sideBySide {
                            SideBySideRow(row: row)
                        } else {
                            UnifiedRow(row: row)
                        }
                    }
                }
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
            }
            .background(Color(nsColor: .textBackgroundColor))
            HStack {
                Text(String(format: L("%d change(s)"), changeCount))
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
        }
        .task(id: Key(left: left, right: right, mode: mode, compact: compact, options: options)) {
            let lt = left, rt = right
            let opts = options
            let m = mode, c = compact
            let computed = await Task.detached(priority: .userInitiated) { () -> ([DiffRow], Int) in
                let l = lt.linesKeepingCR, r = rt.linesKeepingCR
                let ops = DiffEngine.diff(l, r, options: opts)
                let side = DiffEngine.rows(left: l, right: r, ops: ops, compact: c, context: opts.context)
                var hunks = 0
                var inChange = false
                for row in side {
                    let changed = row.kind != .same && row.kind != .gap
                    if changed && !inChange { hunks += 1 }
                    inChange = changed
                }
                return (m == .sideBySide ? side : DiffEngine.unifiedRows(side), hunks)
            }.value
            guard !Task.isCancelled else { return }
            rows = computed.0
            changeCount = computed.1
        }
    }

    private func header(_ t: String) -> some View {
        Text(t).font(.caption.bold()).padding(4).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension DiffRow.Kind {
    var leftBackground: Color {
        switch self {
        case .changed: return .blue.opacity(0.12)
        case .deleted: return .red.opacity(0.15)
        case .inserted: return .gray.opacity(0.08)
        default: return .clear
        }
    }

    var rightBackground: Color {
        switch self {
        case .changed: return .blue.opacity(0.12)
        case .inserted: return .green.opacity(0.15)
        case .deleted: return .gray.opacity(0.08)
        default: return .clear
        }
    }
}

/// Shows a carriage return as "␍" so CRLF/LF differences are visible.
private func visible(_ s: String?) -> String? {
    s.map { $0.hasSuffix("\r") ? String($0.dropLast()) + "␍" : $0 }
}

private struct LineNo: View {
    var n: Int?
    var body: some View {
        Text(n.map(String.init) ?? "")
            .foregroundStyle(.secondary)
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 6)
    }
}

private struct SideBySideRow: View {
    var row: DiffRow

    var body: some View {
        if row.kind == .gap {
            GapRow(text: row.left ?? "")
        } else {
            HStack(spacing: 0) {
                half(row.leftNumber, visible(row.left), row.kind.leftBackground)
                Divider()
                half(row.rightNumber, visible(row.right), row.kind.rightBackground)
            }
        }
    }

    /// Each side takes half of the width; long lines are truncated (full text in the tooltip).
    private func half(_ n: Int?, _ text: String?, _ bg: Color) -> some View {
        HStack(spacing: 0) {
            LineNo(n: n)
            Text(text ?? " ")
                .lineLimit(1)
                .truncationMode(.tail)
                .help(text ?? "")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bg)
    }
}

private struct UnifiedRow: View {
    var row: DiffRow

    var body: some View {
        if row.kind == .gap {
            GapRow(text: row.left ?? "")
        } else {
            let marker = row.kind == .deleted ? "-" : (row.kind == .inserted ? "+" : " ")
            HStack(spacing: 0) {
                LineNo(n: row.leftNumber)
                LineNo(n: row.rightNumber)
                Text(marker + " " + ((row.kind == .inserted ? visible(row.right) : visible(row.left)) ?? "")).fixedSize()
                Spacer(minLength: 0)
            }
            .frame(minWidth: 900, alignment: .leading)
            .background(row.kind == .deleted ? Color.red.opacity(0.15) : row.kind == .inserted ? Color.green.opacity(0.15) : .clear)
        }
    }
}

private struct GapRow: View {
    var text: String
    var body: some View {
        Text("⋯ " + text)
            .foregroundStyle(.secondary)
            .padding(.vertical, 2)
            .padding(.leading, 50)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08))
    }
}

/// Colored rendering of raw `svn diff` output (used where only a patch is available).
struct PatchTextView: View {
    var text: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(text.lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .fixedSize()
                        .foregroundStyle(color(line))
                        .frame(minWidth: 900, alignment: .leading)
                        .background(bg(line))
                }
            }
            .font(.system(size: 11.5, design: .monospaced))
            .textSelection(.enabled)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func color(_ l: String) -> Color {
        if l.hasPrefix("@@") { return .purple }
        if l.hasPrefix("Index:") || l.hasPrefix("===") { return .secondary }
        return .primary
    }

    private func bg(_ l: String) -> Color {
        if l.hasPrefix("+") && !l.hasPrefix("+++") { return .green.opacity(0.15) }
        if l.hasPrefix("-") && !l.hasPrefix("---") { return .red.opacity(0.15) }
        return .clear
    }
}
