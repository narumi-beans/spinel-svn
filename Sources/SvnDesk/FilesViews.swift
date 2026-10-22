import SwiftUI

extension ItemState {
    var color: Color {
        switch self {
        case .modified, .merged: return .blue
        case .added, .replaced: return .green
        case .deleted, .missing, .obstructed, .incomplete: return .red
        case .conflicted: return .orange
        case .unversioned: return .secondary
        case .ignored: return .gray
        case .external: return .purple
        case .normal, .none: return .primary
        }
    }

    var symbol: String {
        switch self {
        case .modified, .merged: return "pencil.circle.fill"
        case .added: return "plus.circle.fill"
        case .replaced: return "arrow.triangle.2.circlepath.circle.fill"
        case .deleted: return "minus.circle.fill"
        case .missing: return "questionmark.circle.fill"
        case .conflicted: return "exclamationmark.triangle.fill"
        case .unversioned: return "questionmark.square.dashed"
        case .ignored: return "eye.slash"
        case .external: return "link.circle"
        case .obstructed, .incomplete: return "xmark.octagon"
        case .normal, .none: return "checkmark.circle"
        }
    }
}

// MARK: - Directories

struct DirectoryTreeView: View {
    @ObservedObject var wc: WorkingCopyModel
    @State private var expanded: Set<String> = [""]

    var body: some View {
        if let tree = wc.dirTree {
            List(selection: $wc.selectedDir) {
                DirRow(wc: wc, node: tree, expanded: $expanded)
            }
            .listStyle(.sidebar)
            .onChange(of: wc.selectedDir) { wc.selectedFiles.removeAll() }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct DirRow: View {
    let wc: WorkingCopyModel
    let node: DirNode
    @Binding var expanded: Set<String>

    var body: some View {
        if let children = node.children {
            DisclosureGroup(isExpanded: Binding(
                get: { expanded.contains(node.path) },
                set: { if $0 { expanded.insert(node.path) } else { expanded.remove(node.path) } })) {
                ForEach(children) { DirRow(wc: wc, node: $0, expanded: $expanded) }
            } label: {
                label
            }
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: 4) {
            Image(systemName: node.hasLocalChanges ? "folder.fill.badge.gearshape" : "folder.fill")
                .foregroundStyle(node.hasLocalChanges ? Color.blue : Color.accentColor.opacity(0.7))
            Text(node.name)
                .foregroundStyle(node.state == .normal ? Color.primary : node.state.color)
        }
        .tag(node.path as String?)
        .contextMenu { DirectoryMenu(wc: wc, path: node.path) }
    }
}

private struct DirectoryMenu: View {
    let wc: WorkingCopyModel
    let path: String

    var body: some View {
        Button(L("Update")) { wc.selectedDir = path; wc.selectedFiles = []; wc.update() }
        Button(L("Commit…")) { wc.commit(paths: wc.committable.filter { path.isEmpty || $0.path == path || $0.path.hasPrefix(path + "/") }.map(\.path)) }
        Divider()
        Button(L("Create Directory…")) { wc.selectedDir = path; wc.createDirectory() }
        Button(L("Log…")) { wc.windowRequest = .log(path) }
        Button(L("Edit Properties…")) { wc.sheet = .properties(path) }
        Divider()
        Button(L("Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: wc.absolute(path))]) }
        Button(L("Open in Terminal")) { wc.selectedDir = path; wc.openInTerminal() }
    }
}

// MARK: - Files

struct FileTableView: View {
    @ObservedObject var wc: WorkingCopyModel
    @State private var sortOrder = [KeyPathComparator(\StatusEntry.sortState), KeyPathComparator(\StatusEntry.name)]

    var body: some View {
        let rows = wc.visibleFiles.sorted(using: sortOrder)
        Table(rows, selection: $wc.selectedFiles, sortOrder: $sortOrder) {
            TableColumn(L("Name"), value: \.name) { e in
                HStack(spacing: 4) {
                    Image(systemName: e.isDirectory ? "folder" : "doc")
                        .foregroundStyle(.secondary)
                    Text(e.name).foregroundStyle(e.effectiveState.color)
                }
            }
            .width(min: 120, ideal: 220)
            TableColumn(L("Revision"), value: \.revisionSort) { e in
                Text(e.committedRevision.map(String.init) ?? "").monospacedDigit()
            }
            .width(min: 50, ideal: 70)
            TableColumn(L("Local State"), value: \.sortState) { e in
                Label(e.localStateLabel, systemImage: e.effectiveState.symbol)
                    .foregroundStyle(e.effectiveState.color)
            }
            .width(min: 90, ideal: 130)
            TableColumn(L("Remote State"), value: \.remoteStateLabel) { e in
                Text(e.remoteStateLabel).foregroundStyle(.purple)
            }
            .width(min: 70, ideal: 100)
            TableColumn(L("Change Set"), value: \.changelistSort) { e in
                Text(e.changelist ?? "")
            }
            .width(min: 60, ideal: 90)
            TableColumn(L("Copy From"), value: \.copyFromSort) { e in
                Text(e.copyFrom ?? "").lineLimit(1).truncationMode(.middle)
            }
            .width(min: 60, ideal: 140)
            TableColumn(L("Relative Directory"), value: \.directory)
                .width(min: 80, ideal: 160)
            TableColumn(L("Author"), value: \.authorSort) { e in
                Text(e.author ?? "")
            }
            .width(min: 60, ideal: 90)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            FileMenu(wc: wc, ids: ids)
        } primaryAction: { ids in
            guard let id = ids.first, let e = wc.entries[id] else { return }
            if e.isDirectory {
                wc.selectedDir = id
            } else if e.effectiveState == .conflicted {
                wc.windowRequest = .conflictSolver(id)
            } else if e.effectiveState == .normal || e.effectiveState == .unversioned {
                wc.openFile()
            } else {
                wc.windowRequest = .compare(id, .base)
            }
        }
        .overlay {
            if rows.isEmpty && wc.dirTree != nil {
                Text(wc.filterText.isEmpty ? L("No files to show") : L("No files match the filter"))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension StatusEntry {
    var sortState: Int { ItemState.allCases.firstIndex(of: effectiveState).map { $0 == 0 ? 99 : $0 } ?? 100 }
    var revisionSort: Int { committedRevision ?? -1 }
    var changelistSort: String { changelist ?? "" }
    var copyFromSort: String { copyFrom ?? "" }
    var authorSort: String { author ?? "" }
}

private struct FileMenu: View {
    let wc: WorkingCopyModel
    let ids: Set<String>

    /// Context menus act on the clicked rows, so select them before running the action.
    private func on(_ action: @escaping () -> Void) -> () -> Void {
        { [wc, ids] in
            if !ids.isEmpty { wc.selectedFiles = ids }
            action()
        }
    }

    var body: some View {
        let first = ids.sorted().first ?? ""
        Button(L("Open File"), action: on { wc.openFile() })
        Button(L("Show Changes"), action: on { wc.windowRequest = .compare(first, .base) })
        Button(L("Compare with HEAD"), action: on { wc.windowRequest = .compare(first, .head) })
        Button(L("Compare with Previous"), action: on { wc.windowRequest = .compare(first, .previous) })
        Divider()
        Button(L("Update"), action: on { wc.update() })
        Button(L("Commit…"), action: on { wc.commit(paths: ids.sorted()) })
        Button(L("Add"), action: on { wc.add() })
        Button(L("Remove…"), action: on { wc.remove() })
        Button(L("Revert…"), action: on { wc.revert() })
        Button(L("Ignore…"), action: on { wc.ignore() })
        Button(L("Conflict Solver…"), action: on { wc.windowRequest = .conflictSolver(first) })
            .disabled(wc.entries[first]?.effectiveState != .conflicted)
        Button(L("Mark Resolved…"), action: on { wc.markResolved() })
        Divider()
        Button(L("Rename…"), action: on { wc.rename() })
        Button(L("Move…"), action: on { wc.move() })
        Button(L("Copy…"), action: on { wc.copy() })
        Button(L("Move to Change Set…"), action: on { wc.moveToChangeSet() })
        Divider()
        Button(L("Log…"), action: on { wc.windowRequest = .log(first) })
        Button(L("Annotate…"), action: on { wc.windowRequest = .annotate(first) })
        Button(L("Edit Properties…"), action: on { wc.sheet = .properties(first) })
        Divider()
        Button(L("Reveal in Finder"), action: on { wc.revealInFinder() })
        Menu(L("Copy Special")) {
            Button(L("Copy Name"), action: on { wc.copyNames() })
            Button(L("Copy Path"), action: on { wc.copyPaths() })
            Button(L("Copy Relative Path"), action: on { wc.copyRelativePaths() })
            Button(L("Copy URL"), action: on { wc.copyURLs() })
        }
        Divider()
        Button(L("Delete Physically…"), role: .destructive, action: on { wc.deletePhysically() })
    }
}

// MARK: - Changes preview

struct ChangesPane: View {
    @ObservedObject var wc: WorkingCopyModel
    @State private var left = ""
    @State private var right = ""
    @State private var note: String?
    @AppStorage("diffMode") private var mode = DiffDisplayMode.sideBySide
    @AppStorage("diffCompact") private var compact = true
    @AppStorage("diffIgnoreWS") private var ignoreWS = false

    private var selection: StatusEntry? {
        wc.selectedFiles.count == 1 ? wc.entries[wc.selectedFiles.first!] : nil
    }

    var body: some View {
        Pane(title: L("Changes"), accessory: {
            DiffControls(mode: $mode, compact: $compact, ignoreWS: $ignoreWS)
        }) {
            if let note {
                Text(note).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DiffTextView(left: left, right: right, mode: mode, compact: compact,
                             options: DiffOptions(ignoreWhitespace: ignoreWS),
                             leftTitle: L("Base"), rightTitle: L("Working Copy"))
            }
        }
        .task(id: TaskKey(entry: selection, generation: wc.refreshGeneration)) { await load() }
    }

    private struct TaskKey: Equatable {
        var entry: StatusEntry?
        var generation: Int
    }

    private func load() async {
        guard let e = selection else {
            note = L("Select a single file to see its changes")
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
