import Foundation

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print(condition ? "PASS: \(name)" : "FAIL: \(name)")
    if !condition { failures += 1 }
}

let strict = DiffOptions()
let smart = DiffOptions(ignoreWhitespace: true, ignoreBlankLines: true)

// ========== Strict regression (existing behavior) ==========

var r = DiffEngine.compare(left: "a\nb\nc", right: "a\nb\nc")
check("identical", r.identical && r.hunkAnchors.isEmpty && !r.onlyWhitespaceDiffers)

r = DiffEngine.compare(left: "a\nfoo bar baz\nc", right: "a\nfoo QUX baz\nc")
check("changed line left", r.leftChanged == [1])
check("changed line right", r.rightChanged == [1])
check("one hunk", r.hunkAnchors.count == 1 && r.hunkAnchors[0] == (1, 1))
check("inline left present", r.leftInline[1]?.isEmpty == false)
check("inline right present", r.rightInline[1]?.isEmpty == false)
if let ranges = r.rightInline[1] {
    check("inline right covers QUX", ranges.contains { NSIntersectionRange($0, NSRange(location: 4, length: 3)).length == 3 })
}

r = DiffEngine.compare(left: "a\nb", right: "a\nb\nc")
check("added line", r.leftChanged.isEmpty && r.rightChanged == [2])
check("added hunk anchor", r.hunkAnchors.count == 1 && r.hunkAnchors[0].right == 2)

r = DiffEngine.compare(left: "x\na\nb", right: "a\nb")
check("removed line", r.leftChanged == [0] && r.rightChanged.isEmpty)

r = DiffEngine.compare(left: "1\n2\n3\n4\n5", right: "1\nX\n3\n4\nY")
check("two hunks", r.hunkAnchors.count == 2)
check("hunk lines", r.leftChanged == [1, 4] && r.rightChanged == [1, 4])

r = DiffEngine.compare(left: "a\np\nq\nz", right: "a\nP\nz")
check("unbalanced left", r.leftChanged == [1, 2])
check("unbalanced right", r.rightChanged == [1])
check("unbalanced one hunk", r.hunkAnchors.count == 1)

r = DiffEngine.compare(left: "", right: "a\nb")
check("empty left", !r.identical)

r = DiffEngine.compare(left: "", right: "")
check("both empty", r.identical && !r.onlyWhitespaceDiffers)

r = DiffEngine.compare(left: "aaaa", right: "bbbb")
check("total change", r.leftChanged == [0] && r.rightChanged == [0])
check("total change gated (no inline)", r.leftInline.isEmpty && r.rightInline.isEmpty)

let longA = String(repeating: "x", count: 10_000) + "MID" + String(repeating: "y", count: 10_000)
let longB = String(repeating: "x", count: 10_000) + "DIFFERENT" + String(repeating: "y", count: 10_000)
r = DiffEngine.compare(left: longA, right: longB)
check("long line changed", r.leftChanged == [0] && r.rightChanged == [0])
check("long line inline present", (r.leftInline[0] ?? []).count >= 1)

var lines = (0..<200_000).map { "line number \($0) with some content" }
let big1 = lines.joined(separator: "\n")
lines[100_000] = "CHANGED"
lines.insert("EXTRA LINE", at: 150_000)
let big2 = lines.joined(separator: "\n")
var t0 = Date()
r = DiffEngine.compare(left: big1, right: big2)
var dt = Date().timeIntervalSince(t0)
check("big diff correct", r.leftChanged == [100_000] && r.rightChanged == [100_000, 150_000])
check("big diff hunks", r.hunkAnchors.count == 2)
print(String(format: "big diff strict (200k lines): %.3fs", dt))
check("big diff fast", dt < 2.0)

let w1 = (0..<3_000).map { "left line \($0)" }.joined(separator: "\n")
let w2 = (0..<3_000).map { "right line \($0)" }.joined(separator: "\n")
t0 = Date()
r = DiffEngine.compare(left: w1, right: w2)
dt = Date().timeIntervalSince(t0)
print(String(format: "worst case strict (2x3000 fully different): %.3fs", dt))
check("worst case ok", r.leftChanged.count == 3_000 && dt < 5.0)

// ========== Smart options: whitespace / blank lines ==========

// Indent shift: same content, every line 4 spaces deeper.
let yaml = (0..<20).map { "key\($0): value \($0)" }
let indented = yaml.map { "    " + $0 }
r = DiffEngine.compare(left: yaml.joined(separator: "\n"), right: indented.joined(separator: "\n"), options: smart)
check("indent shift: identical", r.identical)
check("indent shift: flag set", r.onlyWhitespaceDiffers)
check("indent shift: no hunks", r.hunkAnchors.isEmpty)
r = DiffEngine.compare(left: yaml.joined(separator: "\n"), right: indented.joined(separator: "\n"), options: strict)
check("indent shift strict: all changed", r.leftChanged.count == 20 && r.rightChanged.count == 20)

// Added blank lines only.
let noBlanks = "one\ntwo\nthree"
let withBlanks = "one\n\ntwo\n\n\nthree\n"
r = DiffEngine.compare(left: noBlanks, right: withBlanks, options: smart)
check("blank lines: identical + flag", r.identical && r.onlyWhitespaceDiffers)
r = DiffEngine.compare(left: noBlanks, right: withBlanks, options: strict)
check("blank lines strict: differences", !r.identical)

// Combined HA-like case: nested deeper + blank lines + genuinely new lines.
let v1 = """
actions:
  - alias: Wait for the button
    wait_template: template_here
    timeout: 60
  - alias: Set program auto 2
    action: select.select_option
    data:
      option: auto_2
  - alias: Start the program
    action: start_selected
mode: restart
"""
let v2 = """
actions:
  - choose:
      - alias: Door closed, plan cheapest block
        conditions:
          - condition: trigger
        sequence:
          - alias: Wait for the button
            wait_template: template_here
            timeout: 60

          - alias: Set program auto 2
            action: select.select_option
            data:
              option: auto_2

          - alias: Start the program
            action: start_selected
mode: restart
"""
r = DiffEngine.compare(left: v1, right: v2, options: smart)
check("HA case: no left removals", r.leftChanged.isEmpty)
let expectedNew: Set<Int> = [1, 2, 3, 4, 5]  // choose:, alias wrapper, conditions:, condition, sequence:
check("HA case: only new wrapper lines green", r.rightChanged == expectedNew)
check("HA case: real differences, flag off", !r.onlyWhitespaceDiffers)
r = DiffEngine.compare(left: v1, right: v2, options: strict)
check("HA case strict: nearly everything changed", r.rightChanged.count > 10)

// Index mapping: blank lines BEFORE a real change must not shift indices.
r = DiffEngine.compare(left: "a\n\n\nb\nc", right: "a\nb\nX", options: smart)
check("mapping: left changed is original idx 4", r.leftChanged == [4] && r.rightChanged == [2])
check("mapping: no blank index marked", !r.leftChanged.contains(1) && !r.leftChanged.contains(2))

// Hunk merge semantics: two changes separated only by a blank line.
r = DiffEngine.compare(left: "a\nx\n\ny\nb", right: "a\nX\n\nY\nb", options: smart)
check("hunk merge: one hunk with blank-ignore", r.hunkAnchors.count == 1)
r = DiffEngine.compare(left: "a\nx\n\ny\nb", right: "a\nX\n\nY\nb", options: strict)
check("hunk merge: two hunks strict", r.hunkAnchors.count == 2)

// Internal whitespace collapse.
r = DiffEngine.compare(left: "a  \tb", right: "a b", options: smart)
check("collapse: a..b equals a b", r.identical && r.onlyWhitespaceDiffers)
r = DiffEngine.compare(left: "a b", right: "ab", options: smart)
check("collapse: a b vs ab differs", !r.identical)

// Similarity gate under options.
r = DiffEngine.compare(left: "zzzzzzz", right: "qqqq", options: smart)
check("gate: dissimilar pair no inline", r.leftChanged == [0] && r.leftInline.isEmpty && r.rightInline.isEmpty)
r = DiffEngine.compare(left: "  foo bar baz", right: "foo QUX baz", options: smart)
check("gate: similar pair has inline", r.leftInline[0]?.isEmpty == false)

// Inline range validity on ORIGINAL lines (different indents, one word changed).
let origLeft = "      value: alpha"
let origRight = "  value: beta"
r = DiffEngine.compare(left: origLeft, right: origRight, options: smart)
var rangesValid = true
for range in (r.leftInline[0] ?? []) where NSMaxRange(range) > origLeft.utf16.count { rangesValid = false }
for range in (r.rightInline[0] ?? []) where NSMaxRange(range) > origRight.utf16.count { rangesValid = false }
check("inline ranges within original lines", rangesValid && !r.identical)

// Degenerate cases.
r = DiffEngine.compare(left: "\n\n", right: "", options: smart)
check("blank-only vs empty: identical + flag", r.identical && r.onlyWhitespaceDiffers)
r = DiffEngine.compare(left: "", right: "x", options: smart)
check("empty vs x: difference", !r.identical)

// Normalized prefix/suffix trimming: only middle line flagged.
r = DiffEngine.compare(left: "  a\nX\n  b", right: "a\nY\nb", options: smart)
check("normalized trim: only middle changed", r.leftChanged == [1] && r.rightChanged == [1])

// Performance smoke with options on.
let bigIndented = (0..<200_000).map { "    line number \($0) with some content" }.joined(separator: "\n")
t0 = Date()
r = DiffEngine.compare(left: big1, right: bigIndented, options: smart)
dt = Date().timeIntervalSince(t0)
print(String(format: "big diff smart (200k lines, indent shift): %.3fs", dt))
check("big smart: whitespace-only", r.identical && r.onlyWhitespaceDiffers)
check("big smart fast", dt < 2.0)

if failures > 0 { print("\(failures) FAILURES"); exit(1) }
print("ALL TESTS PASSED")

// ========== Move detection (part A) ==========

let noMoves = DiffOptions(ignoreWhitespace: true, ignoreBlankLines: true, detectMoves: false)

// Simple whole-block move: 3-line block from top to bottom.
let mvLeft = "blok regel een\nblok regel twee\nblok regel drie\nmidden tekst\nslot tekst"
let mvRight = "midden tekst\nslot tekst\nblok regel een\nblok regel twee\nblok regel drie"
r = DiffEngine.compare(left: mvLeft, right: mvRight, options: smart)
check("move: one pair", r.movedPairs.count == 1)
// The LCS keeps the longer block matched; the complementary two lines are
// what gets classified as moved — an equally valid description.
check("move: ranges", r.movedPairs.first == MovedBlock(left: 3..<5, right: 0..<2))
check("move: sets", r.leftMoved == [3, 4] && r.rightMoved == [0, 1])
check("move: changed sets empty", r.leftChanged.isEmpty && r.rightChanged.isEmpty)
check("move: not identical", !r.identical && !r.onlyWhitespaceDiffers)
check("move: two hunks", r.hunkAnchors.count == 2)
check("move: matched lines", r.matchedLines.count == 3)

// detectMoves off reproduces red/green.
r = DiffEngine.compare(left: mvLeft, right: mvRight, options: noMoves)
check("move off: no pairs", r.movedPairs.isEmpty && r.leftChanged == [3, 4])

// Move + re-indent with ignoreWhitespace.
let mvRightIndented = "midden tekst\nslot tekst\n    blok regel een\n    blok regel twee\n    blok regel drie"
r = DiffEngine.compare(left: mvLeft, right: mvRightIndented, options: smart)
check("move indent: detected", r.movedPairs.count == 1 && !r.onlyWhitespaceDiffers)
r = DiffEngine.compare(left: mvLeft, right: mvRightIndented, options: strict)
check("move indent strict: not a move", r.movedPairs.isEmpty)
r = DiffEngine.compare(left: mvLeft, right: mvRight, options: strict)
check("move strict byte-identical: detected", r.movedPairs.count == 1)

// Duplicated block: occurs twice among removals -> never marked moved.
let dupLeft = "unieke blok regel\nx\nunieke blok regel\ny"
let dupRight = "x\ny\nunieke blok regel"
r = DiffEngine.compare(left: dupLeft, right: dupRight, options: smart)
check("duplicate: no move", r.movedPairs.isEmpty && !r.leftChanged.isEmpty)

// Trivial single line moved -> not marked; long unique line -> marked.
r = DiffEngine.compare(left: "ab\nx\ny", right: "x\ny\nab", options: smart)
check("trivial short move: not marked", r.movedPairs.isEmpty)
r = DiffEngine.compare(left: "}\nx\ny", right: "x\ny\n}", options: smart)
check("trivial brace move: not marked", r.movedPairs.isEmpty)
r = DiffEngine.compare(left: "een lange unieke regel tekst\nx\ny", right: "x\ny\neen lange unieke regel tekst", options: smart)
check("long single-line move: marked", r.movedPairs.count == 1)

// Move combined with real adds/removes.
let mixLeft = "verplaats blok regel 1\nverplaats blok regel 2\nblijft staan\nwordt verwijderd regel"
let mixRight = "blijft staan\nnieuw toegevoegde regel\nverplaats blok regel 1\nverplaats blok regel 2"
r = DiffEngine.compare(left: mixLeft, right: mixRight, options: smart)
check("mix: move detected", r.movedPairs.count == 1)
check("mix: removal stays red", r.leftChanged == [3])
check("mix: addition stays green", r.rightChanged == [1])

// Move adjacent to brand-new lines: extension stops at mismatch.
let adjLeft = "verhuis regel alfa\nverhuis regel beta\nk regel 1\nk regel 2\nk regel 3"
let adjRight = "k regel 1\nk regel 2\nk regel 3\nverhuis regel alfa\nverhuis regel beta\ngloednieuw hier\nook gloednieuw"
r = DiffEngine.compare(left: adjLeft, right: adjRight, options: smart)
check("adjacent: block moved", r.movedPairs.count == 1 && r.rightMoved == [3, 4])
check("adjacent: new lines green", r.rightChanged == [5, 6])

// Changed-pair exclusion: positionally paired lines are never moved.
r = DiffEngine.compare(left: "aaa identieke regel hier\nbbb", right: "ccc\naaa identieke regel hier x", options: smart)
check("pair exclusion: no move stolen", r.movedPairs.isEmpty)

// matchedLines correctness with blank lines filtered.
r = DiffEngine.compare(left: "a\n\nb\nc", right: "a\nb\n\n\nX", options: smart)
check("matched mapping", r.matchedLines.count == 2
      && r.matchedLines[0] == (0, 0) && r.matchedLines[1] == (2, 1))
var ascending = true
for i in 1..<max(1, r.matchedLines.count) where i < r.matchedLines.count {
    if r.matchedLines[i].left <= r.matchedLines[i-1].left || r.matchedLines[i].right <= r.matchedLines[i-1].right { ascending = false }
}
check("matched ascending", ascending)

// 200k lines with one 50-line block moved.
var mvBig = (0..<200_000).map { "grote verplaatsing regel \($0)" }
let mvBig1 = mvBig.joined(separator: "\n")
let blok = Array(mvBig[1000..<1050])
mvBig.removeSubrange(1000..<1050)
mvBig.insert(contentsOf: blok, at: 180_000)
let mvBig2 = mvBig.joined(separator: "\n")
t0 = Date()
r = DiffEngine.compare(left: mvBig1, right: mvBig2, options: smart)
dt = Date().timeIntervalSince(t0)
print(String(format: "big move (200k lines, 50-line block): %.3fs", dt))
check("big move: one pair", r.movedPairs.count == 1 && r.leftMoved.count == 50)
check("big move: fast", dt < 3.0)
check("big move: matched count", r.matchedLines.count == 199_950)

// HA fixture: moved variables block must be orange, not red+green.
let haLeft = "alias: test\nvariables:\n  kwartieren: 10\n  prijssensor: sensor.nordpool_kwh\nmode: restart"
let haRight = "alias: test\ntrigger_variables:\n  vanaf: 1500\nvariables:\n  kwartieren: 10\n  prijssensor: sensor.nordpool_kwh\nmode: restart"
r = DiffEngine.compare(left: haLeft, right: haRight, options: smart)
check("HA: no move needed when not moved", r.movedPairs.isEmpty && r.rightChanged == [1, 2])

// ========== Unpairing of dissimilar positional pairs ==========

// A dissimilar positional pair is reclaimed as removal+insertion, so the
// removed line can be recognized as moved elsewhere.
r = DiffEngine.compare(
    left: "verplaatste unieke regel\nx1 vulling regel\nx2 vulling regel",
    right: "andere nieuwe regel hier\nx1 vulling regel\nx2 vulling regel\nverplaatste unieke regel",
    options: smart)
check("unpair: reclaimed as move", r.movedPairs.count == 1 && r.leftMoved == [0] && r.rightMoved == [3])
check("unpair: new line stays green", r.rightChanged == [0] && r.leftChanged.isEmpty)

// Crossed identical lines (equal keys in a positional pair) become a move.
r = DiffEngine.compare(
    left: "blok alfa unieke regel\nblok beta unieke regel",
    right: "blok beta unieke regel\nblok alfa unieke regel",
    options: smart)
check("crossing: classified as move", r.movedPairs.count == 1 && r.leftChanged.isEmpty && r.rightChanged.isEmpty)

// Similar pairs still pair and keep inline emphasis.
r = DiffEngine.compare(left: "foo bar baz", right: "foo QUX baz", options: smart)
check("unpair: similar pair intact", r.movedPairs.isEmpty && r.leftInline[0]?.isEmpty == false)

// ========== Real-world fixture: the two HA automations ==========

if CommandLine.arguments.count >= 3 {
    let v1 = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
    let v2 = try! String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
    let lines1 = v1.components(separatedBy: "\n")
    let lines2 = v2.components(separatedBy: "\n")
    r = DiffEngine.compare(left: v1, right: v2, options: smart)

    let variablesPair = r.movedPairs.first {
        lines1[$0.left.lowerBound].trimmingCharacters(in: .whitespaces) == "variables:"
    }
    check("fixture: variables block moved", variablesPair != nil && variablesPair!.left.count == 3)
    let kwartierenLeft = lines1.firstIndex { $0.contains("kwartieren") }!
    let kwartierenRight = lines2.firstIndex { $0.contains("kwartieren") }!
    check("fixture: kwartieren orange both sides",
          r.leftMoved.contains(kwartierenLeft) && r.rightMoved.contains(kwartierenRight))
    let machineVrij = lines1.firstIndex { $0.contains("De machine is vrij") }!
    check("fixture: machine-vrij matched, not marked",
          !r.leftChanged.contains(machineVrij) && !r.leftMoved.contains(machineVrij))
    check("fixture: little red left", r.leftChanged.count <= 8)
    let triggerVars = lines2.firstIndex { $0.contains("trigger_variables") }!
    check("fixture: new content green", r.rightChanged.contains(triggerVars))
    check("fixture: most lines matched", r.matchedLines.count >= 35)
} else {
    print("SKIP: fixture paths not provided")
}


// ========== Line breaks count as whitespace (word level within hunks) ==========

// Re-wrapped text is not a difference.
let wrapped = "Dit is een lange zin die over\nmeerdere regels is afgebroken door\nde editor."
let unwrapped = "Dit is een lange zin die over meerdere regels is afgebroken door de editor."
r = DiffEngine.compare(left: wrapped, right: unwrapped, options: smart)
check("reflow: identical", r.identical && r.onlyWhitespaceDiffers && r.hunkAnchors.isEmpty)
r = DiffEngine.compare(left: wrapped, right: unwrapped, options: strict)
check("reflow strict: still a difference", !r.identical)

// Re-wrapped with one word changed: only the lines holding the change.
r = DiffEngine.compare(left: "Alpha beta gamma delta\nepsilon zeta eta theta",
                       right: "Alpha beta gamma DELTA epsilon zeta eta theta", options: smart)
check("reflow edit: only changed lines", r.leftChanged == [0] && r.rightChanged == [0])
check("reflow edit: word emphasized", r.leftInline[0] == [NSRange(location: 17, length: 5)]
      && r.rightInline[0] == [NSRange(location: 17, length: 5)])
check("reflow edit: one hunk", r.hunkAnchors.count == 1)

// One word replaced by one word: only the differing characters.
r = DiffEngine.compare(left: "Versie 20261013\nlange regel een twee\ndrie vier",
                       right: "Versie 20261014\nlange regel een twee drie vier", options: smart)
check("token refine: last digit only", r.leftInline[0] == [NSRange(location: 14, length: 1)]
      && r.rightInline[0] == [NSRange(location: 14, length: 1)])

// A comment added to a line: the left line is not colored, the comment is.
r = DiffEngine.compare(left: "a: 1\nrendement: 0.87\nb: 2",
                       right: "a: 1\nrendement: 0.87   # round trip comment\nb: 2", options: smart)
check("added comment: left unmarked", r.leftChanged.isEmpty)
check("added comment: right marked", r.rightChanged == [1])
check("added comment: only comment emphasized",
      r.rightInline[1] == [NSRange(location: 18, length: 20)])

// A number repeated inside an added comment: the shared number stays with
// its line, the comment is emphasized as one piece.
r = DiffEngine.compare(left: "a: 1\nzon_naar_accu_deel: 0.55\nb: 2",
                       right: "a: 1\nzon_naar_accu_deel: 0.55   # bij mij 55 procent\nb: 2", options: smart)
check("repeated number: comment is one emphasis", r.leftChanged.isEmpty
      && r.rightInline[1] == [NSRange(location: 27, length: 20)])

// Two lines joined: only the new comma.
r = DiffEngine.compare(left: "x = 1\ny = 2", right: "x = 1, y = 2", options: smart)
check("joined: left unmarked", r.leftChanged.isEmpty)
check("joined: comma emphasized", r.rightChanged == [0] && r.rightInline[0] == [NSRange(location: 5, length: 1)])

// A banner of repeated punctuation is one token, not dozens.
r = DiffEngine.compare(left: "kop\nalpha beta gamma\ndelta",
                       right: "kop\n# ==========================\nalpha beta gamma delta", options: smart)
check("banner: only banner added", r.leftChanged.isEmpty && r.rightChanged == [1])

// A plain replacement still pairs both lines (unchanged behavior).
r = DiffEngine.compare(left: "foo bar baz", right: "foo QUX baz", options: smart)
check("replacement: both sides marked", r.leftChanged == [0] && r.rightChanged == [0])

// Edits in place are never moves.
r = DiffEngine.compare(
    left: "begin\nregel een met inhoud alpha\nregel twee met inhoud beta\neinde",
    right: "begin\nregel een met inhoud alpha # extra\nregel twee met inhoud beta # extra\neinde",
    options: smart)
check("in place: no move", r.movedPairs.isEmpty && r.leftChanged.isEmpty && r.rightChanged == [1, 2])

// ========== Moves with edits ==========

let editedMoveLeft = "kop\nblok_een: 1\nblok_twee: 2\nblok_drie: 3\nmidden een\nmidden twee\nmidden drie\nstaart"
let editedMoveRight = "kop\nmidden een\nmidden twee\nmidden drie\n# nieuwe kop boven blok\nblok_een: 1   # eerste\nblok_twee: 2   # tweede\nblok_drie: 3\nstaart"
r = DiffEngine.compare(left: editedMoveLeft, right: editedMoveRight, options: smart)
check("edited move: one block", r.movedPairs == [MovedBlock(left: 1..<4, right: 5..<8)])
check("edited move: lines orange", r.leftMoved == [1, 2, 3] && r.rightMoved == [5, 6, 7])
check("edited move: new comment line green", r.rightChanged == [4] && r.leftChanged.isEmpty)
check("edited move: comment emphasized", r.rightInline[5] == [NSRange(location: 14, length: 8)])
// Swapped texts: the edits are now on the left; still one moved block.
r = DiffEngine.compare(left: editedMoveRight, right: editedMoveLeft, options: smart)
check("edited move swapped: one block", r.movedPairs.count == 1 && r.leftChanged == [4])
// Strict comparison keeps exact moves only.
r = DiffEngine.compare(left: editedMoveLeft, right: editedMoveRight, options: strict)
check("edited move strict: not an edited move", r.leftMoved.count <= 1)

// Similar but different list items are not paired as one moved-and-edited
// item (one distinctive line per side is not enough evidence). Only the
// identical line itself is an exact move, as before.
let itemLeft = "lijst:\n- alias: Deur open\n  trigger: state\n  entity_id: sensor.deur\n  to: open\nmidden een\nmidden twee\nmidden drie"
let itemRight = "lijst:\nmidden een\nmidden twee\nmidden drie\n- alias: Raam dicht\n  trigger: state\n  entity_id: sensor.raam\n  to: closed"
r = DiffEngine.compare(left: itemLeft, right: itemRight, options: smart)
check("similar items: not paired", r.movedPairs == [MovedBlock(left: 2..<3, right: 5..<6)])
check("similar items: differing lines stay red/green", r.leftChanged == [1, 3, 4] && r.rightChanged == [4, 6, 7])

// ========== Performance with whitespace-insensitive comparison ==========

let s1 = (0..<1_500).map { "left line \($0)" }.joined(separator: "\n")
let s2 = (0..<1_500).map { "right line \($0)" }.joined(separator: "\n")
t0 = Date()
r = DiffEngine.compare(left: s1, right: s2, options: smart)
dt = Date().timeIntervalSince(t0)
print(String(format: "worst case smart (2x1500 lines, every line edited): %.3fs", dt))
check("worst case smart: fast", dt < 5.0)
check("worst case smart: all marked", r.leftChanged.count == 1_500 && r.rightChanged.count == 1_500)

let longWrapped = (0..<300).map { "woord\($0) en nog wat tekst" }.joined(separator: "\n")
let longUnwrapped = (0..<60).map { block in
    (0..<5).map { "woord\(block * 5 + $0) en nog wat tekst" }.joined(separator: " ")
}.joined(separator: "\n")
t0 = Date()
r = DiffEngine.compare(left: longWrapped, right: longUnwrapped, options: smart)
dt = Date().timeIntervalSince(t0)
print(String(format: "re-wrapped text (300 lines into 60): %.3fs", dt))
check("re-wrapped text: identical", r.identical && r.onlyWhitespaceDiffers)
check("re-wrapped text: fast", dt < 2.0)

// ========== Hunk extents (for the current-difference marker) ==========

r = DiffEngine.compare(left: "1\n2\n3\n4\n5", right: "1\nX\n3\n4\nY")
check("hunks: one per difference", r.hunks == [Hunk(left: 1..<2, right: 1..<2), Hunk(left: 4..<5, right: 4..<5)])
r = DiffEngine.compare(left: "a\nb", right: "a\nb\nc")
check("hunks: added at end is empty at end on the left", r.hunks == [Hunk(left: 2..<2, right: 2..<3)])
r = DiffEngine.compare(left: "x\na\nb", right: "a\nb")
check("hunks: removed at start is empty at start on the right", r.hunks == [Hunk(left: 0..<1, right: 0..<0)])
r = DiffEngine.compare(left: "a\np\nq\nz", right: "a\nP\nz")
check("hunks: unbalanced block spans both removed lines", r.hunks == [Hunk(left: 1..<3, right: 1..<2)])
r = DiffEngine.compare(left: "Alpha beta gamma delta\nepsilon zeta eta theta",
                       right: "Alpha beta gamma DELTA epsilon zeta eta theta", options: smart)
check("hunks: word mode spans the marked lines", r.hunks == [Hunk(left: 0..<1, right: 0..<1)])

// ========== Real-world fixture: re-wrapped and re-organized automation ==========

if CommandLine.arguments.count >= 5 {
    let v1 = try! String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8)
    let v2 = try! String(contentsOfFile: CommandLine.arguments[4], encoding: .utf8)
    let lines1 = v1.components(separatedBy: "\n")
    let lines2 = v2.components(separatedBy: "\n")
    r = DiffEngine.compare(left: v1, right: v2, options: smart)
    print("accu fixture: \(r.leftChanged.count) red, \(r.rightChanged.count) green, \(r.leftMoved.count)/\(r.rightMoved.count) moved, \(r.movedPairs.count) blocks")
    check("accu: few red lines", r.leftChanged.count <= 16)
    check("accu: few green lines", r.rightChanged.count <= 30)
    check("accu: two moved blocks", r.movedPairs.count == 2)
    check("accu: one extent per difference", r.hunks.count == r.hunkAnchors.count && !r.hunks.isEmpty)
    var ordered = true
    for k in 1..<r.hunks.count where r.hunks[k].left.lowerBound < r.hunks[k - 1].left.lowerBound
        || r.hunks[k].right.lowerBound < r.hunks[k - 1].right.lowerBound { ordered = false }
    check("accu: extents in document order", ordered)
    let paragraph = lines1.firstIndex { $0.contains("Vult de accu zo veel mogelijk") }!
    check("accu: re-wrapped paragraph unmarked",
          !r.leftChanged.contains(paragraph) && !r.leftMoved.contains(paragraph))
    let version = lines1.firstIndex { $0.contains("Versie 20261013") }!
    check("accu: version digit emphasized", r.leftInline[version] == [NSRange(location: 16, length: 1)])
    let rendementLeft = lines1.firstIndex { $0.contains("rendement: 0.87") }!
    let rendementRight = lines2.firstIndex { $0.contains("rendement: 0.87") }!
    check("accu: moved setting orange", r.leftMoved.contains(rendementLeft) && r.rightMoved.contains(rendementRight))
    let commentStart = (lines2[rendementRight] as NSString).range(of: "#").location
    check("accu: added comment emphasized", r.rightInline[rendementRight]?.first?.location == commentStart)
} else {
    print("SKIP: accu fixture paths not provided")
}

if failures > 0 { print("\(failures) FAILURES (total)"); exit(1) }
print("ALL TESTS PASSED INCLUDING FIXTURES")
