# Variables

A variable is `:name = expression` in a note. Once defined, `:name` anywhere in
an expression reads its value, and dependent lines update when the definition
changes.

```text
:price = 4 * 12        →  stores 48
:total = :price * 2    →  stores 96
:price = 10            →  redefines; :total still shows 96 from before
```

## Names

- Must start with a letter or underscore; then letters, digits, and underscores.
- Matching is case-insensitive: `:Price` and `:price` are the same variable.
- A bare `price = 4 * 12` (no colon) is **not** a stored variable — it's an
  ordinary line whose right-hand side still computes. The colon is required.

## Typed values

Variables hold any Spark value, not just numbers:

```text
:flag = 2 > 1          →  true
:msg = "hi"            →  "hi"
:items = [10, 20, 30]  →  [10, 20, 30]
```

Read them in expressions: `:items[1]` → 20, `len(:items)` → 3,
`.sum :items` → 60. Non-finite numbers (e.g. `:x = 1 / 0`, `:x = 99999^99`)
never store — the definition stays text.

## Resolution

Definitions are gathered in document order into a table, then resolved in
multiple passes:

- **Later definitions win** — the last `:name = ...` before the reading point
  is the active value.
- **Forward references resolve** — `:a = :b + 1` before `:b = 2` still yields
  `:a = 3`, because a definition lands once its dependencies are in the table.
- **Deletion** — `:name =` (nothing after the equals) removes the variable
  from that line onward. `:price = 8` earlier and `:price =` later leaves
  `:price` undefined where it is read.

## What doesn't resolve

Anything that can't be resolved stays as text and says so (`.vars` or the
return-key hint):

- **Self-reference** — `:a = :a + 1` → "`:a` can't be defined from itself".
- **Undefined dependency** — `:a = :b + 1` with no `:b` → "':b' isn't defined
  yet".
- **Circular definitions** — `:a = :b`, `:b = :c`, `:c = :a` are detected as a
  cycle.

Reserved names that are *not* variables: `true`, `false`, `if`, `then`,
`else`, `pi`, `tau`, `e`, and the built-in function names.

## Definitions in expressions and completion

- Type `:` (or `$(` then `:`) and the completion panel lists the note's live
  variables as `:name` with their current value; accepting inserts `:name `.
- `.vars` opens a reference showing every definition and its value, plus a
  count; unevaluable ones are listed with a reason.
- Definitions don't count their stored result when `.sum` scans the note
  (the committed `=` answer is stripped), and a definition's right-hand side
  *is* a number source: `.sum` counts the numbers inside `:price = 4 * 12`.

## Reactivity

Editing a live definition re-evaluates it in place of the whole note and
recomputes every *committed* dependent line (e.g. `:total = :price * 2 = 96`)
after a short debounce. Committed aggregates recompute too — with the same
arguments/filter they were committed with.