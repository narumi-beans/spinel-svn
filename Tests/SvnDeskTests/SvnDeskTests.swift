import XCTest
@testable import SvnDesk

final class DiffEngineTests: XCTestCase {
    private func apply(_ a: [String], _ b: [String], _ ops: [DiffOp]) -> [String] {
        ops.compactMap {
            switch $0 {
            case let .equal(i, _): return a[i]
            case let .insert(j): return b[j]
            case .delete: return nil
            }
        }
    }

    func testDiffReconstructsRightSide() {
        let cases: [([String], [String])] = [
            ([], []), (["a"], []), ([], ["a"]),
            (["a", "b", "c"], ["a", "x", "c"]),
            (["a", "b", "c", "d"], ["b", "c", "e", "a"]),
            (Array("abcabba").map(String.init), Array("cbabac").map(String.init)),
        ]
        for (a, b) in cases {
            let ops = DiffEngine.diff(a, b)
            XCTAssertEqual(apply(a, b, ops), b, "\(a) -> \(b)")
            XCTAssertEqual(ops.filter { if case .insert = $0 { return false }; return true }.count, a.count)
        }
    }

    func testMinimalEditForSingleChange() {
        let ops = DiffEngine.diff(["a", "b", "c"], ["a", "x", "c"])
        XCTAssertEqual(ops, [.equal(0, 0), .delete(1), .insert(1), .equal(2, 2)])
        let rows = DiffEngine.rows(left: ["a", "b", "c"], right: ["a", "x", "c"], ops: ops, compact: false, context: 3)
        XCTAssertEqual(rows.map(\.kind), [.same, .changed, .same])
    }

    func testIgnoreWhitespace() {
        let ops = DiffEngine.diff(["a  b"], ["ab"], options: DiffOptions(ignoreWhitespace: true))
        XCTAssertEqual(ops, [.equal(0, 0)])
    }

    func testCompactCollapsesUnchangedRuns() {
        let a = (1...20).map(String.init)
        var b = a
        b[10] = "X"
        let rows = DiffEngine.rows(left: a, right: b, ops: DiffEngine.diff(a, b), compact: true, context: 2)
        XCTAssertEqual(rows.filter { $0.kind == .gap }.count, 2)
        XCTAssertEqual(rows.filter { $0.kind == .same }.count, 4)
    }
}

final class ParserTests: XCTestCase {
    func testStatusParsing() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <status><target path="/wc">
        <entry path="/wc/a.txt"><wc-status item="modified" props="none" revision="5">
        <commit revision="3"><author>alice</author><date>2024-01-02T03:04:05.000000Z</date></commit></wc-status>
        <repos-status item="modified" props="none"/></entry>
        <entry path="/wc/new.txt"><wc-status item="unversioned" props="none"/></entry>
        </target>
        <changelist name="cs1"><entry path="/wc/b.txt"><wc-status item="added" props="none" revision="-1" copied="true"/></entry></changelist>
        </status>
        """
        let entries = SVNParse.status(Data(xml.utf8), root: URL(fileURLWithPath: "/wc"))
        XCTAssertEqual(entries.count, 3)
        let a = entries.first { $0.path == "a.txt" }!
        XCTAssertEqual(a.item, .modified)
        XCTAssertEqual(a.committedRevision, 3)
        XCTAssertEqual(a.author, "alice")
        XCTAssertEqual(a.remoteItem, .modified)
        let b = entries.first { $0.path == "b.txt" }!
        XCTAssertEqual(b.changelist, "cs1")
        XCTAssertTrue(b.copied)
        XCTAssertEqual(entries.first { $0.path == "new.txt" }?.item, .unversioned)
    }

    func testLogParsing() {
        let xml = """
        <log><logentry revision="7"><author>bob</author><date>2024-05-06T07:08:09.123456Z</date>
        <paths><path action="A" kind="file" copyfrom-path="/trunk/x" copyfrom-rev="6">/branches/b/x</path></paths>
        <msg>Line 1
        Line 2</msg></logentry></log>
        """
        let log = SVNParse.log(Data(xml.utf8))
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log[0].revision, 7)
        XCTAssertEqual(log[0].message.lines, ["Line 1", "Line 2"])
        XCTAssertEqual(log[0].paths.first?.copyFromRev, 6)
        XCTAssertNotNil(log[0].date)
    }
}

final class Merge3Tests: XCTestCase {
    func testNonConflictingChangesMergeCleanly() {
        let base = ["a", "b", "c", "d", "e"]
        let mine = ["a", "B", "c", "d", "e"]
        let theirs = ["a", "b", "c", "d", "E", "f"]
        let chunks = Merge3.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertFalse(chunks.contains { $0.kind == .conflict })
        XCTAssertEqual(Merge3.result(chunks), ["a", "B", "c", "d", "E", "f"])
    }

    func testOverlappingChangesConflict() {
        let base = ["1", "2", "3"]
        let mine = ["1", "2 mine", "3"]
        let theirs = ["1", "2 theirs", "3"]
        var chunks = Merge3.merge(base: base, mine: mine, theirs: theirs)
        let idx = chunks.firstIndex { $0.kind == .conflict }!
        XCTAssertEqual(chunks[idx].base, ["2"])
        XCTAssertEqual(chunks[idx].mine, ["2 mine"])
        XCTAssertEqual(chunks[idx].theirs, ["2 theirs"])
        chunks[idx].resolution = .theirsThenMine
        XCTAssertEqual(Merge3.result(chunks), ["1", "2 theirs", "2 mine", "3"])
    }

    func testIdenticalChangesAreNotConflicts() {
        let chunks = Merge3.merge(base: ["x"], mine: ["y"], theirs: ["y"])
        XCTAssertEqual(chunks.map(\.kind), [.same])
        XCTAssertEqual(Merge3.result(chunks), ["y"])
    }

    func testInsertionsAtSamePointConflict() {
        let chunks = Merge3.merge(base: ["a", "b"], mine: ["a", "m", "b"], theirs: ["a", "t", "b"])
        XCTAssertEqual(chunks.filter { $0.kind == .conflict }.count, 1)
    }

    func testRealisticSvnConflict() {
        // Same scenario as the manual test: mine adds a first line and edits line 2, theirs edits line 2 and appends.
        let base = ["line1", "line2 changed", "line3", "line4", "line5"]
        let mine = ["line0 mine", "line1", "line2 MINE", "line3", "line4", "line5"]
        let theirs = ["line1", "line2 theirs", "line3", "line4", "line5", "line6 added by them"]
        let chunks = Merge3.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(chunks.filter { $0.kind == .conflict }.count, 1)
        let resolved = chunks.map { c -> MergeChunk in var c = c; if c.kind == .conflict { c.resolution = .mine }; return c }
        XCTAssertEqual(Merge3.result(resolved),
                       ["line0 mine", "line1", "line2 MINE", "line3", "line4", "line5", "line6 added by them"])
    }
}

final class GraphAndCacheTests: XCTestCase {
    private func entry(_ rev: Int, _ paths: [LogPath]) -> LogEntry {
        LogEntry(revision: rev, author: "a", date: nil, message: "m\(rev)", paths: paths)
    }

    private var sample: [LogEntry] {
        [
            entry(1, [LogPath(action: "A", path: "/trunk", kind: "dir"),
                      LogPath(action: "A", path: "/branches", kind: "dir"),
                      LogPath(action: "A", path: "/tags", kind: "dir")]),
            entry(2, [LogPath(action: "A", path: "/trunk/a.c", kind: "file")]),
            entry(3, [LogPath(action: "A", path: "/branches/feat", kind: "dir", copyFromPath: "/trunk", copyFromRev: 2)]),
            entry(4, [LogPath(action: "M", path: "/branches/feat/a.c", kind: "file")]),
            entry(5, [LogPath(action: "M", path: "/trunk/a.c", kind: "file")]),
            entry(6, [LogPath(action: "A", path: "/tags/1.0", kind: "dir", copyFromPath: "/trunk", copyFromRev: 5)]),
        ]
    }

    func testBranchPathClassification() {
        XCTAssertEqual(RevisionGraphModel.branchPath("/trunk/src/a.c")?.0, "/trunk")
        XCTAssertEqual(RevisionGraphModel.branchPath("/proj/branches/x/y")?.0, "/proj/branches/x")
        XCTAssertEqual(RevisionGraphModel.branchPath("/tags/1.0")?.1, .tag)
        XCTAssertNil(RevisionGraphModel.branchPath("/branches"))
    }

    func testGraphLanesAndCopyEdges() {
        let m = RevisionGraphModel.build(sample, maxRows: 100)
        XCTAssertEqual(m.lanes.map(\.path), ["/trunk", "/branches/feat", "/tags/1.0"])
        let copies = m.edges.filter { $0.kind == .copy }
        XCTAssertEqual(copies.count, 2)
        XCTAssertEqual(copies.first { $0.to.revision == 3 }?.from.revision, 2)
        XCTAssertEqual(copies.first { $0.to.revision == 6 }?.from.revision, 5)
        XCTAssertEqual(m.rows, [6, 5, 4, 3, 2, 1])
    }

    func testHistoryFollowsCopies() {
        let h = LogCache.history(of: "/branches/feat/a.c", in: sample, stopOnCopy: false).map(\.revision)
        XCTAssertEqual(h, [4, 3, 2])
        let stop = LogCache.history(of: "/branches/feat/a.c", in: sample, stopOnCopy: true).map(\.revision)
        XCTAssertEqual(stop, [4, 3])
    }
}

final class PegEscapeTests: XCTestCase {
    func testLocalPathsWithAtGetTrailingAt() {
        XCTAssertEqual(SVN.escapePegRevisions(["cat", "-r", "BASE", "/wc/icon@2x.png"]),
                       ["cat", "-r", "BASE", "/wc/icon@2x.png@"])
        XCTAssertEqual(SVN.escapePegRevisions(["commit", "-F", "/tmp/m@1.txt", "/wc/a@b.txt", "/wc/plain.txt"]),
                       ["commit", "-F", "/tmp/m@1.txt", "/wc/a@b.txt@", "/wc/plain.txt"])
    }

    func testCopyDestinationAndPropertyValueUntouched() {
        XCTAssertEqual(SVN.escapePegRevisions(["move", "/wc/a@b.txt", "/wc/c@d.txt"]),
                       ["move", "/wc/a@b.txt@", "/wc/c@d.txt"])
        XCTAssertEqual(SVN.escapePegRevisions(["propset", "svn:externals", "/x@1 ext", "/wc/d@x"]),
                       ["propset", "svn:externals", "/x@1 ext", "/wc/d@x@"])
        XCTAssertEqual(SVN.escapePegRevisions(["cat", "file:///repo/a@b.txt@3"]),
                       ["cat", "file:///repo/a@b.txt@3"])
    }
}

final class HistoryEdgeTests: XCTestCase {
    private func entry(_ rev: Int, _ paths: [LogPath]) -> LogEntry {
        LogEntry(revision: rev, author: "a", date: nil, message: "", paths: paths)
    }

    func testPlainReplaceEndsHistory() {
        let log = [
            entry(4, [LogPath(action: "A", path: "/trunk/f", kind: "file")]),
            entry(5, [LogPath(action: "M", path: "/trunk/f", kind: "file")]),
            entry(6, [LogPath(action: "R", path: "/trunk/f", kind: "file")]),
            entry(7, [LogPath(action: "M", path: "/trunk/f", kind: "file")]),
        ]
        XCTAssertEqual(LogCache.history(of: "/trunk/f", in: log, stopOnCopy: false).map(\.revision), [7, 6])
    }

    func testDeepestCopyWins() {
        let log = [
            entry(1, [LogPath(action: "A", path: "/trunk", kind: "dir"), LogPath(action: "A", path: "/trunk/f", kind: "file")]),
            entry(2, [LogPath(action: "A", path: "/other", kind: "dir"), LogPath(action: "A", path: "/other/g", kind: "file")]),
            entry(3, [LogPath(action: "A", path: "/b", kind: "dir", copyFromPath: "/trunk", copyFromRev: 1),
                      LogPath(action: "R", path: "/b/f", kind: "file", copyFromPath: "/other/g", copyFromRev: 2)]),
        ]
        XCTAssertEqual(LogCache.history(of: "/b/f", in: log, stopOnCopy: false).map(\.revision), [3, 2])
    }

    func testIgnorePatternEscaping() {
        XCTAssertEqual(SVN.globEscaped("file[1]*.txt?"), "file[[]1][*].txt[?]")
    }
}

final class ConflictSolverSaveTests: XCTestCase {
    func testKeepsCRLFWithoutFinalNewline() {
        XCTAssertEqual(ConflictSolverWindow.fileText("a\nB\nC\n", like: "a\r\nb\r\nc"), "a\r\nB\r\nC")
    }

    func testKeepsLFWithFinalNewline() {
        XCTAssertEqual(ConflictSolverWindow.fileText("a\nB\nC\n", like: "a\nb\nc\n"), "a\nB\nC\n")
    }
}

final class RepositoryBrowserUpTests: XCTestCase {
    func testFileURLKeepsEmptyHost() {
        XCTAssertEqual(RepositoryBrowser.parentURL(of: "file:///Users/me/repo/trunk", root: "file:///Users/me/repo"),
                       "file:///Users/me/repo")
    }

    func testHTTPSURLWithTrailingSlash() {
        XCTAssertEqual(RepositoryBrowser.parentURL(of: "https://host/svn/repo/trunk/sub/", root: "https://host/svn/repo"),
                       "https://host/svn/repo/trunk")
    }

    func testStopsAtRepositoryRoot() {
        XCTAssertEqual(RepositoryBrowser.parentURL(of: "file:///Users/me/repo", root: "file:///Users/me/repo"),
                       "file:///Users/me/repo")
    }
}

final class ProcessArgumentTests: XCTestCase {
    func testArgumentsReachTheChildByteForByte() async {
        let name = "新規ディレクトリ"          // precomposed (NFC) as typed on macOS
        let r = await SVN.run(["%s", name], cwd: nil, tool: "/usr/bin/printf")
        XCTAssertEqual(Array(r.stdout), Array(name.utf8))
    }
}

@MainActor
final class TagBranchBaseTests: XCTestCase {
    private func base(_ relativeURL: String, tag: Bool) -> String {
        let wc = WorkingCopyModel(path: "/tmp/wc")
        wc.info = WCInfo(url: "", relativeURL: relativeURL, repositoryRoot: "https://h/repo", revision: 1, uuid: "u")
        return wc.tagBranchBase(isTag: tag)
    }

    func testProjectLayouts() {
        XCTAssertEqual(base("^/proj/trunk", tag: true), "https://h/repo/proj/tags")
        XCTAssertEqual(base("^/proj/branches/feat/src", tag: false), "https://h/repo/proj/branches")
        XCTAssertEqual(base("^/trunk/sub", tag: true), "https://h/repo/tags")
        XCTAssertEqual(base("^/%E8%B3%87%E6%96%99/trunk", tag: true), "https://h/repo/%E8%B3%87%E6%96%99/tags")
    }
}
