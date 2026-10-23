import SwiftUI

enum DiffDisplayMode: String, CaseIterable {
    case unified, sideBySide
}

/// Where the changes view sits in the main window.
enum DiffPlacement: String, CaseIterable {
    case right, bottom
}

struct DiffControls: View {
    @Binding var mode: DiffDisplayMode
    @Binding var compact: Bool
    @Binding var ignoreWS: Bool
    @Binding var ignoreEOL: Bool
    /// Only the main window's changes view can move; separate compare windows can't.
    var showsPlacement = false

    var body: some View {
        HStack(spacing: 8) {
            Picker(L("Layout"), selection: $mode) {
                Label(L("Unified"), systemImage: "rectangle.split.1x2").tag(DiffDisplayMode.unified)
                    .help(L("Unified"))
                Label(L("Side by Side"), systemImage: "rectangle.split.2x1").tag(DiffDisplayMode.sideBySide)
                    .help(L("Side by Side"))
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .labelsHidden()
            .fixedSize()
            Menu {
                Toggle(L("Compact"), isOn: $compact)
                Toggle(L("Ignore WS"), isOn: $ignoreWS)
                Toggle(L("Ignore EOL"), isOn: $ignoreEOL)
                if showsPlacement {
                    Divider()
                    DiffPlacementPicker()
                }
            } label: {
                Label(L("Display Options"), systemImage: "slider.horizontal.3")
                    .labelStyle(.iconOnly)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("Display Options"))
        }
        .controlSize(.small)
    }
}

struct DiffPlacementPicker: View {
    @AppStorage("diffPlacement") private var placement = DiffPlacement.right

    var body: some View {
        Picker(L("Changes View Position"), selection: $placement) {
            Label(L("Right of the File List"), systemImage: "rectangle.righthalf.inset.filled").tag(DiffPlacement.right)
            Label(L("Below the File List"), systemImage: "rectangle.bottomhalf.inset.filled").tag(DiffPlacement.bottom)
        }
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
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
            }
            .defaultScrollAnchor(.topLeading)
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
        Text(t)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension DiffRow.Kind {
    /// Removed text reads red on the base side, added text green on the working-copy side.
    var leftBackground: Color {
        switch self {
        case .changed, .deleted: return .red.opacity(0.12)
        case .inserted: return .secondary.opacity(0.05)
        default: return .clear
        }
    }

    var rightBackground: Color {
        switch self {
        case .changed, .inserted: return .green.opacity(0.12)
        case .deleted: return .secondary.opacity(0.05)
        default: return .clear
        }
    }

    var leftBar: Color? { self == .changed || self == .deleted ? .red : nil }
    var rightBar: Color? { self == .changed || self == .inserted ? .green : nil }
}

/// Shows a carriage return as "␍" so CRLF/LF differences are visible.
private func visible(_ s: String?) -> String? {
    s.map { $0.hasSuffix("\r") ? String($0.dropLast()) + "␍" : $0 }
}

private struct LineNo: View {
    var n: Int?
    var body: some View {
        Text(n.map(String.init) ?? "")
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: 40, alignment: .trailing)
            .padding(.trailing, 8)
    }
}

private struct SideBySideRow: View {
    var row: DiffRow

    var body: some View {
        if row.kind == .gap {
            GapRow(text: row.left ?? "")
        } else {
            HStack(spacing: 0) {
                half(row.leftNumber, visible(row.left), row.kind.leftBackground, row.kind.leftBar)
                Divider()
                half(row.rightNumber, visible(row.right), row.kind.rightBackground, row.kind.rightBar)
            }
        }
    }

    /// Each side takes half of the width; long lines are truncated (full text in the tooltip).
    private func half(_ n: Int?, _ text: String?, _ bg: Color, _ bar: Color?) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(bar ?? .clear).frame(width: 3)
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
                Rectangle()
                    .fill(row.kind == .deleted ? Color.red : row.kind == .inserted ? Color.green : .clear)
                    .frame(width: 3)
                LineNo(n: row.leftNumber)
                LineNo(n: row.rightNumber)
                Text(marker + " " + ((row.kind == .inserted ? visible(row.right) : visible(row.left)) ?? "")).fixedSize()
                Spacer(minLength: 0)
            }
            .frame(minWidth: 900, alignment: .leading)
            .background(row.kind == .deleted ? Color.red.opacity(0.12) : row.kind == .inserted ? Color.green.opacity(0.12) : .clear)
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
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
        }
        .defaultScrollAnchor(.topLeading)
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
