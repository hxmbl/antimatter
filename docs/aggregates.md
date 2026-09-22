# Aggregates

`.sum`, `.avg`, and `.count` scan the note for numbers and rewrite the line to a
committed result:

```text
12
"42"
2 > 1 true
.sum           →  .sum = 12  (prose, quotes, and computed answers don't count)
```

Aliases: `.total` = `.sum`, `.average` = `.avg`.

## What counts as a number

A line contributes only when it is a valid arithmetic expression:

- Prose (`hello world`), dates (`2026-08-22`), and lines containing `$()` are
  skipped (the recursion guard: `$(.sum)` must not count itself).
- A definition contributes only its right-hand side:
  `:price = 4 * 12` contributes `4` and `12` — not the stored `48`.
- A committed line contributes its expression, not the trailing `= 48`:
  `2 * 3 + 4 = 10` contributes `2, 3, 4`.

## Explicit arguments

Type numbers (or an expression) after the command and it aggregates only those:

| Line | Result numbers |
|------|----------------|
| `.sum 10 20 30` | `[10, 20, 30]` |
| `.sum 1..10` | `1…10` |
| `.sum :items` | the list `:items` holds (resolved from the note) |
| `.sum [1, 2, 3]` | the list literal |
| `.sum 2 * 3` | the expression's result, `[6]` |

Bare `.sum` (no arguments) falls back to the whole-note scan.

## Filtering with `where` / `if`

A trailing `where <predicate>` or `if <predicate>` filters the numbers,
binding `it` to each one:

```text
.sum where it > 10        →  sums only numbers above 10
.count if it % 2 == 0     →  counts the even numbers
.avg 1..5 where it != 3   →  averages 1, 2, 4, 5
```

- A predicate that ignores `it` acts as a constant gate:
  `.sum 1..5 where 0 > 1` → nothing; `.count 1..5 where 1 < 2` → all five.
- Predicates can use the note's variables (`where it > :threshold`).
- A predicate that can't be evaluated (unknown name, malformed) is **ignored**
  and all numbers are kept — quiet failure.
- Explicit arguments combine with the filter: `.avg 1..5 where it != 3`.

## Reactivity

Committed aggregate lines recompute as the note changes (after the same debounce
that recomputes definitions), using the arguments and filter they were committed
with. An aggregate with no numbers leaves the line alone — nothing commits and
no `= nan` is written.