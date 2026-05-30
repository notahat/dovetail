# Query language: pipeline operators reference

Part of the [query-language guide](../tutorial/README.md). One
subsection per pipeline form: syntax, semantics, and a single
worked example against the example tables. For a narrative
introduction, see the [tutorial](../tutorial/walkthrough.md); for
the expression and projection sublanguages that appear inside
`restrict`, `project`, and the `on` clause of `join`, see the
[expression and projection reference](expressions.md).

Every pipeline starts at a **source**, threads through zero or
more **operators**, and may end at a **sink** that writes to the
catalog or a table. The three groups each get a section below.

## Sources

A source produces the initial value at the head of the pipeline.
The most common is a bare table name, which reads the whole
table. The three literal forms feed a value straight in without
going via a table -- useful for trying out operators, asking
`| type` what a value's type is, and (for relation literals)
seeding tables through `insert into`. The `catalog` keyword
surfaces the database's catalog so the `tables` and `type`
operators can read it.

### Relation references

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

### Scalar literals

**Syntax:** `<int64-literal>` | `"<string-literal>"` | `true` | `false`

A bare scalar at the head of a pipeline yields that scalar value.
The supported forms are the same three the
[expression reference](expressions.md#literals)
describes: signed decimal integers, double-quoted strings (with
`\"` and `\\` escapes), and the keywords `true` and `false`. The
only operator that consumes a scalar is `type`, which yields the
scalar's type.

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

### Row literals

**Syntax:** `(<name> = <scalar>, ...)`

A parenthesised, comma-separated list of `<name> = <value>`
bindings yields a single row whose fields are those bindings, in
written order. The empty form `()` yields the empty row. Field
names must be unique within the literal; values are scalar
literals (no expressions or column references at the row-literal
level). The only operator that consumes a row is `type`, which
yields the row's type.

```
> (id = 1, name = "alice")
(id = 1, name = "alice")
> (id = 1, name = "alice") | type
(id: int64, name: string)
> ()
()
```

### Relation literals

**Syntax:** `relation (<row-type> [, <refinement>...]) { <row-literal>, ... }`

A `relation` keyword followed by a parenthesised relation type and
a brace-delimited body of row literals yields a relation of that
type. The head's parenthesised list is a row type (`<name>: <type>`
declarations) optionally interleaved with refinements (today just
`primary key (...)`); the body is zero or more row literals,
comma-separated, with a permitted trailing comma. Every row's
fields must be a permutation of the declared row type's fields,
and each value must match its field's type. The empty body is
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

### catalog

**Syntax:** `catalog`

A bare `catalog` at the head of a pipeline yields the database's
catalog as a value -- every table's name paired with its rows. The
catalog is the top rung of the type ladder; unlike scalars, rows,
and relations it has no surface literal form, so this keyword is
the only way to produce one. The operators that consume a catalog
are [`tables`](#tables), which projects out the table-name column
as a one-column relation, and [`type`](#type), which renders the
catalog's type rather than its rows.

A bare `catalog` against the example tables prints both tables in
full -- a few dozen rows of structured output. The shape (a `catalog
{ ... }` literal whose entries are `<name> = relation (...) { ... }`)
is more useful than the rows, so the type form below is the more
common interrogation:

```
> catalog | type
catalog { orders: (orders.id: int64, orders.user_id: int64, orders.description: string, orders.amount: int64, primary key (id)), users: (users.id: int64, users.name: string, users.email: string, users.active: bool, primary key (id)) }
```

## Sinks

A sink mutates the catalog or a table and reports the result as a
one-row status relation. Every sink is terminal: the parser
rejects any pipe-step after it, and at most one sink may appear
per pipeline. The whole sink runs in one write transaction; any
failure aborts the transaction and the database is unchanged.

### insert into

**Syntax:** `<input> | insert into <table-name>`

Writes every row of `<input>` to `<table-name>` and returns a one-row
relation `(insert_count: int64)` reporting how many rows were
written. `<input>` is currently a relation literal of the form
`relation (column: type, ...) { (column = value, ...), ... }`; the
literal's columns must be a permutation of the target's columns, and
each value must match its target column's type. Arbitrary upstream
pipelines (insert-from-query) are deferred to a later slice.

```
> relation (id: int64, user_id: int64, description: string, amount: int64) { (id = 7, user_id = 4, description = "Muffin", amount = 2) } | insert into orders
relation (insert_count: int64) {
  (insert_count = 1)
}
```

### create table

**Syntax:** `<type-expression> | create table <table-name>` (empty
form) or `<value-pipeline> | create table <table-name>` (seeded
form).

Adds a new table to the catalog. The empty form takes a relation
type on the left (a parenthesised `<name>: <type>` list with
optional refinements like `primary key (...)`) and creates an empty
table of that type. The seeded form takes any value-yielding
pipeline; the new table's type is derived from the upstream's row
type, and its rows are the upstream's rows. Either form yields a
one-row relation `(created: string)` reporting the new table's
name.

The seeded form rejects sources whose row type carries qualifiers
-- pipe through `unqualify` first if the upstream is a base
relation -- and rejects sources whose derived type has no primary
key. A primary key is required because tables are index-organised.

```
> (id: int64, name: string, primary key (id)) | create table widgets
relation (created: string) {
  (created = "widgets")
}
> users | unqualify | create table users_copy
relation (created: string) {
  (created = "users_copy")
}
```

### drop table

**Syntax:** `drop table <table-name>`

Removes `<table-name>` from the catalog and reclaims its storage,
and yields a one-row relation `(dropped: string)` reporting the
dropped table's name. Unlike the other sinks `drop table` takes
no upstream -- nothing sits to its left, and the whole pipeline
is just `drop table <name>`.

```
> drop table widgets
relation (dropped: string) {
  (dropped = "widgets")
}
```
