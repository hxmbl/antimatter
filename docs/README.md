# Antimatter Docs

Antimatter is a tiny, local, command-aware notes app for macOS. This directory
documents the **Spark** expression language and the rest of the note-processing
engine that lives in `antimatter/Parser/`.

- [Spark, the expression language](spark.md) — numbers, operators, functions,
  lists, ranges, indexing, conditionals, string/boolean values, `$()` embedding.
- [Variables](variables.md) — `:name = expression`, forward references,
  deletion, typed values, how definitions resolve, and completion.
- [Aggregates](aggregates.md) — `.sum` / `.avg` / `.count`, explicit arguments,
  and `where` / `if` filtering.
- [Commands](commands.md) — the `.` command reference and the JSON/CSV exports.
- [Architecture](architecture.md) — the parsing pipeline and where each piece
  lives (no UI coverage).

Each document describes current behavior as implemented. Precedence, error
messages, and quirks are stated as-is; if a feature isn't listed it isn't there.