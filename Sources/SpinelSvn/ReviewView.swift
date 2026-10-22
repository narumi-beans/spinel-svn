import SwiftUI

/// Review perspective: step through every local change, mark files as reviewed
/// and commit the reviewed set without leaving the window.
struct ReviewView: View {
    @ObservedObject var wc: WorkingCopyModel
    @State private var current: String?
    @State private var left = ""
    @State private var right = ""
    @State private var note: String?
    @State private var message = ""
    @AppStorage("diffMode") private var mode = DiffDisplayMode.sideBySide
    @AppStorage("diffCompact") private var compact = true
    @AppStorage("diffIgnoreWS") private var ignoreWS = false
    @AppStorage("diffIgnoreEOL") private var ignoreEOL = false

    private var files: [StatusEntry] { wc.committable }
    private var entry: StatusEntry? { current.flatMap { wc.entries[$0] } }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text(L("Changes to Review")).font(.headline)
                    Spacer()
                    Text("\(wc.reviewed.intersection(files.map(\.path)).count)/\(files.count)")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(8)
                Divider()
                List(files, selection: $current) { e in
                    HStack(spacing: 6) {
                        Button {
                            toggleReviewed(e.path)
                        } label: {
                            Image(systemName: wc.reviewed.contains(e.path) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(wc.reviewed.contains(e.path) ? .green : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help(L("Mark as reviewed"))
                        Image(systemName: e.effectiveState.symbol).foregroundStyle(e.effectiveState.color)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(e.name)
                            Text(e.directory.isEmpty ? "." : e.directory).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if e.effectiveState == .conflicted {
                            Button(L("Solve")) { wc.windowRequest = .conflictSolver(e.path) }.controlSize(.small)
                        }
                    }
                    .tag(e.path)
                }
                .overlay {
                    if files.isEmpty { Text(L("No local changes")).foregroundStyle(.secondary) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Commit message")).font(.headline)
                    TextEditor(text: $message)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 80)
                        .border(Color.secondary.opacity(0.3))
                    Button {
                        let paths = files.map(\.path).filter { wc.reviewed.contains($0) }
                        wc.runCommit(paths: paths, message: message, keepChangelists: false) {
                            paths.forEach { wc.setReviewed($0, false) }
                            message = ""
                        }
                    } label: {
                        Text(String(format: L("Commit %d Reviewed File(s)"), wc.reviewed.intersection(files.map(\.path)).count))
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(wc.reviewed.intersection(files.map(\.path)).isEmpty
                              || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(8)
            }
            .frame(minWidth: 260, idealWidth: 320, maxWidth: 480)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if let e = entry {
                        Image(systemName: e.effectiveState.symbol).foregroundStyle(e.effectiveState.color)
                        Text(e.path).font(.headline).lineLimit(1).truncationMode(.middle)
                        Text(e.localStateLabel).foregroundStyle(.secondary)
                    }
                    Spacer()
                    DiffControls(mode: $mode, compact: $compact, ignoreWS: $ignoreWS, ignoreEOL: $ignoreEOL)
                    Button { move(-1) } label: { Image(systemName: "chevron.up") }
                        .keyboardShortcut(.upArrow, modifiers: [.option])
                        .help(L("Previous File"))
                    Button { move(1) } label: { Image(systemName: "chevron.down") }
                        .keyboardShortcut(.downArrow, modifiers: [.option])
                        .help(L("Next File"))
                    Button {
                        if let c = current { wc.setReviewed(c, true) }
                        move(1)
                    } label: {
                        Label(L("Reviewed, Next"), systemImage: "checkmark")
                    }
                    .keyboardShortcut(.return, modifiers: [.option])
                    .disabled(current == nil)
                }
                .padding(8)
                Divider()
                if let note {
                    Text(note).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    DiffTextView(left: left, right: right, mode: mode, compact: compact,
                                 options: DiffOptions(ignoreWhitespace: ignoreWS, ignoreLineEndings: ignoreEOL),
                                 leftTitle: L("Base"), rightTitle: L("Working Copy"))
                }
            }
            .frame(minWidth: 500)
        }
        .task(id: ReloadKey(entry: entry, generation: wc.refreshGeneration)) { await load() }
        .onAppear { if current == nil { current = files.first?.path } }
    }

    private struct ReloadKey: Equatable {
        var entry: StatusEntry?
        var generation: Int
    }

    private func toggleReviewed(_ p: String) {
        wc.setReviewed(p, !wc.reviewed.contains(p))
    }

    private func move(_ d: Int) {
        let paths = files.map(\.path)
        guard !paths.isEmpty else { return }
        if let c = current, let i = paths.firstIndex(of: c) {
            current = paths[min(max(i + d, 0), paths.count - 1)]
        } else {
            current = paths.first
        }
    }

    private func load() async {
        guard let e = entry else {
            note = files.isEmpty ? L("No local changes") : L("Select a file to review")
            return
        }
        let content = await wc.diffContent(for: e)
        guard !Task.isCancelled else { return }
        switch content {
        case let .text(l, r):
            note = nil
            left = l
            right = r
        case let .message(m):
            note = m
        }
    }
}
