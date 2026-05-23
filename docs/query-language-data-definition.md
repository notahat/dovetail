# Query language: data definition reference

Part of the [query-language guide](query-language.md). Data-definition
statements inspect or change the catalog rather than read or write
rows. They are distinguished from pipelines by a leading `:` sigil:
anything starting with `:` (after optional whitespace) is parsed as a
data-definition statement; anything else is parsed as a pipeline.

The sigil is only meaningful at the very start of input. Inside a
pipeline, expression, or column list, `:` remains a parse error, and
the keywords `list`, `drop`, `create`, `table`, `tables`, and `key`
are ordinary identifiers -- they only acquire special meaning after
the sigil has been consumed.

Three statements are supported:

- `:list tables` -- list every table in the catalog.
- `:create table <name> (<columns>) primary key (<columns>)` -- add
  a new empty table to the catalog.
- `:drop table <name>` -- remove a table and its rows.

To inspect a table's schema, pipe it into the `type` operator:
`<name> | type`. The operator yields the relation's type without
opening any cursors. This replaces the earlier `:describe` form.

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
inspects it via `:list tables` and `widgets | type`, then drops
it so subsequent sections see the same example-table catalog the
section started with:

```
> :create table widgets (id: Int64, name: String) primary key (id)
created table "widgets"
> :list tables
orders
users
widgets
> widgets | type
(id: int64, name: string, primary key (id))
> :drop table widgets
dropped table "widgets"
```

Structural checks run before any transaction opens. An empty
column list, a duplicate column name, an empty primary-key list,
a primary-key column not in the field list, and a duplicate
primary-key column each raise before the writer lock is acquired:

```
> :create table widgets () primary key (id)
error: DDL: create table "widgets": column list is empty
> :create table widgets (id: Int64, id: String) primary key (id)
error: DDL: create table "widgets": column "id" appears twice
> :create table widgets (id: Int64) primary key ()
error: DDL: create table "widgets": primary key is empty
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

A dropped table stays dropped: restarting the REPL does not bring
it back. Launching the REPL again with `--demo-data` re-seeds the
example tables only when *both* `users` and `orders` are absent
from the catalog -- the flag is a one-shot bootstrap rather than
a per-table top-up. So after dropping a single example table, the
way to get it back is `:create table` (and per-row inserts), not a
relaunch with the flag.
