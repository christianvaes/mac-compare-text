import Foundation

/// Matching options. Display always uses the original lines; these options
/// only affect which lines are considered equal.
struct DiffOptions: Sendable, Equatable {
    /// Match lines ignoring leading/trailing whitespace and collapsing
    /// internal whitespace runs to a single space.
    var ignoreWhitespace: Bool = false
    /// Lines that are empty after trimming never count as differences.
    var ignoreBlankLines: Bool = false
    /// Detect blocks that occur unchanged in both texts at different
    /// positions and classify them as moved instead of removed+added.
    var detectMoves: Bool = true
}

/// A block of lines present in both texts at different positions. Ranges are
/// over ORIGINAL line indices (half-open). With ignoreBlankLines a range may
/// span skipped blank lines; leftMoved/rightMoved hold the exact matched
/// lines and are what the UI colors.
struct MovedBlock: Sendable, Equatable {
    var left: Range<Int>
    var right: Range<Int>
}

/// Result of a line-based comparison. Line indices are 0-based and always
/// refer to the ORIGINAL texts, regardless of options.
struct DiffResult: Sendable {
    /// Lines in the left text that were removed or changed.
    var leftChanged: Set<Int> = []
    /// Lines in the right text that were added or changed.
    var rightChanged: Set<Int> = []
    /// For changed line pairs: emphasized character ranges (UTF-16, relative
    /// to the start of the original line) that actually differ within the line.
    var leftInline: [Int: [NSRange]] = [:]
    var rightInline: [Int: [NSRange]] = [:]
    /// One anchor per contiguous block of differences, for navigation.
    /// (line in left text, line in right text)
    var hunkAnchors: [(left: Int, right: Int)] = []
    /// Blocks present in both texts at different positions.
    var movedPairs: [MovedBlock] = []
    var leftMoved: Set<Int> = []
    var rightMoved: Set<Int> = []
    /// Every LCS-matched line pair (0-based original indices, strictly
    /// ascending in both components). Basis for synchronized scrolling.
    var matchedLines: [(left: Int, right: Int)] = []
    /// True when the texts are not byte-identical but show no differences
    /// under the active options (whitespace / blank lines only).
    var onlyWhitespaceDiffers: Bool = false

    var identical: Bool { leftChanged.isEmpty && rightChanged.isEmpty && movedPairs.isEmpty }
}

enum DiffEngine {
    /// Below this prefix/suffix similarity, a changed pair gets only the
    /// line-level color and no character-level emphasis.
    private static let inlineSimilarityThreshold = 0.3

    /// One side of the comparison: original lines for display, normalized
    /// keys of the kept lines for matching, and the mapping back.
    private struct Side {
        let lines: [String]
        let keys: [String]
        /// kept index -> original line index; nil means identity (no
        /// filtering or normalization happened).
        let map: [Int]?

        func original(_ kept: Int) -> Int { map?[kept] ?? kept }

        /// Original line index to anchor a hunk that starts at this kept
        /// index; clamps past-the-end to the last line.
        func anchor(_ kept: Int) -> Int {
            kept < keys.count ? original(kept) : max(0, lines.count - 1)
        }
    }

    /// Line-based Myers diff with intra-line refinement.
    ///
    /// Matching runs on normalized keys (see DiffOptions); the common prefix
    /// and suffix are trimmed first so the expensive part only touches the
    /// changed region. Within a block of differences, the i-th removed line
    /// is paired with the i-th inserted line and refined to character level,
    /// WinMerge-style.
    static func compare(left: String, right: String, options: DiffOptions = DiffOptions()) -> DiffResult {
        let a = makeSide(left, options: options)
        let b = makeSide(right, options: options)

        var prefix = 0
        while prefix < a.keys.count, prefix < b.keys.count, a.keys[prefix] == b.keys[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < a.keys.count - prefix, suffix < b.keys.count - prefix,
              a.keys[a.keys.count - 1 - suffix] == b.keys[b.keys.count - 1 - suffix] {
            suffix += 1
        }

        let aMid = Array(a.keys[prefix..<(a.keys.count - suffix)])
        let bMid = Array(b.keys[prefix..<(b.keys.count - suffix)])

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
        // Note: with ignoreBlankLines, two difference regions separated only
        // by blank lines merge into a single hunk — acceptable, navigation
        // still lands on the first changed line.
        var result = DiffResult()
        result.matchedLines.reserveCapacity(min(a.keys.count, b.keys.count))
        for i in 0..<prefix {
            result.matchedLines.append((left: a.original(i), right: b.original(i)))
        }
        // Kept indices of single-sided changes; input for move detection.
        var pureRemovedKept: [Int] = []
        var pureInsertedKept: [Int] = []
        var ia = 0, ib = 0
        var inHunk = false
        while ia < aMid.count || ib < bMid.count {
            let aChanged = ia < aMid.count && removed.contains(ia)
            let bChanged = ib < bMid.count && inserted.contains(ib)

            if !aChanged && !bChanged {
                inHunk = false
                if ia < aMid.count, ib < bMid.count {
                    result.matchedLines.append((left: a.original(prefix + ia), right: b.original(prefix + ib)))
                }
                if ia < aMid.count { ia += 1 }
                if ib < bMid.count { ib += 1 }
                continue
            }
            if !inHunk {
                inHunk = true
                result.hunkAnchors.append((left: a.anchor(prefix + ia), right: b.anchor(prefix + ib)))
            }
            if aChanged && bChanged {
                let lineA = a.original(prefix + ia)
                let lineB = b.original(prefix + ib)
                result.leftChanged.insert(lineA)
                result.rightChanged.insert(lineB)
                // Barely-similar pairs (common in merged hunks) get only the
                // line-level color; character emphasis would be noise.
                if similarity(aMid[ia], bMid[ib]) >= inlineSimilarityThreshold {
                    let (rangesA, rangesB) = intraline(a.lines[lineA], b.lines[lineB])
                    if !rangesA.isEmpty { result.leftInline[lineA] = rangesA }
                    if !rangesB.isEmpty { result.rightInline[lineB] = rangesB }
                }
                ia += 1
                ib += 1
            } else if aChanged {
                result.leftChanged.insert(a.original(prefix + ia))
                pureRemovedKept.append(prefix + ia)
                ia += 1
            } else {
                result.rightChanged.insert(b.original(prefix + ib))
                pureInsertedKept.append(prefix + ib)
                ib += 1
            }
        }
        for i in 0..<suffix {
            result.matchedLines.append((
                left: a.original(a.keys.count - suffix + i),
                right: b.original(b.keys.count - suffix + i)
            ))
        }

        if options.detectMoves {
            detectMoves(a: a, b: b,
                        pureRemovedKept: pureRemovedKept,
                        pureInsertedKept: pureInsertedKept,
                        result: &result)
        }

        if result.identical,
           options.ignoreWhitespace || options.ignoreBlankLines,
           left != right {
            result.onlyWhitespaceDiffers = true
        }
        return result
    }

    // MARK: - Move detection

    /// Above this many pure removed+inserted lines, move detection is skipped.
    private static let moveDetectionLimit = 50_000
    /// Minimum normalized key length for a line to serve as a unique anchor.
    private static let moveAnchorMinLength = 4
    /// A single-line moved block must have at least this normalized length.
    private static let moveSingleLineMinLength = 8

    /// Patience-style move detection: a key that occurs exactly once among
    /// the pure removals and once among the pure insertions anchors a block,
    /// which is extended greedily while lines stay contiguous and equal.
    /// Matched lines move from the changed sets into the moved sets.
    private static func detectMoves(
        a: Side, b: Side,
        pureRemovedKept: [Int],
        pureInsertedKept: [Int],
        result: inout DiffResult
    ) {
        guard !pureRemovedKept.isEmpty, !pureInsertedKept.isEmpty,
              pureRemovedKept.count + pureInsertedKept.count <= moveDetectionLimit else { return }

        // key -> position in the pure arrays; -2 marks duplicate keys.
        var removedPos: [String: Int] = [:]
        removedPos.reserveCapacity(pureRemovedKept.count)
        for (position, kept) in pureRemovedKept.enumerated() {
            removedPos[a.keys[kept]] = removedPos[a.keys[kept]] == nil ? position : -2
        }
        var insertedPos: [String: Int] = [:]
        insertedPos.reserveCapacity(pureInsertedKept.count)
        for (position, kept) in pureInsertedKept.enumerated() {
            insertedPos[b.keys[kept]] = insertedPos[b.keys[kept]] == nil ? position : -2
        }

        var removedClaimed = [Bool](repeating: false, count: pureRemovedKept.count)
        var insertedClaimed = [Bool](repeating: false, count: pureInsertedKept.count)

        for anchorR in pureRemovedKept.indices {
            if removedClaimed[anchorR] { continue }
            let key = a.keys[pureRemovedKept[anchorR]]
            guard key.utf16.count >= moveAnchorMinLength,
                  removedPos[key] == anchorR,
                  let anchorI = insertedPos[key], anchorI >= 0,
                  !insertedClaimed[anchorI] else { continue }

            // Extend to a maximal run around the anchor. Contiguity is
            // measured on kept indices, so skipped blank lines don't split
            // a block.
            var r0 = anchorR, i0 = anchorI
            while r0 > 0, i0 > 0,
                  !removedClaimed[r0 - 1], !insertedClaimed[i0 - 1],
                  pureRemovedKept[r0 - 1] == pureRemovedKept[r0] - 1,
                  pureInsertedKept[i0 - 1] == pureInsertedKept[i0] - 1,
                  a.keys[pureRemovedKept[r0 - 1]] == b.keys[pureInsertedKept[i0 - 1]] {
                r0 -= 1
                i0 -= 1
            }
            var r1 = anchorR, i1 = anchorI
            while r1 + 1 < pureRemovedKept.count, i1 + 1 < pureInsertedKept.count,
                  !removedClaimed[r1 + 1], !insertedClaimed[i1 + 1],
                  pureRemovedKept[r1 + 1] == pureRemovedKept[r1] + 1,
                  pureInsertedKept[i1 + 1] == pureInsertedKept[i1] + 1,
                  a.keys[pureRemovedKept[r1 + 1]] == b.keys[pureInsertedKept[i1 + 1]] {
                r1 += 1
                i1 += 1
            }
            for position in r0...r1 { removedClaimed[position] = true }
            for position in i0...i1 { insertedClaimed[position] = true }

            // Trivial blocks stay red/green. They also stay claimed, so they
            // can't be glued onto a neighboring anchor across a mismatch.
            if r1 == r0, key.utf16.count < moveSingleLineMinLength { continue }

            result.movedPairs.append(MovedBlock(
                left: a.original(pureRemovedKept[r0])..<(a.original(pureRemovedKept[r1]) + 1),
                right: b.original(pureInsertedKept[i0])..<(b.original(pureInsertedKept[i1]) + 1)
            ))
            for position in r0...r1 {
                let line = a.original(pureRemovedKept[position])
                result.leftMoved.insert(line)
                result.leftChanged.remove(line)
            }
            for position in i0...i1 {
                let line = b.original(pureInsertedKept[position])
                result.rightMoved.insert(line)
                result.rightChanged.remove(line)
            }
        }
        result.movedPairs.sort { $0.left.lowerBound < $1.left.lowerBound }
    }

    // MARK: - Preprocessing

    private static func makeSide(_ text: String, options: DiffOptions) -> Side {
        let lines = text.components(separatedBy: "\n")
        if !options.ignoreWhitespace && !options.ignoreBlankLines {
            return Side(lines: lines, keys: lines, map: nil)
        }
        var keys: [String] = []
        var map: [Int] = []
        keys.reserveCapacity(lines.count)
        map.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            if options.ignoreBlankLines, line.allSatisfy(\.isWhitespace) { continue }
            keys.append(options.ignoreWhitespace ? normalize(line) : line)
            map.append(index)
        }
        return Side(lines: lines, keys: keys, map: map)
    }

    /// Trims leading/trailing whitespace and collapses internal whitespace
    /// runs to a single space. Returns the original string instance when
    /// nothing changes, to avoid allocations on already-clean lines.
    private static func normalize(_ line: String) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        var changed = false
        var emitted = false
        for scalar in line.unicodeScalars {
            if scalar.properties.isWhitespace {
                if scalar != " " { changed = true }
                if emitted {
                    if pendingSpace { changed = true }
                    pendingSpace = true
                } else {
                    changed = true // leading whitespace is dropped
                }
            } else {
                if pendingSpace {
                    scalars.append(" ")
                    pendingSpace = false
                }
                scalars.append(scalar)
                emitted = true
            }
        }
        if pendingSpace { changed = true } // trailing whitespace is dropped
        return changed ? String(scalars) : line
    }

    /// Cheap similarity in [0, 1]: shared prefix+suffix relative to the total
    /// length, on UTF-16 units.
    private static func similarity(_ a: String, _ b: String) -> Double {
        let ua = Array(a.utf16)
        let ub = Array(b.utf16)
        if ua.isEmpty && ub.isEmpty { return 1 }
        var prefix = 0
        while prefix < ua.count, prefix < ub.count, ua[prefix] == ub[prefix] {
            prefix += 1
        }
        var suffix = 0
        let maxSuffix = min(ua.count, ub.count) - prefix
        while suffix < maxSuffix, ua[ua.count - 1 - suffix] == ub[ub.count - 1 - suffix] {
            suffix += 1
        }
        return Double(2 * (prefix + suffix)) / Double(ua.count + ub.count)
    }

    // MARK: - Intra-line refinement

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
