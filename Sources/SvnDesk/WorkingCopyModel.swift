import AppKit
import SwiftUI

struct OutputLine: Identifiable {
    enum Kind { case command, info, error, success }
    let id = UUID()
    var kind: Kind
    var text: String
    var date = Date()
}

final class DirNode: Identifiable, Hashable {
    let path: String          // relative, "" for root
    let name: String
    var children: [DirNode]?
    var state: ItemState = .normal
    var hasLocalChanges = false

    init(path: String, name: String) {
        self.path = path
        self.name = name
    }

    var id: String { path }
    static func == (a: DirNode, b: DirNode) -> Bool { a.path == b.path }
    func hash(into h: inout Hasher) { h.combine(path) }
}

/// Which modal dialog the project window should present.
enum ProjectSheet: Identifiable {
    case commit([String])
    case input(InputRequest)
    case properties(String)
    case updateToRevision
    case switchTo
    case relocate
    case merge
    case tagBranch(isTag: Bool)
    case credentials
    case confirm(ConfirmRequest)

    var id: String {
        switch self {
        case .commit: return "commit"
        case let .input(r): return "input-\(r.title)"
        case let .properties(p): return "props-\(p)"
        case .updateToRevision: return "updrev"
        case .switchTo: return "switch"
        case .relocate: return "relocate"
        case .merge: return "merge"
        case let .tagBranch(t): return "tag-\(t)"
        case .credentials: return "credentials"
        case let .confirm(r): return "confirm-\(r.title)"
        }
    }
}

struct InputRequest {
    var title: String
    var message: String
    var initial: String
    var action: (String) -> Void
}

struct ConfirmRequest {
    var title: String
    var message: String
    var destructive: Bool
    var options: [String] = []      // optional checkbox labels
    var action: ([Bool]) -> Void
}

enum WindowRequest: Equatable {
    case log(String)
    case annotate(String)
    case compare(String, CompareMode)
    case repoBrowser
    case revisionGraph
    case conflictSolver(String)
}

/// State and operations for one opened working copy (one project window).
@MainActor
final class WorkingCopyModel: ObservableObject {
    let root: URL
    var rootPath: String { root.path }
    var name: String { root.lastPathComponent }

    @Published var info: WCInfo?
    @Published var entries: [String: StatusEntry] = [:]
    @Published var dirTree: DirNode?
    @Published var selectedDir: String? = ""
    @Published var selectedFiles: Set<String> = []
    @Published var output: [OutputLine] = []
    @Published var transactions: [LogEntry] = []
    @Published var busy = false
    @Published var busyLabel = ""
    @Published var sheet: ProjectSheet?
    @Published var windowRequest: WindowRequest?
    @Published var filterText = ""
    @Published var credentials: SVNCredentials?
    @Published var remoteStateLoaded = false
    @Published var reviewed: Set<String> = []
    /// Bumped on every refresh so views keyed on file state also reload unchanged-looking entries.
    @Published var refreshGeneration = 0
    @Published var perspective: Perspective = .main

    enum Perspective: String { case main, review }

    // View toggles (View menu), persisted as defaults for new windows.
    @Published var showSubdirFiles = Pref.bool("showSubdirFiles", false) { didSet { Pref.set("showSubdirFiles", showSubdirFiles) } }
    @Published var showUnchanged = Pref.bool("showUnchanged", true) { didSet { Pref.set("showUnchanged", showUnchanged) } }
    @Published var showUnversioned = Pref.bool("showUnversioned", true) { didSet { Pref.set("showUnversioned", showUnversioned) } }
    @Published var showIgnored = Pref.bool("showIgnored", false) {
        didSet { Pref.set("showIgnored", showIgnored); rebuildTree() }
    }
    @Published var showChangeSetFiles = Pref.bool("showChangeSetFiles", true) { didSet { Pref.set("showChangeSetFiles", showChangeSetFiles) } }
    @Published var showRemoteChanged = Pref.bool("showRemoteChanged", true) { didSet { Pref.set("showRemoteChanged", showRemoteChanged) } }

    private var pendingRetry: (() -> Void)?

    init(path: String) {
        root = URL(fileURLWithPath: path).standardizedFileURL
    }

    // MARK: Running commands

    func log(_ kind: OutputLine.Kind, _ text: String) {
        output.append(OutputLine(kind: kind, text: text))
        if output.count > 2000 { output.removeFirst(output.count - 2000) }
    }

    @discardableResult
    func svn(_ args: [String], quiet: Bool = false, cwd: URL? = nil) async -> SVNResult {
        if !quiet { log(.command, SVN.commandLine(args)) }
        let r = await SVN.run(args, cwd: cwd ?? root, credentials: credentials)
        if !quiet {
            let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { log(.info, text) }
        }
        if !r.ok {
            log(.error, r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return r
    }

    /// Runs a modifying operation with busy indicator, auth retry and a refresh afterwards.
    func perform(_ label: String, refreshAfter: Bool = true, onSuccess: (() -> Void)? = nil,
                 _ body: @escaping () async -> SVNResult?) {
        Task { [weak self] in
            guard let self else { return }
            busy = true
            busyLabel = label
            let r = await body()
            busy = false
            busyLabel = ""
            if let r {
                if r.ok {
                    log(.success, String(format: L("%@ finished."), label))
                    onSuccess?()
                } else if r.isAuthFailure {
                    pendingRetry = { [weak self] in self?.perform(label, refreshAfter: refreshAfter, onSuccess: onSuccess, body) }
                    sheet = .credentials
                    return
                }
            }
            if refreshAfter { await refresh() }
        }
    }

    func retryWithCredentials(_ c: SVNCredentials) {
        credentials = c
        SVN.sessionCredentials = c
        let retry = pendingRetry
        pendingRetry = nil
        retry?()
    }

    // MARK: Loading state

    func load() async {
        let r = await svn(["info", "--xml", rootPath], quiet: true)
        info = SVNParse.info(r.stdout)
        await refresh()
        await loadTransactions()
        if let action = AppState.shared.pendingActions.removeValue(forKey: rootPath) {
            switch action {
            case .update: update()
            case .commit: commit(paths: nil)
            }
        }
    }

    func refresh(remote: Bool = false) async {
        var args = ["status", "--xml", "-v", "--no-ignore"]
        if remote || remoteStateLoaded { args.append("-u") }
        args.append(rootPath)
        let r = await svn(args, quiet: true)
        if !r.ok && r.isAuthFailure && (remote || remoteStateLoaded) {
            pendingRetry = { [weak self] in Task { await self?.refresh(remote: true) } }
            sheet = .credentials
            return
        }
        if !r.ok && (remote || remoteStateLoaded) {
            // Server unreachable: fall back to local status instead of showing an empty list.
            remoteStateLoaded = false
            await refresh()
            return
        }
        if remote && r.ok { remoteStateLoaded = true }
        var map: [String: StatusEntry] = [:]
        for e in SVNParse.status(r.stdout, root: root) { map[e.path] = e }
        hideConflictArtifacts(&map)
        await fillCopyFrom(&map)
        entries = map
        refreshGeneration += 1
        rebuildTree()
        selectedFiles = selectedFiles.filter { map[$0] != nil }
    }

    /// svn leaves .mine/.rN/.merge-left… files next to text conflicts; show only the conflicted file.
    private func hideConflictArtifacts(_ map: inout [String: StatusEntry]) {
        let conflicted = map.values.filter { $0.item == .conflicted }.map(\.path)
        guard !conflicted.isEmpty else { return }
        for (path, e) in map where e.item == .unversioned {
            for c in conflicted where path.hasPrefix(c + ".") {
                let suffix = path.dropFirst(c.count + 1)
                if suffix == "mine" || suffix == "working" || suffix.hasPrefix("merge-left.r") || suffix.hasPrefix("merge-right.r")
                    || (suffix.hasPrefix("r") && Int(suffix.dropFirst()) != nil) {
                    map[path] = nil
                }
            }
        }
    }

    func clearRemoteState() {
        remoteStateLoaded = false
        for k in entries.keys {
            entries[k]?.remoteItem = nil
            entries[k]?.remoteProps = nil
        }
    }

    private func fillCopyFrom(_ map: inout [String: StatusEntry]) async {
        let copied = map.values.filter(\.copied).map(\.path)
        guard !copied.isEmpty else { return }
        let r = await svn(["info", "--xml", "--depth", "empty"] + copied.map(absolute), quiet: true)
        for (p, from) in SVNParse.copyFrom(r.stdout) {
            let rel = relative(p)
            map[rel]?.copyFrom = from
        }
    }

    func loadTransactions() async {
        guard let info else { return }
        let r = await svn(["log", "--xml", "-l", "50", info.url], quiet: true)
        if r.ok { transactions = SVNParse.log(r.stdout) }
    }

    func rebuildTree() {
        let fm = FileManager.default
        let rootNode = DirNode(path: "", name: name)
        func build(_ node: DirNode, depth: Int) {
            let abs = absolute(node.path)
            guard depth < 40, let items = try? fm.contentsOfDirectory(atPath: abs) else { return }
            var kids: [DirNode] = []
            for item in items.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) where item != ".svn" {
                var isDir: ObjCBool = false
                let childRel = node.path.isEmpty ? item : node.path + "/" + item
                guard fm.fileExists(atPath: (abs as NSString).appendingPathComponent(item), isDirectory: &isDir),
                      isDir.boolValue else { continue }
                let state = entries[childRel]?.effectiveState ?? .unversioned
                if state == .ignored && !showIgnored { continue }
                let child = DirNode(path: childRel, name: item)
                child.state = state
                if state != .ignored && state != .unversioned { build(child, depth: depth + 1) }
                kids.append(child)
            }
            node.children = kids.isEmpty ? nil : kids
        }
        build(rootNode, depth: 0)
        // Mark directories that contain local modifications.
        var changedDirs = Set<String>()
        for e in entries.values where e.effectiveState != .normal && e.effectiveState != .ignored {
            var d = e.directory
            while true {
                changedDirs.insert(d)
                if d.isEmpty { break }
                d = (d as NSString).deletingLastPathComponent
            }
        }
        func mark(_ n: DirNode) {
            n.hasLocalChanges = changedDirs.contains(n.path)
            n.children?.forEach(mark)
        }
        mark(rootNode)
        dirTree = rootNode
    }

    // MARK: Derived data

    var visibleFiles: [StatusEntry] {
        let dir = selectedDir ?? ""
        let filter = filterText.lowercased()
        return entries.values.filter { e in
            if e.path.isEmpty { return false }
            if e.isDirectory && e.item == .normal && e.props != "modified" { return false }
            if showSubdirFiles {
                if !dir.isEmpty && !(e.path.hasPrefix(dir + "/")) { return false }
            } else if e.directory != dir {
                return false
            }
            let remoteChanged = e.remoteItem.map { $0 != .none && $0 != .normal } ?? false
            switch e.effectiveState {
            case .normal:
                if !(showUnchanged || (showRemoteChanged && remoteChanged)) { return false }
            case .unversioned: if !showUnversioned { return false }
            case .ignored: if !showIgnored { return false }
            default: break
            }
            if !showChangeSetFiles && e.changelist != nil { return false }
            if !filter.isEmpty && !e.name.lowercased().contains(filter) { return false }
            return true
        }
    }

    var committable: [StatusEntry] {
        entries.values.filter { $0.effectiveState.isCommittable || $0.effectiveState == .conflicted || $0.props == "modified" }
            .filter { !$0.path.isEmpty || $0.props == "modified" }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Selected files, or the selected directory when no file is selected.
    var targets: [String] {
        if !selectedFiles.isEmpty { return selectedFiles.sorted() }
        return [selectedDir ?? ""]
    }

    var selectedEntries: [StatusEntry] { selectedFiles.compactMap { entries[$0] } }

    func absolute(_ rel: String) -> String {
        rel.isEmpty ? rootPath : (rootPath as NSString).appendingPathComponent(rel)
    }

    func relative(_ abs: String) -> String {
        let std = (abs as NSString).standardizingPath
        if std == rootPath { return "" }
        return std.hasPrefix(rootPath + "/") ? String(std.dropFirst(rootPath.count + 1)) : abs
    }

    func url(for rel: String) -> String? {
        guard let info else { return nil }
        return rel.isEmpty ? info.url : info.url + "/" + rel.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
    }

    enum DiffContent {
        case text(String, String)
        case message(String)
    }

    /// BASE vs working-file texts for the change preview and the review perspective.
    func diffContent(for e: StatusEntry) async -> DiffContent {
        if e.isDirectory { return .message(L("Directories have no content changes")) }
        let abs = absolute(e.path)
        let size = (try? FileManager.default.attributesOfItem(atPath: abs)[.size] as? Int) ?? 0
        if size > 5_000_000 { return .message(L("File too large to preview")) }
        let local = (try? Data(contentsOf: URL(fileURLWithPath: abs))) ?? Data()
        var base = Data()
        if ![.unversioned, .added, .ignored].contains(e.item) || e.copied {
            base = await SVN.run(["cat", "-r", "BASE", abs], cwd: root, credentials: credentials).stdout
        }
        if local.looksBinary || base.looksBinary { return .message(L("Binary file")) }
        let right = e.item == .deleted || e.item == .missing ? "" : String(decoding: local, as: UTF8.self)
        return .text(String(decoding: base, as: UTF8.self), right)
    }

    // MARK: Operations (Modify menu)

    func update(revision: String? = nil, depth: String? = nil) {
        var args = ["update"]
        if let revision, !revision.isEmpty { args += ["-r", revision] }
        if let depth { args += ["--set-depth", depth] }
        let paths = targets.map(absolute)
        perform(L("Update")) { [self] in
            let r = await svn(args + paths)
            await loadTransactions()
            return r
        }
    }

    func commit(paths: [String]?) {
        sheet = .commit(paths ?? (selectedFiles.isEmpty ? committable.map(\.path) : selectedFiles.sorted()))
    }

    func runCommit(paths: [String], message: String, keepChangelists: Bool, onSuccess: (() -> Void)? = nil) {
        AppState.shared.remember(message: message)
        perform(L("Commit"), onSuccess: onSuccess) { [self] in
            let selected = paths.compactMap { entries[$0] }
            let unversioned = selected.filter { $0.item == .unversioned }
            var commitPaths = paths.map(absolute)
            if !unversioned.isEmpty {
                // --force keeps a retry (after an auth failure) from failing on already-added items.
                let r = await svn(["add", "--parents", "--force", "--depth", "infinity"] + unversioned.map { absolute($0.path) })
                if !r.ok { return r }
                // The commit runs with --depth empty, so list the contents of new directories explicitly.
                let dirs = unversioned.filter(\.isDirectory).map { absolute($0.path) }
                if !dirs.isEmpty {
                    let st = await svn(["status", "--xml"] + dirs, quiet: true)
                    commitPaths += SVNParse.status(st.stdout, root: root)
                        .filter { $0.item == .added }.map { absolute($0.path) }
                }
            }
            let missing = selected.filter { $0.item == .missing }.map { absolute($0.path) }
            if !missing.isEmpty {
                let r = await svn(["delete"] + missing)
                if !r.ok { return r }
            }
            let msgFile = FileManager.default.temporaryDirectory.appendingPathComponent("svndesk-msg-\(UUID().uuidString).txt")
            try? message.write(to: msgFile, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: msgFile) }
            var args = ["commit", "-F", msgFile.path, "--encoding", "UTF-8", "--depth", "empty"]
            if keepChangelists { args.append("--keep-changelists") }
            let r = await svn(args + Array(NSOrderedSet(array: commitPaths)).compactMap { $0 as? String })
            await loadTransactions()
            return r
        }
    }

    func add() {
        let paths = targets.map(absolute)
        perform(L("Add")) { [self] in await svn(["add", "--parents", "--force", "--depth", "infinity"] + paths) }
    }

    func remove() {
        let paths = targets.filter { !$0.isEmpty }
        guard !paths.isEmpty else { return }
        sheet = .confirm(ConfirmRequest(
            title: L("Remove"),
            message: String(format: L("Remove %d item(s) from version control?"), paths.count),
            destructive: true, options: [L("Keep local copy")]) { [self] opts in
                var args = ["delete", "--force"]
                if opts.first == true { args.append("--keep-local") }
                // `svn delete --force` erases unversioned files for good; those are not svn's to remove.
                let versioned = paths.filter { entries[$0]?.item != .unversioned }
                for p in paths where entries[p]?.item == .unversioned && opts.first != true {
                    try? FileManager.default.trashItem(at: URL(fileURLWithPath: absolute(p)), resultingItemURL: nil)
                }
                guard !versioned.isEmpty else { Task { await refresh() }; return }
                perform(L("Remove")) { [self] in await svn(args + versioned.map(absolute)) }
            })
    }

    func revert() {
        let paths = targets
        sheet = .confirm(ConfirmRequest(
            title: L("Revert"),
            message: String(format: L("Revert local changes of %d item(s)? This cannot be undone."), paths.count),
            destructive: true, options: [L("Recurse into directories")]) { [self] opts in
                var args = ["revert"]
                if opts.first == true { args += ["--depth", "infinity"] }
                perform(L("Revert")) { [self] in await svn(args + paths.map(absolute)) }
            })
    }

    func deletePhysically() {
        let paths = targets.filter { !$0.isEmpty }
        guard !paths.isEmpty else { return }
        sheet = .confirm(ConfirmRequest(
            title: L("Delete Physically"),
            message: String(format: L("Move %d item(s) to the Trash?"), paths.count),
            destructive: true) { [self] _ in
                for p in paths {
                    do {
                        try FileManager.default.trashItem(at: URL(fileURLWithPath: absolute(p)), resultingItemURL: nil)
                        log(.info, String(format: L("Moved to Trash: %@"), p))
                    } catch {
                        log(.error, error.localizedDescription)
                    }
                }
                Task { await refresh() }
            })
    }

    func ignore() {
        let paths = targets.filter { !$0.isEmpty }
        guard !paths.isEmpty else { return }
        perform(L("Ignore")) { [self] in
            var last: SVNResult?
            for (dir, items) in Dictionary(grouping: paths, by: { ($0 as NSString).deletingLastPathComponent }) {
                let get = await svn(["propget", "svn:ignore", absolute(dir)], quiet: true)
                var patterns = get.ok ? get.text.lines.filter { !$0.isEmpty } : []
                for i in items {
                    let n = SVN.globEscaped((i as NSString).lastPathComponent)
                    if !patterns.contains(n) { patterns.append(n) }
                }
                last = await svn(["propset", "svn:ignore", patterns.joined(separator: "\n"), absolute(dir)])
            }
            return last
        }
    }

    func createDirectory() {
        let base = selectedDir ?? ""
        sheet = .input(InputRequest(title: L("Create Directory"), message: L("Name of the new directory:"), initial: "") { [self] name in
            let rel = base.isEmpty ? name : base + "/" + name
            perform(L("Create Directory")) { [self] in await svn(["mkdir", "--parents", absolute(rel)]) }
        })
    }

    func rename() {
        guard let p = targets.first, !p.isEmpty else { return }
        let old = (p as NSString).lastPathComponent
        sheet = .input(InputRequest(title: L("Rename"), message: L("New name:"), initial: old) { [self] name in
            let dst = ((p as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
            perform(L("Rename")) { [self] in await svn(["move", absolute(p), absolute(dst)]) }
        })
    }

    func move() {
        let paths = targets.filter { !$0.isEmpty }
        guard !paths.isEmpty else { return }
        sheet = .input(InputRequest(title: L("Move"), message: L("Target directory (relative to the working copy root):"),
                                    initial: selectedDir ?? "") { [self] dir in
            perform(L("Move")) { [self] in
                // With a single source, `svn move` onto a missing path renames instead of moving into it.
                if !FileManager.default.fileExists(atPath: absolute(dir)) {
                    let r = await svn(["mkdir", "--parents", absolute(dir)])
                    if !r.ok { return r }
                }
                return await svn(["move"] + paths.map(absolute) + [absolute(dir)])
            }
        })
    }

    func copy() {
        guard let p = targets.first, !p.isEmpty else { return }
        sheet = .input(InputRequest(title: L("Copy"), message: L("Copy to (relative to the working copy root):"),
                                    initial: p + "-copy") { [self] dst in
            perform(L("Copy")) { [self] in await svn(["copy", "--parents", absolute(p), absolute(dst)]) }
        })
    }

    func markResolved() {
        let paths = targets.map(absolute)
        perform(L("Mark Resolved")) { [self] in await svn(["resolve", "--accept", "working", "--depth", "infinity"] + paths) }
    }

    func cleanUp() {
        perform(L("Clean Up")) { [self] in await svn(["cleanup", rootPath]) }
    }

    func vacuum() {
        perform(L("Vacuum")) { [self] in
            await svn(["cleanup", "--vacuum-pristines", rootPath])
        }
    }

    func fixLineEndings() {
        let paths = selectedEntries.filter { !$0.isDirectory }.map(\.path)
        guard !paths.isEmpty else { return }
        perform(L("Fix Line-Endings"), refreshAfter: true) { [self] in
            for p in paths {
                let url = URL(fileURLWithPath: absolute(p))
                guard let data = try? Data(contentsOf: url), !data.looksBinary,
                      let text = String(data: data, encoding: .utf8) else { continue }
                let fixed = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                if fixed != text {
                    try? fixed.write(to: url, atomically: true, encoding: .utf8)
                    log(.info, String(format: L("Normalized line endings: %@"), p))
                }
            }
            return nil
        }
    }

    func switchTo(url: String, revision: String) {
        var args = ["switch", url, rootPath]
        if !revision.isEmpty { args.insert(contentsOf: ["-r", revision], at: 1) }
        perform(L("Switch")) { [self] in
            let r = await svn(args)
            let i = await svn(["info", "--xml", rootPath], quiet: true)
            info = SVNParse.info(i.stdout)
            await loadTransactions()
            return r
        }
    }

    func relocate(to url: String) {
        perform(L("Relocate")) { [self] in
            let r = await svn(["relocate", url, rootPath])
            let i = await svn(["info", "--xml", rootPath], quiet: true)
            info = SVNParse.info(i.stdout)
            return r
        }
    }

    func merge(source: String, range: String, dryRun: Bool) {
        var args = ["merge"]
        if !range.isEmpty { args += ["-r", range] }
        if dryRun { args.append("--dry-run") }
        args += [source, absolute(selectedDir ?? "")]
        perform(dryRun ? L("Merge (dry run)") : L("Merge"), refreshAfter: !dryRun) { [self] in await svn(args) }
    }

    func mergeTwoSources(from: String, to: String) {
        perform(L("Merge from 2 Sources")) { [self] in await svn(["merge", from, to, absolute(selectedDir ?? "")]) }
    }

    func applyPatch() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.message = L("Choose a patch file")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform(L("Apply Patch")) { [self] in await svn(["patch", url.path, rootPath]) }
    }

    func createPatch() {
        let paths = targets.map { $0.isEmpty ? "." : $0 }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name).patch"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform(L("Create Patch"), refreshAfter: false) { [self] in
            let r = await svn(["diff", "--internal-diff"] + paths, quiet: true)
            if r.ok {
                do {
                    try r.stdout.write(to: url)
                    log(.success, String(format: L("Patch written to %@"), url.path))
                } catch {
                    log(.error, error.localizedDescription)
                }
            }
            return r
        }
    }

    func exportBackup() {
        let changed = committable.filter { !$0.isDirectory && $0.item != .missing && $0.item != .deleted }
        guard !changed.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = L("Choose a directory for the backup")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let dest = dir.appendingPathComponent("\(name)-backup-\(Int(Date().timeIntervalSince1970))")
        for e in changed {
            let target = dest.appendingPathComponent(e.path)
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(atPath: absolute(e.path), toPath: target.path)
        }
        log(.success, String(format: L("Backup of %d file(s) written to %@"), changed.count, dest.path))
    }

    // MARK: Change sets

    func moveToChangeSet() {
        let paths = selectedEntries.filter { !$0.isDirectory }.map(\.path)
        guard !paths.isEmpty else { return }
        let existing = Set(entries.values.compactMap(\.changelist)).sorted().first ?? ""
        sheet = .input(InputRequest(title: L("Move to Change Set"),
                                    message: L("Change set name (empty removes the files from their change set):"),
                                    initial: existing) { [self] cl in
            perform(L("Move to Change Set")) { [self] in
                if cl.isEmpty { return await svn(["changelist", "--remove"] + paths.map(absolute)) }
                return await svn(["changelist", cl] + paths.map(absolute))
            }
        })
    }

    // MARK: Tags, branches

    func createTagOrBranch(isTag: Bool, name: String, message: String, fromWorkingCopy: Bool) {
        guard let info else { return }
        let dst = tagBranchBase(isTag: isTag) + "/" + name
        let src = fromWorkingCopy ? rootPath : info.url
        perform(isTag ? L("Add Tag") : L("Add Branch"), refreshAfter: false) { [self] in
            await svn(["copy", "--parents", src, dst, "-m", message])
        }
    }

    /// "<repo>/<project>/tags" for a working copy of "<repo>/<project>/trunk" (or of a branch/tag).
    func tagBranchBase(isTag: Bool) -> String {
        guard let info else { return "" }
        let container = isTag ? "tags" : "branches"
        let rel = String(info.relativeURL.dropFirst())     // "^/proj/trunk/sub" -> "/proj/trunk/sub"
        guard let (branch, _) = RevisionGraphModel.branchPath(rel.removingPercentEncoding ?? rel) else {
            return info.repositoryRoot + "/" + container
        }
        let project = (branch as NSString).deletingLastPathComponent
        let projectPath = branch.hasSuffix("/trunk") ? project : (project as NSString).deletingLastPathComponent
        let prefix = projectPath == "/" ? "" : projectPath
        return info.repositoryRoot + (prefix.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? prefix) + "/" + container
    }

    // MARK: Locks

    func lock(message: String) {
        let paths = selectedEntries.filter { !$0.isDirectory }.map { absolute($0.path) }
        guard !paths.isEmpty else { return }
        perform(L("Lock")) { [self] in await svn(["lock", "-m", message] + paths) }
    }

    func unlock() {
        let paths = selectedEntries.filter { !$0.isDirectory }.map { absolute($0.path) }
        guard !paths.isEmpty else { return }
        perform(L("Unlock")) { [self] in await svn(["unlock"] + paths) }
    }

    func toggleNeedsLock() {
        let files = selectedEntries.filter { !$0.isDirectory }
        guard !files.isEmpty else { return }
        perform(L("Change 'Needs Lock'")) { [self] in
            var last: SVNResult?
            for f in files {
                let has = await svn(["propget", "svn:needs-lock", absolute(f.path)], quiet: true)
                if has.ok && !has.text.isEmpty {
                    last = await svn(["propdel", "svn:needs-lock", absolute(f.path)])
                } else {
                    last = await svn(["propset", "svn:needs-lock", "*", absolute(f.path)])
                }
            }
            return last
        }
    }

    func showLockInfo() {
        let paths = selectedEntries.map { absolute($0.path) }
        guard !paths.isEmpty else { return }
        Task { await svn(["info"] + paths) }
    }

    // MARK: Properties

    func setProperty(_ name: String, value: String?, on paths: [String], recursive: Bool = false) {
        let paths = paths.map(absolute)
        perform(L("Set Property")) { [self] in
            var args = value == nil ? ["propdel", name] : ["propset", name, value!]
            if recursive { args.append("-R") }
            return await svn(args + paths)
        }
    }

    // MARK: Tools

    func openFile() {
        for p in targets { NSWorkspace.shared.open(URL(fileURLWithPath: absolute(p))) }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(targets.map { URL(fileURLWithPath: absolute($0)) })
    }

    func openInTerminal() {
        let dir = selectedDir.map(absolute) ?? rootPath
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([URL(fileURLWithPath: dir)], withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    func copyNames() { copyToPasteboard(targets.map { ($0 as NSString).lastPathComponent }.joined(separator: "\n")) }
    func copyPaths() { copyToPasteboard(targets.map(absolute).joined(separator: "\n")) }
    func copyRelativePaths() { copyToPasteboard(targets.joined(separator: "\n")) }
    func copyURLs() { copyToPasteboard(targets.compactMap(url(for:)).joined(separator: "\n")) }
    func copyRelativePathsAndRevision() {
        copyToPasteboard(targets.map { "\($0)@\(entries[$0]?.revision.map(String.init) ?? "")" }.joined(separator: "\n"))
    }

    func selectCommittable() {
        selectedFiles = Set(visibleFiles.filter { $0.effectiveState.isCommittable }.map(\.path))
    }
}
