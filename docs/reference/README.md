# Query language reference

One file per item: each pipeline source, operator, sink, expression
form, and type. For a narrative introduction see the
[tutorial](../tutorial/walkthrough.md); every example reads against the
[example tables](../tutorial/README.md#the-example-tables).

A pipeline starts at a **source**, threads through zero or more
**operators**, and may end at a **sink** that writes to the catalog or a
table. The **expression** and **projection** sublanguages appear inside
operators like `restrict`, `project`, and `join`. The **types** are what
`| type` reports for a value at each rung.

## Operators

An operator transforms its left-hand input and yields a new value. Most
operate on a relation; `tables` consumes a catalog; `type` reaches
across every rung and yields the input's type rather than its value.

- [restrict](restrict.md) — keep rows matching a predicate
- [project](project.md) — keep named columns, in order
- [cross](cross.md) — Cartesian product of two relations
- [join](join.md) — `cross` plus a predicate
- [unqualify](unqualify.md) — strip column qualifiers
- [tables](tables.md) — list a catalog's tables
- [type](type.md) — report the input's type
