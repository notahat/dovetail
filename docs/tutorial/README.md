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
- [Tutorial](walkthrough.md) -- one query grown stage
  by stage, introducing each operator in turn.
- [Pipeline operators reference](../reference/README.md)
  -- per-operator syntax and semantics.
- [Expression and projection reference](../reference/README.md)
  -- the sublanguages used inside `restrict`, `project`, and the
  `on` clause of `join`.

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
relation (users.id: int64, users.name: string, users.email: string, users.active: bool, primary key (id)) {
  (users.id = 1, users.name = "Alice", users.email = "alice@example.com", users.active = true),
  (users.id = 2, users.name = "Bob", users.email = "bob@example.com", users.active = false),
  (users.id = 3, users.name = "Carol", users.email = "carol@example.com", users.active = true),
  (users.id = 4, users.name = "Dave", users.email = "dave@example.com", users.active = true),
  (users.id = 5, users.name = "Eve", users.email = "eve@example.com", users.active = false)
}
```

## The example tables

The examples in this guide query against two small tables, `users`
and `orders`, created by `--demo-data`. Knowing them up front saves
jumping back and forth as you read later sections. The schemas and
rows are documented here in prose; the `--demo-data` flag is what
puts them in your data directory.

### `users`

| column   | type   | notes                                |
| -------- | ------ | ------------------------------------ |
| `id`     | Int64  | primary key                          |
| `name`   | String |                                      |
| `email`  | String |                                      |
| `active` | Bool   | whether the account is enabled       |

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

### `orders`

| column        | type   | notes                            |
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
relation (orders.id: int64, orders.user_id: int64, orders.description: string, orders.amount: int64, primary key (id)) {
  (orders.id = 1, orders.user_id = 1, orders.description = "Coffee", orders.amount = 5),
  (orders.id = 2, orders.user_id = 1, orders.description = "Bagel", orders.amount = 4),
  (orders.id = 3, orders.user_id = 2, orders.description = "Tea", orders.amount = 3),
  (orders.id = 4, orders.user_id = 3, orders.description = "Sandwich", orders.amount = 8),
  (orders.id = 5, orders.user_id = 3, orders.description = "Cake", orders.amount = 6),
  (orders.id = 6, orders.user_id = 5, orders.description = "Cookie", orders.amount = 2)
}
```
