import SwiftUI

struct ConflictFiles {
    var base: String
    var mine: String
    var theirs: String
    var baseLabel: String
    var theirsLabel: String
}

extension SVNParse {
    /// Reads the text-conflict artifact files from `svn info --xml`.
    static func conflictFiles(_ data: Data) -> ConflictFiles? {
        guard let doc = XNode.parse(data), let entry = doc.child("entry") else { return nil }
        // svn 1.14 nests <conflict> inside <wc-info>; older releases put it on the entry.
        let conflicts = (entry.child("wc-info")?.all("conflict") ?? []) + entry.all("conflict")
        guard let c = conflicts.first(where: { $0["type"] == "text" }),
              let base = c.child("prev-base-file")?.trimmed,
              let mine = c.child("prev-wc-file")?.trimmed,
              let theirs = c.child("cur-base-file")?.trimmed else { return nil }
        let versions = c.all("version")
        func label(_ side: String) -> String {
            guard let v = versions.first(where: { $0["side"] == side }) else { return "" }
            return "\(v["path-in-repos"] ?? "")@\(v["revision"] ?? "")"
        }
        return ConflictFiles(base: base, mine: mine, theirs: theirs,
                             baseLabel: label("source-left"), theirsLabel: label("source-right"))
    }
}

struct ConflictSolverWindow: View {
    let target: FileTarget
    @State private var chunks: [MergeChunk] = []
    @State private var files: ConflictFiles?
    @State private var resultText = ""
    @State private var resultEdited = false
    @State private var mineText = ""
    @State private var error: String?
    @State private var saved = false
    @State private var focus: Int?
    @Environment(\.dismiss) private var dismiss

    private var absPath: String { (target.root as NSString).appendingPathComponent(target.path) }
    private var conflictIDs: [Int] { chunks.filter { $0.kind == .conflict }.map(\.id) }
    private var unresolved: Int { chunks.filter { $0.kind == .conflict && $0.resolution == .unresolved }.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error {
                Text(error).foregroundStyle(.red).frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else {
                VSplitView {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach($chunks) { $chunk in
                                    ChunkView(chunk: $chunk, focused: focus == chunk.id)
                                        .id(chunk.id)
                                }
                            }
                            .padding(8)
                        }
                        .onChange(of: focus) { _, f in
                            if let f { withAnimation { proxy.scrollTo(f, anchor: .top) } }
                        }
                    }
                    .frame(minHeight: 250)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(L("Result")).font(.headline)
                            if resultEdited {
                                Text(L("(edited manually)")).font(.caption).foregroundStyle(.orange)
                                Button(L("Regenerate from choices")) { regenerate(force: true) }.controlSize(.small)
                            }
                            Spacer()
                        }
                        TextEditor(text: Binding(get: { resultText }, set: { resultText = $0; resultEdited = true }))
                            .font(.system(size: 11.5, design: .monospaced))
                            .border(Color.secondary.opacity(0.3))
                    }
                    .padding(8)
                    .frame(minHeight: 150)
                }
            }
        }
        .navigationTitle(String(format: L("Conflict Solver: %@"), target.path))
        .task { await load() }
        .onChange(of: chunks) { regenerate(force: false) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let files {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: L("Mine: %@"), (files.mine as NSString).lastPathComponent)).font(.caption)
                    Text(String(format: L("Theirs: %@"), files.theirsLabel)).font(.caption)
                    Text(String(format: L("Base: %@"), files.baseLabel)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(String(format: L("%d of %d conflicts unresolved"), unresolved, conflictIDs.count))
                .foregroundStyle(unresolved > 0 ? .orange : .green)
            Button { step(-1) } label: { Image(systemName: "chevron.up") }
                .help(L("Previous Conflict")).disabled(conflictIDs.isEmpty)
            Button { step(1) } label: { Image(systemName: "chevron.down") }
                .help(L("Next Conflict")).disabled(conflictIDs.isEmpty)
            Menu(L("Take All")) {
                Button(L("Mine")) { setAll(.mine) }
                Button(L("Theirs")) { setAll(.theirs) }
                Button(L("Mine, then Theirs")) { setAll(.mineThenTheirs) }
                Button(L("Theirs, then Mine")) { setAll(.theirsThenMine) }
            }
            .fixedSize()
            Button(L("Save and Mark Resolved")) { Task { await save() } }
                .keyboardShortcut("s")
                .disabled(files == nil || saved || (unresolved > 0 && !resultEdited))
                .help(L("Writes the result to the file and runs svn resolve --accept working"))
        }
        .padding(8)
    }

    private func step(_ d: Int) {
        let ids = conflictIDs
        guard !ids.isEmpty else { return }
        if let f = focus, let i = ids.firstIndex(of: f) {
            focus = ids[(i + d + ids.count) % ids.count]
        } else {
            focus = d > 0 ? ids.first : ids.last
        }
    }

    private func setAll(_ r: MergeChunk.Resolution) {
        for i in chunks.indices where chunks[i].kind == .conflict { chunks[i].resolution = r }
    }

    private func regenerate(force: Bool) {
        guard force || !resultEdited else { return }
        resultText = Merge3.result(chunks).joined(separator: "\n") + "\n"
        resultEdited = false
    }

    private func load() async {
        let r = await SVN.run(["info", "--xml", absPath], cwd: URL(fileURLWithPath: target.root))
        guard let f = SVNParse.conflictFiles(r.stdout) else {
            error = L("This file has no text conflict. Tree and property conflicts must be resolved with Mark Resolved.")
            return
        }
        func read(_ p: String) -> String? {
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: p)) else { return "" }
            return d.looksBinary ? nil : String(decoding: d, as: UTF8.self)
        }
        guard let base = read(f.base), let mine = read(f.mine), let theirs = read(f.theirs) else {
            error = L("Binary files cannot be merged here. Choose a version with Mark Resolved.")
            return
        }
        files = f
        mineText = mine
        chunks = Merge3.merge(base: base.lines, mine: mine.lines, theirs: theirs.lines)
        regenerate(force: true)
        focus = conflictIDs.first
    }

    private func save() async {
        do {
            try Self.fileText(resultText, like: mineText).write(toFile: absPath, atomically: true, encoding: .utf8)
        } catch {
            self.error = error.localizedDescription
            return
        }
        let r = await SVN.run(["resolve", "--accept", "working", absPath], cwd: URL(fileURLWithPath: target.root))
        if r.ok {
            saved = true
            NotificationCenter.default.post(name: .workingCopyChanged, object: target.root)
            dismiss()
        } else {
            error = r.stderr
        }
    }

    /// Re-joins the LF-only editor text with the newline style and final-newline presence of `original`.
    static func fileText(_ text: String, like original: String) -> String {
        let eol = original.contains("\r\n") ? "\r\n" : "\n"
        let lines = text.lines
        return lines.joined(separator: eol) + (original.hasSuffix("\n") && !lines.isEmpty ? eol : "")
    }
}

extension Notification.Name {
    /// Posted with the working-copy root path when another window changed files in it.
    static let workingCopyChanged = Notification.Name("SvnDeskWorkingCopyChanged")
}

private struct ChunkView: View {
    @Binding var chunk: MergeChunk
    var focused: Bool

    var body: some View {
        switch chunk.kind {
        case .stable:
            Text(String(format: L("%d unchanged lines"), chunk.base.count))
                .font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 4)
        case .mine, .theirs, .same:
            VStack(alignment: .leading, spacing: 2) {
                Text(chunk.kind == .mine ? L("Changed in mine (taken automatically)")
                     : chunk.kind == .theirs ? L("Changed in theirs (taken automatically)")
                     : L("Same change on both sides"))
                    .font(.caption).foregroundStyle(.secondary)
                code(chunk.result, color: chunk.kind == .theirs ? .green : .blue)
            }
        case .conflict:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(L("Conflict"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Spacer()
                    Picker("", selection: $chunk.resolution) {
                        Text(L("Unresolved")).tag(MergeChunk.Resolution.unresolved)
                        Text(L("Mine")).tag(MergeChunk.Resolution.mine)
                        Text(L("Theirs")).tag(MergeChunk.Resolution.theirs)
                        Text(L("Mine, then Theirs")).tag(MergeChunk.Resolution.mineThenTheirs)
                        Text(L("Theirs, then Mine")).tag(MergeChunk.Resolution.theirsThenMine)
                        Text(L("Base")).tag(MergeChunk.Resolution.base)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                HStack(alignment: .top, spacing: 8) {
                    side(L("Mine"), chunk.mine, .blue, chunk.resolution == .mine)
                    side(L("Base"), chunk.base, .gray, chunk.resolution == .base)
                    side(L("Theirs"), chunk.theirs, .green, chunk.resolution == .theirs)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(focused ? 0.15 : 0.07)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? Color.orange : .clear, lineWidth: 1.5))
        }
    }

    private func side(_ title: String, _ lines: [String], _ color: Color, _ chosen: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.bold()).foregroundStyle(color)
            code(lines, color: color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 4).stroke(chosen ? color : .clear, lineWidth: 2))
    }

    private func code(_ lines: [String], color: Color) -> some View {
        Text(lines.isEmpty ? L("(empty)") : lines.joined(separator: "\n"))
            .font(.system(size: 11.5, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
            .background(color.opacity(0.08))
    }
}
