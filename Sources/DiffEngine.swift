import Foundation

/// Result of a line-based comparison. Line indices are 0-based.
struct DiffResult: Sendable {
    /// Lines in the left text that were removed or changed.
    var leftChanged: Set<Int> = []
    /// Lines in the right text that were added or changed.
    var rightChanged: Set<Int> = []
    /// For changed line pairs: emphasized character ranges (UTF-16, relative
    /// to the start of the line) that actually differ within the line.
    var leftInline: [Int: [NSRange]] = [:]
    var rightInline: [Int: [NSRange]] = [:]
    /// One anchor per contiguous block of differences, for navigation.
    /// (line in left text, line in right text)
    var hunkAnchors: [(left: Int, right: Int)] = []

    var identical: Bool { leftChanged.isEmpty && rightChanged.isEmpty }
}

enum DiffEngine {
    /// Line-based Myers diff with intra-line refinement.
    ///
    /// The common prefix and suffix are trimmed first so the expensive part
    /// only runs on the region that actually changed. Within a block of
    /// differences, the i-th removed line is paired with the i-th inserted
    /// line and refined to character level, WinMerge-style.
    static func compare(left: String, right: String) -> DiffResult {
        let a = left.components(separatedBy: "\n")
        let b = right.components(separatedBy: "\n")

        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }

        let aMid = Array(a[prefix..<(a.count - suffix)])
        let bMid = Array(b[prefix..<(b.count - suffix)])

        var removed = Set<Int>()   // indices within aMid
        var inserted = Set<Int>()  // indices within bMid
        for change in bMid.difference(from: aMid) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        // Walk both sides in lockstep. Unchanged lines are LCS matches and
        // advance together; runs of removed/inserted lines form one hunk in
        // which lines are paired positionally for intra-line refinement.
        var result = DiffResult()
        var ia = 0, ib = 0
        var inHunk = false
        while ia < aMid.count || ib < bMid.count {
            let aChanged = ia < aMid.count && removed.contains(ia)
            let bChanged = ib < bMid.count && inserted.contains(ib)

            if !aChanged && !bChanged {
                inHunk = false
                if ia < aMid.count { ia += 1 }
                if ib < bMid.count { ib += 1 }
                continue
            }
            if !inHunk {
                inHunk = true
                result.hunkAnchors.append((
                    left: min(prefix + ia, max(0, a.count - 1)),
                    right: min(prefix + ib, max(0, b.count - 1))
                ))
            }
            if aChanged && bChanged {
                let lineA = prefix + ia, lineB = prefix + ib
                result.leftChanged.insert(lineA)
                result.rightChanged.insert(lineB)
                let (rangesA, rangesB) = intraline(aMid[ia], bMid[ib])
                if !rangesA.isEmpty { result.leftInline[lineA] = rangesA }
                if !rangesB.isEmpty { result.rightInline[lineB] = rangesB }
                ia += 1
                ib += 1
            } else if aChanged {
                result.leftChanged.insert(prefix + ia)
                ia += 1
            } else {
                result.rightChanged.insert(prefix + ib)
                ib += 1
            }
        }
        return result
    }

    /// Character-level diff between two paired lines. Returns emphasized
    /// UTF-16 ranges relative to each line's start.
    private static func intraline(_ a: String, _ b: String) -> ([NSRange], [NSRange]) {
        let ua = Array(a.utf16)
        let ub = Array(b.utf16)

        var prefix = 0
        while prefix < ua.count, prefix < ub.count, ua[prefix] == ub[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < ua.count - prefix, suffix < ub.count - prefix,
              ua[ua.count - 1 - suffix] == ub[ub.count - 1 - suffix] {
            suffix += 1
        }

        let midA = ua.count - prefix - suffix
        let midB = ub.count - prefix - suffix
        if midA == 0 && midB == 0 { return ([], []) }

        // Very long changed middles: highlight the whole middle instead of
        // running an expensive character diff (keeps huge single-line pastes,
        // like minified JSON, fast).
        if midA + midB > 6000 {
            return (
                midA > 0 ? [NSRange(location: prefix, length: midA)] : [],
                midB > 0 ? [NSRange(location: prefix, length: midB)] : []
            )
        }

        var removedUnits = IndexSet()
        var insertedUnits = IndexSet()
        for change in Array(ub[prefix..<(prefix + midB)]).difference(from: Array(ua[prefix..<(prefix + midA)])) {
            switch change {
            case .remove(let offset, _, _): removedUnits.insert(offset)
            case .insert(let offset, _, _): insertedUnits.insert(offset)
            }
        }
        return (ranges(from: removedUnits, offset: prefix),
                ranges(from: insertedUnits, offset: prefix))
    }

    /// Convert an index set to ranges, merging runs separated by tiny gaps so
    /// the emphasis reads as words rather than confetti.
    private static func ranges(from set: IndexSet, offset: Int, mergeGap: Int = 2) -> [NSRange] {
        var result: [NSRange] = []
        for run in set.rangeView {
            let range = NSRange(location: offset + run.lowerBound, length: run.count)
            if let last = result.last,
               range.location - (last.location + last.length) <= mergeGap {
                result[result.count - 1] = NSRange(
                    location: last.location,
                    length: range.location + range.length - last.location
                )
            } else {
                result.append(range)
            }
        }
        return result
    }
}
