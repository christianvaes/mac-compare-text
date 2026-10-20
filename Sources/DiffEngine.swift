import Foundation

/// Matching options. Display always uses the original lines; these options
/// only affect which lines are considered equal.
struct DiffOptions: Sendable, Equatable {
    /// Match lines ignoring leading/trailing whitespace and collapsing
    /// internal whitespace runs to a single space.
    var ignoreWhitespace: Bool = false
    /// Lines that are empty after trimming never count as differences.
    var ignoreBlankLines: Bool = false
    /// Upper- and lowercase letters count as equal.
    var ignoreCase: Bool = false
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

/// The lines one difference spans on each side (original line indices,
/// half-open). An empty range marks where lines were added on the other
/// side: before the line at its lower bound (`lines.count` = at the end).
struct Hunk: Sendable, Equatable {
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
    /// The extent of each difference, in the same order as `hunkAnchors`.
    var hunks: [Hunk] = []
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
    /// Positionally aligned lines are only treated as an edited pair when
    /// they are at least this similar; otherwise they are classified as a
    /// removal plus an insertion (and stay available for move detection).
    private static let pairSimilarityThreshold = 0.3

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

        /// Original lines covered by a run of kept lines; for an empty run,
        /// the empty range at the insertion point.
        func span(_ kept: Range<Int>) -> Range<Int> {
            guard let first = kept.first, let last = kept.last else {
                let at = kept.lowerBound < keys.count ? original(kept.lowerBound) : lines.count
                return at..<at
            }
            return original(first)..<(original(last) + 1)
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
        // advance together; between two matches, the removed lines on the
        // left and the inserted lines on the right form one hunk.
        // Note: with ignoreBlankLines, two difference regions separated only
        // by blank lines merge into a single hunk — acceptable, navigation
        // still lands on the first changed line.
        var result = DiffResult()
        result.matchedLines.reserveCapacity(min(a.keys.count, b.keys.count))
        for i in 0..<prefix {
            result.matchedLines.append((left: a.original(i), right: b.original(i)))
        }
        // Kept indices of single-sided changes, and the hunk each one is in;
        // input for move detection.
        var pureRemovedKept: [Int] = []
        var pureInsertedKept: [Int] = []
        var pureRemovedHunk: [Int] = []
        var pureInsertedHunk: [Int] = []
        var hunkIndex = 0
        var ia = 0, ib = 0
        while ia < aMid.count || ib < bMid.count {
            let aChanged = ia < aMid.count && removed.contains(ia)
            let bChanged = ib < bMid.count && inserted.contains(ib)

            if !aChanged && !bChanged {
                if ia < aMid.count, ib < bMid.count {
                    result.matchedLines.append((left: a.original(prefix + ia), right: b.original(prefix + ib)))
                }
                if ia < aMid.count { ia += 1 }
                if ib < bMid.count { ib += 1 }
                continue
            }
            let hunkA = ia, hunkB = ib
            while ia < aMid.count, removed.contains(ia) { ia += 1 }
            while ib < bMid.count, inserted.contains(ib) { ib += 1 }
            let removedBefore = pureRemovedKept.count
            let insertedBefore = pureInsertedKept.count
            processHunk(a: a, b: b,
                        aKept: (prefix + hunkA)..<(prefix + ia),
                        bKept: (prefix + hunkB)..<(prefix + ib),
                        options: options, result: &result,
                        pureRemovedKept: &pureRemovedKept,
                        pureInsertedKept: &pureInsertedKept)
            pureRemovedHunk += Array(repeating: hunkIndex, count: pureRemovedKept.count - removedBefore)
            pureInsertedHunk += Array(repeating: hunkIndex, count: pureInsertedKept.count - insertedBefore)
            hunkIndex += 1
        }
        for i in 0..<suffix {
            result.matchedLines.append((
                left: a.original(a.keys.count - suffix + i),
                right: b.original(b.keys.count - suffix + i)
            ))
        }

        if options.detectMoves {
            if options.ignoreWhitespace {
                detectEditedMoves(a: a, b: b,
                                  pureRemovedKept: &pureRemovedKept, removedHunk: &pureRemovedHunk,
                                  pureInsertedKept: &pureInsertedKept, insertedHunk: &pureInsertedHunk,
                                  foldCase: options.ignoreCase, result: &result)
            }
            detectMoves(a: a, b: b,
                        pureRemovedKept: pureRemovedKept,
                        pureInsertedKept: pureInsertedKept,
                        result: &result)
            mergeAdjacentMoves(a: a, b: b, result: &result)
        }

        if result.identical,
           options.ignoreWhitespace || options.ignoreBlankLines || options.ignoreCase,
           left != right {
            result.onlyWhitespaceDiffers = true
        }
        return result
    }

    // MARK: - Hunks

    /// Classifies the lines of one hunk. With ignoreWhitespace, line breaks
    /// count as whitespace too: the hunk is first compared word by word
    /// across its lines, which recognizes text that was only re-wrapped. That
    /// result is used only when it shows at least one line as unchanged;
    /// otherwise the hunk is compared line by line exactly as before.
    private static func processHunk(
        a: Side, b: Side,
        aKept: Range<Int>, bKept: Range<Int>,
        options: DiffOptions,
        result: inout DiffResult,
        pureRemovedKept: inout [Int],
        pureInsertedKept: inout [Int]
    ) {
        if options.ignoreWhitespace, !aKept.isEmpty, !bKept.isEmpty,
           let verdicts = wordDiff(aKept.map { a.lines[a.original($0)] },
                                   bKept.map { b.lines[b.original($0)] },
                                   foldCase: options.ignoreCase) {
            func apply(_ lineVerdicts: [LineVerdict], side: Side, kept: Range<Int>,
                       changed: inout Set<Int>, inline: inout [Int: [NSRange]],
                       pure: inout [Int]) -> Range<Int>? {
                var first: Int?
                var last: Int?
                for (offset, verdict) in lineVerdicts.enumerated() {
                    let line = side.original(kept.lowerBound + offset)
                    switch verdict {
                    case .unchanged:
                        continue
                    case .edited(let ranges):
                        changed.insert(line)
                        if !ranges.isEmpty { inline[line] = ranges }
                    case .unmatched:
                        changed.insert(line)
                        pure.append(kept.lowerBound + offset)
                    }
                    if first == nil { first = line }
                    last = line
                }
                guard let first, let last else { return nil }
                return first..<(last + 1)
            }
            let markedA = apply(verdicts.left, side: a, kept: aKept,
                                changed: &result.leftChanged, inline: &result.leftInline,
                                pure: &pureRemovedKept)
            let markedB = apply(verdicts.right, side: b, kept: bKept,
                                changed: &result.rightChanged, inline: &result.rightInline,
                                pure: &pureInsertedKept)
            // A hunk that turned out to be only re-wrapped is no difference.
            // A side without marked lines spans the whole (re-wrapped) region.
            if markedA != nil || markedB != nil {
                result.hunkAnchors.append((left: markedA?.lowerBound ?? a.anchor(aKept.lowerBound),
                                           right: markedB?.lowerBound ?? b.anchor(bKept.lowerBound)))
                result.hunks.append(Hunk(left: markedA ?? a.span(aKept), right: markedB ?? b.span(bKept)))
            }
            return
        }

        // Line by line: the i-th removed line is paired with the i-th
        // inserted line for intra-line refinement, the rest is single-sided.
        result.hunkAnchors.append((left: a.anchor(aKept.lowerBound), right: b.anchor(bKept.lowerBound)))
        result.hunks.append(Hunk(left: a.span(aKept), right: b.span(bKept)))
        let pairs = min(aKept.count, bKept.count)
        for offset in 0..<pairs {
            let keptA = aKept.lowerBound + offset
            let keptB = bKept.lowerBound + offset
            let lineA = a.original(keptA)
            let lineB = b.original(keptB)
            result.leftChanged.insert(lineA)
            result.rightChanged.insert(lineB)
            let keyA = a.keys[keptA]
            let keyB = b.keys[keptB]
            if keyA != keyB, similarity(keyA, keyB) >= pairSimilarityThreshold {
                let (rangesA, rangesB) = options.ignoreCase
                    ? intraline(caseFolded(a.lines[lineA]), caseFolded(b.lines[lineB]))
                    : intraline(a.lines[lineA], b.lines[lineB])
                if !rangesA.isEmpty { result.leftInline[lineA] = rangesA }
                if !rangesB.isEmpty { result.rightInline[lineB] = rangesB }
            } else {
                // Not really the same line edited: equal keys mean crossed
                // (moved) content the LCS could not match, dissimilar keys
                // mean an unrelated removal next to an insertion. Keep both
                // available for move detection.
                pureRemovedKept.append(keptA)
                pureInsertedKept.append(keptB)
            }
        }
        for keptA in (aKept.lowerBound + pairs)..<aKept.upperBound {
            result.leftChanged.insert(a.original(keptA))
            pureRemovedKept.append(keptA)
        }
        for keptB in (bKept.lowerBound + pairs)..<bKept.upperBound {
            result.rightChanged.insert(b.original(keptB))
            pureInsertedKept.append(keptB)
        }
    }

    // MARK: - Word-level comparison of a hunk

    /// How one line of a hunk compares in word mode.
    private enum LineVerdict {
        /// Its text is present on the other side, possibly wrapped differently.
        case unchanged
        /// Edited: shares text with the other side; ranges are the parts
        /// that differ (empty when the edit is only on the other side).
        case edited([NSRange])
        /// Nothing in it is shared with the other side.
        case unmatched
    }

    private struct Token {
        let line: Int
        let range: NSRange
        let text: String
        let isWord: Bool
    }

    /// Hunks with more tokens than this are compared line by line.
    private static let wordDiffTokenLimit = 12_000
    /// Hunks sharing less than this fraction of their tokens are rewrites,
    /// compared line by line.
    private static let wordDiffMinOverlap = 0.4

    /// Word diff of a hunk across its line breaks. Returns nil when the hunk
    /// is too large or too dissimilar, or when no line comes out unchanged.
    private static func wordDiff(_ aLines: [String], _ bLines: [String], foldCase: Bool)
        -> (left: [LineVerdict], right: [LineVerdict])? {
        let ta = tokenize(aLines, foldCase: foldCase)
        let tb = tokenize(bLines, foldCase: foldCase)
        guard !ta.isEmpty, !tb.isEmpty, ta.count + tb.count <= wordDiffTokenLimit else { return nil }

        var counts: [String: Int] = [:]
        for token in ta { counts[token.text, default: 0] += 1 }
        var common = 0
        for token in tb {
            if let count = counts[token.text], count > 0 {
                counts[token.text] = count - 1
                common += 1
            }
        }
        guard Double(2 * common) / Double(ta.count + tb.count) >= wordDiffMinOverlap else { return nil }

        let alignment = alignWords(ta, tb, aLineCount: aLines.count, bLineCount: bLines.count)
        let unchanged = (alignment.left + alignment.right).filter {
            if case .unchanged = $0 { return true } else { return false }
        }.count
        return unchanged > 0 ? (alignment.left, alignment.right) : nil
    }

    private struct WordAlignment {
        let left: [LineVerdict]
        let right: [LineVerdict]
        /// Characters of the word tokens shared in order, and of all word
        /// tokens per side.
        let sharedWordChars: Int
        let leftWordChars: Int
        let rightWordChars: Int
    }

    /// Token-level LCS between two lists of lines, classified per line.
    private static func alignWords(_ ta: [Token], _ tb: [Token], aLineCount: Int, bLineCount: Int) -> WordAlignment {
        var removedTokens = IndexSet()
        var insertedTokens = IndexSet()
        for change in tb.map(\.text).difference(from: ta.map(\.text)) {
            switch change {
            case .remove(let offset, _, _): removedTokens.insert(offset)
            case .insert(let offset, _, _): insertedTokens.insert(offset)
            }
        }
        var partnerA = [Int](repeating: -1, count: ta.count)
        var partnerB = [Int](repeating: -1, count: tb.count)
        var i = 0, j = 0
        while i < ta.count, j < tb.count {
            if removedTokens.contains(i) { i += 1; continue }
            if insertedTokens.contains(j) { j += 1; continue }
            partnerA[i] = j
            partnerB[j] = i
            i += 1
            j += 1
        }

        // Of equally long alignments, prefer the one that keeps shared tokens
        // together: in `0.55` vs `0.55  # … bij mij 55`, the `55` belongs
        // after `0.`, not inside the comment.
        slideMatches(&partnerA, &partnerB, ta)
        slideMatches(&partnerB, &partnerA, tb)

        // A lone matched punctuation mark amid differences on both sides is
        // a coincidence, not shared content.
        func isolated(_ partners: [Int], _ k: Int) -> Bool {
            (k == 0 || partners[k - 1] < 0) && (k + 1 == partners.count || partners[k + 1] < 0)
        }
        for k in ta.indices where partnerA[k] >= 0 && !ta[k].isWord {
            let m = partnerA[k]
            if isolated(partnerA, k), isolated(partnerB, m) {
                partnerA[k] = -1
                partnerB[m] = -1
            }
        }

        var markedA = Set<Int>(), markedB = Set<Int>()
        var emphasisA: [Int: [NSRange]] = [:], emphasisB: [Int: [NSRange]] = [:]
        markRuns(tokens: ta, partners: partnerA, other: tb, marked: &markedA, emphasis: &emphasisA)
        markRuns(tokens: tb, partners: partnerB, other: ta, marked: &markedB, emphasis: &emphasisB)

        func wordChars(_ tokens: [Token], sharedOnly partners: [Int]?) -> Int {
            tokens.indices.reduce(0) { sum, k in
                guard tokens[k].isWord, partners.map({ $0[k] >= 0 }) ?? true else { return sum }
                return sum + tokens[k].text.utf16.count
            }
        }
        return WordAlignment(
            left: verdicts(lineCount: aLineCount, tokens: ta, partners: partnerA,
                           marked: markedA, emphasis: emphasisA),
            right: verdicts(lineCount: bLineCount, tokens: tb, partners: partnerB,
                            marked: markedB, emphasis: emphasisB),
            sharedWordChars: wordChars(ta, sharedOnly: partnerA),
            leftWordChars: wordChars(ta, sharedOnly: nil),
            rightWordChars: wordChars(tb, sharedOnly: nil)
        )
    }

    /// Moves a match backward across a run of unmatched tokens when the run
    /// starts with the same token and that makes the match directly follow
    /// the previous match on both sides. The alignment stays a valid one of
    /// equal length; the unmatched tokens just end up in one run.
    private static func slideMatches(_ partners: inout [Int], _ otherPartners: inout [Int], _ tokens: [Token]) {
        var start = 1
        while start < tokens.count {
            guard partners[start] < 0, partners[start - 1] >= 0 else { start += 1; continue }
            var end = start
            while end + 1 < tokens.count, partners[end + 1] < 0 { end += 1 }
            var runStart = start
            while end + 1 < tokens.count,
                  partners[end + 1] >= 0,
                  partners[end + 1] == partners[runStart - 1] + 1,
                  tokens[runStart].text == tokens[end + 1].text,
                  tokens[runStart].line == tokens[runStart - 1].line {
                let partner = partners[end + 1]
                partners[runStart] = partner
                otherPartners[partner] = runStart
                partners[end + 1] = -1
                runStart += 1
                end += 1
                while end + 1 < tokens.count, partners[end + 1] < 0 { end += 1 }
            }
            start = end + 1
        }
    }

    /// Splits lines into tokens: runs of letters, digits and underscores,
    /// and punctuation, where a run of the same punctuation character (such
    /// as a `# ======` banner) is one token. Whitespace separates tokens.
    private static func tokenize(_ lines: [String], foldCase: Bool) -> [Token] {
        var tokens: [Token] = []
        for (lineIndex, line) in lines.enumerated() {
            var offset = 0
            var wordStart = -1
            var word = String.UnicodeScalarView()
            for scalar in line.unicodeScalars {
                let width = scalar.utf16.count
                if isWordScalar(scalar) {
                    if wordStart < 0 { wordStart = offset }
                    word.append(scalar)
                } else {
                    if wordStart >= 0 {
                        tokens.append(Token(line: lineIndex,
                                            range: NSRange(location: wordStart, length: offset - wordStart),
                                            text: foldCase ? caseFolded(String(word)) : String(word), isWord: true))
                        wordStart = -1
                        word = String.UnicodeScalarView()
                    }
                    if !scalar.properties.isWhitespace {
                        let text = String(scalar)
                        if let last = tokens.last, last.line == lineIndex, !last.isWord,
                           NSMaxRange(last.range) == offset, last.text.hasPrefix(text),
                           last.text.unicodeScalars.allSatisfy({ $0 == scalar }) {
                            tokens[tokens.count - 1] = Token(
                                line: lineIndex,
                                range: NSRange(location: last.range.location, length: last.range.length + width),
                                text: last.text + text, isWord: false)
                        } else {
                            tokens.append(Token(line: lineIndex, range: NSRange(location: offset, length: width),
                                                text: text, isWord: false))
                        }
                    }
                }
                offset += width
            }
            if wordStart >= 0 {
                tokens.append(Token(line: lineIndex,
                                    range: NSRange(location: wordStart, length: offset - wordStart),
                                    text: foldCase ? caseFolded(String(word)) : String(word), isWord: true))
            }
        }
        return tokens
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || scalar.properties.isAlphabetic || scalar.properties.numericType != nil
            || scalar.properties.generalCategory == .nonspacingMark
    }

    /// Marks every line holding unmatched tokens and emphasizes them. A line
    /// whose tokens are all present on the other side stays unmarked, even
    /// when the other side added or dropped something next to it: that
    /// difference shows, emphasized, on the side that has it. Coloring the
    /// counterpart as well would paint whole re-wrapped paragraphs for a
    /// one-word edit.
    private static func markRuns(tokens: [Token], partners: [Int], other: [Token],
                                 marked: inout Set<Int>, emphasis: inout [Int: [NSRange]]) {
        for k in tokens.indices where partners[k] < 0 {
            marked.insert(tokens[k].line)
        }

        // Emphasis: unmatched tokens, bridged over at most two shared
        // punctuation marks between them on the same line.
        var emphasized = partners.map { $0 < 0 }
        var k = 0
        while k < tokens.count {
            if emphasized[k] { k += 1; continue }
            var end = k
            while end + 1 < tokens.count, !emphasized[end + 1] { end += 1 }
            if end - k < 2, k > 0, end + 1 < tokens.count,
               tokens[k - 1].line == tokens[end + 1].line,
               (k...end).allSatisfy({ !tokens[$0].isWord }) {
                for m in k...end { emphasized[m] = true }
            }
            k = end + 1
        }

        var s = 0
        while s < tokens.count {
            guard emphasized[s] else { s += 1; continue }
            var e = s
            while e + 1 < tokens.count, emphasized[e + 1], tokens[e + 1].line == tokens[s].line { e += 1 }
            var ranges = [NSRange(location: tokens[s].range.location,
                                  length: NSMaxRange(tokens[e].range) - tokens[s].range.location)]
            // One word replaced by one word: emphasize only the characters
            // that differ, like the line-by-line comparison does.
            if s == e, tokens[s].isWord,
               let counterpart = soleCounterpart(of: s, partners: partners, other: other),
               other[counterpart].isWord {
                let refined = intraline(tokens[s].text, other[counterpart].text).0
                if !refined.isEmpty {
                    ranges = refined.map { NSRange(location: tokens[s].range.location + $0.location, length: $0.length) }
                }
            }
            emphasis[tokens[s].line, default: []].append(contentsOf: ranges)
            s = e + 1
        }
    }

    /// The single unmatched token on the other side that an unmatched token
    /// replaces, if the replacement is exactly one token for one token.
    private static func soleCounterpart(of k: Int, partners: [Int], other: [Token]) -> Int? {
        let before = k > 0 ? partners[k - 1] : -1
        let after = k + 1 < partners.count ? partners[k + 1] : -1
        guard (k == 0 || before >= 0), (k + 1 == partners.count || after >= 0) else { return nil }
        let lower = k == 0 ? 0 : before + 1
        let upper = k + 1 == partners.count ? other.count : after
        return upper - lower == 1 ? lower : nil
    }

    private static func verdicts(lineCount: Int, tokens: [Token], partners: [Int],
                                 marked: Set<Int>, emphasis: [Int: [NSRange]]) -> [LineVerdict] {
        var total = [Int](repeating: 0, count: lineCount)
        var shared = [Int](repeating: 0, count: lineCount)
        for (k, token) in tokens.enumerated() {
            total[token.line] += 1
            if partners[k] >= 0 { shared[token.line] += 1 }
        }
        return (0..<lineCount).map { line in
            if total[line] == 0 || shared[line] == 0 { return .unmatched }
            if !marked.contains(line) { return .unchanged }
            return .edited(emphasis[line] ?? [])
        }
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

    // MARK: - Moves with edits

    /// Two regions must share at least this many characters of words to be
    /// considered one block that moved and was edited.
    private static let editedMoveMinSharedChars = 24
    /// Fraction of the smaller region's word characters that must be shared
    /// in the same order.
    private static let editedMoveMinOrderedShare = 0.6
    /// Evidence that two regions really are the same block: this many lines
    /// (fewer for one-line regions) must come through unchanged and be
    /// distinctive, i.e. occur only once on their side and be at least
    /// `editedMoveDistinctiveLength` long. Generic lines such as
    /// `trigger: state` in a list of similar items don't count.
    private static let editedMoveDistinctiveLines = 2
    private static let editedMoveDistinctiveLength = 8
    /// Above this many pure lines, or region pairs, the search is skipped.
    private static let editedMoveLineLimit = 20_000
    private static let editedMoveMaxPairs = 40_000
    private static let editedMoveMaxRounds = 20

    /// A run of consecutive single-sided changed lines within one hunk.
    private struct Region {
        let kept: [Int]
        let positions: Range<Int>
        let hunk: Int
    }

    private static func regions(_ kept: [Int], _ hunks: [Int]) -> [Region] {
        var result: [Region] = []
        var start = 0
        while start < kept.count {
            var end = start
            while end + 1 < kept.count, kept[end + 1] == kept[end] + 1, hunks[end + 1] == hunks[start] {
                end += 1
            }
            result.append(Region(kept: Array(kept[start...end]), positions: start..<(end + 1), hunk: hunks[start]))
            start = end + 1
        }
        return result
    }

    /// Finds blocks that moved and were edited on the way, such as a section
    /// moved elsewhere that also gained comments. A removed region and an
    /// inserted region in different hunks are paired when they share enough
    /// words in the same order; their lines become moved, with the edits
    /// emphasized. Regions in the same hunk are never paired: that is an
    /// edit in place, not a move. Greedy, best-sharing pair first; what
    /// remains of a region can pair again in a later round.
    private static func detectEditedMoves(
        a: Side, b: Side,
        pureRemovedKept: inout [Int], removedHunk: inout [Int],
        pureInsertedKept: inout [Int], insertedHunk: inout [Int],
        foldCase: Bool,
        result: inout DiffResult
    ) {
        guard pureRemovedKept.count + pureInsertedKept.count <= editedMoveLineLimit else { return }
        var rejected = Set<[Int]>()
        func keyCounts(_ side: Side) -> [String: Int] {
            var counts: [String: Int] = [:]
            for key in side.keys { counts[key, default: 0] += 1 }
            return counts
        }
        var countsA: [String: Int]?
        var countsB: [String: Int]?
        func distinctiveUnchanged(_ verdicts: [LineVerdict], region: Region, side: Side,
                                  counts: [String: Int]) -> Int {
            verdicts.indices.filter { offset in
                guard case .unchanged = verdicts[offset] else { return false }
                let key = side.keys[region.kept[offset]]
                return key.utf16.count >= editedMoveDistinctiveLength && counts[key] == 1
            }.count
        }

        for _ in 0..<editedMoveMaxRounds {
            let regionsA = regions(pureRemovedKept, removedHunk)
            let regionsB = regions(pureInsertedKept, insertedHunk)
            guard !regionsA.isEmpty, !regionsB.isEmpty,
                  regionsA.count * regionsB.count <= editedMoveMaxPairs else { return }

            let tokensA = regionsA.map { region in
                tokenize(region.kept.map { a.lines[a.original($0)] }, foldCase: foldCase)
            }
            let tokensB = regionsB.map { region in
                tokenize(region.kept.map { b.lines[b.original($0)] }, foldCase: foldCase)
            }
            func profile(_ tokens: [Token]) -> (counts: [String: Int], chars: Int) {
                var counts: [String: Int] = [:]
                var chars = 0
                for token in tokens where token.isWord {
                    counts[token.text, default: 0] += 1
                    chars += token.text.utf16.count
                }
                return (counts, chars)
            }
            let profilesA = tokensA.map(profile)
            let profilesB = tokensB.map(profile)

            var candidates: [(shared: Int, i: Int, j: Int)] = []
            for i in regionsA.indices {
                for j in regionsB.indices where regionsA[i].hunk != regionsB[j].hunk {
                    let pa = profilesA[i], pb = profilesB[j]
                    let smaller = min(pa.chars, pb.chars)
                    guard smaller > 0 else { continue }
                    let (few, many) = pa.counts.count <= pb.counts.count ? (pa.counts, pb.counts) : (pb.counts, pa.counts)
                    var shared = 0
                    for (text, count) in few {
                        if let other = many[text] { shared += min(count, other) * text.utf16.count }
                    }
                    if shared >= editedMoveMinSharedChars, Double(shared) >= 0.5 * Double(smaller) {
                        candidates.append((shared, i, j))
                    }
                }
            }
            candidates.sort { $0.shared > $1.shared }

            var accepted = false
            for candidate in candidates {
                let ra = regionsA[candidate.i], rb = regionsB[candidate.j]
                let key = [ra.kept[0], ra.kept[ra.kept.count - 1], rb.kept[0], rb.kept[rb.kept.count - 1]]
                guard !rejected.contains(key) else { continue }
                let ta = tokensA[candidate.i], tb = tokensB[candidate.j]
                guard ta.count + tb.count <= wordDiffTokenLimit else { rejected.insert(key); continue }
                let alignment = alignWords(ta, tb, aLineCount: ra.kept.count, bLineCount: rb.kept.count)
                let smaller = min(alignment.leftWordChars, alignment.rightWordChars)
                guard smaller > 0,
                      Double(alignment.sharedWordChars) >= editedMoveMinOrderedShare * Double(smaller) else {
                    rejected.insert(key)
                    continue
                }
                if countsA == nil { countsA = keyCounts(a) }
                if countsB == nil { countsB = keyCounts(b) }
                // Either side may carry the edits (texts can be swapped), so
                // the evidence is counted per side, never summed: one line
                // present on both sides is one piece of evidence.
                let evidence = max(distinctiveUnchanged(alignment.left, region: ra, side: a, counts: countsA!),
                                   distinctiveUnchanged(alignment.right, region: rb, side: b, counts: countsB!))
                let needed = min(editedMoveDistinctiveLines, ra.kept.count, rb.kept.count)
                guard evidence >= needed else {
                    rejected.insert(key)
                    continue
                }

                // Lines with shared text move; lines with nothing shared stay
                // removed/added (new or dropped lines inside the block).
                func claim(_ verdicts: [LineVerdict], region: Region, side: Side,
                           changed: inout Set<Int>, moved: inout Set<Int>,
                           inline: inout [Int: [NSRange]]) -> [Int] {
                    var claimed: [Int] = []
                    for (offset, verdict) in verdicts.enumerated() {
                        let line = side.original(region.kept[offset])
                        switch verdict {
                        case .unmatched:
                            continue
                        case .unchanged:
                            break
                        case .edited(let ranges):
                            if !ranges.isEmpty { inline[line] = ranges }
                        }
                        changed.remove(line)
                        moved.insert(line)
                        claimed.append(offset)
                    }
                    return claimed
                }
                let claimedA = claim(alignment.left, region: ra, side: a, changed: &result.leftChanged,
                                     moved: &result.leftMoved, inline: &result.leftInline)
                let claimedB = claim(alignment.right, region: rb, side: b, changed: &result.rightChanged,
                                     moved: &result.rightMoved, inline: &result.rightInline)
                if let firstA = claimedA.first, let lastA = claimedA.last,
                   let firstB = claimedB.first, let lastB = claimedB.last {
                    result.movedPairs.append(MovedBlock(
                        left: a.original(ra.kept[firstA])..<(a.original(ra.kept[lastA]) + 1),
                        right: b.original(rb.kept[firstB])..<(b.original(rb.kept[lastB]) + 1)
                    ))
                }

                let dropA = Set(claimedA.map { ra.positions.lowerBound + $0 })
                let dropB = Set(claimedB.map { rb.positions.lowerBound + $0 })
                let keepA = pureRemovedKept.indices.filter { !dropA.contains($0) }
                let keepB = pureInsertedKept.indices.filter { !dropB.contains($0) }
                pureRemovedKept = keepA.map { pureRemovedKept[$0] }
                removedHunk = keepA.map { removedHunk[$0] }
                pureInsertedKept = keepB.map { pureInsertedKept[$0] }
                insertedHunk = keepB.map { insertedHunk[$0] }
                accepted = true
                break
            }
            if !accepted { return }
        }
    }

    /// Joins moved blocks that sit directly after each other on both sides
    /// (blank lines in between allowed), so one moved section draws one band.
    private static func mergeAdjacentMoves(a: Side, b: Side, result: inout DiffResult) {
        guard result.movedPairs.count > 1 else { return }
        func onlyBlank(_ lines: [String], from lower: Int, to upper: Int) -> Bool {
            guard lower <= upper else { return false }
            return (lower..<upper).allSatisfy { lines[$0].allSatisfy(\.isWhitespace) }
        }
        let sorted = result.movedPairs.sorted { $0.left.lowerBound < $1.left.lowerBound }
        var merged = [sorted[0]]
        for block in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            if onlyBlank(a.lines, from: last.left.upperBound, to: block.left.lowerBound),
               onlyBlank(b.lines, from: last.right.upperBound, to: block.right.lowerBound) {
                merged[merged.count - 1] = MovedBlock(left: last.left.lowerBound..<block.left.upperBound,
                                                      right: last.right.lowerBound..<block.right.upperBound)
            } else {
                merged.append(block)
            }
        }
        result.movedPairs = merged
    }

    // MARK: - Preprocessing

    private static func makeSide(_ text: String, options: DiffOptions) -> Side {
        let lines = text.components(separatedBy: "\n")
        if !options.ignoreWhitespace && !options.ignoreBlankLines && !options.ignoreCase {
            return Side(lines: lines, keys: lines, map: nil)
        }
        var keys: [String] = []
        var map: [Int] = []
        keys.reserveCapacity(lines.count)
        map.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            if options.ignoreBlankLines, line.allSatisfy(\.isWhitespace) { continue }
            let key = options.ignoreWhitespace ? normalize(line) : line
            keys.append(options.ignoreCase ? key.lowercased() : key)
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
    /// Lowercased for case-insensitive comparison, but only when that keeps
    /// the UTF-16 length, so emphasis ranges still fit the original text.
    private static func caseFolded(_ text: String) -> String {
        let folded = text.lowercased()
        return folded.utf16.count == text.utf16.count ? folded : text
    }

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
