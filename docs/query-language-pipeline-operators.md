# Query language: pipeline operators reference

Part of the [query-language guide](query-language.md). One
subsection per pipeline operator: syntax, semantics, and a single
worked example against the example tables. For a narrative
introduction,
see the [tutorial](query-language-tutorial.md); for the expression
and projection sublanguages that appear inside `restrict`,
`project`, and the `on` clause of `join`, see the
[expression and projection reference](query-language-expressions.md).

A pipeline starts with one of four source forms: a relation
reference (a bare table name) or a literal at any of the scalar,
row, or relation rungs. The literal forms let you feed a value
into the pipeline without first putting it in a table -- useful
for trying out operators, asking `| type` what a value's type is,
and (for relation literals) seeding tables through `insert into`.

## Relation references

**Syntax:** `<table-name>`

A bare identifier reads every row of the named table in primary-
key order. The output schema is the table's schema, with each
column's qualifier set to the table name -- so a later operator
can disambiguate columns that share a name across tables.

```
> users
relation (users.id: int64, users.name: string, users.email: string, users.active: bool, primary key (id)) {
  (users.id = 1, users.name = "Alice", users.email = "alice@example.com", users.active = true),
  (users.id = 2, users.name = "Bob", users.email = "bob@example.com", users.active = false),
  (users.id = 3, users.name = "Carol", users.email = "carol@example.com", users.active = true),
  (users.id = 4, users.name = "Dave", users.email = "dave@example.com", users.active = true),
  (users.id = 5, users.name = "Eve", users.email = "eve@example.com", users.active = false)
}
```

## Scalar literals

**Syntax:** `<int64-literal>` | `"<string-literal>"` | `true` | `false`

A bare scalar at the head of a pipeline yields that scalar value.
The supported forms are the same three kinds the
[expression reference](query-language-expressions.md#literals)
describes: signed decimal integers, double-quoted strings (with
`\"` and `\\` escapes), and the keywords `true` and `false`. The
only operator that consumes a scalar is `type`, which yields the
scalar's kind.

```
> 42
42
> "hello"
"hello"
> true
true
> 42 | type
int64
```

## Row literals

**Syntax:** `(<name> = <scalar>, ...)`

A parenthesised, comma-separated list of `<name> = <value>`
bindings yields a single row whose fields are those bindings, in
written order. The empty form `()` yields the empty row. Field
names must be unique within the literal; values are scalar
literals (no expressions or column references at the row-literal
level). The only operator that consumes a row is `type`, which
yields the row's kind.

```
> (id = 1, name = "alice")
(id = 1, name = "alice")
> (id = 1, name = "alice") | type
(id: int64, name: string)
> ()
()
```

## Relation literals

**Syntax:** `relation (<row-type> [, <refinement>...]) { <row-literal>, ... }`

A `relation` keyword followed by a parenthesised relation type and
a brace-delimited body of row literals yields a relation of that
type. The head's parenthesised list is a row type (`<name>: <kind>`
declarations) optionally interleaved with refinements (today just
`primary key (...)`); the body is zero or more row literals,
comma-separated, with a permitted trailing comma. Every row's
fields must be a permutation of the declared row type's fields,
and each value must match its field's kind. The empty body is
allowed and produces a header-only table.

Relation literals are the form `insert into` accepts as its
upstream; see [`insert into`](#insert-into) below.

```
> relation (id: int64, name: string) { (id = 1, name = "alice"), (id = 2, name = "bob") }
relation (id: int64, name: string) {
  (id = 1, name = "alice"),
  (id = 2, name = "bob")
}
> relation (id: int64, name: string) {} | type
(id: int64, name: string)
```

## restrict

**Syntax:** `<input> | restrict <predicate>`

Keeps rows of `<input>` for which `<predicate>` evaluates to true.
The predicate is any expression that resolves to a Bool; see the
[expression reference](query-language-expressions.md) for the full
grammar. The short version: literals, column references,
comparisons (`=`, `<>`, `<`, `<=`, `>`, `>=`), and the boolean
operators `and`, `or`, `not`. Output schema and column qualifiers
are `<input>`'s, unchanged.

```
> users | restrict id = 1
relation (users.id: int64, users.name: string, users.email: string, users.active: bool, primary key (id)) {
  (users.id = 1, users.name = "Alice", users.email = "alice@example.com", users.active = true)
}
```

## project

**Syntax:** `<input> | project <column-list>`

Keeps only the named columns from `<input>`, in the order listed.
Each entry is either a bare name (`name`) or qualified
(`users.name`); see the
[projection reference](query-language-expressions.md#projections)
for the precise rules. Bare names must resolve unambiguously
against `<input>`'s schema, duplicates in the column list are
rejected, and each retained column keeps its qualifier from
`<input>`.

```
> users | project name, email
relation (users.name: string, users.email: string) {
  (users.name = "Alice", users.email = "alice@example.com"),
  (users.name = "Bob", users.email = "bob@example.com"),
  (users.name = "Carol", users.email = "carol@example.com"),
  (users.name = "Dave", users.email = "dave@example.com"),
  (users.name = "Eve", users.email = "eve@example.com")
}
```

## cross

**Syntax:** `<input> | cross <relation>`

Emits the Cartesian product of `<input>` and `<relation>`: every
row of `<input>` paired with every row of `<relation>`. The output
schema is `<input>`'s fields followed by `<relation>`'s fields,
each retaining the qualifier it arrived with. `<relation>` must
be a relation reference; chaining a sub-pipeline on the right
isn't supported.

`cross` is predicate-free and so produces row counts that are the
product of its inputs' counts. The example below pairs Dave (one
row) with all six orders -- even though Dave hasn't actually
placed any of them, since `cross` doesn't know about foreign keys.

```
> users | restrict id = 4 | cross orders
relation (users.id: int64, users.name: string, users.email: string, users.active: bool, orders.id: int64, orders.user_id: int64, orders.description: string, orders.amount: int64) {
  (users.id = 4, users.name = "Dave", users.email = "dave@example.com", users.active = true, orders.id = 1, orders.user_id = 1, orders.description = "Coffee", orders.amount = 5),
  (users.id = 4, users.name = "Dave", users.email = "dave@example.com", users.active = true, orders.id = 2, orders.user_id = 1, orders.description = "Bagel", orders.amount = 4),
  (users.id = 4, users.name = "Dave", users.email = "dave@example.com", users.active = true, orders.id = 3, orders.user_id = 2, orders.description = "Tea", orders.amount = 3),
  (users.id = 4, users.name = "Dave", users.email = "dave@example.com", users.active = true, orders.id = 4, orders.user_id = 3, orders.description = "Sandwich", orders.amount = 8),
  (users.id = 4, users.name = "Dave", users.email = "dave@example.com", users.active = true, orders.id = 5, orders.user_id = 3, orders.description = "Cake", orders.amount = 6),
  (users.id = 4, users.name = "Dave", users.email = "dave@example.com", users.active = true, orders.id = 6, orders.user_id = 5, orders.description = "Cookie", orders.amount = 2)
}
```

## join

**Syntax:** `<input> | join <relation> on <predicate>`

Combined schema is the same as `cross` -- left fields followed by
right fields, qualifiers preserved -- but the output keeps only
rows for which `<predicate>` evaluates to true. Conceptually it's
`<input> | cross <relation> | restrict <predicate>`; in practice
the engine may pick a more efficient plan when the predicate is
an equality against a primary key.

The predicate language is the same one `restrict` uses, and
qualified column references (`users.id`, `orders.user_id`) are
how you name which side of the join each column comes from.

```
> users | restrict id = 1 | join orders on users.id = orders.user_id
relation (users.id: int64, users.name: string, users.email: string, users.active: bool, orders.id: int64, orders.user_id: int64, orders.description: string, orders.amount: int64) {
  (users.id = 1, users.name = "Alice", users.email = "alice@example.com", users.active = true, orders.id = 1, orders.user_id = 1, orders.description = "Coffee", orders.amount = 5),
  (users.id = 1, users.name = "Alice", users.email = "alice@example.com", users.active = true, orders.id = 2, orders.user_id = 1, orders.description = "Bagel", orders.amount = 4)
}
```

## type

**Syntax:** `<input> | type`

Yields `<input>`'s relation type rather than its rows -- no cursors
open, no rows are pulled. The output is a one-line rendering of the
type in the same surface syntax used by `:create table`: a
parenthesised, comma-separated list of `<name>: <kind>` field
declarations, followed by any refinements (today just
`primary key (...)`).

`type` only applies at the relation rung; piping its output back
through `type` (`<input> | type | type`) is rejected -- the second
`type`'s input is already a type, not a relation.

This is the replacement for the retired `:describe` statement; see
[`<name> | type` in the data-definition reference](query-language-data-definition.md)
for the catalog-inspection use.

```
> users | type
(users.id: int64, users.name: string, users.email: string, users.active: bool, primary key (id))
```

## insert into

**Syntax:** `<input> | insert into <table-name>`

Writes every row of `<input>` to `<table-name>` and returns a one-row
relation `(insert_count: int64)` reporting how many rows were
written. `<input>` is currently a relation literal of the form
`relation (column: type, ...) { (column = value, ...), ... }`; the
literal's columns must be a permutation of the target's columns, and
each value must match its target column's kind. Arbitrary upstream
pipelines (insert-from-query) are deferred to a later slice.

Insert is a regular pipeline operator with one surface restriction:
the parser rejects any pipe-step after `insert into <name>`, so it
always appears as the last step. The whole insert runs in one write
transaction; a primary-key collision (or any other failure) aborts
the transaction and the table is unchanged.

```
> relation (id: int64, user_id: int64, description: string, amount: int64) { (id = 7, user_id = 4, description = "Muffin", amount = 2) } | insert into orders
relation (insert_count: int64) {
  (insert_count = 1)
}
```
