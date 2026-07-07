# Compare Text (Vergelijk Tekst)

Simple, fully offline macOS app for comparing two pasted texts side by side.
The UI is in Dutch or English, depending on your system language.

## Usage

1. Paste text into the left field (original) and the right field (new).
2. Click **Compare** (or press **↩** / **⌘↩**).
3. Differences are highlighted per line, with extra emphasis on the words
   that differ within a line (WinMerge-style):
   - **red** (left) = line removed or changed
   - **green** (right) = line added or changed
4. Navigate through the differences with **◀ ▶** (or **⌘[** / **⌘]**);
   both sides scroll to the difference automatically.
5. For a new comparison: select all (**⌘A**), paste the new text over it and
   compare again. Highlights disappear automatically as soon as you type or
   paste.

Extras: **Swap** (⇧⌘T) exchanges both texts, **Clear** (⇧⌘K) empties
everything, **⌘F** searches within a field, **⌘Z** is undo. The menu
**Compare Text → About Compare Text** shows the version, build date and
website (www.cvaes.nl).

## Installation (any Mac, Apple Silicon or Intel)

The whole app ships as a single file — no compiling needed:

1. **[Download CompareText.zip](dist/CompareText.zip?raw=true)** and
   double-click to unpack.
2. Drag `CompareText.app` to the **Applications** folder.
3. First launch: **right-click → Open → Open** (needed once because the app
   is not distributed through the App Store).

No dependencies, no configuration, nothing machine-specific.

## Building from source

```sh
./build.sh          # universal binary (arm64 + x86_64) + dist/CompareText.zip
open build/CompareText.app
```

Requires only the Xcode Command Line Tools.

Testing:

```sh
# Full end-to-end UI test (drives the real app, verifies highlights,
# navigation, swap, large texts, and renders dark/light screenshots):
open build/CompareText.app --env COMPARETEXT_SELFTEST=1 --stdout /tmp/selftest.log
```

## Security & design

- **No network**: the app contains no networking APIs and has no network
  entitlement — text never leaves your machine.
- **App Sandbox** enabled, with no further entitlements; **hardened
  runtime** enabled. `build.sh` verifies after signing that the sandbox is
  really active.
- **Plain text only**: pasted formatting, images and links are stripped;
  spell checking, autocorrection and data detection are off.
- **No dependencies**: 100% Apple frameworks (AppKit + TextKit 2).
- **Performance**: line-level Myers diff with prefix/suffix trimming and
  intra-line refinement, on a background thread. Comparing 200,000 lines
  takes ~0.14 s on Apple Silicon; the UI roundtrip with 20,000 lines is
  ~0.1 s.

## Architecture

| File | Responsibility |
| --- | --- |
| `Sources/CompareTextApp.swift` | App lifecycle, menu bar and About window |
| `Sources/MainWindowController.swift` | Window, button bar, actions (compare/navigate/swap) |
| `Sources/PaneController.swift` | One text pane: header, line numbers, placeholder, highlights |
| `Sources/LineNumberSidebar.swift` | Line-number sidebar based on TextKit 2 layout positions |
| `Sources/DiffEngine.swift` | Line- and word-level diff (pure, unit-tested) |
| `Sources/L10n.swift` | Dutch/English |
| `Sources/DebugSelfTest.swift` | End-to-end test suite (only active with `COMPARETEXT_SELFTEST=1`) |

## Technical note (macOS 26)

The text views must stay strictly on TextKit 2: touching any TextKit 1 API
(`textView.layoutManager`) or using `NSRulerView` makes the text view stop
rendering entirely on macOS 26. That is why the line numbers are a custom
`NSView` sidebar and the UI is pure AppKit. Custom views that draw only once
must sit on top of the z-order (see `PaneController`), or their layer
contents get overdrawn.
