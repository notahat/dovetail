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

One file per pipeline source, operator, sink, expression form, and
type, with a worked example for each.

- [Reference index](reference/README.md)

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
