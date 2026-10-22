import SwiftUI

extension ItemState {
    var color: Color { self == .normal || self == .none ? .primary : tint }

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

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var wc: WorkingCopyModel
    @State private var expanded: Set<String> = [""]

    var body: some View {
        List(selection: Binding(get: { wc.scope }, set: { if let s = $0 { wc.scope = s } })) {
            Section(L("Workspace")) {
                Label(L("Local Changes"), systemImage: "square.and.pencil")
                    .badge(wc.committable.count)
                    .tag(WorkingCopyModel.Scope.changes)
                Label(L("All Files"), systemImage: "doc.on.doc")
                    .tag(WorkingCopyModel.Scope.all)
            }
            Section(L("Folders")) {
                if let tree = wc.dirTree {
                    DirRow(wc: wc, node: tree, expanded: $expanded)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .listStyle(.sidebar)
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
        Label {
            HStack(spacing: 6) {
                Text(node.name)
                    .foregroundStyle(node.state == .normal ? Color.primary : node.state.color)
                if node.hasLocalChanges {
                    Circle().fill(ItemState.modified.tint).frame(width: 6, height: 6)
                        .help(L("Contains local changes"))
                }
            }
        } icon: {
            Image(systemName: node.path.isEmpty ? "externaldrive.connected.to.line.below" : "folder")
                .foregroundStyle(.secondary)
        }
        .tag(WorkingCopyModel.Scope.folder(node.path))
        .contextMenu { DirectoryMenu(wc: wc, path: node.path) }
    }
}

private struct DirectoryMenu: View {
    let wc: WorkingCopyModel
    let path: String

    var body: some View {
        Button(L("Update")) { wc.selectedDir = path; wc.selectedFiles = []; wc.update() }
        Button(L("Commit…")) { wc.commit(paths: wc.committable.filter { path.isEmpty || $0.path == path || $0.path.hasPrefix(path + "/") }.map(\.path), pickedFiles: false) }
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
    @Environment(\.openWindow) private var openWindow
    @State private var sortOrder = [KeyPathComparator(\StatusEntry.sortState), KeyPathComparator(\StatusEntry.name)]
    @SceneStorage("fileColumns") private var columns = TableColumnCustomization<StatusEntry>()

    private var showsFolderColumn: Bool {
        if case .folder = wc.scope { return wc.showSubdirFiles }
        return true
    }

    var body: some View {
        let rows = wc.sortedVisibleFiles(sortOrder)
        Table(rows, selection: $wc.selectedFiles, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn(L("Name"), value: \.name) { e in
                HStack(spacing: 7) {
                    Image(systemName: fileSymbol(e))
                        .foregroundStyle(e.effectiveState == .normal ? Color.secondary : e.effectiveState.tint)
                        .frame(width: 16)
                    Text(e.name)
                        .strikethrough(e.item == .deleted || e.item == .missing)
                    if showsFolderColumn && !e.directory.isEmpty {
                        Text(e.directory).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                    }
                }
            }
            .width(min: 140, ideal: 200)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)
            TableColumn(L("Local State"), value: \.sortState) { e in
                StatePill(entry: e)
            }
            .width(min: 84, ideal: 96)
            .customizationID("state")
            TableColumn(L("Revision"), value: \.revisionSort) { e in
                Text(e.committedRevision.map(String.init) ?? "")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 64)
            .customizationID("revision")
            TableColumn(L("Author"), value: \.authorSort) { e in
                Text(e.author ?? "").foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 100)
            .customizationID("author")
            TableColumn(L("Remote State"), value: \.remoteStateLabel) { e in
                Text(e.remoteStateLabel).foregroundStyle(.purple)
            }
            .width(min: 70, ideal: 100)
            .customizationID("remote")
            .defaultVisibility(.hidden)
            TableColumn(L("Change Set"), value: \.changelistSort) { e in
                Text(e.changelist ?? "")
            }
            .width(min: 60, ideal: 90)
            .customizationID("changeset")
            .defaultVisibility(.hidden)
            TableColumn(L("Copy From"), value: \.copyFromSort) { e in
                Text(e.copyFrom ?? "").lineLimit(1).truncationMode(.middle)
            }
            .width(min: 60, ideal: 140)
            .customizationID("copyfrom")
            .defaultVisibility(.hidden)
            TableColumn(L("Relative Directory"), value: \.directory)
                .width(min: 80, ideal: 160)
                .customizationID("directory")
                .defaultVisibility(.hidden)
        }
        .tableStyle(.inset)
        .contextMenu(forSelectionType: String.self) { ids in
            FileMenu(wc: wc, ids: ids)
        } primaryAction: { ids in
            let picked = ids.sorted().compactMap { wc.entries[$0] }
            if picked.count == 1, let only = picked.first, only.isDirectory {
                wc.selectedDir = only.path
                return
            }
            // Like Finder, a double-click acts on every selected file, in a stable order.
            for e in picked where !e.isDirectory { open(e) }
        }
        .overlay {
            if rows.isEmpty && wc.dirTree != nil { emptyState }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !wc.filterText.isEmpty {
            ContentUnavailableView.search(text: wc.filterText)
        } else if wc.scope == .changes {
            ContentUnavailableView(L("No Local Changes"), systemImage: "checkmark.seal",
                                   description: Text(L("The working copy matches the repository.")))
        } else {
            ContentUnavailableView(L("No Files"), systemImage: "folder",
                                   description: Text(L("This folder has no files to show with the current view options.")))
        }
    }

}

extension FileTableView {
    private func open(_ e: StatusEntry) {
        switch e.effectiveState {
        case .conflicted:
            openWindow(id: "conflict", value: FileTarget(root: wc.rootPath, path: e.path))
        case .normal, .unversioned, .ignored:
            NSWorkspace.shared.open(URL(fileURLWithPath: wc.absolute(e.path)))
        default:
            openWindow(id: "compare", value: CompareTarget(root: wc.rootPath, path: e.path, mode: .base))
        }
    }
}

extension StatusEntry {
    private static let stateRank: [ItemState: Int] =
        Dictionary(uniqueKeysWithValues: ItemState.allCases.enumerated().map { ($1, $0 == 0 ? 99 : $0) })
    var sortState: Int { Self.stateRank[effectiveState] ?? 100 }
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

// MARK: - Changes (detail column)

struct ChangesPane: View {
    @ObservedObject var wc: WorkingCopyModel
    @State private var left = ""
    @State private var right = ""
    @State private var note: String?
    @AppStorage("diffMode") private var mode = DiffDisplayMode.sideBySide
    @AppStorage("diffCompact") private var compact = true
    @AppStorage("diffIgnoreWS") private var ignoreWS = false
    @AppStorage("diffIgnoreEOL") private var ignoreEOL = false

    private var selection: StatusEntry? {
        wc.selectedFiles.count == 1 ? wc.entries[wc.selectedFiles.first!] : nil
    }

    var body: some View {
        Group {
            if let e = selection {
                VStack(spacing: 0) {
                    header(e)
                    Divider()
                    if let note {
                        ContentUnavailableView(note, systemImage: "doc.questionmark")
                    } else {
                        DiffTextView(left: left, right: right, mode: mode, compact: compact,
                                     options: DiffOptions(ignoreWhitespace: ignoreWS, ignoreLineEndings: ignoreEOL),
                                     leftTitle: L("Base"), rightTitle: L("Working Copy"))
                    }
                }
            } else if wc.selectedFiles.count > 1 {
                ContentUnavailableView(String(format: L("%d files selected"), wc.selectedFiles.count),
                                       systemImage: "doc.on.doc",
                                       description: Text(L("Select a single file to see its changes")))
            } else {
                ContentUnavailableView(L("No File Selected"), systemImage: "doc.text.magnifyingglass",
                                       description: Text(L("Select a single file to see its changes")))
            }
        }
        .task(id: TaskKey(entry: selection, generation: wc.refreshGeneration)) { await load() }
    }

    private func header(_ e: StatusEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: fileSymbol(e))
                .font(.title2)
                .foregroundStyle(e.effectiveState == .normal ? Color.secondary : e.effectiveState.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(e.directory.isEmpty ? wc.name : e.directory)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            .layoutPriority(1)
            StatePill(entry: e).fixedSize()
            Spacer(minLength: 12)
            DiffControls(mode: $mode, compact: $compact, ignoreWS: $ignoreWS, ignoreEOL: $ignoreEOL)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private struct TaskKey: Equatable {
        var entry: StatusEntry?
        var generation: Int
    }

    private func load() async {
        guard let e = selection else { return }
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
