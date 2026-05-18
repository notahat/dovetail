# Query language: data definition reference

Part of the [query-language guide](query-language.md). Data-definition
statements inspect or change the catalog rather than read or write
rows. They are distinguished from pipelines by a leading `:` sigil:
anything starting with `:` (after optional whitespace) is parsed as a
data-definition statement; anything else is parsed as a pipeline.

The sigil is only meaningful at the very start of input. Inside a
pipeline, expression, or column list, `:` remains a parse error, and
the keywords `list`, `drop`, `describe`, `create`, `table`, `tables`,
and `key` are ordinary identifiers -- they only acquire special
meaning after the sigil has been consumed.

Four statements are supported:

- `:list tables` -- list every table in the catalog.
- `:describe <name>` -- print a table's schema in canonical form.
- `:create table <name> (<columns>) primary key (<columns>)` -- add
  a new empty table to the catalog.
- `:drop table <name>` -- remove a table and its rows.

The four statements round-trip through the parser: the output of
`:describe <name>` is a syntactically valid `:create table <name>
(...)` that would reproduce the schema if executed against a fresh
database. This is the design's strongest correctness anchor for the
DDL surface.

## `:list tables`

**Syntax:** `:list tables`

Prints the name of every table in the catalog, one per line, in
byte-sorted order. An empty catalog produces no output between
prompts. The statement runs inside a read transaction and never
modifies state.

```
> :list tables
orders
users
```

## `:describe <name>`

**Syntax:** `:describe <identifier>`

Prints the schema of the named table in canonical form: a
syntactically valid `:create table <name> (...)` statement that
would reproduce the schema if executed against a fresh database.
The statement runs inside a read transaction and never modifies
state.

```
> :describe users
:create table users (
  id: Int64,
  name: String,
  email: String,
  active: Bool,
) primary key (id)
```

If the named table does not exist, the statement raises a
`no such table` error and the loop continues:

```
> :describe nonexistent
error: DDL: describe "nonexistent": no such table
```

## `:create table <name> (...) primary key (...)`

**Syntax:** `:create table <identifier> (<field-list>) primary key
(<column-list>)`

Where:

- `<field-list>` is a comma-separated sequence of `<name>: <kind>`
  pairs, with an optional trailing comma. The supported kinds are
  `Int64`, `String`, and `Bool`.
- `<column-list>` is a comma-separated sequence of names drawn
  from the field list, with an optional trailing comma. Names
  appear in key order.

Adds a new empty table to the catalog inside a single write
transaction: the catalog entry and the storage backing the rows
are created together. On success the REPL prints a status line
naming the created table. The example below creates `widgets`,
inspects it via `:list tables` and `:describe widgets`, then drops
it so subsequent sections see a fixture-only catalog:

```
> :create table widgets (id: Int64, name: String) primary key (id)
created table "widgets"
> :list tables
orders
users
widgets
> :describe widgets
:create table widgets (
  id: Int64,
  name: String,
) primary key (id)
> :drop table widgets
dropped table "widgets"
```

Structural checks run before any transaction opens. A duplicate
column name, a primary-key column not in the field list, and a
duplicate primary-key column each raise before the writer lock is
acquired:

```
> :create table widgets (id: Int64, id: String) primary key (id)
error: DDL: create table "widgets": column "id" appears twice
> :create table widgets (id: Int64, name: String) primary key (xyz)
error: DDL: create table "widgets": primary key column "xyz" not in column list
> :create table widgets (id: Int64) primary key (id, id)
error: DDL: create table "widgets": primary key column "id" appears twice
```

The catalog-aware "table already exists" check runs inside the
transaction: creating a table whose name is already bound raises
and the loop continues:

```
> :create table users (id: Int64) primary key (id)
error: DDL: create table "users": table already exists
```

## `:drop table <name>`

**Syntax:** `:drop table <identifier>`

Removes the named table's catalog entry and its storage in a single
write transaction. The catalog entry and the row data are removed
together: an interrupted transaction leaves both halves in place.

On success the REPL prints a status line naming the dropped table:

```
> :drop table orders
dropped table "orders"
> :list tables
users
```

If the named table does not exist, the statement raises a
`no such table` error and leaves the catalog untouched. The loop
continues, so a follow-up statement still runs:

```
> :drop table nonexistent
error: DDL: drop table "nonexistent": no such table
```

The fixture re-seeds `users` and `orders` on the next REPL startup
*only when the catalog entry is missing*. So a dropped fixture
table reappears after a restart; but a user-created table that
happens to share a fixture name (e.g. `:create table users (id:
Int64) primary key (id)` after dropping the fixture `users`)
survives, because the catalog entry is no longer missing. The
fixture will retire entirely once a future slice replaces it with
DDL-driven seeding.
