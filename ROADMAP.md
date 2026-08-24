# Roadmap

Ordered by what improves **Open → type → get something useful → leave** most per unit of work. Each milestone is shippable on its own. Anything that fights the [Non-Goals](README.md#non-goals) stays out no matter how good the idea sounds.

Positioning in one line: Antinote et al. proved the temp-notes niche; Antimatter's unfair advantages are the **syntax-collapsing Markdown editor** and **your data is one plain `.md` file you own** — every milestone below strengthens one of those two or deepens the core loop. No feature-chasing.

## M0 — Hardening (unglamorous, first)

- [x] **Test the glue layer.** Extract intent execution (caret line range, calc rewrite, deferred commit) out of `PaneEditor.Coordinator` into testable functions. It is currently the only logic with zero tests and the most reentrancy subtlety.
- [x] **Remember window frame** across relaunches (`setFrameAutosaveName`).
- [x] **Stop failing silently.** Disk writes are all `try?`; on failure show a transient inline hint and keep a `.bak` of the last good save before overwriting.
- [x] **README matches reality:** flat files, not SQLite; document Markdown rendering, tasks, tables, links (implemented but unwritten).
- [x] **External-edit safety:** watch `scratchpad.md`; if the user edits it in another editor, reload instead of clobbering on next flush.

## M1 — Math worth evangelizing

The single biggest functional gap. All deterministic, all local.

- [x] **Reactive variables.** `price = 4 * 12` defines; later lines use `price / 2`. Editing a definition recomputes dependents live. Turns the scratchpad into a small spreadsheet without becoming one.
- [x] **Aggregate intents.** `sum`, `avg`, `count` — operate on the numbers in the note, ignoring prose.
- [x] **A few real functions.** `sqrt`, `round`, `min`, `max`, `abs` — nothing more until something is genuinely missing.

## M2 — Dates & units

Dates are already parsed-but-rejected; flip that guard into a feature.

- [x] **Date intents.** `2026-08-22` quietly shows its weekday; `days until 2026-09-01 = 8`.
- [x] **Offline unit conversion.** `12 kg → lb`, `3 mi → km` from a built-in table. No network.
- [ ] **Currency (opt-in network).** Deliberately deferred: M2's offline pieces landed first; rates-on-demand stays out until it can respect the no-network default.

## M3 — Capture

Getting content *into* the pane without switching apps.

- [x] **`paste` intent.** Return on `paste` streams subsequent clipboard copies into the note as plain text until dismissed.
- [x] **Screenshot → text.** Drop an image onto the pane; Vision framework OCR, on-device, never uploaded.

## M4 — Timers that reach you

- [x] **System notifications on completion**, not just a sound — the pane is usually hidden when a timer ends.
- [x] Named timers in the notification, click to reopen the pane.
- [ ] Stopwatch / pomodoro variants — deferred; they did not stay this small.

## M5 — Comfort

- [x] **Runtime settings:** hotkey chord picker, font size, theme — replacing "edit `PaneStyle.swift`".
- [x] **Find bar** (`⌘F`) — nearly free from `NSTextView.performFindPanelAction`.
- [x] **Reveal in Finder** — surface the ownership story: the scratchpad is a file.
- [x] Menu-bar/accessory mode toggle (Dock icon off) for people who want it invisible.

## Deliberately not planned

Sync, multi-note management UI, plugins/extensions, accounts, AI chat, Electron. See [Non-Goals](README.md#non-goals). "Progressive intelligence" (ML interpretation of ambiguous input) is still allowed by the philosophy but has no milestone until deterministic rules demonstrably stop being sufficient.
