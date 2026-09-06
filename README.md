# Antimatter

A tiny, local, command-aware scratchpad for macOS. Not a notes app — a place to dump whatever's in your head and get something back.

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
- **Reminders** — `.remind in 10 minutes` or `.remind tomorrow at 3pm`. One-shot system notifications, persisted.
- **Dates & units, offline** — return on `2026-08-22` appends its weekday; `days until …` counts down; `12 kg -> lb` converts. Built-in table, no network.
- **Capture** — `.paste` streams clipboard copies into the note until you dismiss it. Drop an image on the pane for on-device OCR (Apple Vision, fully local).
- **Command palette (`⌘P`)** — fuzzy-search every dot-command, pick one, and it lands on its own line at the caret ready for arguments.
- **Autosave** — every keystroke saved atomically to `Application Support/Antimatter/scratchpad.md` with a one-generation `.bak`. Type → quit → relaunch → it's still there. External edits are adopted instead of clobbered.
- **Dot-command autocompletion** — native completion window appears as you type after a `.`.
- **Help & debug** — `.help` opens a full-screen command reference; `.debug` shows the event log.

## Dot-Commands

| Command | What it does |
|---------|--------------|
| `.timer 5 soup` | Countdown timer with a label |
| `.timer cancel all` | Clear running timers |
| `.remind in 10 minutes` | One-shot reminder |
| `.reminder cancel all` | Clear reminders |
| `.paste` | Stream clipboard copies into the note |
| `.sum` / `.total` | Sum the note's numbers |
| `.avg` / `.average` | Average the note's numbers |
| `.count` | Count the note's numbers |
| `.settings` | Open settings |
| `.debug` | Show diagnostics + event log |
| `.help` | Show the command reference |

Not sure which command does what? Type `.` and autocomplete, or `⌘P` and fuzzy-search.

## Settings

- **Hot key chord** — pick your own modifiers + key (default `⌃⌥Space`).
- **Font size** — 11–26pt.
- **Appearance** — System / Light / Dark.

## Keyboard

| Shortcut | Action |
|----------|--------|
| `⌃⌥Space` | Toggle pane (configurable) |
| `Esc` | Hide pane / close reference view |
| `⌘P` | Command palette |
| `⌘F` / `⌘G` / `⌘⇧G` | Find / next / previous |
| `⌘R` | Reveal scratchpad in Finder |

## Architecture

```text
antimatter/
├── App         app entry, window scene, hotkey wiring
├── UI          pane editor (NSTextView), command palette, chips, styling
├── Parser      Markdown, expression evaluator, intent detection
├── Storage     autosaved scratchpad
├── Services    timers, global hot key
└── antimatterTests   Swift Testing
```

Simple operations are deterministic — timers use a timer, arithmetic uses a parser, dates use a date parser. No LLM is peeking at your keystrokes.

## Stack

- **Language:** Swift
- **UI:** SwiftUI + AppKit (`NSTextView` pane)
- **Platform:** macOS
- **Persistence:** plain Markdown file (`scratchpad.md` + `.bak`) and JSON for timers, in Application Support
- **OCR:** Apple Vision, on-device
- **Tests:** Swift Testing

## Building

Open `antimatter.xcodeproj` in Xcode and run. No dependencies to fetch.

## Why This Exists

Every notes app either locks you into a system or makes you pick a mode before you type. Antimatter just sits in front of you, takes what's in your head, and does the obvious thing with it.

> **Don't organize your thoughts. Interact with them.**

## License

No.
