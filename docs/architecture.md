# Architecture

Where the note-processing engine lives and how a line flows through it. UI
(panes, text views, windows) is out of scope here; everything below is in
`antimatter/Parser/` and `antimatter/Services/`.

## Components

| File | Role |
|------|------|
| `ExpressionEvaluator.swift` | Tokenizer + recursive-descent parser (`SparkValue`, `Token`, `ParseState`) |
| `Variables.swift` | `VariableTable` (scan/resolve) + `Aggregates` (number scanning) |
| `Intents.swift` | `IntentParser`: calculation detection, Spark value/answer formatting |
| `IntentExecution.swift` | Central dispatch: `action(forLine:)`, `preview(forLine:)`, commits, aggregates, `.help`, completion |
| `TimeIntent.swift` · `DateIntent.swift` · `ReminderIntent.swift` · `UnitConverter.swift` | Timers/dates/reminders/unit + currency conversion |
| `ExportCenter.swift` | `.export` destinations (Apple Notes, Obsidian, JSON, CSV) |

## The pipeline

1. **Typing / return key** — a coordinator (not covered here) turns every edit
   and every return press into a call into `IntentExecution` with the full note
   text plus the caret line.
2. **Intent detection** — `action(forLine:)` classifies the line: dot-command,
   calculation, date, unit conversion, or nothing (prose stays text). A leading
   `\` forces "nothing".
3. **Evaluation** — math-shaped lines go to `ExpressionEvaluator`. The
   evaluator never touches the note; it returns a `SparkValue?` (number,
   boolean, string, list) or records a first-error message.
4. **Commit model** — committed answers are `Commit(range, replacement)`
   applied bottom-up. `staleResultCommits(in:)` re-derives every committed
   line whose stored result drifted (edited definitions, changed whole-note
   numbers) so dependents recompute live.
5. **Completion** — `completionCandidates(for:buffer:usageCount:)` returns
   dot-commands (ranked by category, then usage) for `.`-prefixed tokens and
   live variables for `:`-prefixed tokens.

## Evaluate

`SparkValue` is the value union:

```swift
enum SparkValue: Equatable {
    case number(Double)
    case boolean(Bool)
    case string(String)
    case list([SparkValue])
    var isFinite: Bool // recursion into lists; numbers must be finite
}
```

Entry points:

- `evaluate(_:variables:buffer:) -> Double?` — numeric-only, finite. The old
  numeric API; converts its `[String: Double]` table.
- `evaluateValue(_:variables:buffer:) -> SparkValue?` — the real entry; parses
  `expression()` (which adds `if/then/else` over the Boolean chain) and
  requires the whole token stream be consumed.
- `error(in:variables:buffer:) -> String?` — nil when the line evaluates;
  otherwise the first recorded parse error, an unexpected-tail token message,
  or a "too large/undefined" note.
- `looksArithmetic(_:) -> Bool` — gate that keeps prose quiet: at least one
  number plus an operator or paren.
- `dependencies(in:) -> [String]` — variable names in first-mention order,
  excluding function calls, keywords (`if then else true false`), and
  constants (`pi tau e`).

### Grammar (loosest to tightest)

```
expression   → if c then a else b   |  or
or           → and ('||' and)*
and          → equality ('&&' equality)*
equality     → comparison (('==' | '!=') comparison)*
comparison   → range (('<' | '<=' | '>' | '>=') range)*
range        → additive ('..' additive)*        // list expansion
additive     → multiplicative (('+' | '-') multiplicative)*
multiplicative → power (('*' | '/' | '%') power)*  // + lparen juxtaposition = implicit multiply
power        → unary ('^' power)                // right-associative
unary        → ('-' | '+' | '!') unary | primary
primary      → primaryAtom postfix*             // postfix = '[' expression ']' indexing
```

`if/then/else` parses both branches but evaluates only the taken one; the
untaken branch is parsed into a scratch parse state (its runtime errors can't
sink the expression) and the real state advances past it.

## Variable resolution

`VariableTable.resolve` (multi-pass, in `Variables.swift`):

1. Bindings from `:name = expression` definitions and `:name =` deletions.
2. Repeatedly: deletions land immediately at document position; a definition
   lands when its dependencies are all already in the table, so forward
   references and chains settle regardless of order.
3. A definition must evaluate to a finite value (`value.isFinite`), else it
   never lands and is reported via `unresolvedDefinitions` /
   `circularDependencies` for diagnostics.

The table is `[String: SparkValue]`. `resolve` returns the value of RHS with
the note text as `buffer` so `$()` substitutions work inside definitions.

## Aggregates

`AggregateKind` (`sum`/`avg`/`count`) with aliases `.total`, `.average`.
`aggregateNumbers(forLine:in:)`:

1. Split the line into command + args.
2. Explicit args: a single Spark expression evaluated against the note's
   variable table (`.sum 1..10`, `.sum :items`, `.sum 2 * 3`), flattened via
   `ExpressionEvaluator.numbers(from:)`; falls back to `listLiterals`
   (`.sum 10 20 30`). No args → whole-note scan (`Aggregates.numbers`).
3. Optional `where <predicate>` / `if <predicate>` filter, `it` bound to each
   number; an un-evaluable predicate keeps everything.

`Aggregates.numbers(in:)` skips dates, blocks `$()`-containing lines, and
strips `= answer` tails (or definition prefixes) so committed results don't
double-count.

## Exports

`ExportCenter.export(_:text:)` dispatches on `ExportDestination` (`notes`,
`obsidian`, `json`, `csv`). JSON serializes the note text plus each finite
variable's JSON value; CSV writes `name,value,type` rows with RFC 4180
escaping. `IntentParser.format(_: SparkValue)` provides the Spark text form
shared by commits, `.vars`, CSV values, and completion descriptions.

## Tests

`antimatterTests/` (Swift Testing). The parser tests drive the same
public entry points above; there is no injection or test doubles at this
layer.