import Foundation

enum DiffOp: Equatable {
    case equal(Int, Int)      // left index, right index
    case delete(Int)          // left index
    case insert(Int)          // right index
}

struct DiffRow: Identifiable {
    enum Kind { case same, changed, deleted, inserted, gap }
    var id: Int
    var kind: Kind
    var leftNumber: Int?
    var rightNumber: Int?
    var left: String?
    var right: String?
}

struct DiffOptions: Equatable {
    var ignoreWhitespace = false
    var ignoreCase = false
    var ignoreLineEndings = false
    var context = 3
}

enum DiffEngine {
    /// Myers O(ND) line diff.
    static func diff(_ a: [String], _ b: [String], options: DiffOptions = DiffOptions()) -> [DiffOp] {
        func norm(_ s: String) -> String {
            var t = s
            if options.ignoreLineEndings, t.hasSuffix("\r") { t.removeLast() }
            if options.ignoreWhitespace { t = t.filter { !$0.isWhitespace } }
            if options.ignoreCase { t = t.lowercased() }
            return t
        }
        // Map lines to integer ids for fast comparison.
        var ids: [String: Int] = [:]
        let x = a.map { s -> Int in let k = norm(s); if let i = ids[k] { return i }; ids[k] = ids.count; return ids.count - 1 }
        let y = b.map { s -> Int in let k = norm(s); if let i = ids[k] { return i }; ids[k] = ids.count; return ids.count - 1 }

        // Trim common prefix and suffix.
        var pre = 0
        while pre < x.count, pre < y.count, x[pre] == y[pre] { pre += 1 }
        var suf = 0
        while suf < x.count - pre, suf < y.count - pre, x[x.count - 1 - suf] == y[y.count - 1 - suf] { suf += 1 }
        let xs = Array(x[pre..<(x.count - suf)]), ys = Array(y[pre..<(y.count - suf)])

        var ops: [DiffOp] = (0..<pre).map { .equal($0, $0) }
        ops += core(xs, ys).map {
            switch $0 {
            case let .equal(i, j): return .equal(i + pre, j + pre)
            case let .delete(i): return .delete(i + pre)
            case let .insert(j): return .insert(j + pre)
            }
        }
        ops += (0..<suf).map { .equal(x.count - suf + $0, y.count - suf + $0) }
        return ops
    }

    private static func core(_ a: [Int], _ b: [Int]) -> [DiffOp] {
        let n = a.count, m = b.count
        if n == 0 { return (0..<m).map { .insert($0) } }
        if m == 0 { return (0..<n).map { .delete($0) } }
        let max = n + m
        let offset = max
        var v = [Int](repeating: 0, count: 2 * max + 2)
        var trace: [[Int]] = []
        outer: for d in 0...max {
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                var xi: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    xi = v[offset + k + 1]
                } else {
                    xi = v[offset + k - 1] + 1
                }
                var yi = xi - k
                while xi < n, yi < m, a[xi] == b[yi] { xi += 1; yi += 1 }
                v[offset + k] = xi
                if xi >= n, yi >= m { trace.append(v); break outer }
            }
        }
        // Backtrack.
        var ops: [DiffOp] = []
        var xi = n, yi = m
        for d in stride(from: trace.count - 2, through: 0, by: -1) {
            let v = trace[d]
            let k = xi - yi
            let prevK: Int
            if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }
            let prevX = v[offset + prevK]
            let prevY = prevX - prevK
            while xi > prevX, yi > prevY {
                xi -= 1; yi -= 1
                ops.append(.equal(xi, yi))
            }
            if d > 0 {
                if xi == prevX { yi -= 1; ops.append(.insert(yi)) } else { xi -= 1; ops.append(.delete(xi)) }
            }
            xi = prevX; yi = prevY
        }
        return ops.reversed()
    }

    /// Builds side-by-side rows. In compact mode unchanged runs are collapsed to `context` lines.
    static func rows(left: [String], right: [String], ops: [DiffOp], compact: Bool, context: Int) -> [DiffRow] {
        var rows: [DiffRow] = []
        var i = 0
        while i < ops.count {
            if case let .equal(l, r) = ops[i] {
                rows.append(DiffRow(id: 0, kind: .same, leftNumber: l + 1, rightNumber: r + 1, left: left[l], right: right[r]))
                i += 1
                continue
            }
            var dels: [Int] = [], ins: [Int] = []
            while i < ops.count {
                if case let .delete(l) = ops[i] { dels.append(l) }
                else if case let .insert(r) = ops[i] { ins.append(r) }
                else { break }
                i += 1
            }
            for k in 0..<Swift.max(dels.count, ins.count) {
                let l = k < dels.count ? dels[k] : nil
                let r = k < ins.count ? ins[k] : nil
                let kind: DiffRow.Kind = (l != nil && r != nil) ? .changed : (l != nil ? .deleted : .inserted)
                rows.append(DiffRow(id: 0, kind: kind, leftNumber: l.map { $0 + 1 }, rightNumber: r.map { $0 + 1 },
                                    left: l.map { left[$0] }, right: r.map { right[$0] }))
            }
        }
        if compact { rows = collapse(rows, context: context) }
        for k in rows.indices { rows[k].id = k }
        return rows
    }

    private static func collapse(_ rows: [DiffRow], context: Int) -> [DiffRow] {
        let changed = rows.indices.filter { rows[$0].kind != .same }
        if changed.isEmpty { return rows.isEmpty ? [] : [DiffRow(id: 0, kind: .gap, left: L("No differences"))] }
        var keep = [Bool](repeating: false, count: rows.count)
        for c in changed {
            for k in Swift.max(0, c - context)...Swift.min(rows.count - 1, c + context) { keep[k] = true }
        }
        var out: [DiffRow] = []
        var skipped = 0
        for k in rows.indices {
            if keep[k] {
                if skipped > 0 {
                    out.append(DiffRow(id: 0, kind: .gap, left: String(format: L("%d unchanged lines"), skipped)))
                    skipped = 0
                }
                out.append(rows[k])
            } else {
                skipped += 1
            }
        }
        if skipped > 0 { out.append(DiffRow(id: 0, kind: .gap, left: String(format: L("%d unchanged lines"), skipped))) }
        return out
    }

    /// Unified-style rows: deletions then insertions per hunk.
    static func unifiedRows(_ sideBySide: [DiffRow]) -> [DiffRow] {
        var out: [DiffRow] = []
        var pendingIns: [DiffRow] = []
        func flush() {
            out += pendingIns
            pendingIns.removeAll()
        }
        for r in sideBySide {
            switch r.kind {
            case .same, .gap:
                flush()
                out.append(r)
            case .deleted:
                out.append(r)
            case .inserted:
                pendingIns.append(r)
            case .changed:
                out.append(DiffRow(id: 0, kind: .deleted, leftNumber: r.leftNumber, left: r.left))
                pendingIns.append(DiffRow(id: 0, kind: .inserted, rightNumber: r.rightNumber, right: r.right))
            }
        }
        flush()
        for k in out.indices { out[k].id = k }
        return out
    }
}
