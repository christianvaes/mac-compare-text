# Compare Text (Vergelijk Tekst)

Simple, fully offline macOS app for comparing two pasted texts side by side.
The UI is in Dutch or English, depending on your system language.

## Usage

1. Paste text into the left field (original) and the right field (new).
2. Click **Compare** in the toolbar (or press **⌘↩**).
3. Differences are highlighted per line, with extra emphasis on the words
   that differ within a line (WinMerge-style):
   - **red** (left) = line removed or changed
   - **green** (right) = line added or changed
4. Navigate through the differences with the **chevrons** in the toolbar (or **⌘[** / **⌘]**);
   both sides scroll to the difference automatically.
5. For a new comparison: select all (**⌘A**), paste the new text over it and
   compare again. Highlights disappear automatically as soon as you type or
   paste.

By default the comparison **ignores whitespace and blank lines**: lines that
only differ in indentation or spacing (e.g. a YAML block nested one level
deeper) are not marked, and added/removed blank lines are skipped. Untick the
**Ignore whitespace** option (toolbar options menu or the Comparison menu) to compare strictly; the
choice is remembered.

**Moved blocks** (text present in both versions at a different position) are
shown in **orange** in both panes instead of red+green, connected by an
orange band through the gap between the panes, and counted separately in the
summary.

With **Scroll together** enabled (the default), both panes scroll in sync
after a comparison, aligned on matching lines — texts of different lengths
stay side by side. Editing a text pauses the sync until the next comparison.

The status bar shows a color legend with line counts after each comparison.

Extras: **Swap** (⇧⌘T) exchanges both texts, **Clear** (⇧⌘K) empties
everything, **⌘F** searches within a field, **⌘Z** is undo. The menu
**Compare Text → About Compare Text** shows the version, build date and
website (www.cvaes.nl).

## Installation

Requires **macOS 14 Sonoma or later**. The app is a universal binary (Apple
Silicon and Intel). It has been tested on macOS 26 on Apple Silicon; the Intel
build has been tested under Rosetta, not on Intel hardware, and macOS 14/15
have not been tested.

The whole app ships as a single file — no compiling needed:

1. **[Download CompareText.zip](https://raw.githubusercontent.com/christianvaes/mac-compare-text/main/dist/CompareText.zip)**
   (about 420 KB) and double-click to unpack.
2. Drag `CompareText.app` to the **Applications** folder.
3. First launch: if macOS reports the app as damaged or from an unknown
   developer (it is not notarized by Apple), run this once in Terminal:
   `xattr -d com.apple.quarantine /Applications/CompareText.app`

No dependencies and no configuration.

## Building from source

```sh
./build.sh          # universal binary (arm64 + x86_64) + dist/CompareText.zip
open build/CompareText.app
```

Requires only the Xcode Command Line Tools.

Testing:

```sh
# Unit tests for the diff engine, including a real-world fixture comparison:
./tests/run-tests.sh

# Full end-to-end UI test (drives the real app, verifies highlights,
# navigation, sync scrolling, moved blocks, and renders screenshots).
# The paste check expects "PLAKTEST" on the clipboard:
printf 'PLAKTEST' | pbcopy
open build/CompareText.app --env COMPARETEXT_SELFTEST=1 --stdout /tmp/selftest.log
```

The UI test leaves both options (Ignore whitespace, Scroll together) switched
on, overwriting your saved choice.

## Security & design

- **No network**: the app contains no networking APIs and has no network
  entitlement — text never leaves your machine. (The website link in the
  About window opens your default browser.)
- **App Sandbox** enabled, with no further entitlements; **hardened
  runtime** enabled. `build.sh` verifies after signing that the sandbox is
  really active.
- **Plain text only**: pasted formatting, images and links are stripped;
  spell checking, autocorrection and data detection are off.
- **No dependencies**: 100% Apple frameworks (AppKit + TextKit 2).
- **Performance**: line-level Myers diff with prefix/suffix trimming and
  intra-line refinement, on a background thread. Measured on Apple Silicon:
  200,000 lines take ~0.15 s with strict comparison and ~1 s with the default
  whitespace-insensitive comparison; the UI roundtrip with 20,000 lines is
  ~0.1–0.2 s.

## Architecture

| File | Responsibility |
| --- | --- |
| `Sources/CompareTextApp.swift` | App lifecycle, menu bar and About window |
| `Sources/MainWindowController.swift` | Window, toolbar, status bar with legend, actions (compare/navigate/swap/options) |
| `Sources/PaneController.swift` | One text pane: header, line numbers, placeholder, highlights |
| `Sources/LineNumberSidebar.swift` | Line-number sidebar based on TextKit 2 layout positions |
| `Sources/DiffEngine.swift` | Line- and word-level diff, moved-block detection (pure, unit-tested) |
| `Sources/ScrollSyncCoordinator.swift` | Anchor-based synchronized scrolling between the panes |
| `Sources/MovedLinksOverlay.swift` | Orange bands between old and new location of moved blocks |
| `Sources/L10n.swift` | Dutch/English |
| `Sources/DebugSelfTest.swift` | End-to-end test suite (only active with `COMPARETEXT_SELFTEST=1`) |
| `tests/` | Diff engine unit tests (`run-tests.sh`) with a real-world fixture pair |

## Technical note (macOS 26)

The text views must stay strictly on TextKit 2: touching any TextKit 1 API
(`textView.layoutManager`) or using `NSRulerView` makes the text view stop
rendering entirely on macOS 26. That is why the line numbers are a custom
`NSView` sidebar and the UI is pure AppKit. Custom views that draw only once
must sit on top of the z-order (see `PaneController`), or their layer
contents get overdrawn.
