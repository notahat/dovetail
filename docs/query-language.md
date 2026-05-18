# Query language

Dovetail's query language is pipeline-shaped: you name a relation,
then chain operators with `|`. Every example in this guide is run
through the REPL during `dune test`, so what you read is what the
engine actually produces.

This document is the user-facing reference. It assumes you know what
a table, row, column, join, predicate, and projection are; it does
not assume you've read any of Dovetail's source.

The guide is in several parts:

- This file -- launching the REPL and the shape of the example
  tables every example reads against.
- [Tutorial](query-language-tutorial.md) -- one query grown stage
  by stage, introducing each operator in turn.
- [Pipeline operators reference](query-language-pipeline-operators.md)
  -- per-operator syntax and semantics.
- [Expression and projection reference](query-language-expressions.md)
  -- the sublanguages used inside `restrict`, `project`, and the
  `on` clause of `join`.
- [Data definition reference](query-language-data-definition.md) --
  the `:`-prefixed statements that inspect and modify the catalog
  (`:list tables`, `:describe <name>`, `:create table <name>
  (...)`, `:drop table <name>`).

## Running the REPL

Build the binary, then launch it against a data directory:

```
./dovetail [--demo-data] dovetail-data
```

The REPL prints a `> ` prompt, reads one query per line, and pretty-
prints the resulting rows as a Unicode-bordered table. `Ctrl-D`
exits. The data directory is created if it doesn't exist; pass
`--demo-data` on first launch to seed the example tables described
below. Re-running with `--demo-data` against an already-seeded data
directory is a no-op, so it's safe to include in a shell alias.

A first query: every row of the `users` table.

```
> users
│ users.id │ users.name │ users.email       │ users.active │
├──────────┼────────────┼───────────────────┼──────────────┤
│        1 │ Alice      │ alice@example.com │ true         │
│        2 │ Bob        │ bob@example.com   │ false        │
│        3 │ Carol      │ carol@example.com │ true         │
│        4 │ Dave       │ dave@example.com  │ true         │
│        5 │ Eve        │ eve@example.com   │ false        │
```

## The example tables

The examples in this guide query against two small tables, `users`
and `orders`, created by `--demo-data`. Knowing them up front saves
jumping back and forth as you read later sections. The schemas and
rows are documented here in prose; the `--demo-data` flag is what
puts them in your data directory.

### `users`

| column   | kind   | notes                                |
| -------- | ------ | ------------------------------------ |
| `id`     | Int64  | primary key                          |
| `name`   | String |                                      |
| `email`  | String |                                      |
| `active` | Bool   | whether the account is enabled       |

```
> users
│ users.id │ users.name │ users.email       │ users.active │
├──────────┼────────────┼───────────────────┼──────────────┤
│        1 │ Alice      │ alice@example.com │ true         │
│        2 │ Bob        │ bob@example.com   │ false        │
│        3 │ Carol      │ carol@example.com │ true         │
│        4 │ Dave       │ dave@example.com  │ true         │
│        5 │ Eve        │ eve@example.com   │ false        │
```

### `orders`

| column        | kind   | notes                            |
| ------------- | ------ | -------------------------------- |
| `id`          | Int64  | primary key                      |
| `user_id`     | Int64  | foreign key into `users.id`      |
| `description` | String | what was ordered                 |
| `amount`      | Int64  | order quantity                   |

Dave (user 4) deliberately has no orders, and Alice (1) and Carol
(3) each have two -- a shape that makes the join examples in later
sections produce visibly interesting output.

```
> orders
│ orders.id │ orders.user_id │ orders.description │ orders.amount │
├───────────┼────────────────┼────────────────────┼───────────────┤
│         1 │              1 │ Coffee             │             5 │
│         2 │              1 │ Bagel              │             4 │
│         3 │              2 │ Tea                │             3 │
│         4 │              3 │ Sandwich           │             8 │
│         5 │              3 │ Cake               │             6 │
│         6 │              5 │ Cookie             │             2 │
```
