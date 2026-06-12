# Dovetail documentation

Organised by audience -- start in the section that matches why you're
here.

## Tutorial — new to Dovetail

Learn the query language from the ground up.

- [Overview](tutorial/README.md) — running the REPL and the example
  tables every example reads against.
- [Walkthrough](tutorial/walkthrough.md) — one query grown operator by
  operator.

## Reference — looking something up

One file per item, with a worked example for each. Dovetail has two
query surfaces, each with its own reference:

- [Relational-algebra reference](reference/ra/README.md) — the
  pipeline surface (`users | restrict … | project …`): sources,
  operators, sinks, expression forms, and types.
- [SQL reference](reference/sql/README.md) — the
  `SELECT … FROM … WHERE …` surface over a single table.

## Internals — understanding the implementation

For coders reading the source.

- [Architecture](internals/architecture.md) — how the pieces fit
  together: the query pipeline, the storage stack, the sub-library
  layout.
- [Executor](internals/executor.md) — why evaluation is in
  continuation-passing style, how the per-operator modules compose,
  and the join materialisation tradeoff.
- [Ubiquitous language](internals/ubiquitous-language.md) — shared
  vocabulary, defined once.

## Design and plans — setting direction

The maintainer's design notes and build plans. Everything under
`internals/` above describes the code as it is; docs here may not.
Each design and archive doc opens with a **Status** banner —
as-built, proposal, superseded, or historical record — saying how
far to trust it.

- [Design notes](design/) — the type system, the type ladder, and
  the IR types.
- [Slice plans](plans/) — numbered, one per slice of the build;
  frozen history once a slice closes.
- [Archive](archive/) — closed design discussions and reviews.
