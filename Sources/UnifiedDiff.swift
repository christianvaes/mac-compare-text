import Foundation

/// Writes the differences of a comparison as a unified diff (the format of
/// `diff -u` and git), for pasting into a ticket or a message.
///
/// The differences are the ones the app shows, so with whitespace ignored,
/// re-wrapped text is not listed. Context lines come from the left text.
enum UnifiedDiff {
    static func make(left: String, right: String, hunks: [Hunk],
                     leftName: String, rightName: String, context: Int = 3) -> String {
        guard !hunks.isEmpty else { return "" }
        let a = left.components(separatedBy: "\n")
        let b = right.components(separatedBy: "\n")

        // Differences whose context would overlap share one @@ section.
        var groups: [[Hunk]] = []
        for hunk in hunks {
            if let previous = groups.last?.last,
               hunk.left.lowerBound - previous.left.upperBound <= 2 * context,
               hunk.right.lowerBound - previous.right.upperBound <= 2 * context {
                groups[groups.count - 1].append(hunk)
            } else {
                groups.append([hunk])
            }
        }

        var out = "--- \(leftName)\n+++ \(rightName)\n"
        for group in groups {
            let first = group[0]
            let last = group[group.count - 1]
            let lead = min(context, first.left.lowerBound, first.right.lowerBound)
            let trail = min(context, max(0, a.count - last.left.upperBound), max(0, b.count - last.right.upperBound))

            var body: [String] = []
            var leftCount = 0
            var rightCount = 0
            func keep(_ range: Range<Int>) {
                for line in range { body.append(" " + a[line]) }
                leftCount += range.count
                rightCount += range.count
            }
            func remove(_ range: Range<Int>) {
                for line in range { body.append("-" + a[line]) }
                leftCount += range.count
            }
            func add(_ range: Range<Int>) {
                for line in range { body.append("+" + b[line]) }
                rightCount += range.count
            }

            keep((first.left.lowerBound - lead)..<first.left.lowerBound)
            for (index, hunk) in group.enumerated() {
                if index > 0 {
                    let previous = group[index - 1]
                    let gapA = previous.left.upperBound..<hunk.left.lowerBound
                    let gapB = previous.right.upperBound..<hunk.right.lowerBound
                    // Unequal gaps (skipped blank lines) can't be shared
                    // context; list them as removed and added.
                    if gapA.count == gapB.count {
                        keep(gapA)
                    } else {
                        remove(gapA)
                        add(gapB)
                    }
                }
                remove(hunk.left)
                add(hunk.right)
            }
            keep(last.left.upperBound..<(last.left.upperBound + trail))

            let leftStart = first.left.lowerBound - lead
            let rightStart = first.right.lowerBound - lead
            out += "@@ -\(position(leftStart, leftCount)) +\(position(rightStart, rightCount)) @@\n"
            out += body.joined(separator: "\n") + "\n"
        }
        return out
    }

    /// `start,count` as diff writes it: 1-based, the count left out when it
    /// is 1, and for an empty range the line before the insertion point.
    private static func position(_ start: Int, _ count: Int) -> String {
        switch count {
        case 0: return "\(start),0"
        case 1: return "\(start + 1)"
        default: return "\(start + 1),\(count)"
        }
    }
}
