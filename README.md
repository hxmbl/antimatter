# Antimatter

A tiny, local, command-aware notes app for macOS. Not a filing system — a place to dump whatever's in your head and get something back.

**Typing is the interface.** No modes to pick. Everything you type is a valid line of Markdown — only deliberate dot-commands and math do something special.

```text
.timer 5 soup          → 5-minute countdown chip, ding when done
384 * 27 =              → instant answer: 384 * 27 = 10368
price = 4 * 12          → define a variable, later lines use it
days until 2026-09-01   → 8
12 kg -> lb             → 26.46
2026-08-22              → Saturday
remember to fix the relay   → just stays text. good.
```

## Features

- **Floating pane** — stays above everything, hides on `Esc` or the hotkey, reopens with the same chord. Position and size survive relaunches.
- **Markdown that knows how to disappear** — Notion-style syntax collapsing: headings, block quotes, fenced code, lists, task lists, tables, bold/italic/inline code/strikethrough, links, bare URLs, `\` escapes. Syntax collapses away from the caret and reappears on its line.
- **Real math** — type `384 * 27 =` for an instant answer, or return on a pure-arithmetic line to rewrite it to `384 * 27 = 10368`. Operators include `+ - * / % ^`, parens, `sqrt abs round min max`, and typographic `× ÷ −`.
- **Reactive variables** — `price = 4 * 12` defines a variable; later lines use `price / 2`. Edit a definition and committed dependents recompute live.
- **Aggregates** — `.sum` `.avg` `.count` scan the note's numbers (prose ignored) and recompute when the note changes.
- **Timers** — `.timer 5`, `.timer 90s`, `.timer 1h 20m stand up`. Countdown chips float in the corner, a sound plays on completion, a notification carries the name (click to reopen the pane), and unfinished timers survive relaunches. `.timer cancel` / `.timer cancel all` to clear.
- **Stopwatches** — `.stopwatch` starts a counter that ticks up in the corner; `⏹` freezes its reading, `.stopwatch cancel` clears it. No end means no banners — the chip is the whole surface, and it keeps counting across relaunches.
- **Reminders** — `.remind in 10 minutes` or `.remind tomorrow at 3pm`. One-shot system notifications, persisted.
- **Dates & units, offline** — return on `2026-08-22` appends its weekday; `days until …` counts down; `12 kg -> lb` converts. Built-in table, no network.
- **Currency & crypto, opt-in** — flip *Settings → Currency* and `100 USD → EUR` converts live rates; crypto works too (`1 BTC → USD`). The switch is off by default so the note never touches the network until you ask; rates refresh at most once an hour (Coinbase exchange rates, fiat + crypto).
- **Capture** — `.paste` streams clipboard copies into the note until you dismiss it. Drop an image on the pane for on-device OCR (Apple Vision, fully local).
- **Autosave** — every keystroke saved atomically to `Application Support/Antimatter/notes/notes.json` with a one-generation `.bak`. Legacy `scratchpad.md` files are imported automatically. Type → quit → relaunch → it's still there.
- **Dot-command autocompletion** — native completion window appears as you type after a `.`.
- **Export, no network** — `.export notes` sends the note to Apple Notes; `.export obsidian` saves it as a markdown file wherever you point.
- **Typing that stays literal** — punctuation is never silently rewritten while you type. URLs with `utm_*`, `fbclid`, `gclid` & friends lose their tracking parameters only when rendered as links.
- **A smooth, quiet caret** — the caret glides between positions on a faint, fading spline (like the iPhone's text cursor) instead of teleporting, and it's still the same old accessible insertion point underneath.
- **Help & debug** — `.help` opens a full-screen command reference; `.debug` shows the event log.

## Dot-Commands

| Command | What it does |
|---------|--------------|
| `.timer 5 soup` | Countdown timer with a label |
| `.timer cancel all` | Clear running timers |
| `.pomodoro 25/5/4` | Work/break cycle timer (minutes, up to 12 cycles) |
| `.stopwatch soup` | Stopwatch that counts up |
| `.stopwatch cancel all` | Clear stopwatches |
| `.remind in 10 minutes` | One-shot reminder |
| `.reminder cancel all` | Clear reminders |
| `.paste` | Stream clipboard copies into the note |
| `.sum` / `.total` | Sum the note's numbers |
| `.avg` / `.average` | Average the note's numbers |
| `.count` | Count the note's numbers |
| `.export notes` | Send the note to Apple Notes |
| `.export obsidian` | Save the note as markdown in your vault |
| `.settings` | Open settings |
| `.find` | Open the find bar (also `⌘F`) |
| `.replace find → replace` | Global replace in the note |
| `.debug` | Show diagnostics + event log |
| `.help` | Show the command reference |

Not sure which command does what? Type `.` and use the native completion list.

## Settings

- **Hot key chord** — pick your own modifiers + key (default `⌃⌥Space`).
- **Font size** — 11–26pt.
- **Appearance** — System / Light / Dark.
- **Currency conversion** — off by default; flip it on to fetch (and cache) live fiat + crypto exchange rates.

## Keyboard

| Shortcut | Action |
|----------|--------|
| `⌃⌥Space` | Toggle pane (configurable) |
| `Esc` | Hide pane / close reference view |
| `⌘F` / `⌘G` / `⌘⇧G` | Find / next / previous |
| `⌘R` | Reveal notes in Finder |

## Architecture

```text
antimatter/
├── App         app entry, window scene, hotkey wiring
├── UI          pane editor (NSTextView), chips, and styling
├── Parser      Markdown, expression evaluator, and intent detection

Linting
-------
This repository includes a recommended SwiftLint configuration (.swiftlint.yml) and a helper script at tools/run-swiftlint.sh.

To enable linting locally:
- Install SwiftLint (Homebrew): brew install swiftlint
- Or add SwiftLint as an Xcode package: File → Add Packages… → https://github.com/realm/SwiftLint

Optional: add a Run Script Phase to the antimatter target (Xcode Build Phases):

if which swiftlint >/dev/null; then
  swiftlint
fi

There is also a git hook template at .githooks/pre-commit. Enable it with:

chmod +x .githooks/pre-commit
ln -s ../../.githooks/pre-commit .git/hooks/pre-commit

The project uses a non-blocking (recommended) setup by default; ask to enable strict mode that fails builds/commits on violations.
├── Storage     autosaved notes and legacy migration
├── Services    timers, global hot key, currency rates, exports
└── antimatterTests   Swift Testing
```

Simple operations are deterministic — timers use a timer, arithmetic uses a parser, dates use a date parser. No LLM is peeking at your keystrokes.

## Stack

- **Language:** Swift
- **UI:** SwiftUI + AppKit (`NSTextView` pane)
- **Platform:** macOS
- **Persistence:** JSON for notes, timers, reminders, and cached exchange rates in Application Support; legacy Markdown scratchpads are imported once
- **OCR:** Apple Vision, on-device
- **Tests:** Swift Testing

## Building

Open `antimatter.xcodeproj` in Xcode and run. No dependencies to fetch.

## Why This Exists

Every notes app either locks you into a system or makes you pick a mode before you type. Antimatter just sits in front of you, takes what's in your head, and does the obvious thing with it.

> **Don't organize your thoughts. Interact with them.**

## License

No.
