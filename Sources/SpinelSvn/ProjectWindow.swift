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
    @SceneStorage("inspectorShown") private var inspectorShown = false

    init(path: String) {
        _wc = StateObject(wrappedValue: WorkingCopyModel(path: path))
    }

    var body: some View {
        Group {
            if wc.perspective == .review {
                ReviewView(wc: wc)
            } else {
                NavigationSplitView {
                    SidebarView(wc: wc)
                        .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 360)
                } content: {
                    FileTableView(wc: wc)
                        .navigationSplitViewColumnWidth(min: 300, ideal: 380)
                } detail: {
                    ChangesPane(wc: wc)
                        .frame(minWidth: 420)
                }
            }
        }
        .inspector(isPresented: $inspectorShown) {
            InspectorView(wc: wc)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 440)
        }
        .searchable(text: $wc.filterText, placement: .toolbar, prompt: Text(L("Filter files")))
        .navigationTitle(wc.name)
        .navigationSubtitle(subtitle)
        .toolbar(id: "spinel.main") { MainToolbar(wc: wc, inspectorShown: $inspectorShown) }
        .background(WindowAccessor { window in
            // The same window may have shown the welcome view with a transparent title bar.
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            window.styleMask.remove(.fullSizeContentView)
            window.toolbar?.isVisible = true
            window.isMovableByWindowBackground = false
            if window.frame.width < 900 {
                window.setContentSize(NSSize(width: 1280, height: 820))
                window.center()
            }
            window.toolbar?.allowsUserCustomization = true
            window.toolbar?.autosavesConfiguration = true
            window.setFrameAutosaveName("SpinelSvnProject-\(wc.rootPath)")
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

    private var subtitle: String {
        guard let info = wc.info else { return wc.rootPath }
        return "\(info.relativeURL)   r\(info.revision)"
    }
}

/// Toolbar items are individually identified so the user can rearrange them
/// (right-click the toolbar, or Edit ▸ Configure Toolbar…). Only everyday actions show by default.
struct MainToolbar: CustomizableToolbarContent {
    @ObservedObject var wc: WorkingCopyModel
    @Binding var inspectorShown: Bool

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
        ToolbarItem(id: "commit", placement: .navigation) {
            Button { wc.commit(paths: nil) } label: { Label(L("Commit"), systemImage: "arrow.up.circle") }
                .help(L("Commit local changes to the repository"))
        }
        ToolbarItem(id: "activity", placement: .navigation) {
            if wc.busy {
                ProgressView().controlSize(.small).help(wc.busyLabel)
            }
        }
        ToolbarItem(id: "merge", showsByDefault: false) {
            Button { wc.sheet = .merge } label: { Label(L("Merge"), systemImage: "arrow.triangle.merge") }
                .help(L("Merge changes into the working copy"))
        }
        ToolbarItem(id: "add") {
            Button { wc.add() } label: { Label(L("Add"), systemImage: "plus.square") }
                .help(L("Put files under version control"))
        }
        ToolbarItem(id: "revert") {
            Button { wc.revert() } label: { Label(L("Revert"), systemImage: "arrow.uturn.backward") }
                .help(L("Discard local changes"))
        }
        ToolbarItem(id: "remove", showsByDefault: false) {
            Button { wc.remove() } label: { Label(L("Remove"), systemImage: "minus.square") }
                .disabled(wc.selectedFiles.isEmpty)
                .help(L("Remove files from version control"))
        }
        ToolbarItem(id: "move", showsByDefault: false) {
            Button { wc.move() } label: { Label(L("Move"), systemImage: "arrow.right.doc.on.clipboard") }
                .disabled(wc.selectedFiles.isEmpty)
        }
        ToolbarItem(id: "delete", showsByDefault: false) {
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
        ToolbarItem(id: "changes", showsByDefault: false) {
            Button {
                if let p = wc.targets.first { wc.windowRequest = .compare(p, .base) }
            } label: { Label(L("Changes"), systemImage: "rectangle.split.2x1") }
                .disabled(wc.selectedFiles.isEmpty)
        }
        ToolbarItem(id: "annotate", showsByDefault: false) {
            Button {
                if let p = wc.targets.first { wc.windowRequest = .annotate(p) }
            } label: { Label(L("Annotate"), systemImage: "text.line.first.and.arrowtriangle.forward") }
                .disabled(wc.selectedFiles.isEmpty)
        }
        ToolbarItem(id: "log") {
            Button {
                wc.windowRequest = .log(wc.targets.first ?? "")
            } label: { Label(L("Log"), systemImage: "clock.arrow.circlepath") }
                .help(L("Log"))
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
        ToolbarItem(id: "inspector", placement: .primaryAction) {
            Button { inspectorShown.toggle() } label: { Label(L("Inspector"), systemImage: "sidebar.right") }
                .help(L("Show recent commits and activity"))
        }
    }
}

// MARK: - Inspector (recent commits, activity)

struct InspectorView: View {
    @ObservedObject var wc: WorkingCopyModel
    @SceneStorage("inspectorTab") private var tab = Tab.commits

    enum Tab: String { case commits, activity }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text(L("Recent Commits")).tag(Tab.commits)
                Text(L("Activity")).tag(Tab.activity)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            switch tab {
            case .commits: TransactionsPane(wc: wc)
            case .activity: OutputPane(wc: wc)
            }
        }
    }
}

struct OutputPane: View {
    @ObservedObject var wc: WorkingCopyModel

    var body: some View {
        ScrollViewReader { proxy in
            List(wc.output) { line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: symbol(line.kind))
                        .foregroundStyle(color(line.kind))
                        .font(.caption)
                    Text(line.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(line.kind == .error ? Color.red : .primary)
                        .textSelection(.enabled)
                }
                .id(line.id)
            }
            .listStyle(.plain)
            .overlay {
                if wc.output.isEmpty {
                    ContentUnavailableView(L("No Activity"), systemImage: "terminal",
                                           description: Text(L("svn commands run by SpinelSvn appear here.")))
                }
            }
            .onChange(of: wc.output.last?.id) {
                if let last = wc.output.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button(L("Clear Output")) { wc.output.removeAll() }
                    .controlSize(.small)
                    .disabled(wc.output.isEmpty)
            }
            .padding(8)
        }
    }

    private func symbol(_ k: OutputLine.Kind) -> String {
        switch k {
        case .command: return "chevron.right"
        case .info: return "text.alignleft"
        case .error: return "xmark.octagon.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    private func color(_ k: OutputLine.Kind) -> Color {
        switch k {
        case .command: return .secondary
        case .info: return .secondary
        case .error: return .red
        case .success: return .green
        }
    }
}

struct TransactionsPane: View {
    @ObservedObject var wc: WorkingCopyModel
    @Environment(\.openWindow) var openWindow

    var body: some View {
        List(wc.transactions) { e in
            VStack(alignment: .leading, spacing: 3) {
                Text(e.message.lines.first ?? "")
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(verbatim: "r\(e.revision)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(e.author)
                    Spacer()
                    if let d = e.date { Text(d, style: .relative) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                openWindow(id: "log", value: FileTarget(root: wc.rootPath, path: "", revision: e.revision))
            }
            .help(L("Double-click to open the log at this revision"))
        }
        .listStyle(.plain)
        .overlay {
            if wc.transactions.isEmpty {
                ContentUnavailableView(L("No Commits"), systemImage: "clock",
                                       description: Text(L("Recent commits to this branch appear here.")))
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button(L("Refresh")) { Task { await wc.loadTransactions() } }.controlSize(.small)
            }
            .padding(8)
        }
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
