# Query language: data definition reference

Part of the [query-language guide](query-language.md). Data-definition
statements inspect or change the catalog rather than read or write
rows. They are distinguished from pipelines by a leading `:` sigil:
anything starting with `:` (after optional whitespace) is parsed as a
data-definition statement; anything else is parsed as a pipeline.

The sigil is only meaningful at the very start of input. Inside a
pipeline, expression, or column list, `:` remains a parse error, and
the keywords `list`, `drop`, `table`, `tables` are ordinary
identifiers -- they only acquire special meaning after the sigil has
been consumed.

Two statements are supported today:

- `:list tables` -- list every table in the catalog.
- `:drop table <name>` -- remove a table and its rows.

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
error: Ddl: drop table "nonexistent": no such table
```

The fixture re-seeds `users` and `orders` on the next REPL startup
against the same data directory, so a dropped fixture table will
reappear after a restart. That behaviour will go away once
`:create table` lands and the fixture retires.
