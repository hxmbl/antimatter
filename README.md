# Antimatter

> A tiny, local, command-aware scratchpad for macOS.

Antimatter is **not a traditional notes app**.

It is a place to quickly put whatever is currently in your head — text, calculations, timers, temporary information, commands — and let the app figure out what to do with it.

# Antimatter stack — straight up
Language: Swift
UI: SwiftUI
Platform: macOS initially
Persistence: flat files you own — `scratchpad.md` (+ a one-generation `.bak`) and `timers.json` in Application Support/Antimatter
Concurrency: Swift Concurrency (async/await, Task, actors where useful)
Parsing: Swift, deterministic parser first
Timers: Swift Concurrency / Foundation
Global hotkey: macOS Carbon/AppKit API or a tiny library
Calculations: your own parser initially / Foundation where appropriate
ML later: Core ML
Build: Xcode + Swift Package Manager
Tests: XCTest / Swift Testing


## Philosophy

Antimatter should feel like an extension of the user's thought process, not another productivity system.

The user should be able to:

```text
.timer 5
```

and get a five-minute timer.

Or:

```text
384 * 27
```

and get the result.

Or simply:

```text
remember to fix Relay tomorrow
```

and have it remain ordinary text.

**Typing should be the interface.**

Do not force the user to choose a mode before entering something.

Do not turn every piece of text into a "note".

Do not add complexity merely because the app can support it.

## Core Principles

### Instant

Opening Antimatter should feel instantaneous.

Typing must never feel delayed because of parsing, persistence, networking, or machine learning.

### Local

Antimatter should work without an account or internet connection.

User data belongs to the user.

Prefer local storage and system APIs.

### Lightweight

Keep CPU, memory, battery, and disk usage low.

Do not introduce heavyweight dependencies unless there is a compelling reason.

### Deterministic First

Simple operations should use deterministic code.

For example:

* timers → timer implementation
* arithmetic → calculator/parser
* dates → date parser
* text → plain text

Machine learning should only be used where deterministic rules stop being sufficient.

### Progressive Intelligence

Antimatter may become more intelligent over time, but intelligence must remain unobtrusive.

A model should help interpret ambiguous input, not control the application.

Prefer:

```text
input
 ↓
deterministic parser
 ↓
known intent?
 ├── yes → execute
 └── no  → optional intelligent interpretation
```

rather than sending every keystroke through an LLM.

## Initial Feature Set

The first version should remain deliberately small.

### Required

* macOS native application
* Swift / SwiftUI
* global keyboard shortcut
* lightweight floating window
* text input
* local persistence
* automatic saving
* command detection
* timers
* basic calculations
* instant dismissal/reopening

### Example Inputs

```text
.timer 5
.timer 5 laundry
25 * 48
2026-08-22
hello world
TODO: investigate this
```

Dot-commands (`.timer`, `.sum`, `.paste`) must be typed deliberately.
Math happens automatically — only recognised commands produce special
behaviour; everything else remains valid text.

Only recognized commands should produce special behaviour.

Everything else should remain valid text.

## Architecture

Keep the architecture modular without prematurely building a framework.

The current structure:

```text
Antimatter
├── App        app entry, window scene, hotkey wiring
├── UI         pane editor (NSTextView), chips, styling
├── Parser     Markdown, expression evaluator, intent detection
├── Storage    autosaved scratchpad
├── Services   timers, global hot key
└── Tests      Swift Testing
```

The exact structure may change as the project develops.

Avoid creating abstractions until they solve an actual problem.

## Implemented so far

* plain-text Markdown editing with Notion-style syntax collapsing
* Markdown rendering while the source stays untouched: ATX and setext headings, block quotes, fenced code blocks (with language tag), bullet/ordered/task lists, GFM tables, thematic breaks, bold/italic/inline-code/strikethrough spans, links, images (as links over alt text), autolinks and bare URLs, `\` escapes — syntax collapses away from the caret and reappears on its line
* autosave to `Application Support/Antimatter/scratchpad.md` — type → quit → relaunch → the text is still there; saves are atomic with a one-generation `.bak`, a failed write shows a transient hint, and edits made in another editor are adopted instead of clobbered
* floating pane: stays above other windows, hides on Escape or ⌃⌥Space, reopens with the same chord; position and size survive relaunches
* calculations: type `384 * 27 =` for an instant answer, or press return on a pure-arithmetic line to rewrite it to `384 * 27 = 10368` (date-shaped lines like `2026-08-22` are left alone)
* dot-commands are explicit — `.timer 5`, `.timer 90s`, `.timer 1h 20m stand up` — countdown chips float in the corner, a sound plays on completion, a system notification carries the name (click it to reopen the pane), and unfinished timers survive relaunches
* reactive math: `price = 4 * 12` defines a variable, later lines use `price / 2`; editing a definition recomputes committed dependents live. Functions `sqrt abs round min max`; `.sum` `.avg` `.count` aggregate over the note's numbers (prose ignored) and recompute when the note changes
* dates & units offline: return on `2026-08-22` shows its weekday, `days until 2026-09-01` counts down, `12 kg → lb` converts (built-in table, no network)
* capture: return on `.paste` streams clipboard copies into the note until dismissed; drop an image on the pane for on-device OCR text capture
* comfort: runtime settings (hot key chord picker, font size, light/dark theme, Dock-icon-off menu-bar mode), system find bar (`⌘F`), Reveal Scratchpad in Finder (`⌘R`)

## Command System

Commands should be extensible.

Conceptually:

```text
Input
  ↓
Parser
  ↓
Intent
  ↓
Handler
  ↓
Result
```

For example:

```text
".timer 5"
      ↓
TimerIntent(duration: 300)
      ↓
TimerHandler
      ↓
5:00 countdown
```

A command should not need to know about the UI that invoked it.

## Future Possibilities

These are deliberately **not requirements for the first version**:

* richer natural-language commands
* clipboard operations
* unit conversion
* date calculations
* Markdown
* plugins/extensions
* Shortcuts integration
* Raycast integration
* cross-platform clients
* lightweight local ML
* learned personal command interpretation
* synchronization

Build the useful core before building these.

## Non-Goals

Antimatter is not intended to become:

* a Notion replacement
* a full knowledge-management system
* a project-management application
* a cloud service
* an AI chatbot
* an Electron application
* a giant plugin framework

If a feature requires significant complexity, ask whether it improves the fundamental interaction:

> **Open → type → get something useful → leave.**

If it does not, it probably does not belong in the core application.

## Development

Build and test the smallest useful behaviour first.

The first meaningful milestone is:

```text
Open Antimatter
      ↓
Type text
      ↓
Close Antimatter
      ↓
Open it again
      ↓
Text is still there
```

Then:

```text
.timer 5
```

should actually create a timer.

Then:

```text
384 * 27
```

should actually calculate.

Everything else can come later.

## Design

Antimatter should feel:

* minimal
* fast
* native
* quiet
* slightly unconventional
* responsive
* useful without explanation

Avoid unnecessary UI.

The interface should disappear into the user's workflow rather than becoming another place they have to manage.

## The Name

**Antimatter** is intentionally contrasted with conventional "matter" — and with conventional notes applications.

Traditional notes encourage storing and organizing information.

Antimatter is about **transforming thoughts into actions**.

> **Don't organize your thoughts. Interact with them.**
