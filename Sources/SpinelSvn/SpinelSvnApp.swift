import SwiftUI

struct FileTarget: Codable, Hashable {
    var root: String
    var path: String          // relative to root
    var revision: Int? = nil  // revision to select initially (log window)
}

enum CompareMode: String, Codable, Hashable {
    case base, head, previous
}

struct CompareTarget: Codable, Hashable {
    var root: String
    var path: String
    var mode: CompareMode
}

@main
struct SpinelSvnApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var app = AppState.shared

    var body: some Scene {
        WindowGroup(id: "project", for: String.self) { $path in
            ProjectWindow(path: $path)
                .environmentObject(app)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { MainCommands() }

        WindowGroup(id: "log", for: FileTarget.self) { $t in
            if let t { LogWindow(target: t) }
        }
        .defaultSize(width: 1000, height: 700)

        WindowGroup(id: "annotate", for: FileTarget.self) { $t in
            if let t { AnnotateWindow(target: t) }
        }
        .defaultSize(width: 1000, height: 700)

        WindowGroup(id: "compare", for: CompareTarget.self) { $t in
            if let t { CompareWindow(target: t) }
        }
        .defaultSize(width: 1100, height: 700)

        WindowGroup(id: "graph", for: String.self) { $root in
            if let root { RevisionGraphWindow(root: root) }
        }
        .defaultSize(width: 1100, height: 750)

        WindowGroup(id: "conflict", for: FileTarget.self) { $t in
            if let t { ConflictSolverWindow(target: t) }
        }
        .defaultSize(width: 1100, height: 800)

        Window(L("SpinelSvn Help"), id: "help") { HelpWindow() }
            .defaultSize(width: 900, height: 620)

        Window(L("Manage Log Caches"), id: "logcaches") { LogCacheManager() }
            .defaultSize(width: 760, height: 360)

        WindowGroup(id: "browser", for: String.self) { $root in
            if let root { RepositoryBrowser(root: root) }
        }
        .defaultSize(width: 900, height: 600)

        Settings { SettingsView() }
    }
}

struct MainCommands: Commands {
    @FocusedObject var wc: WorkingCopyModel?
    @Environment(\.openWindow) var openWindow

    private var noWC: Bool { wc == nil }

    /// Uses an open welcome window if there is one; otherwise opens a new window for the dialog.
    private func showWelcome(_ request: WelcomeRouter.Request) {
        if WelcomeRouter.shared.openWelcomeWindows == 0 { openWindow(id: "project") }
        WelcomeRouter.shared.request = request
    }
    private var noSel: Bool { wc?.selectedFiles.isEmpty ?? true }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L("New Project Window")) { openWindow(id: "project") }
                .keyboardShortcut("n")
        }

        CommandMenu(L("Project")) {
            Button(L("Check Out…")) { showWelcome(.checkout) }
            Button(L("Open Working Copy…")) { showWelcome(.open) }
            Button(L("Import Into Repository…")) { showWelcome(.importProject) }
            Button(L("Set Up Local Repository…")) { showWelcome(.localRepo) }
            Button(L("Open or Manage Projects…")) { openWindow(id: "project") }
                .keyboardShortcut("o")
            Divider()
            Button(L("Hidden Files…")) { wc?.sheet = .excludes }.disabled(noWC)
            Button(L("Manage Log Caches…")) { openWindow(id: "logcaches") }
            Divider()
            Button(L("Remove Working Copy from Project List")) {
                if let wc { AppState.shared.remove(path: wc.rootPath) }
            }.disabled(noWC)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button(L("Select Committable Files")) { wc?.selectCommittable() }.disabled(noWC)
            Menu(L("Copy Special")) {
                Button(L("Copy Name")) { wc?.copyNames() }
                Button(L("Copy Path")) { wc?.copyPaths() }
                Button(L("Copy Relative Path")) { wc?.copyRelativePaths() }
                Button(L("Copy Relative Path and Revision")) { wc?.copyRelativePathsAndRevision() }
                Button(L("Copy URL")) { wc?.copyURLs() }
            }.disabled(noWC)
            Button(L("Clear Output")) { wc?.output.removeAll() }.disabled(noWC)
            Button(L("Configure Toolbar…")) {
                let window = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }.first { $0.toolbar?.allowsUserCustomization == true }
                    ?? NSApp.windows.first { $0.isVisible && $0.toolbar?.allowsUserCustomization == true }
                window?.makeKeyAndOrderFront(nil)
                window?.toolbar?.runCustomizationPalette(nil)
            }
            .disabled(noWC)
        }

        CommandGroup(before: .toolbar) {
            Button(L("Refresh")) { Task { await wc?.refresh() } }
                .keyboardShortcut("r").disabled(noWC)
            if let wc {
                ViewToggles(wc: wc)
            }
            DiffPlacementPicker()
            Divider()
        }

        CommandMenu(L("Modify")) {
            Button(L("Update")) { wc?.update() }.keyboardShortcut("u").disabled(noWC)
            Button(L("Update to Revision…")) { wc?.sheet = .updateToRevision }.disabled(noWC)
            Button(L("Switch…")) { wc?.sheet = .switchTo }.disabled(noWC)
            Button(L("Relocate…")) { wc?.sheet = .relocate }.disabled(noWC)
            Divider()
            Button(L("Merge…")) { wc?.sheet = .merge }.disabled(noWC)
            Button(L("Apply Patch…")) { wc?.applyPatch() }.disabled(noWC)
            Divider()
            Button(L("Commit…")) { wc?.commit() }.keyboardShortcut("k").disabled(noWC)
            Button(L("Add")) { wc?.add() }.keyboardShortcut("+", modifiers: [.command, .option]).disabled(noWC)
            Button(L("Remove…")) { wc?.remove() }.disabled(noSel)
            Button(L("Ignore…")) { wc?.ignore() }.disabled(noSel)
            Button(L("Delete Physically…")) { wc?.deletePhysically() }.disabled(noSel)
            Divider()
            Button(L("Create Directory…")) { wc?.createDirectory() }.disabled(noWC)
            Button(L("Rename…")) { wc?.rename() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(noSel)
            Button(L("Move…")) { wc?.move() }.disabled(noSel)
            Button(L("Copy…")) { wc?.copy() }.disabled(noSel)
            Divider()
            Button(L("Revert…")) { wc?.revert() }.keyboardShortcut("z", modifiers: [.command, .option]).disabled(noWC)
            Button(L("Mark Resolved…")) { wc?.markResolved() }.disabled(noSel)
            Button(L("Fix Line-Endings…")) { wc?.fixLineEndings() }.disabled(noSel)
            Button(L("Clean Up…")) { wc?.cleanUp() }.disabled(noWC)
            Button(L("Vacuum…")) { wc?.vacuum() }.disabled(noWC)
        }

        CommandMenu(L("Change Set")) {
            Button(L("Move to Change Set…")) { wc?.moveToChangeSet() }.disabled(noSel)
        }

        CommandMenu(L("Tag+Branch")) {
            Button(L("Add Tag…")) { wc?.sheet = .tagBranch(isTag: true) }.disabled(noWC)
            Button(L("Add Branch…")) { wc?.sheet = .tagBranch(isTag: false) }.disabled(noWC)
        }

        CommandMenu(L("Query")) {
            Button(L("Open in Repository Browser")) { wc?.windowRequest = .repoBrowser }.disabled(noWC)
            Divider()
            Button(L("Compare with HEAD")) { if let p = wc?.targets.first { wc?.windowRequest = .compare(p, .head) } }.disabled(noSel)
            Button(L("Compare with Previous")) { if let p = wc?.targets.first { wc?.windowRequest = .compare(p, .previous) } }.disabled(noSel)
            Button(L("Show Changes")) { if let p = wc?.targets.first { wc?.windowRequest = .compare(p, .base) } }
                .keyboardShortcut("d").disabled(noSel)
            Divider()
            Button(L("Log…")) { if let p = wc?.targets.first { wc?.windowRequest = .log(p) } }
                .keyboardShortcut("l").disabled(noWC)
            Button(L("Annotate…")) { if let p = wc?.targets.first { wc?.windowRequest = .annotate(p) } }.disabled(noSel)
            Button(L("Revision Graph…")) { wc?.windowRequest = .revisionGraph }
                .keyboardShortcut("g", modifiers: [.command, .option]).disabled(noWC)
            Button(L("Conflict Solver…")) { if let p = wc?.targets.first { wc?.windowRequest = .conflictSolver(p) } }
                .disabled(wc?.targets.first.flatMap { wc?.entries[$0] }?.effectiveState != .conflicted)
            Divider()
            Button(L("Create Patch…")) { wc?.createPatch() }.disabled(noWC)
            Button(L("Export Backup…")) { wc?.exportBackup() }.disabled(noWC)
            Divider()
            Button(L("Refresh Remote State")) { Task { await wc?.refresh(remote: true) } }
                .keyboardShortcut("r", modifiers: [.command, .option]).disabled(noWC)
            Button(L("Clear Remote State")) { wc?.clearRemoteState() }.disabled(noWC)
        }

        CommandMenu(L("Properties")) {
            Button(L("Edit Properties…")) { if let p = wc?.targets.first { wc?.sheet = .properties(p) } }.disabled(noWC)
            Divider()
            Button(L("Ignore Patterns…")) {
                if let wc { wc.sheet = .properties(wc.selectedDir ?? "") }
            }.disabled(noWC)
            Button(L("Externals…")) {
                if let wc { wc.sheet = .properties(wc.selectedDir ?? "") }
            }.disabled(noWC)
        }

        CommandMenu(L("Locks")) {
            Button(L("Lock…")) {
                wc?.sheet = .input(InputRequest(title: L("Lock"), message: L("Lock comment:"), initial: "") { m in wc?.lock(message: m) })
            }.disabled(noSel)
            Button(L("Unlock…")) { wc?.unlock() }.disabled(noSel)
            Button(L("Show Info")) { wc?.showLockInfo() }.disabled(noSel)
            Button(L("Change 'Needs Lock'")) { wc?.toggleNeedsLock() }.disabled(noSel)
        }

        CommandGroup(before: .windowList) {
            Button(L("Main Perspective")) { wc?.perspective = .main }
                .keyboardShortcut("1", modifiers: [.command, .option]).disabled(noWC)
            Button(L("Review Perspective")) { wc?.perspective = .review }
                .keyboardShortcut("2", modifiers: [.command, .option]).disabled(noWC)
            Divider()
        }

        CommandGroup(replacing: .help) {
            Button(L("SpinelSvn Help")) { openWindow(id: "help") }
                .keyboardShortcut("?", modifiers: .command)
        }

        CommandMenu(L("Tools")) {
            Button(L("Open File")) { wc?.openFile() }.disabled(noSel)
            Button(L("Reveal in Finder")) { wc?.revealInFinder() }.disabled(noWC)
            Button(L("Open in Terminal")) { wc?.openInTerminal() }.disabled(noWC)
        }
    }
}

private struct ViewToggles: View {
    @ObservedObject var wc: WorkingCopyModel

    var body: some View {
        Toggle(L("Files from Subdirectories"), isOn: $wc.showSubdirFiles)
        Toggle(L("Unchanged Files"), isOn: $wc.showUnchanged)
        Toggle(L("Unversioned Files"), isOn: $wc.showUnversioned)
        Toggle(L("Ignored Files"), isOn: $wc.showIgnored)
        Toggle(L("Files Assigned to Change Set"), isOn: $wc.showChangeSetFiles)
        Toggle(L("Remote Changed Files"), isOn: $wc.showRemoteChanged)
    }
}

/// Lets menu commands ask the welcome view to open a specific dialog.
final class WelcomeRouter: ObservableObject {
    static let shared = WelcomeRouter()
    enum Request { case checkout, open, importProject, localRepo }
    @Published var request: Request?
    var openWelcomeWindows = 0
}
