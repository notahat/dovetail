# Query language reference

One file per item: each pipeline source, operator, sink, expression
form, and type. For a narrative introduction see the
[tutorial](../../tutorial/walkthrough.md); every example reads against the
[example tables](../../tutorial/README.md#the-example-tables).

A pipeline starts at a **source**, threads through zero or more
**operators**, and may end at a **sink** that writes to the catalog or a
table. The **expression** and **projection** sublanguages appear inside
operators like `restrict`, `project`, and `join`. The **types** are what
`| type` reports for a value at each rung.

## Sources

A source produces the initial value at the head of the pipeline. The
most common is a bare table name, which reads the whole table. The three
literal forms feed a value straight in without going via a table. The
`catalog` keyword surfaces the database's catalog so the `tables` and
`type` operators can read it.

- [Relation references](relation-reference.md) — read a table by name
- [Scalar literals](scalar-literal.md) — `42`, `"hello"`, `true`
- [Row literals](row-literal.md) — `(id = 1, name = "alice")`
- [Relation literals](relation-literal.md) — `relation (...) { ... }`
- [catalog](catalog.md) — the database's catalog as a value

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

## Sinks

A sink mutates the catalog or a table and reports the result as a
one-row status relation. Every sink is terminal: the parser rejects any
pipe-step after it, and at most one sink may appear per pipeline. The
whole sink runs in one write transaction; any failure aborts the
transaction and the database is unchanged.

- [insert into](insert-into.md) — append rows to a table
- [create table](create-table.md) — add a new table, empty or seeded
- [drop table](drop-table.md) — remove a table and its storage

## Expressions

The expression language is used as a predicate in `restrict` and in
`join`'s `on` clause; the projection language is used in `project`.

- [Literals](literals.md) — `42`, `"hello"`, `true`, `false`
- [Column references](column-references.md) — `id`, `users.id`
- [Comparisons](comparisons.md) — `=`, `<>`, `<`, `<=`, `>`, `>=`
- [Boolean operators](boolean-operators.md) — `and`, `or`, `not`
- [Parentheses](parentheses.md) — grouping to override precedence
- [Precedence and associativity](precedence.md) — how the forms bind
- [Projections](projections.md) — the column list `project` takes

## Types

The types are what `| type` reports for a value at each rung of the
ladder -- a scalar, a row, a relation, or a catalog.

- [Int64](int64.md) — signed 64-bit integer
- [String](string.md) — a sequence of bytes
- [Bool](bool.md) — `true` or `false`
- [Row type](row-type.md) — `(name: type, ...)`
- [Relation type](relation-type.md) — a row type plus refinements
- [Catalog type](catalog-type.md) — table names to relation types
