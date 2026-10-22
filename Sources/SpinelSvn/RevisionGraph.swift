import SwiftUI

// MARK: - Graph model

struct GraphLane: Identifiable, Hashable {
    enum Kind { case trunk, branch, tag, other }
    var id: Int
    var path: String
    var kind: Kind
    var deletedAt: Int?
}

struct GraphNode: Identifiable, Hashable {
    var id: String { "\(lane):\(revision)" }
    var lane: Int
    var revision: Int
    var created: Bool          // lane created in this revision
    var deleted: Bool          // lane deleted in this revision
}

struct GraphEdge: Hashable {
    enum Kind { case line, copy }
    var from: GraphNode
    var to: GraphNode
    var kind: Kind
}

struct RevisionGraphModel {
    var lanes: [GraphLane] = []
    var rows: [Int] = []                 // revisions that have nodes, newest first
    var nodes: [GraphNode] = []
    var edges: [GraphEdge] = []

    /// Maps a repository path to the branch it belongs to, understanding the
    /// trunk/branches/tags convention at any depth ("/proj/branches/x/...").
    static func branchPath(_ path: String) -> (String, GraphLane.Kind)? {
        let comps = path.split(separator: "/").map(String.init)
        for (i, c) in comps.enumerated() {
            if c == "trunk" { return ("/" + comps[...i].joined(separator: "/"), .trunk) }
            if (c == "branches" || c == "tags") && i + 1 < comps.count {
                return ("/" + comps[...(i + 1)].joined(separator: "/"), c == "tags" ? .tag : .branch)
            }
            if c == "branches" || c == "tags" { return nil }   // the container directory itself
        }
        guard let first = comps.first else { return nil }
        return ("/" + first, .other)
    }

    static func build(_ entries: [LogEntry], maxRows: Int, laneFilter: String = "") -> RevisionGraphModel {
        var m = RevisionGraphModel()
        var laneIndex: [String: Int] = [:]
        var lastNode: [Int: GraphNode] = [:]            // lane -> newest node so far
        var nodesByLane: [Int: [GraphNode]] = [:]       // ascending
        var nodeRevs = Set<Int>()

        func lane(_ path: String, _ kind: GraphLane.Kind) -> Int {
            if let i = laneIndex[path] { return i }
            let i = m.lanes.count
            m.lanes.append(GraphLane(id: i, path: path, kind: kind))
            laneIndex[path] = i
            return i
        }

        for e in entries.sorted(by: { $0.revision < $1.revision }) {
            var touched: [Int: (created: Bool, deleted: Bool, copyFrom: (String, Int)?)] = [:]
            for p in e.paths {
                guard let (bp, kind) = branchPath(p.path) else { continue }
                if !laneFilter.isEmpty && !bp.localizedCaseInsensitiveContains(laneFilter) { continue }
                // A deleted branch path that is re-created later starts a new lane.
                if p.path == bp, p.action == "A" || p.action == "R", let old = laneIndex[bp], m.lanes[old].deletedAt != nil {
                    laneIndex[bp] = nil
                }
                let l = lane(bp, kind)
                var t = touched[l] ?? (false, false, nil)
                if p.path == bp {
                    if p.action == "A" || p.action == "R" {
                        t.created = true
                        if let f = p.copyFromPath, let r = p.copyFromRev { t.copyFrom = (f, r) }
                    }
                    if p.action == "D" { t.deleted = true }
                }
                touched[l] = t
            }
            for (l, t) in touched {
                let node = GraphNode(lane: l, revision: e.revision, created: t.created, deleted: t.deleted)
                m.nodes.append(node)
                nodeRevs.insert(e.revision)
                if let prev = lastNode[l], !t.created {
                    m.edges.append(GraphEdge(from: prev, to: node, kind: .line))
                }
                if let (src, srcRev) = t.copyFrom, let (sbp, _) = branchPath(src), let sl = laneIndex[sbp],
                   let source = nodesByLane[sl]?.last(where: { $0.revision <= srcRev }) {
                    m.edges.append(GraphEdge(from: source, to: node, kind: .copy))
                }
                if t.deleted { m.lanes[l].deletedAt = e.revision }
                lastNode[l] = node
                nodesByLane[l, default: []].append(node)
            }
        }
        m.rows = Array(nodeRevs.sorted(by: >).prefix(maxRows))
        if let oldest = m.rows.last {
            m.nodes = m.nodes.filter { $0.revision >= oldest }
            m.edges = m.edges.filter { $0.to.revision >= oldest && $0.from.revision >= oldest }
        }
        return m
    }
}

// MARK: - Window

struct RevisionGraphWindow: View {
    let root: String
    @State private var entries: [LogEntry] = []
    @State private var model = RevisionGraphModel()
    @State private var byRevision: [Int: LogEntry] = [:]
    @State private var selected: GraphNode?
    @State private var progress: String?
    @State private var error: String?
    @State private var laneFilter = ""
    @State private var maxRows = 500
    @State private var currentLane: String?
    /// Visible part of the graph; drawing is limited to it so large histories stay responsive.
    @State private var visibleRect: CGRect = .null
    @State private var buildTask: Task<Void, Never>?

    private let rowH: CGFloat = 26
    private let laneW: CGFloat = 150
    private let topH: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(L("Filter branches"), text: $laneFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit(rebuild)
                Stepper(String(format: L("Show %d revisions"), maxRows), value: $maxRows, in: 100...20000, step: 100)
                    .onChange(of: maxRows) { rebuild() }
                Spacer()
                if let progress { ProgressView().controlSize(.small); Text(progress).font(.caption) }
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .help(L("Refresh"))
            }
            .padding(8)
            Divider()
            if let error {
                Text(error).foregroundStyle(.red).padding()
            }
            HSplitView {
                ScrollView([.horizontal, .vertical]) {
                    if model.lanes.isEmpty {
                        ProgressView().frame(width: 400, height: 200)
                    } else {
                        graph
                    }
                }
                // Content grows after loading; without an anchor the view stays centred in it.
                .defaultScrollAnchor(.topLeading)
                .trackingVisibleRect($visibleRect)
                .background(Color(nsColor: .textBackgroundColor))
                .frame(minWidth: 400)
                details
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 500)
            }
        }
        .navigationTitle(L("Revision Graph"))
        .task { await load() }
    }

    private var graph: some View {
        let width = max(CGFloat(model.lanes.count) * laneW + 40, 400)
        let height = topH + CGFloat(model.rows.count) * rowH + 20
        var rowIndex: [Int: Int] = [:]
        for (i, r) in model.rows.enumerated() { rowIndex[r] = i }
        func point(_ n: GraphNode) -> CGPoint? {
            guard let row = rowIndex[n.revision] else { return nil }
            return CGPoint(x: 20 + CGFloat(n.lane) * laneW + laneW / 2, y: topH + CGFloat(row) * rowH + rowH / 2)
        }
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                let visible = visibleRect.isNull ? CGRect.infinite : visibleRect.insetBy(dx: -laneW, dy: -rowH * 2)
                for e in model.edges {
                    guard let a = point(e.from), let b = point(e.to),
                          visible.intersects(CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                                    width: abs(a.x - b.x) + 1, height: abs(a.y - b.y) + 1)) else { continue }
                    var path = Path()
                    path.move(to: a)
                    if e.kind == .copy {
                        path.addCurve(to: b, control1: CGPoint(x: a.x, y: (a.y + b.y) / 2),
                                      control2: CGPoint(x: b.x, y: (a.y + b.y) / 2))
                        ctx.stroke(path, with: .color(.orange), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    } else {
                        path.addLine(to: b)
                        ctx.stroke(path, with: .color(laneColor(model.lanes[e.to.lane].kind).opacity(0.7)), lineWidth: 2)
                    }
                }
                drawNodes(ctx, point, in: visible)
            }
            .frame(width: width, height: height)

            ForEach(model.lanes) { lane in
                Text(lane.path)
                    .font(.caption.bold())
                    .foregroundStyle(laneColor(lane.kind))
                    .strikethrough(lane.deletedAt != nil)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: laneW - 8, height: topH - 6)
                    .background(currentLane == lane.path ? Color.accentColor.opacity(0.15) : .clear)
                    .offset(x: 20 + CGFloat(lane.id) * laneW + 4, y: 2)
                    .help(lane.path)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { tap in
            let row = Int(((tap.location.y - topH) / rowH).rounded(.down))
            let lane = Int(((tap.location.x - 20) / laneW).rounded(.down))
            guard model.rows.indices.contains(row) else { return }
            selected = model.nodes.first { $0.lane == lane && $0.revision == model.rows[row] }
        })
    }

    /// Nodes are drawn into the Canvas rather than built as views: thousands of separate
    /// views (with tooltips and gestures) froze the window on large histories.
    private func drawNodes(_ ctx: GraphicsContext, _ point: (GraphNode) -> CGPoint?, in visible: CGRect) {
        for n in model.nodes {
            guard let p = point(n), visible.contains(p) else { continue }
            let lane = model.lanes[n.lane]
            let color = n.deleted ? Color.red : laneColor(lane.kind)
            let isSel = selected == n
            let label = ctx.resolve(Text(verbatim: "\(n.revision)").font(.system(size: 10).monospacedDigit()))
            let labelSize = label.measure(in: CGSize(width: 100, height: 20))
            let box = CGRect(x: p.x - (labelSize.width + 17) / 2, y: p.y - 8, width: labelSize.width + 17, height: 16)
            let shape = Path(roundedRect: box, cornerRadius: 4)
            // Opaque first: the selection tint alone is translucent and let the lane line show through.
            ctx.fill(shape, with: .color(Color(nsColor: .textBackgroundColor)))
            if isSel { ctx.fill(shape, with: .color(Color.accentColor.opacity(0.3))) }
            ctx.stroke(shape, with: .color(isSel ? Color.accentColor : color.opacity(0.4)))
            let glyph = CGPoint(x: box.minX + 8, y: p.y)
            if lane.kind == .tag || n.deleted {
                var image = ctx.resolve(Image(systemName: n.deleted ? "xmark.circle.fill" : "tag.fill"))
                image.shading = .color(color)
                ctx.draw(image, in: CGRect(x: glyph.x - 5, y: glyph.y - 5, width: 10, height: 10))
            } else {
                ctx.fill(Path(ellipseIn: CGRect(x: glyph.x - 5, y: glyph.y - 5, width: 10, height: 10)), with: .color(color))
            }
            ctx.draw(label, at: CGPoint(x: glyph.x + 7, y: p.y), anchor: .leading)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let n = selected, let e = byRevision[n.revision] {
                Text(verbatim: "r\(e.revision)").font(.title3.bold())
                Text(model.lanes[n.lane].path).foregroundStyle(laneColor(model.lanes[n.lane].kind))
                Text("\(e.author)  \(e.date.map(Fmt.short) ?? "")").font(.caption).foregroundStyle(.secondary)
                Divider()
                ScrollView {
                    Text(e.message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                Divider()
                List(e.paths) { p in
                    HStack(alignment: .top) {
                        Text(p.action).bold().frame(width: 14)
                        VStack(alignment: .leading) {
                            Text(p.path)
                            if let f = p.copyFromPath {
                                Text(String(format: L("(from %@@%d)"), f, p.copyFromRev ?? 0))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            } else {
                Text(L("Select a revision node to see its details"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(8)
    }

    private func laneColor(_ k: GraphLane.Kind) -> Color {
        switch k {
        case .trunk: return .blue
        case .branch: return .green
        case .tag: return .orange
        case .other: return .gray
        }
    }

    private func rebuild() {
        buildTask?.cancel()
        let entries = entries, maxRows = maxRows, laneFilter = laneFilter
        buildTask = Task {
            let m = await Task.detached(priority: .userInitiated) {
                RevisionGraphModel.build(entries, maxRows: maxRows, laneFilter: laneFilter)
            }.value
            guard !Task.isCancelled else { return }
            // Lane indices are renumbered by every build, so a kept selection could index past model.lanes.
            selected = nil
            model = m
        }
    }

    private func load() async {
        error = nil
        let i = await SVN.run(["info", "--xml", root], cwd: nil)
        guard let info = SVNParse.info(i.stdout) else { error = i.stderr; return }
        currentLane = RevisionGraphModel.branchPath(String(info.relativeURL.dropFirst()))?.0
        do {
            let store = try await LogCache.shared.update(rootURL: info.repositoryRoot, uuid: info.uuid, credentials: nil) { from, head in
                Task { @MainActor in progress = String(format: L("Updating log cache: r%d / r%d"), from, head) }
            }
            progress = nil
            entries = store.entries
            byRevision = Dictionary(uniqueKeysWithValues: store.entries.map { ($0.revision, $0) })
            rebuild()
        } catch {
            progress = nil
            self.error = error.localizedDescription
        }
    }
}

private extension View {
    /// macOS 14 has no scroll-geometry API; there the rect stays .null and everything is drawn.
    @ViewBuilder func trackingVisibleRect(_ rect: Binding<CGRect>) -> some View {
        if #available(macOS 15, *) {
            onScrollGeometryChange(for: CGRect.self, of: \.visibleRect) { _, new in rect.wrappedValue = new }
                .defaultScrollAnchor(.topLeading, for: .sizeChanges)
        } else {
            self
        }
    }
}

// MARK: - Log cache management

struct LogCacheManager: View {
    @State private var caches: [LogCache.Summary] = []
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading) {
            Text(L("Log caches store the complete repository history locally so the log and the revision graph open quickly."))
                .foregroundStyle(.secondary)
            Table(caches, selection: $selected) {
                TableColumn(L("Repository")) { c in Text(c.rootURL).lineLimit(1).truncationMode(.middle) }
                TableColumn(L("Revisions")) { c in Text(verbatim: "\(c.revisions) (r\(c.lastRevision))").monospacedDigit() }.width(110)
                TableColumn(L("Size")) { c in Text(ByteCountFormatter.string(fromByteCount: Int64(c.bytes), countStyle: .file)) }.width(80)
                TableColumn(L("Updated")) { c in Text(Fmt.short(c.updated)) }.width(130)
            }
            HStack {
                Button(L("Delete Cache")) {
                    guard let s = selected else { return }
                    Task {
                        await LogCache.shared.remove(uuid: s)
                        caches = await LogCache.shared.summaries()
                    }
                }
                .disabled(selected == nil)
                Button(L("Reveal in Finder")) {
                    NSWorkspace.shared.open(LogCache.directory)
                }
                Spacer()
            }
        }
        .padding()
        .navigationTitle(L("Manage Log Caches"))
        .task { caches = await LogCache.shared.summaries() }
    }
}
