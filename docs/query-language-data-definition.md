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

Two statements are supported:

- `:list tables` -- list every table in the catalog.
- `:drop table <name>` -- remove a table and its rows.

Adding a table is no longer a DDL statement: the
`<type-expr> | create table <name>` and
`<relation-value> | create table <name>` sinks live in the pipeline
grammar instead. See the
[`create table`](query-language-pipeline-operators.md#create-table)
section of the pipeline-operators reference.

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
way to get it back is the `create table` pipe sink (and per-row
inserts), not a relaunch with the flag.
