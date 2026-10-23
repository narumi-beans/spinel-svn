import Foundation

/// Per-project patterns for files SpinelSvn hides from its own views. They live in the app's
/// preferences only; nothing is written to the repository (unlike svn:ignore).
///
/// - `name` or `*.log` (no slash): matches that name at any depth.
/// - `build/` (trailing slash): matches a folder of that name at any depth, and everything in it.
/// - `app/tmp/*.txt` or `/docs` (any other slash): matches the path from the working-copy root.
/// A matching folder also hides everything below it.
struct ExcludeRules: Equatable {
    let patterns: [String]

    init(_ patterns: [String]) {
        self.patterns = patterns
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    var isEmpty: Bool { patterns.isEmpty }

    func excludes(_ path: String, isDirectory: Bool) -> Bool {
        guard !patterns.isEmpty, !path.isEmpty else { return false }
        let components = path.split(separator: "/").map(String.init)
        // A path is excluded if it or any of its parent folders matches.
        for depth in components.indices {
            let prefix = components[...depth].joined(separator: "/")
            let isDir = depth < components.count - 1 || isDirectory
            if patterns.contains(where: { matches($0, path: prefix, name: components[depth], isDirectory: isDir) }) {
                return true
            }
        }
        return false
    }

    private func matches(_ pattern: String, path: String, name: String, isDirectory: Bool) -> Bool {
        var p = pattern
        if p.hasSuffix("/") {
            guard isDirectory else { return false }
            p.removeLast()
        }
        let anchored = p.hasPrefix("/") || p.contains("/")
        if p.hasPrefix("/") { p.removeFirst() }
        return anchored ? glob(p, path) : glob(p, name)
    }

    private func glob(_ pattern: String, _ text: String) -> Bool {
        fnmatch(pattern, text, FNM_PATHNAME) == 0
    }
}

/// Stores each project's exclude patterns, keyed by working-copy root path.
enum ProjectExcludes {
    private static let key = "projectExcludePatterns"

    static func load(for root: String) -> [String] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: [String]])?[root] ?? []
    }

    static func save(_ patterns: [String], for root: String) {
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: [String]]) ?? [:]
        all[root] = patterns.isEmpty ? nil : patterns
        UserDefaults.standard.set(all, forKey: key)
    }
}
