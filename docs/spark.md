# Spark — the expression language

Spark is the math/text language you type into a note. Any line that parses as a
Spark expression evaluates; plain prose stays text. A line ending in `=` (or
pressed with ⏎) is rewritten in place with its committed result, e.g.
`384 * 27 = 10368`.

Evaluating an expression yields one of four values:

| Value | Examples | Renders as |
|-------|----------|------------|
| number | `3`, `2e3`, `3.14`, `pi` | `3`, `2000`, `3.14`, `3.14159…` |
| boolean | `true`, `2 > 1` | `true` / `false` |
| string | `"hi"`, `"a" + "b"` | `"hi"`, `"ab"` (quoted) |
| list | `[1, 2, 3]`, `1..5` | `[1, 2, 3]` |

## Literals

- **Numbers** — `42`, `3.14`, scientific notation `1e6`, `2E-3`, `1e-2`. A
  trailing lone `e` (`1e`) is not a number.
- **Strings** — double- or single-quoted, backslash-escaped
  (`"say \"hi\""`). `+` concatenates strings.
- **Booleans** — `true`, `false`.
- **Lists** — `[1, 2, 3]`, nested `[[1], [2, 3]]`, empty `[]`. Numbers,
  strings, booleans, and nested lists are all valid elements.
- **Ranges** — `1..5` makes `[1, 2, 3, 4, 5]`; `-2..0` works. Ranges must go
  *upward* (`5..1` doesn't evaluate), bounds must be whole numbers
  (`1.5..3` doesn't evaluate), and the range cap is 100,000 entries.
- **Constants** — `pi`, `tau` (= 2·π), `e`.

## Operators (loosest to tightest)

| Level | Operators | Notes |
|-------|-----------|-------|
| conditional | `if c then a else b` | lazy; only the taken branch matters |
| or | `a || b` | booleans |
| and | `a && b` | booleans |
| equality | `==`, `!=` | numbers, strings, or booleans of the same kind |
| comparison | `<`, `<=`, `>`, `>=` | numbers only |
| range | `a..b` | expands to a list, level above addition |
| additive | `+`, `-` | `+` also concatenates strings |
| multiplicative | `*`, `/`, `%` | `%` is the truncated remainder |
| power | `^` | right-associative, `pow()` |
| unary | `-`, `+`, `!` | `!` needs a boolean |
| implicit multiply | `2(3 + 4)`, `(2)(3)` | paren juxtaposition only; `sqrt(9)2` isn't supported |

Precedence example: `1..3 + 1` parses as `1..(3 + 1)` → `[1, 2, 3, 4]`.
To be safe, parenthesize: `(1..3) + 1` is an error (you can't add to a list).

## Variables

`:name = expression` stores a value; `:name` reads it back. See
[variables.md](variables.md).

## Functions

**Aggregates over numbers** — `min`, `max` also flatten lists, so
`min([3, 1], 2)` → 1 and `max(1..5)` → 5.

- `sqrt(x)`, `abs(x)`, `round(x)` (half away from zero), `floor(x)`, `ceil(x)`,
  `sign(x)` (1 / 0 / −1)
- `sin(x)`, `cos(x)`, `tan(x)`, `asin(x)`, `acos(x)`, `atan(x)` (radians)
- `ln(x)` (natural log), `log(x)` (base-10), `exp(x)`
- `len(x)` — length of a string *or* a list
- `upper(s)`, `lower(s)` — string casing

`ln` / `log` of a non-positive number yield an undefined (non-finite) result,
which nothing commits.

## Indexing

`expr[i]` reads one item of a list or one character of a string. Indexes are
whole numbers; a negative index counts from the end (`:items[-1]` is the last
item). Out-of-range or non-numeric indexes quietly fail (`[1, 2][5]`, `[1, 2]["a"]`).
Ranges are lists, so index a range with parens: `(1..5)[2]` → 3.

## Conditionals

`if <condition> then <a> else <b>` — the condition must be a boolean. Evaluation
is **lazy**: only the branch that runs is evaluated, so
`if x > 0 then 100 / x else 0` never divides by zero when x == 0, and an error
in the untaken branch is ignored. Branches can be any value and can nest or
contain full expressions.

## `$()` embedding

`$(expression)` or `$(.command)` evaluates inside an expression:

- `:total = $(.sum 10 20 30)` — embeds a dot-command result (aggregates and
  `.time`; everything else is an unknown-name failure and stays text)
- `$(if false then 1 else 4)` → 4, `$(:x + 1)` → 3 with `:x = 2`

## Errors and quietness

- Malformed math gives a return-key hint and a footer preview instead of
  rewriting your line or printing nonsense (non-destructive).
- Parser failures return `nil`; the *first* error wins (deepest message).
- Lines that don't look arithmetic (`hello world`, `Hey!`) never get a hint.
- A leading `\` escapes the line: `\ .timer` types the command literally, and
  nothing is auto-committed or completed.
- `2026-08-22` shapes are treated as dates and never auto-calculate.

## Formatting committed answers

Whole numbers render without a decimal (`2`, `120`); other numbers use up to 12
significant figures. Strings render quoted (`"ab"`), booleans as `true` / `false`,
lists as `[1, 2, 3]`.