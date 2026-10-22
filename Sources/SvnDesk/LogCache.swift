import Foundation

/// Persistent cache of the complete repository log (`svn log -v` of the repository root),
/// stored per repository UUID. It is updated incrementally and used by the log window
/// and the revision graph so the server is only asked for new revisions.
actor LogCache {
    static let shared = LogCache()

    struct Store: Codable {
        var rootURL: String
        var uuid: String
        var entries: [LogEntry]        // ascending by revision
        var updated: Date

        var lastRevision: Int { entries.last?.revision ?? 0 }
    }

    struct Summary: Identifiable {
        var uuid: String
        var rootURL: String
        var revisions: Int
        var lastRevision: Int
        var bytes: Int
        var updated: Date
        var id: String { uuid }
    }

    enum CacheError: LocalizedError {
        case svn(String)
        var errorDescription: String? {
            if case let .svn(m) = self { return m }
            return nil
        }
    }

    private var memory: [String: Store] = [:]
    private let chunkSize = 1000

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SvnDesk/LogCache", isDirectory: true)
    }

    private func file(_ uuid: String) -> URL { Self.directory.appendingPathComponent("\(uuid).json") }

    func cached(uuid: String) -> Store? {
        if let s = memory[uuid] { return s }
        guard let data = try? Data(contentsOf: file(uuid)),
              let s = try? JSONDecoder().decode(Store.self, from: data) else { return nil }
        memory[uuid] = s
        return s
    }

    private func save(_ s: Store) {
        memory[s.uuid] = s
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: file(s.uuid), options: .atomic) }
    }

    /// Fetches revisions newer than the cached ones. `progress` receives (fetched-up-to, head).
    func update(rootURL: String, uuid: String, credentials: SVNCredentials?,
                progress: @escaping @Sendable (Int, Int) -> Void) async throws -> Store {
        var store = cached(uuid: uuid) ?? Store(rootURL: rootURL, uuid: uuid, entries: [], updated: .distantPast)
        let info = await SVN.run(["info", "--xml", rootURL], cwd: nil, credentials: credentials)
        guard info.ok, let head = SVNParse.info(info.stdout)?.revision else {
            if store.entries.isEmpty { throw CacheError.svn(info.stderr) }
            return store      // offline: serve what we have
        }
        var from = store.lastRevision + 1
        while from <= head {
            let to = min(from + chunkSize - 1, head)
            progress(from, head)
            let r = await SVN.run(["log", "--xml", "-v", "-r", "\(from):\(to)", rootURL], cwd: nil, credentials: credentials)
            guard r.ok else { throw CacheError.svn(r.stderr) }
            let page = SVNParse.log(r.stdout).sorted { $0.revision < $1.revision }
            store.entries += page.filter { $0.revision > store.lastRevision }
            store.updated = Date()
            save(store)          // persist per chunk so an interrupted build can resume
            from = to + 1
        }
        progress(head, head)
        store.updated = Date()
        save(store)
        return store
    }

    func summaries() -> [Summary] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            let uuid = url.deletingPathExtension().lastPathComponent
            guard let s = cached(uuid: uuid) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Summary(uuid: uuid, rootURL: s.rootURL, revisions: s.entries.count,
                           lastRevision: s.lastRevision, bytes: size, updated: s.updated)
        }
    }

    func remove(uuid: String) {
        memory[uuid] = nil
        try? FileManager.default.removeItem(at: file(uuid))
    }

    /// History of one repository path (e.g. "/trunk/src/a.c"), newest first,
    /// following copies back to their source unless `stopOnCopy` is set.
    nonisolated static func history(of path: String, in entries: [LogEntry], stopOnCopy: Bool) -> [LogEntry] {
        var current = path
        var result: [LogEntry] = []
        var limit = Int.max
        for e in entries.reversed() where e.revision <= limit {
            // A revision belongs to the history if it changes the path, something below it,
            // or adds/replaces/deletes one of its ancestors (e.g. the branch copy itself).
            let touches = current == "/" || e.paths.contains {
                $0.path == current || $0.path.hasPrefix(current + "/")
                    || ($0.action != "M" && current.hasPrefix($0.path + "/"))
            }
            guard touches else { continue }
            result.append(e)
            // The deepest add/replace of `current` or an ancestor decides where history continues:
            // a copy jumps to its source, a plain add or replace starts the history here.
            let origin = e.paths
                .filter { ($0.action == "A" || $0.action == "R") && (current == $0.path || current.hasPrefix($0.path + "/")) }
                .max { $0.path.count < $1.path.count }
            guard let origin else { continue }
            guard let from = origin.copyFromPath, let fromRev = origin.copyFromRev, !stopOnCopy else { break }
            current = from + current.dropFirst(origin.path.count)
            limit = fromRev
        }
        return result
    }
}
