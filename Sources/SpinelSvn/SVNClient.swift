import Foundation

// MARK: - Process runner

struct SVNResult {
    var status: Int32
    var stdout: Data
    var stderr: String

    var ok: Bool { status == 0 }
    var text: String { String(decoding: stdout, as: UTF8.self) }
    var isAuthFailure: Bool {
        stderr.contains("E170001") || stderr.contains("E215004") || stderr.contains("Authentication")
    }
}

struct SVNCredentials: Equatable {
    var username: String
    var password: String
}

enum SVN {
    static let candidatePaths = ["/opt/homebrew/bin/svn", "/usr/local/bin/svn", "/usr/bin/svn"]

    static var executable: String {
        if let custom = UserDefaults.standard.string(forKey: "svnPath"), !custom.isEmpty,
           FileManager.default.isExecutableFile(atPath: custom) {
            return custom
        }
        return candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "svn"
    }

    static var svnadmin: String {
        let dir = (executable as NSString).deletingLastPathComponent
        let path = (dir as NSString).appendingPathComponent("svnadmin")
        return FileManager.default.isExecutableFile(atPath: path) ? path : "svnadmin"
    }

    /// Commands that never need the network or credentials.
    private static let localCommands: Set<String> = [
        "status", "add", "revert", "resolve", "cleanup", "changelist", "propset", "propdel",
        "proplist", "propget", "mkdir", "move", "rename", "patch", "upgrade"
    ]


    static func run(_ args: [String], cwd: URL?, credentials: SVNCredentials? = nil,
                    tool: String? = nil) async -> SVNResult {
        var full = tool == nil ? escapePegRevisions(args) : args
        var stdin: String?
        if tool == nil {
            full.append("--non-interactive")
            if let c = credentials ?? CredentialStore.shared.lookup(args: args, cwd: cwd), !localCommands.contains(args.first ?? "") || args.contains("-u") {
                // --password-from-stdin keeps the password out of the process list.
                full += ["--username", c.username, "--password-from-stdin"]
                stdin = c.password
            }
        }
        let exe = tool ?? executable
        return await withCheckedContinuation { [full, stdin] cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runSync(exe, full, cwd: cwd, stdin: stdin))
            }
        }
    }

    /// Escapes fnmatch metacharacters so an svn:ignore entry matches only this exact name.
    static func globEscaped(_ name: String) -> String {
        name.map { "[*?".contains($0) ? "[\($0)]" : String($0) }.joined()
    }

    /// svn reads the text after the last "@" of a target as a peg revision, so a local path
    /// containing "@" (e.g. "icon@2x.png") must end in "@". The destination of copy-like
    /// commands is a new path and would get the "@" literally, so it is left alone.
    static func escapePegRevisions(_ args: [String]) -> [String] {
        let command = args.first ?? ""
        let destination: Int? = ["move", "copy", "checkout", "import", "export"].contains(command)
            ? args.lastIndex { $0.hasPrefix("/") } : nil
        let valueOptions: Set<String> = ["-F", "--file", "--targets", "-m", "--message"]
        return args.enumerated().map { i, arg in
            guard arg.hasPrefix("/"), arg.contains("@"), i != destination,
                  i == 0 || !valueOptions.contains(args[i - 1]),
                  !(command == "propset" && i == 2) else { return arg }
            return arg + "@"
        }
    }

    /// Spawns with posix_spawn instead of Foundation's Process: Process passes arguments through
    /// fileSystemRepresentation, which decomposes "デ" into "テ"+"゛" (NFD). svn compares names
    /// byte for byte, so a decomposed path no longer matches the precomposed name on disk.
    private static func runSync(_ exe: String, _ args: [String], cwd: URL?, stdin: String? = nil) -> SVNResult {
        let argv = (exe.hasPrefix("/") ? [exe] : ["/usr/bin/env", exe]) + args
        var env = ProcessInfo.processInfo.environment
        env["LC_CTYPE"] = "UTF-8"
        env["LANG"] = "en_US.UTF-8"
        let out = Pipe(), err = Pipe(), input = Pipe()

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, input.fileHandleForReading.fileDescriptor, 0)
        posix_spawn_file_actions_adddup2(&actions, out.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&actions, err.fileHandleForWriting.fileDescriptor, 2)
        if let cwd { posix_spawn_file_actions_addchdir_np(&actions, cwd.path) }

        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (cArgs + cEnv).forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &actions, nil, cArgs, cEnv)
        try? input.fileHandleForReading.close()
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        guard rc == 0 else {
            return SVNResult(status: -1, stdout: Data(), stderr: "\(exe): \(String(cString: strerror(rc)))")
        }
        if let stdin { input.fileHandleForWriting.write(Data((stdin + "\n").utf8)) }
        try? input.fileHandleForWriting.close()

        // Read both pipes concurrently so a full stderr buffer can't block the child.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        let exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -(status & 0x7f)
        return SVNResult(status: exitCode, stdout: outData, stderr: String(decoding: errData, as: UTF8.self))
    }

    /// Display form of an svn command line (credentials are appended later by `run`, so never shown).
    static func commandLine(_ args: [String]) -> String {
        "svn " + args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }
}

/// Credentials entered in any window, per repository root, so windows that have none of
/// their own (log, annotate, graph, …) can reach the same server.
final class CredentialStore {
    static let shared = CredentialStore()
    private let lock = NSLock()
    private var byRepository: [String: SVNCredentials] = [:]
    private var repositoryOfWorkingCopy: [String: String] = [:]

    func save(_ c: SVNCredentials, repository: String) {
        lock.withLock { byRepository[repository] = c }
    }

    func register(workingCopy root: String, repository: String) {
        lock.withLock { repositoryOfWorkingCopy[root] = repository }
    }

    /// Finds credentials for the first URL or working-copy path among the arguments (or the cwd).
    func lookup(args: [String], cwd: URL?) -> SVNCredentials? {
        lock.withLock {
            for arg in args + [cwd?.path].compactMap({ $0 }) {
                let repository = arg.contains("://") ? arg : repositoryOfWorkingCopy.first {
                    arg == $0.key || arg.hasPrefix($0.key + "/")
                }?.value
                guard let repository else { continue }
                if let match = byRepository.first(where: { repository.hasPrefix($0.key) || $0.key.hasPrefix(repository) }) {
                    return match.value
                }
            }
            return nil
        }
    }
}

// MARK: - Minimal XML DOM

final class XNode {
    let name: String
    let attrs: [String: String]
    var children: [XNode] = []
    var text = ""

    init(name: String, attrs: [String: String]) {
        self.name = name
        self.attrs = attrs
    }

    func child(_ n: String) -> XNode? { children.first { $0.name == n } }
    func all(_ n: String) -> [XNode] { children.filter { $0.name == n } }
    subscript(_ a: String) -> String? { attrs[a] }
    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func parse(_ data: Data) -> XNode? {
        let b = Builder()
        let p = XMLParser(data: data)
        p.delegate = b
        return p.parse() ? b.root : nil
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XNode?
        var stack: [XNode] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let n = XNode(name: elementName, attrs: attributeDict)
            if let top = stack.last { top.children.append(n) } else { root = n }
            stack.append(n)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            stack.removeLast()
        }
    }
}

// MARK: - Models

enum ItemState: String, CaseIterable {
    case normal, modified, added, deleted, replaced, conflicted, missing, unversioned
    case ignored, external, incomplete, obstructed, merged, none

    var isCommittable: Bool {
        [.modified, .added, .deleted, .replaced, .missing, .unversioned].contains(self)
    }

    var label: String {
        switch self {
        case .normal: return L("Unchanged")
        case .modified: return L("Modified")
        case .added: return L("Added")
        case .deleted: return L("Removed")
        case .replaced: return L("Replaced")
        case .conflicted: return L("Conflict")
        case .missing: return L("Missing")
        case .unversioned: return L("Unversioned")
        case .ignored: return L("Ignored")
        case .external: return L("External")
        case .incomplete: return L("Incomplete")
        case .obstructed: return L("Obstructed")
        case .merged: return L("Merged")
        case .none: return ""
        }
    }
}

struct StatusEntry: Identifiable, Hashable {
    var path: String              // relative to working copy root, "/" separated; "" for root
    var item: ItemState
    var props: String             // none, normal, modified, conflicted
    var revision: Int?
    var committedRevision: Int?
    var author: String?
    var copied: Bool
    var treeConflicted: Bool
    var locked: Bool
    var changelist: String?
    var remoteItem: ItemState?
    var remoteProps: String?
    var copyFrom: String?
    var isDirectory: Bool

    var id: String { path }
    var name: String { path.isEmpty ? "." : (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }

    var effectiveState: ItemState {
        if treeConflicted || props == "conflicted" { return .conflicted }
        if item == .normal && props == "modified" { return .modified }
        return item
    }

    var localStateLabel: String {
        var s = effectiveState.label
        if item == .normal && props == "modified" { s = L("Modified (Properties)") }
        if item == .modified && props == "modified" { s = L("Modified (Content+Properties)") }
        if treeConflicted { s = L("Tree Conflict") }
        if copied && item == .added { s = L("Added (Copied)") }
        if locked { s += " 🔒" }
        return s
    }

    var remoteStateLabel: String {
        guard let r = remoteItem else { return "" }
        if r == .none, remoteProps == "modified" { return L("Modified (Properties)") }
        return r == .none ? "" : r.label
    }
}

struct WCInfo {
    var url: String
    var relativeURL: String
    var repositoryRoot: String
    var revision: Int
    var uuid: String
}

struct LogPath: Hashable, Identifiable, Codable {
    var action: String          // A M D R
    var path: String
    var kind: String
    var copyFromPath: String?
    var copyFromRev: Int?
    var id: String { action + path }
}

struct LogEntry: Identifiable, Hashable, Codable {
    var revision: Int
    var author: String
    var date: Date?
    var message: String
    var paths: [LogPath]
    var id: Int { revision }
}

struct BlameLine: Identifiable {
    var number: Int
    var revision: Int?
    var author: String
    var date: Date?
    var text: String
    var id: Int { number }
}

struct PropEntry: Identifiable, Hashable {
    var name: String
    var value: String
    var id: String { name }
}

enum SVNParse {
    static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return dateFormatter.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    /// Parses `svn status --xml`. Paths are made relative to `root`.
    static func status(_ data: Data, root: URL) -> [StatusEntry] {
        guard let doc = XNode.parse(data) else { return [] }
        let rootPath = root.standardizedFileURL.path
        var result: [StatusEntry] = []

        func rel(_ p: String) -> String {
            let abs = p.hasPrefix("/") ? p : (rootPath as NSString).appendingPathComponent(p)
            let std = (abs as NSString).standardizingPath
            if std == rootPath { return "" }
            if std.hasPrefix(rootPath + "/") { return String(std.dropFirst(rootPath.count + 1)) }
            return p
        }

        func add(_ e: XNode, changelist: String?) {
            guard let wc = e.child("wc-status"), let p = e["path"] else { return }
            let commit = wc.child("commit")
            let repos = e.child("repos-status")
            let relPath = rel(p)
            var isDir = false
            var d: ObjCBool = false
            if FileManager.default.fileExists(atPath: (rootPath as NSString).appendingPathComponent(relPath), isDirectory: &d) {
                isDir = d.boolValue
            }
            result.append(StatusEntry(
                path: relPath,
                item: ItemState(rawValue: wc["item"] ?? "none") ?? .none,
                props: wc["props"] ?? "none",
                revision: wc["revision"].flatMap(Int.init),
                committedRevision: commit?["revision"].flatMap(Int.init),
                author: commit?.child("author")?.trimmed,
                copied: wc["copied"] == "true",
                treeConflicted: wc["tree-conflicted"] == "true",
                locked: wc.child("lock") != nil,
                changelist: changelist,
                remoteItem: repos.flatMap { ItemState(rawValue: $0["item"] ?? "none") },
                remoteProps: repos?["props"],
                copyFrom: nil,
                isDirectory: isDir))
        }

        for target in doc.all("target") {
            for e in target.all("entry") { add(e, changelist: nil) }
        }
        for cl in doc.all("changelist") {
            for e in cl.all("entry") { add(e, changelist: cl["name"]) }
        }
        return result
    }

    static func info(_ data: Data) -> WCInfo? {
        guard let doc = XNode.parse(data), let entry = doc.child("entry") else { return nil }
        let repo = entry.child("repository")
        return WCInfo(url: entry.child("url")?.trimmed ?? "",
                      relativeURL: entry.child("relative-url")?.trimmed ?? "",
                      repositoryRoot: repo?.child("root")?.trimmed ?? "",
                      revision: Int(entry["revision"] ?? "") ?? 0,
                      uuid: repo?.child("uuid")?.trimmed ?? "")
    }

    /// Returns path -> copy-from URL@rev for entries of `svn info --xml`.
    static func copyFrom(_ data: Data) -> [String: String] {
        guard let doc = XNode.parse(data) else { return [:] }
        var map: [String: String] = [:]
        for e in doc.all("entry") {
            guard let p = e["path"], let wci = e.child("wc-info"),
                  let url = wci.child("copy-from-url")?.trimmed else { continue }
            let rev = wci.child("copy-from-rev")?.trimmed ?? ""
            map[p] = rev.isEmpty ? url : "\(url)@\(rev)"
        }
        return map
    }

    static func log(_ data: Data) -> [LogEntry] {
        guard let doc = XNode.parse(data) else { return [] }
        return doc.all("logentry").compactMap { e in
            guard let rev = e["revision"].flatMap(Int.init) else { return nil }
            let paths = e.child("paths")?.all("path").map {
                LogPath(action: $0["action"] ?? "", path: $0.trimmed, kind: $0["kind"] ?? "",
                        copyFromPath: $0["copyfrom-path"], copyFromRev: $0["copyfrom-rev"].flatMap(Int.init))
            } ?? []
            return LogEntry(revision: rev,
                            author: e.child("author")?.trimmed ?? "",
                            date: date(e.child("date")?.trimmed),
                            message: e.child("msg")?.text ?? "",
                            paths: paths)
        }
    }

    static func blame(_ data: Data, lines: [String]) -> [BlameLine] {
        guard let doc = XNode.parse(data), let target = doc.child("target") else { return [] }
        return target.all("entry").enumerated().map { i, e in
            let c = e.child("commit")
            return BlameLine(number: Int(e["line-number"] ?? "") ?? i + 1,
                             revision: c?["revision"].flatMap(Int.init),
                             author: c?.child("author")?.trimmed ?? "",
                             date: date(c?.child("date")?.trimmed),
                             text: i < lines.count ? lines[i] : "")
        }
    }

    /// Keeps the "Index: <path>" sections of a unified diff that belong to `paths`
    /// (a directory keeps everything below it, "" keeps everything).
    static func patchSections(_ patch: String, keeping paths: [String]) -> String {
        var out: [String] = []
        var keep = false
        for line in patch.components(separatedBy: "\n") {
            if line.hasPrefix("Index: ") {
                let file = String(line.dropFirst(7))
                keep = paths.contains { $0.isEmpty || file == $0 || file.hasPrefix($0 + "/") }
            }
            if keep { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    static func props(_ data: Data) -> [PropEntry] {
        guard let doc = XNode.parse(data), let target = doc.child("target") else { return [] }
        return target.all("property").map { PropEntry(name: $0["name"] ?? "", value: $0.text) }
    }
}

extension String {
    /// Splits text into lines without the trailing empty element for a final newline.
    var lines: [String] {
        var parts = components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        if parts.last == "" { parts.removeLast() }
        return parts
    }
}

extension String {
    /// Lines that keep a trailing "\r", so a diff can see line-ending changes.
    var linesKeepingCR: [String] {
        var parts = components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }
}

extension Data {
    var looksBinary: Bool { prefix(8000).contains(0) }
}
