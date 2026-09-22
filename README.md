# Antimatter

![Build & Test](https://github.com/hxmbl/antimatter/actions/workflows/build.yml/badge.svg)

A tiny, local, command-aware notes app for macOS. Not a filing system — a place to dump whatever's in your head and get something back.

**Typing is the interface.** No modes to pick. Everything you type is a valid line of Markdown — only deliberate dot-commands and math do something special.

```text
.timer 5 soup          → 5-minute countdown chip, ding when done
384 * 27 =              → instant answer: 384 * 27 = 10368
:price = 4 * 12        → define a variable, later lines use it
:total = $(.sum 10 20 30) → embed dot-commands with $()
days until 2026-09-01   → 8
12 kg -> lb             → 26.46
2026-08-22              → Saturday
remember to fix the relay   → just stays text. good.
```

Pressing **⏎** on any of those lines commits the result. Typing `.help` shows every command in a full-screen reference.

---

## Quick start

1. Build & run the app (see [Building](#building)).
2. Hit `⌃⌥Space` anywhere to summon the pane.
3. Type `.help` and press **⏎** — that's the whole onboarding.

No setup, no account, no data leaves your Mac until you ask it to.

---

## Documentation

The `docs/` folder covers the note-processing engine:

- [`docs/spark.md`](docs/spark.md) — the Spark expression language (operators, functions, lists, ranges, indexing, conditionals, `$()`).
- [`docs/variables.md`](docs/variables.md) — how `:name = expression` variables work (forward references, deletion, typed values, completion).
- [`docs/aggregates.md`](docs/aggregates.md) — `.sum` / `.avg` / `.count`, explicit arguments, and `where` / `if` filtering.
- [`docs/commands.md`](docs/commands.md) — the full command reference and the JSON/CSV exports.
- [`docs/architecture.md`](docs/architecture.md) — the parsing pipeline and code layout (no UI).

---

## What it does

- **Spark, the note's math language** — type `384 * 27 =` for the answer as you type, or press return on a pure-arithmetic line to rewrite it to `384 * 27 = 10368`. Operators: `+ - * / % ^`, parens, `sqrt abs round min max sin cos tan asin acos atan ln log exp floor ceil sign`, constants `pi tau e`, scientific notation (`1e6`), implicit multiplication (`2(3+4)`), comparisons (`2 > 1` → `2 > 1 = true`), boolean logic (`! && ||`), string literals and `upper/lower/len`, lists (`[1, 2, 3]`), ranges (`1..10`), indexing (`:items[1]`, `"hello"[1]`, negative = from the end), and `if condition then a else b` conditionals with lazy evaluation. Typographic `× ÷ −` work too. Broken math says why: a return-key hint explains the problem instead of staying silent.
- **Reactive variables** — `:price = 4 * 12` defines a variable; later lines use `price / 2`. Forward references resolve no matter the order (`:a = :b + 1` above `:b = 2` still gets `:a = 3`); `:price =` deletes the variable; self-references and circular definitions stay text and are explained. Edit a definition and every committed dependent recomputes live. Variables hold numbers, `"text"`, `true`/`false`, and lists (`:items = [10, 20, 30]`; read them with `:items[0]` or `len(:items)`). Variable names must start with a letter or underscore and can contain letters, numbers, and underscores. Type `:` (or `$(` + `:`) to autocomplete your note's variables. Note: bare `price = 4 * 12` (without the colon) is just text with math calculation, not a stored variable. Embed dot-commands in expressions using `$()`: `:total = $(.sum 10 20 30)` or `:total = $(.sum)` for whole-note aggregates. A leading `\` types `.timer` literally instead of firing it.
- **Aggregates** — `.sum`, `.avg`, `.count` scan the note's numbers (prose ignored) and rewrite to `.sum = 46`. Recompute as the note changes. Type arguments after the command to aggregate those instead — numbers or an expression: `.sum 10 20 30` → 60, `.sum 1..10` → 55, `.sum :items`, `.sum 2 * 3` → 6. Filter with `where`/`if` (bound to `it`): `.sum where it > 10`, `.count 1..50 if it % 2 == 0`.
- **Dates & units, offline** — return on `2026-08-22` appends its weekday; `days until …` counts down; `12 kg -> lb` converts. Built-in table, no network.
- **Currency & crypto, opt-in** — flip *Settings → Notes → Live currency & crypto conversion* and `100 USD → EUR` converts with live rates; `1 BTC → USD` works too. Off by default so the note never touches the network until you ask. Rates refresh at most once an hour (Coinbase, fiat + crypto).
- **Markdown that knows how to disappear** — Notion-style syntax collapsing: headings, block quotes, fenced code, lists, task lists, tables, bold/italic/inline code/strikethrough, links, bare URLs, `\` escapes. Syntax collapses away from the caret and reappears on its line.
- **Capture** — `.paste` streams clipboard copies into the note until you dismiss it. Drop an image on the pane for on-device OCR (Apple Vision, fully local).
- **A smooth, quiet caret** — glides between positions on a faint, fading spline (like the iPhone's text cursor) instead of teleporting; still the same accessible insertion point underneath.
- **Typing that stays literal** — punctuation is never silently rewritten while you type. URLs with `utm_*`, `fbclid`, `gclid` & friends lose their tracking parameters only when rendered as links.

### Time

- `.timer 5`, `.timer 90s`, `.timer 1h 20m stand up` — countdown chips float in the corner, a sound plays on completion, a notification carries the label (click it to reopen the pane). Unfinished timers survive relaunches. Max 30 days. `.timer cancel all` clears. `.timer list` shows running timers.
- `.pomodoro 25/5/4` — work/break in minutes, up to 12 cycles.
- `.stopwatch soup` — counts up in the corner; `⏹` freezes the reading, `.stopwatch cancel` clears. Keeps counting across relaunches. `.stopwatch list` shows stopwatch readings.
- `.remind in 10 minutes` or `.remind tomorrow at 3pm` — one-shot system notifications, persisted. `.reminder cancel all` clears. `.reminder list` shows upcoming reminders.

### Everything else

- **Autosave** — every keystroke saved atomically to `~/Library/Application Support/Antimatter/notes/notes.json` with a one-generation `.bak`. Legacy `scratchpad.md` files are imported automatically. Type → quit → relaunch → it's still there.
- **Multiple notes** — type `.new` to start a fresh note, or swipe left/right on the pane to switch between them. Deleted notes sit in The Void for 36 hours before they're gone.
- **Export, no network** — `.export notes` sends the note to Apple Notes; `.export obsidian` saves it as a markdown file wherever you point; `.export json` / `.export csv` write the note's text and variables to a file you choose.
- **iCloud sync, optional** — notes are encrypted on-device before syncing; the encryption key rides iCloud Keychain so a second Mac can decrypt what the first uploaded. Both iCloud and iCloud Keychain must be enabled in Settings for multi-device sync. Flip it on in Settings.
- **Deep links** — `antimatter://`, `antimatter://note?text=…`, `antimatter://append?text=…`, `antimatter://command?line=.timer 5` bring up the pane, create/append notes, or run any dot-command from outside the app.
- **Raycast extension** — `raycast-extension/` wraps those deep links: Open Pane, Create Note, and Run Command.

## Dot-commands

| Command | What it does |
|---------|--------------|
| `.timer 5 soup` | Countdown timer with a label (bare number = minutes; also `90s`, `1h 20m`) |
| `.timer cancel all` | Clear running timers |
| `.timer list` | Show running timers and remaining time |
| `.pomodoro 25/5/4` | Work/break cycle timer (minutes, up to 12 cycles) |
| `.stopwatch soup` | Stopwatch that counts up |
| `.stopwatch cancel all` | Clear stopwatches |
| `.stopwatch list` | Show stopwatch readings |
| `.remind in 10 minutes` | One-shot reminder (natural language: "tomorrow at 3pm", "in 10 mins") |
| `.reminder cancel all` | Clear reminders |
| `.reminder list` | Show upcoming reminders |
| `.paste` | Stream clipboard copies into the note |
| `.new` | Create a new, empty note (swipe left/right to switch) |
| `.clear` | Clear the current note |
| `.switch` | Switch to another note (quick switcher menu) |
| `.undo` | Undo the last edit |
| `.redo` | Redo the last undone edit |
| `.sum` / `.total` | Sum the note's numbers, arguments, or a filtered set: `.sum 10 20 30` → 60, `.sum 1..10` → 55, `.sum where it > 10` |
| `.avg` / `.average` | Average the note's numbers (or `.avg 10 20 30`) |
| `.count` | Count the note's numbers (or `.count 10 20 30`, `.count 1..50 if it % 2 == 0`) |
| `.time` | Stamp the current time: `.time` → `.time = 2:31 PM` |
| `.vars` | List this note's `:name = expression` variable definitions |
| `.export notes` | Send the note to Apple Notes |
| `.export obsidian` | Save the note as markdown in your vault |
| `.export json` | Save the note + its variables as JSON |
| `.export csv` | Save the note's variables as CSV |
| `.find` | Open the find bar (also `⌘F`) |
| `.replace find → replace` | Global replace in the note |
| `.hide` | Minimize the pane out of the way |
| `.settings` | Open settings |
| `.debug` | Show diagnostics + event log |
| `.stats` | Show your usage statistics (typed, deleted, notes, version, time with Antimatter) |
| `.exit` / `.quit` | Quit Antimatter |
| `.help` | Full-screen command reference |

Not sure which command does what? Type `.` — a native completion window lists them as you type. Type `:` and it lists your note's variables.

## Keyboard

| Shortcut | Action |
|----------|--------|
| `⌃⌥Space` | Toggle pane (configurable) |
| `Esc` | Hide pane / close reference view |
| `⌘F` / `⌘G` / `⌘⇧G` | Find / next / previous |
| `⌘R` | Reveal notes in Finder |
| `⌘1`–`⌘9` | Jump to a slotted note (creating and pinning one if the slot is empty) |

## Settings

- **Show as** — Dock or Menu Bar.
- **Hot key chord** — pick your own modifiers + key (default `⌃⌥Space`; bare keys and Shift-only are blocked so they can't swallow your typing).
- **Appearance** — System / Light / Dark.
- **Window** — text size 11–26pt, corner radius, max width.
- **Background** — translucent blur, tint, window opacity.
- **Behavior** — float above other apps, hide on Esc.
- **Notes** — currency & crypto conversion, line numbers in code blocks, word count.
- **iCloud Sync** — optional encrypted note sync.

---

## Building

Open `antimatter.xcodeproj` in Xcode and press **⌘R**. No dependencies to fetch.

```sh
xcodebuild -project antimatter.xcodeproj -scheme antimatter build
```

## Tests and releases

Swift Testing, in `antimatterTests/`. Run locally with `tools/run-tests.sh`; GitHub Actions runs the suite on pushes and pull requests. To publish a release, push a version tag such as `v1.0.0`; Actions builds an unsigned macOS app, packages it as a ZIP, and attaches it to a generated GitHub release.

## Project layout

```text
antimatter/
├── App/          entry point, menus, window scene, hotkey wiring, deep links
├── UI/           pane editor (NSTextView), chips, styling, settings
├── Parser/       Markdown, expression evaluator, intent detection
├── Storage/      autosaved notes, The Void, legacy migration
├── Services/     timers, reminders, stopwatches, paste stream, currency,
│                 exports, OCR, iCloud sync, global hot key
└── antimatterTests/   Swift Testing
```

Simple operations are deterministic — timers use a timer, arithmetic uses a parser, dates use a date parser. **No LLM is peeking at your keystrokes.**

### Linting

This repo includes a recommended SwiftLint configuration (`.swiftlint.yml`) and a helper script at `tools/run-swiftlint.sh`. Non-blocking by default; ask to enable strict mode that fails builds/commits on violations.

Enable the git hook with:

```sh
chmod +x .githooks/pre-commit
ln -s ../../.githooks/pre-commit .git/hooks/pre-commit
```

```sh
brew install swiftlint
tools/run-swiftlint.sh
```

## Stack

- **Language:** Swift
- **UI:** SwiftUI + AppKit (`NSTextView` pane)
- **Platform:** macOS
- **Persistence:** JSON for notes, timers, reminders, and cached exchange rates in Application Support; legacy Markdown scratchpads are imported once
- **OCR:** Apple Vision, on-device
- **Tests:** Swift Testing

## Why This Exists

Every notes app either locks you into a system or makes you pick a mode before you type. Antimatter just sits in front of you, takes what's in your head, and does the obvious thing with it.

> **Don't organize your thoughts. Interact with them.**

## License

No.
