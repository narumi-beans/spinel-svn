import SwiftUI

struct ProjectWindow: View {
    @Binding var path: String?
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) var openWindow

    var body: some View {
        Group {
            if let path {
                MainProjectView(path: path).id(path)
            } else {
                WelcomeView { chosen in
                    app.register(path: chosen)
                    path = chosen
                }
                .frame(minWidth: 620, minHeight: 460)
            }
        }
        .onAppear {
            if app.openProject == nil {
                app.openProject = { p in openWindow(id: "project", value: p) }
            }
        }
    }
}

// MARK: - Main window

struct MainProjectView: View {
    @StateObject private var wc: WorkingCopyModel
    @Environment(\.openWindow) var openWindow

    init(path: String) {
        _wc = StateObject(wrappedValue: WorkingCopyModel(path: path))
    }

    var body: some View {
        VStack(spacing: 0) {
            if wc.perspective == .review {
                ReviewView(wc: wc)
            } else {
                mainPerspective
            }
            StatusBar(wc: wc)
        }
        .navigationTitle(wc.name)
        .navigationSubtitle(wc.info?.relativeURL ?? wc.rootPath)
        .toolbar(id: "main") { MainToolbar(wc: wc) }
        .background(WindowAccessor { window in
            window.toolbar?.displayMode = .iconAndLabel
            window.toolbar?.allowsUserCustomization = true
            window.toolbar?.autosavesConfiguration = true
            window.setFrameAutosaveName("SvnDeskProject-\(wc.rootPath)")
        })
        .focusedSceneObject(wc)
        .task { await wc.load() }
        .sheet(item: $wc.sheet) { sheet in
            ProjectSheetView(wc: wc, sheet: sheet)
        }
        .onReceive(NotificationCenter.default.publisher(for: .workingCopyChanged)) { n in
            if (n.object as? String) == wc.rootPath { Task { await wc.refresh() } }
        }
        .onChange(of: wc.windowRequest) { _, req in
            guard let req else { return }
            wc.windowRequest = nil
            switch req {
            case let .log(p): openWindow(id: "log", value: FileTarget(root: wc.rootPath, path: p))
            case let .annotate(p): openWindow(id: "annotate", value: FileTarget(root: wc.rootPath, path: p))
            case let .compare(p, m): openWindow(id: "compare", value: CompareTarget(root: wc.rootPath, path: p, mode: m))
            case .repoBrowser: openWindow(id: "browser", value: wc.rootPath)
            case .revisionGraph: openWindow(id: "graph", value: wc.rootPath)
            case let .conflictSolver(p): openWindow(id: "conflict", value: FileTarget(root: wc.rootPath, path: p))
            }
        }
    }

    private var mainPerspective: some View {
        VSplitView {
            HSplitView {
                Pane(title: L("Directories")) { DirectoryTreeView(wc: wc) }
                    .frame(minWidth: 180, idealWidth: 240, maxWidth: 500)
                Pane(title: L("Files"), accessory: { FileFilterField(wc: wc) }) { FileTableView(wc: wc) }
                    .frame(minWidth: 400)
            }
            .frame(minHeight: 220, idealHeight: 420)
            ChangesPane(wc: wc)
                .frame(minHeight: 120, idealHeight: 260)
            HSplitView {
                OutputPane(wc: wc).frame(minWidth: 250)
                TransactionsPane(wc: wc).frame(minWidth: 250)
            }
            .frame(minHeight: 90, idealHeight: 180)
        }
    }
}

/// Toolbar items are individually identified so the user can rearrange them
/// (right-click the toolbar, or Edit ▸ Configure Toolbar…).
struct MainToolbar: CustomizableToolbarContent {
    @ObservedObject var wc: WorkingCopyModel

    private var single: String? { wc.selectedFiles.count == 1 ? wc.selectedFiles.first : nil }

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "update", placement: .navigation) {
            Menu {
                Button(L("Update to HEAD")) { wc.update() }
                Button(L("Update to Revision…")) { wc.sheet = .updateToRevision }
                Button(L("Switch…")) { wc.sheet = .switchTo }
            } label: {
                Label(L("Update"), systemImage: "arrow.down.circle")
            } primaryAction: {
                wc.update()
            }
            .help(L("Update the working copy from the repository"))
        }
        ToolbarItem(id: "merge", placement: .navigation) {
            Button { wc.sheet = .merge } label: { Label(L("Merge"), systemImage: "arrow.triangle.merge") }
                .help(L("Merge changes into the working copy"))
        }
        ToolbarItem(id: "commit", placement: .navigation) {
            Button { wc.commit(paths: nil) } label: { Label(L("Commit"), systemImage: "arrow.up.circle") }
                .help(L("Commit local changes to the repository"))
        }
        ToolbarItem(id: "add") {
            Button { wc.add() } label: { Label(L("Add"), systemImage: "plus.square") }
                .help(L("Put files under version control"))
        }
        ToolbarItem(id: "remove") {
            Button { wc.remove() } label: { Label(L("Remove"), systemImage: "minus.square") }
                .disabled(wc.selectedFiles.isEmpty)
                .help(L("Remove files from version control"))
        }
        ToolbarItem(id: "move") {
            Button { wc.move() } label: { Label(L("Move"), systemImage: "arrow.right.doc.on.clipboard") }
                .disabled(wc.selectedFiles.isEmpty)
        }
        ToolbarItem(id: "revert") {
            Button { wc.revert() } label: { Label(L("Revert"), systemImage: "arrow.uturn.backward") }
                .help(L("Discard local changes"))
        }
        ToolbarItem(id: "delete") {
            Button { wc.deletePhysically() } label: { Label(L("Delete"), systemImage: "trash") }
                .disabled(wc.selectedFiles.isEmpty)
        }
        ToolbarItem(id: "resolve") {
            Button {
                if let p = single { wc.windowRequest = .conflictSolver(p) }
            } label: { Label(L("Conflict Solver"), systemImage: "exclamationmark.triangle") }
                .disabled(single.flatMap { wc.entries[$0] }?.effectiveState != .conflicted)
                .help(L("Resolve a text conflict with the 3-way merge tool"))
        }
        ToolbarItem(id: "cleanup", showsByDefault: false) {
            Button { wc.cleanUp() } label: { Label(L("Clean Up"), systemImage: "wrench.and.screwdriver") }
                .help(L("Run svn cleanup on the working copy"))
        }
        ToolbarItem(id: "changes") {
            Button {
                if let p = wc.targets.first { wc.windowRequest = .compare(p, .base) }
            } label: { Label(L("Changes"), systemImage: "rectangle.split.2x1") }
                .disabled(wc.selectedFiles.isEmpty)
        }
        ToolbarItem(id: "annotate") {
            Button {
                if let p = wc.targets.first { wc.windowRequest = .annotate(p) }
            } label: { Label(L("Annotate"), systemImage: "text.line.first.and.arrowtriangle.forward") }
                .disabled(wc.selectedFiles.isEmpty)
        }
        ToolbarItem(id: "log") {
            Button {
                wc.windowRequest = .log(wc.targets.first ?? "")
            } label: { Label(L("Log"), systemImage: "clock.arrow.circlepath") }
        }
        ToolbarItem(id: "graph") {
            Button { wc.windowRequest = .revisionGraph } label: { Label(L("Graph"), systemImage: "point.3.connected.trianglepath.dotted") }
                .help(L("Revision Graph"))
        }
        ToolbarItem(id: "browser", showsByDefault: false) {
            Button { wc.windowRequest = .repoBrowser } label: { Label(L("Repository"), systemImage: "server.rack") }
        }
        ToolbarItem(id: "refresh", showsByDefault: false) {
            Button { Task { await wc.refresh() } } label: { Label(L("Refresh"), systemImage: "arrow.clockwise") }
        }
        ToolbarItem(id: "perspective", placement: .primaryAction) {
            Picker(L("Perspective"), selection: $wc.perspective) {
                Label(L("Main"), systemImage: "rectangle.split.3x1").tag(WorkingCopyModel.Perspective.main)
                Label(L("Review"), systemImage: "checklist").tag(WorkingCopyModel.Perspective.review)
            }
            .pickerStyle(.segmented)
            .help(L("Switch between the main and the review perspective"))
        }
    }
}

// MARK: - Generic pane chrome

struct Pane<Content: View, Accessory: View>: View {
    var title: String
    var accessory: Accessory
    var content: Content

    init(title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                Spacer()
                accessory
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.bar)
            Divider()
            content
        }
    }
}

struct FileFilterField: View {
    @ObservedObject var wc: WorkingCopyModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L("File Filter"), text: $wc.filterText)
                .textFieldStyle(.plain)
                .frame(width: 200)
            if !wc.filterText.isEmpty {
                Button { wc.filterText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
    }
}

// MARK: - Bottom panes

struct OutputPane: View {
    @ObservedObject var wc: WorkingCopyModel

    var body: some View {
        Pane(title: L("Output"), accessory: {
            Button { wc.output.removeAll() } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help(L("Clear Output"))
        }) {
            ScrollViewReader { proxy in
                List(wc.output) { line in
                    Text(line.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(color(line.kind))
                        .textSelection(.enabled)
                        .id(line.id)
                }
                .listStyle(.plain)
                .onChange(of: wc.output.last?.id) {
                    if let last = wc.output.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func color(_ k: OutputLine.Kind) -> Color {
        switch k {
        case .command: return .accentColor
        case .info: return .primary
        case .error: return .red
        case .success: return .green
        }
    }
}

struct TransactionsPane: View {
    @ObservedObject var wc: WorkingCopyModel
    @Environment(\.openWindow) var openWindow

    var body: some View {
        Pane(title: L("Transactions"), accessory: {
            Button { Task { await wc.loadTransactions() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help(L("Refresh"))
        }) {
            List(wc.transactions) { e in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("r\(e.revision)").font(.caption.monospacedDigit().bold())
                        Text(e.author).font(.caption)
                        Spacer()
                        Text(e.date.map(Fmt.short) ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(e.message.lines.first ?? "").font(.caption).lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    openWindow(id: "log", value: FileTarget(root: wc.rootPath, path: ""))
                }
            }
            .listStyle(.plain)
        }
    }
}

struct StatusBar: View {
    @ObservedObject var wc: WorkingCopyModel

    var body: some View {
        HStack(spacing: 8) {
            if wc.busy {
                ProgressView().controlSize(.small)
                Text(wc.busyLabel + "…")
            } else {
                Text(L("Ready"))
            }
            Spacer()
            if let info = wc.info {
                Text(info.url).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Text("r\(info.revision)").monospacedDigit()
            }
            if wc.remoteStateLoaded {
                Image(systemName: "network").help(L("Remote state is shown"))
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.bar)
    }
}

enum Fmt {
    static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    static func short(_ d: Date) -> String { shortFormatter.string(from: d) }
}

/// Gives access to the hosting NSWindow (toolbar display mode, autosave name).
struct WindowAccessor: NSViewRepresentable {
    var configure: (NSWindow) -> Void

    final class Probe: NSView {
        var configure: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            configure?(window)
            // SwiftUI installs the toolbar after the first layout pass; configure again then.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                if let w = self?.window { self?.configure?(w) }
            }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let v = Probe()
        v.configure = configure
        return v
    }

    func updateNSView(_ nsView: Probe, context: Context) {}
}
