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
- [Ubiquitous language](internals/ubiquitous-language.md) — shared
  vocabulary, defined once.

## Design and plans — setting direction

The maintainer's working notes. Some are speculative, some superseded;
this corner is still being untangled.

- [Design notes](design/) — the type system, IR types, the ladder
  framing, and the DML/DDL surface designs.
- [Slice plans](plans/) — numbered, one per slice of the build.
