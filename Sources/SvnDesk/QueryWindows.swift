import SwiftUI

// MARK: - Log

struct LogWindow: View {
    let target: FileTarget
    @State private var entries: [LogEntry] = []
    @State private var selected: Int?
    @State private var selectedPath: String?
    @State private var filter = ""
    @State private var loading = false
    @State private var error: String?
    @State private var reachedEnd = false
    @State private var patch: String?
    @State private var stopOnCopy = false
    @State private var progress: String?
    @AppStorage("useLogCache") private var useCache = true
    private let pageSize = 100

    private var absPath: String {
        target.path.isEmpty ? target.root : (target.root as NSString).appendingPathComponent(target.path)
    }

    private var filtered: [LogEntry] {
        guard !filter.isEmpty else { return entries }
        let f = filter.lowercased()
        return entries.filter {
            $0.message.lowercased().contains(f) || $0.author.lowercased().contains(f) || "r\($0.revision)".contains(f)
                || $0.paths.contains { $0.path.lowercased().contains(f) }
        }
    }

    private var current: LogEntry? { entries.first { $0.revision == selected } }

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                HStack {
                    TextField(L("Filter by message, author, path or revision"), text: $filter)
                        .textFieldStyle(.roundedBorder)
                    Toggle(L("Stop on copy"), isOn: $stopOnCopy)
                        .onChange(of: stopOnCopy) { Task { await reload() } }
                    Toggle(L("Use log cache"), isOn: $useCache)
                        .onChange(of: useCache) { Task { await reload() } }
                    if loading { ProgressView().controlSize(.small) }
                    if let progress { Text(progress).font(.caption).foregroundStyle(.secondary) }
                    if !useCache {
                        Button(L("Load More")) { Task { await loadMore() } }.disabled(reachedEnd || loading)
                    }
                }
                .padding(8)
                Table(filtered, selection: $selected) {
                    TableColumn(L("Revision")) { e in Text("\(e.revision)").monospacedDigit() }.width(60)
                    TableColumn(L("Date")) { e in Text(e.date.map(Fmt.short) ?? "") }.width(min: 100, ideal: 130)
                    TableColumn(L("Author"), value: \.author).width(min: 60, ideal: 100)
                    TableColumn(L("Message")) { e in Text(e.message.lines.first ?? "") }
                }
                if let error { Text(error).foregroundStyle(.red).font(.caption).padding(4) }
            }
            .frame(minHeight: 200)
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView {
                        Text(current?.message ?? "")
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(minHeight: 60, maxHeight: 140)
                    Divider()
                    List(current?.paths ?? [], selection: $selectedPath) { p in
                        HStack {
                            Text(p.action).bold().foregroundStyle(actionColor(p.action)).frame(width: 16)
                            Text(p.path)
                            if let cf = p.copyFromPath {
                                Text(String(format: L("(from %@@%d)"), cf, p.copyFromRev ?? 0)).foregroundStyle(.secondary)
                            }
                        }
                        .tag(p.path)
                    }
                }
                .frame(minWidth: 280)
                Group {
                    if let patch {
                        PatchTextView(text: patch)
                    } else {
                        Text(L("Select a changed path to see its diff")).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 400)
            }
            .frame(minHeight: 200)
        }
        .navigationTitle(String(format: L("Log: %@"), target.path.isEmpty ? (target.root as NSString).lastPathComponent : target.path))
        .task { await reload() }
        .onChange(of: selected) { selectedPath = nil; patch = nil }
        .onChange(of: selectedPath) { Task { await loadPatch() } }
    }

    private func actionColor(_ a: String) -> Color {
        switch a {
        case "A": return .green
        case "D": return .red
        case "R": return .orange
        default: return .blue
        }
    }

    private func args(from rev: Int?) -> [String] {
        var a = ["log", "--xml", "-v", "-l", String(pageSize)]
        if stopOnCopy { a.append("--stop-on-copy") }
        if let rev { a += ["-r", "\(rev):1"] }
        return a + [absPath]
    }

    private func reload() async {
        entries = []
        reachedEnd = false
        error = nil
        if useCache {
            await loadFromCache()
        } else {
            await load(args(from: nil))
        }
    }

    private func loadFromCache() async {
        loading = true
        defer { loading = false; progress = nil }
        let i = await SVN.run(["info", "--xml", absPath], cwd: URL(fileURLWithPath: target.root))
        guard let info = SVNParse.info(i.stdout) else { error = i.stderr; return }
        let repoPath = String(info.relativeURL.dropFirst()).removingPercentEncoding ?? String(info.relativeURL.dropFirst())
        do {
            let store = try await LogCache.shared.update(rootURL: info.repositoryRoot, uuid: info.uuid, credentials: nil) { from, head in
                Task { @MainActor in progress = String(format: L("Updating log cache: r%d / r%d"), from, head) }
            }
            entries = LogCache.history(of: repoPath.isEmpty ? "/" : repoPath, in: store.entries, stopOnCopy: stopOnCopy)
            reachedEnd = true
            if selected == nil { selected = entries.first?.revision }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard let last = entries.last?.revision, last > 1 else { reachedEnd = true; return }
        await load(args(from: last - 1))
    }

    private func load(_ a: [String]) async {
        loading = true
        let r = await SVN.run(a, cwd: URL(fileURLWithPath: target.root))
        loading = false
        if !r.ok { error = r.stderr; return }
        let page = SVNParse.log(r.stdout)
        if page.count < pageSize { reachedEnd = true }
        entries += page
        if selected == nil { selected = entries.first?.revision }
    }

    private func loadPatch() async {
        guard let rev = selected, let p = selectedPath else { return }
        let info = await SVN.run(["info", "--xml", target.root], cwd: nil)
        guard let root = SVNParse.info(info.stdout)?.repositoryRoot else { return }
        let encoded = p.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        let r = await SVN.run(["diff", "--internal-diff", "-c", String(rev), root + "/" + encoded + "@\(rev)"], cwd: nil)
        patch = r.ok ? (r.text.isEmpty ? L("(no textual changes)") : r.text) : r.stderr
    }
}

// MARK: - Annotate

struct AnnotateWindow: View {
    let target: FileTarget
    @State private var lines: [BlameLine] = []
    @State private var error: String?
    @State private var highlight: Int?
    @State private var messages: [Int: LogEntry] = [:]

    private var absPath: String { (target.root as NSString).appendingPathComponent(target.path) }

    var body: some View {
        VStack(spacing: 0) {
            if let error {
                Text(error).foregroundStyle(.red).padding()
            }
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { l in
                        HStack(spacing: 8) {
                            Text(l.revision.map { "r\($0)" } ?? "")
                                .frame(width: 60, alignment: .trailing)
                                .foregroundStyle(.blue)
                            Text(l.author).frame(width: 90, alignment: .leading).lineLimit(1)
                            Text(l.date.map(Fmt.short) ?? "").frame(width: 120, alignment: .leading).foregroundStyle(.secondary)
                            Text("\(l.number)").frame(width: 44, alignment: .trailing).foregroundStyle(.secondary)
                            Text(l.text.isEmpty ? " " : l.text).fixedSize()
                        }
                        .frame(minWidth: 900, alignment: .leading)
                        .background(highlight != nil && l.revision == highlight ? Color.yellow.opacity(0.25) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { highlight = l.revision }
                        .help(l.revision.flatMap { messages[$0]?.message } ?? "")
                    }
                }
                .font(.system(size: 11.5, design: .monospaced))
            }
            .background(Color(nsColor: .textBackgroundColor))
            if let h = highlight, let m = messages[h] {
                Divider()
                Text("r\(m.revision) \(m.author): \(m.message)")
                    .font(.caption)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
        }
        .navigationTitle(String(format: L("Annotate: %@"), target.path))
        .task { await load() }
    }

    private func load() async {
        let cwd = URL(fileURLWithPath: target.root)
        async let blame = SVN.run(["blame", "--xml", absPath], cwd: cwd)
        async let cat = SVN.run(["cat", "-r", "BASE", absPath], cwd: cwd)
        async let log = SVN.run(["log", "--xml", "-l", "500", absPath], cwd: cwd)
        let (b, c, lg) = await (blame, cat, log)
        if !b.ok { error = b.stderr; return }
        lines = SVNParse.blame(b.stdout, lines: c.text.lines)
        for e in SVNParse.log(lg.stdout) { messages[e.revision] = e }
    }
}

// MARK: - Compare

struct CompareWindow: View {
    let target: CompareTarget
    @State private var left = ""
    @State private var right = ""
    @State private var leftTitle = ""
    @State private var rightTitle = ""
    @State private var note: String?
    @AppStorage("diffMode") private var mode = DiffDisplayMode.sideBySide
    @AppStorage("diffCompact") private var compact = true
    @AppStorage("diffIgnoreWS") private var ignoreWS = false
    @State private var ignoreCase = false

    private var absPath: String { (target.root as NSString).appendingPathComponent(target.path) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(target.path).font(.headline)
                Spacer()
                Toggle(L("Ignore Case"), isOn: $ignoreCase).toggleStyle(.button).controlSize(.small)
                DiffControls(mode: $mode, compact: $compact, ignoreWS: $ignoreWS)
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .help(L("Reload"))
            }
            .padding(8)
            Divider()
            if let note {
                Text(note).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DiffTextView(left: left, right: right, mode: mode, compact: compact,
                             options: DiffOptions(ignoreWhitespace: ignoreWS, ignoreCase: ignoreCase),
                             leftTitle: leftTitle, rightTitle: rightTitle)
            }
        }
        .navigationTitle(String(format: L("Compare: %@"), (target.path as NSString).lastPathComponent))
        .task { await load() }
    }

    private func load() async {
        let cwd = URL(fileURLWithPath: target.root)
        let rev: String
        switch target.mode {
        case .base: rev = "BASE"
        case .head: rev = "HEAD"
        case .previous: rev = "PREV"
        }
        let r = await SVN.run(["cat", "-r", rev, absPath], cwd: cwd)
        let local = (try? Data(contentsOf: URL(fileURLWithPath: absPath))) ?? Data()
        if r.stdout.looksBinary || local.looksBinary {
            note = L("Binary file")
            return
        }
        note = nil
        left = r.ok ? r.text : ""
        right = String(decoding: local, as: UTF8.self)
        leftTitle = rev + (r.ok ? "" : " — " + r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        rightTitle = L("Working Copy")
    }
}

// MARK: - Repository browser

struct RepoItem: Identifiable, Hashable {
    var url: String
    var name: String
    var isDir: Bool
    var revision: Int?
    var author: String
    var size: Int?
    var date: Date?
    var children: [RepoItem]?
    var id: String { url }
}

struct RepositoryBrowser: View {
    let root: String
    @State private var baseURL = ""
    @State private var repositoryRoot = ""
    @State private var items: [RepoItem] = []
    @State private var selected: String?
    @State private var error: String?
    @State private var loading = false
    @State private var content: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(L("URL"), text: $baseURL).textFieldStyle(.roundedBorder).onSubmit { Task { await list() } }
                if loading { ProgressView().controlSize(.small) }
                Button(L("Go")) { Task { await list() } }
                Button(L("Up")) {
                    baseURL = Self.parentURL(of: baseURL, root: repositoryRoot)
                    Task { await list() }
                }
            }
            .padding(8)
            if let error { Text(error).foregroundStyle(.red).font(.caption).padding(4) }
            HSplitView {
                Table(items, selection: $selected) {
                    TableColumn(L("Name")) { i in
                        Label(i.name, systemImage: i.isDir ? "folder" : "doc")
                    }
                    TableColumn(L("Revision")) { i in Text(i.revision.map(String.init) ?? "").monospacedDigit() }.width(70)
                    TableColumn(L("Author"), value: \.author).width(100)
                    TableColumn(L("Size")) { i in Text(i.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "") }.width(80)
                    TableColumn(L("Date")) { i in Text(i.date.map(Fmt.short) ?? "") }.width(130)
                }
                .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                    guard let id = ids.first, let item = items.first(where: { $0.url == id }) else { return }
                    if item.isDir {
                        baseURL = item.url
                        Task { await list() }
                    }
                }
                .frame(minWidth: 450)
                ScrollView {
                    Text(content ?? L("Select a file to preview it"))
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minWidth: 250)
            }
        }
        .navigationTitle(L("Repository Browser"))
        .task {
            let r = await SVN.run(["info", "--xml", root], cwd: nil)
            let info = SVNParse.info(r.stdout)
            baseURL = info?.url ?? ""
            repositoryRoot = info?.repositoryRoot ?? ""
            await list()
        }
        .onChange(of: selected) { Task { await preview() } }
    }

    private func list() async {
        loading = true
        defer { loading = false }
        let r = await SVN.run(["list", "--xml", baseURL], cwd: nil)
        guard r.ok, let doc = XNode.parse(r.stdout), let list = doc.child("list") else {
            error = r.stderr
            return
        }
        error = nil
        content = nil
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        items = list.all("entry").map { e in
            let name = e.child("name")?.trimmed ?? ""
            let c = e.child("commit")
            return RepoItem(url: base + "/" + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name),
                            name: name, isDir: e["kind"] == "dir",
                            revision: c?["revision"].flatMap(Int.init),
                            author: c?.child("author")?.trimmed ?? "",
                            size: e.child("size").flatMap { Int($0.trimmed) },
                            date: SVNParse.date(c?.child("date")?.trimmed))
        }
        .sorted { ($0.isDir ? 0 : 1, $0.name) < ($1.isDir ? 0 : 1, $1.name) }
    }

    /// The URL one directory up, never above the repository root.
    static func parentURL(of url: String, root: String) -> String {
        func trimmed(_ s: String) -> String { s.hasSuffix("/") ? String(s.dropLast()) : s }
        let current = trimmed(url)
        guard current != trimmed(root), let u = URL(string: current) else { return current }
        return trimmed(u.deletingLastPathComponent().absoluteString)
    }

    private func preview() async {
        guard let id = selected, let item = items.first(where: { $0.url == id }), !item.isDir else {
            content = nil
            return
        }
        if (item.size ?? 0) > 2_000_000 {
            content = L("File too large to preview")
            return
        }
        let r = await SVN.run(["cat", item.url], cwd: nil)
        content = r.stdout.looksBinary ? L("Binary file") : r.text
    }
}
