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

Pressing **⏎** on any of those lines commits the result. Typing `.help` shows every command in a full-screen reference.

---

## Quick start

1. Build & run the app (see [Building](#building)).
2. Hit `⌃⌥Space` anywhere to summon the pane.
3. Type `.help` and press **⏎** — that's the whole onboarding.

No setup, no account, no data leaves your Mac until you ask it to.

---

## What it does

- **Instant math** — type `384 * 27 =` for the answer as you type, or press return on a pure-arithmetic line to rewrite it to `384 * 27 = 10368`. Operators: `+ - * / % ^`, parens, `sqrt abs round min max`, and the typographic `× ÷ −`.
- **Reactive variables** — `price = 4 * 12` defines a variable; later lines use `price / 2`. Edit a definition and every committed dependent recomputes live.
- **Aggregates** — `.sum`, `.avg`, `.count` scan the note's numbers (prose ignored) and rewrite to `.sum = 46`. Recompute as the note changes.
- **Dates & units, offline** — return on `2026-08-22` appends its weekday; `days until …` counts down; `12 kg -> lb` converts. Built-in table, no network.
- **Currency & crypto, opt-in** — flip *Settings → Notes → Live currency & crypto conversion* and `100 USD → EUR` converts with live rates; `1 BTC → USD` works too. Off by default so the note never touches the network until you ask. Rates refresh at most once an hour (Coinbase, fiat + crypto).
- **Markdown that knows how to disappear** — Notion-style syntax collapsing: headings, block quotes, fenced code, lists, task lists, tables, bold/italic/inline code/strikethrough, links, bare URLs, `\` escapes. Syntax collapses away from the caret and reappears on its line.
- **Capture** — `.paste` streams clipboard copies into the note until you dismiss it. Drop an image on the pane for on-device OCR (Apple Vision, fully local).
- **A smooth, quiet caret** — glides between positions on a faint, fading spline (like the iPhone's text cursor) instead of teleporting; still the same accessible insertion point underneath.
- **Typing that stays literal** — punctuation is never silently rewritten while you type. URLs with `utm_*`, `fbclid`, `gclid` & friends lose their tracking parameters only when rendered as links.

### Time

- `.timer 5`, `.timer 90s`, `.timer 1h 20m stand up` — countdown chips float in the corner, a sound plays on completion, a notification carries the label (click it to reopen the pane). Unfinished timers survive relaunches. Max 30 days. `.timer cancel all` clears.
- `.pomodoro 25/5/4` — work/break in minutes, up to 12 cycles.
- `.stopwatch soup` — counts up in the corner; `⏹` freezes the reading, `.stopwatch cancel` clears. Keeps counting across relaunches.
- `.remind in 10 minutes` or `.remind tomorrow at 3pm` — one-shot system notifications, persisted. `.reminder cancel all` clears.

### Everything else

- **Autosave** — every keystroke saved atomically to `~/Library/Application Support/Antimatter/notes/notes.json` with a one-generation `.bak`. Legacy `scratchpad.md` files are imported automatically. Type → quit → relaunch → it's still there.
- **Multiple notes** — type `.new` to start a fresh note, or swipe left/right on the pane to switch between them. Deleted notes sit in The Void for 36 hours before they're gone.
- **Export, no network** — `.export notes` sends the note to Apple Notes; `.export obsidian` saves it as a markdown file wherever you point.
- **iCloud sync, optional** — notes are encrypted on-device before syncing. Flip it on in Settings.
- **Deep links** — `antimatter://`, `antimatter://note?text=…`, `antimatter://append?text=…`, `antimatter://command?line=.timer 5` bring up the pane, create/append notes, or run any dot-command from outside the app.
- **Raycast extension** — `raycast-extension/` wraps those deep links: Open Pane, Create Note, and Run Command.

## Dot-commands

| Command | What it does |
|---------|--------------|
| `.timer 5 soup` | Countdown timer with a label (bare number = minutes; also `90s`, `1h 20m`) |
| `.timer cancel all` | Clear running timers |
| `.pomodoro 25/5/4` | Work/break cycle timer (minutes, up to 12 cycles) |
| `.stopwatch soup` | Stopwatch that counts up |
| `.stopwatch cancel all` | Clear stopwatches |
| `.remind in 10 minutes` | One-shot reminder (natural language: "tomorrow at 3pm", "in 10 mins") |
| `.reminder cancel all` | Clear reminders |
| `.paste` | Stream clipboard copies into the note |
| `.new` | Create a new, empty note (swipe left/right to switch) |
| `.sum` / `.total` | Sum the note's numbers |
| `.avg` / `.average` | Average the note's numbers |
| `.count` | Count the note's numbers |
| `.export notes` | Send the note to Apple Notes |
| `.export obsidian` | Save the note as markdown in your vault |
| `.find` | Open the find bar (also `⌘F`) |
| `.replace find → replace` | Global replace in the note |
| `.settings` | Open settings |
| `.debug` | Show diagnostics + event log |
| `.help` | Full-screen command reference |

Not sure which command does what? Type `.` — a native completion window lists them as you type.

## Keyboard

| Shortcut | Action |
|----------|--------|
| `⌃⌥Space` | Toggle pane (configurable) |
| `Esc` | Hide pane / close reference view |
| `⌘F` / `⌘G` / `⌘⇧G` | Find / next / previous |
| `⌘R` | Reveal notes in Finder |

## Settings

- **Show as** — Dock, Menu Bar, or Dropdown (Spotlight-style, top of the screen).
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

## Tests

Swift Testing, in `antimatterTests/`:

```sh
xcodebuild -project antimatter.xcodeproj -scheme antimatter test
```

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

## Disclaimer

May not compile. No em dashes used.

## Why This Exists

Every notes app either locks you into a system or makes you pick a mode before you type. Antimatter just sits in front of you, takes what's in your head, and does the obvious thing with it.

> **Don't organize your thoughts. Interact with them.**

## License

No.