import Foundation

/// One region of a three-way merge between a common base and two derived versions.
struct MergeChunk: Identifiable, Equatable {
    enum Kind: Equatable {
        case stable          // unchanged on both sides
        case mine            // changed only in mine
        case theirs          // changed only in theirs
        case same            // changed identically on both sides
        case conflict        // changed differently on both sides
    }

    enum Resolution: String, CaseIterable, Equatable {
        case unresolved, mine, theirs, mineThenTheirs, theirsThenMine, base
    }

    var id: Int
    var kind: Kind
    var base: [String]
    var mine: [String]
    var theirs: [String]
    var resolution: Resolution

    /// Lines contributed to the merged result.
    var result: [String] {
        switch kind {
        case .stable: return base
        case .mine, .same: return mine
        case .theirs: return theirs
        case .conflict:
            switch resolution {
            case .mine: return mine
            case .theirs: return theirs
            case .mineThenTheirs: return mine + theirs
            case .theirsThenMine: return theirs + mine
            case .base: return base
            case .unresolved: return ["<<<<<<< mine"] + mine + ["======="] + theirs + [">>>>>>> theirs"]
            }
        }
    }
}

enum Merge3 {
    /// A changed region of base: lines [start, end) replaced by `lines`.
    private struct Hunk {
        var start: Int
        var end: Int
        var lines: [String]
        var side: Int        // 0 = mine, 1 = theirs
    }

    private static func hunks(_ base: [String], _ other: [String], side: Int, options: DiffOptions) -> [Hunk] {
        let ops = DiffEngine.diff(base, other, options: options)
        var result: [Hunk] = []
        var basePos = 0
        var current: Hunk?
        func flush() {
            if let c = current { result.append(c) }
            current = nil
        }
        for op in ops {
            switch op {
            case let .equal(i, _):
                flush()
                basePos = i + 1
            case let .delete(i):
                if current == nil { current = Hunk(start: i, end: i, lines: [], side: side) }
                current!.end = i + 1
                basePos = i + 1
            case let .insert(j):
                if current == nil { current = Hunk(start: basePos, end: basePos, lines: [], side: side) }
                current!.lines.append(other[j])
            }
        }
        flush()
        return result
    }

    /// Applies one side's hunks that fall inside base[start..<end].
    private static func apply(_ base: [String], _ hs: [Hunk], start: Int, end: Int) -> [String] {
        var out: [String] = []
        var pos = start
        for h in hs.sorted(by: { $0.start < $1.start }) {
            out += base[pos..<h.start]
            out += h.lines
            pos = h.end
        }
        out += base[pos..<end]
        return out
    }

    static func merge(base: [String], mine: [String], theirs: [String], options: DiffOptions = DiffOptions()) -> [MergeChunk] {
        let all = (hunks(base, mine, side: 0, options: options) + hunks(base, theirs, side: 1, options: options))
            .sorted { ($0.start, $0.end, $0.side) < ($1.start, $1.end, $1.side) }
        var chunks: [MergeChunk] = []
        func add(_ kind: MergeChunk.Kind, _ b: [String], _ m: [String], _ t: [String]) {
            chunks.append(MergeChunk(id: chunks.count, kind: kind, base: b, mine: m, theirs: t,
                                     resolution: kind == .conflict ? .unresolved : .mine))
        }

        var pos = 0
        var i = 0
        while i < all.count {
            // Collect a group of overlapping hunks (insertions at the same point also overlap).
            var group = [all[i]]
            var gStart = all[i].start, gEnd = all[i].end
            i += 1
            while i < all.count {
                let h = all[i]
                let touchesEmpty = h.start == h.end || gStart == gEnd
                if h.start < gEnd || (h.start == gEnd && touchesEmpty) {
                    group.append(h)
                    gEnd = max(gEnd, h.end)
                    gStart = min(gStart, h.start)
                    i += 1
                } else {
                    break
                }
            }
            if pos < gStart {
                let stable = Array(base[pos..<gStart])
                add(.stable, stable, stable, stable)
            }
            let b = Array(base[gStart..<gEnd])
            let mineHunks = group.filter { $0.side == 0 }
            let theirHunks = group.filter { $0.side == 1 }
            let m = apply(base, mineHunks, start: gStart, end: gEnd)
            let t = apply(base, theirHunks, start: gStart, end: gEnd)
            if theirHunks.isEmpty {
                add(.mine, b, m, t)
            } else if mineHunks.isEmpty {
                add(.theirs, b, m, t)
            } else if m == t {
                add(.same, b, m, t)
            } else {
                add(.conflict, b, m, t)
            }
            pos = gEnd
        }
        if pos < base.count {
            let stable = Array(base[pos...])
            add(.stable, stable, stable, stable)
        }
        return chunks
    }

    static func result(_ chunks: [MergeChunk]) -> [String] {
        chunks.flatMap(\.result)
    }
}
