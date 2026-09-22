# Commands

A line starting with `.` is a command. A leading `\` escapes a line so a command
types literally (`.export` becomes text). Hitting return on a command runs it;
the completion panel lists every command as you type the leading `.`.

## Note management

| Command | What it does |
|---------|--------------|
| `.new` | create a new, empty note |
| `.clear` | clear the current note |
| `.switch` | switch to another note |
| `.delete` | delete the current note |
| `.undo` / `.redo` | undo / redo the last edit |
| `.paste` | stream clipboard copies into the note |
| `.export notes` | send the note to Apple Notes |
| `.export obsidian` | save the note as markdown in a vault |
| `.export json` | save note text + variable values as JSON |
| `.export csv` | save variable values as a `name,value,type` CSV table |

## Timers & reminders

| Command | What it does |
|---------|--------------|
| `.timer <duration> [label]` | start a countdown (`5`, `90s`, `1h 20m`) |
| `.timer cancel all` | cancel every running timer |
| `.timer list` | show running timers |
| `.stopwatch [label]` | start a stopwatch that counts up |
| `.stopwatch list` | show stopwatch readings |
| `.remind …` | natural-language reminder ("in 10 minutes", "tomorrow at 3pm") |
| `.reminder cancel all` | cancel every pending reminder |
| `.reminder list` | show upcoming reminders |
| `.pomodoro` | work/break cycle timer (e.g. `.pomodoro 25/5/4`) |

## Math & aggregates

See [aggregates.md](aggregates.md) for arguments and `where`/`if` filters.

| Command | What it does |
|---------|--------------|
| `.sum` / `.total` | sum numbers — `.sum 10 20 30`, `.sum 1..10`, `.sum where it > 10` |
| `.avg` / `.average` | average numbers |
| `.count` | count numbers — `.count 1..50 if it % 2 == 0` |
| `.time` | stamp the current time: `.time` → `.time = 2:31 PM` |
| `.vars` | list this note's `:name = expression` definitions with values |

## Utilities & system

| Command | What it does |
|---------|--------------|
| `.find` | open the find bar |
| `.replace find → replace` | global replace in the note |
| `.settings` | open the settings window |
| `.debug` | show diagnostics + event log |
| `.stats` | show usage statistics |
| `.hide` | minimize the pane out of the way |
| `.exit` / `.quit` | quit Antimatter |
| `.help` | show the full command reference |

## Automatic lines (no command needed)

Pressing return on these commits a result instead of a newline:

| Line | Becomes |
|------|---------|
| `384 * 27` | `384 * 27 = 10368` |
| `2 > 1` | `2 > 1 = true` |
| `"a" + "b"` | `"a" + "b" = "ab"` |
| `:price = 4 * 12` | variable stored, no rewrite |
| `price = 4 * 12` | `price = 4 * 12 = 48` |
| `2026-08-22` | weekday appended |
| `days until 2026-09-01` | countdown appended |
| `12 kg -> lb` | `12 kg -> lb = 26.46` |

## Exports

- **`.export json`** — an NSSavePanel writes `{"text": …, "variables": …}`
  where every variable is its JSON value (numbers, booleans, strings, arrays of
  those). Non-finite numbers are skipped. Empty variable table still exports
  the note text.
- **`.export csv`** — writes a RFC-4180 `name,value,type` table of the note's
  variables (types: `number`, `boolean`, `string`, `list`). Value cells use the
  Spark formatting (strings quoted, lists `[1, 2, 3]`). With no variables the
  export says so instead of opening a save panel.

Both use Spark's formatting for each value's text; neither touches the network.