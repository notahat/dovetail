# Query language tutorial

Part of the [query-language tutorial](README.md). This file
grows one query, one operator at a time. By the end you'll have
built the canonical multi-operator query -- a join with a trailing
projection -- and seen enough of the pipeline shape to make the
operator reference feel familiar.

Every query reads against the example tables described in the
[overview](README.md#the-example-tables), so you can
compare each transformation to what came before.

## Start with a table

Name a table on its own and the REPL prints every row in primary-
key order. Notice that the headers are qualified: `users.id` rather
than `id`. Qualifiers come from the table the column was scanned
out of; they ride along through every later operator.

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

## Filter with `restrict`

A pipeline operator is added with `|`. `restrict` keeps rows for
which its predicate evaluates to true; the predicate can be any
expression that resolves to a Bool. A bare column reference works
when the column itself is a Bool, so the active-users filter is as
small as it gets:

```
> users | restrict active
relation (users.id: int64, users.name: string, users.email: string, users.active: bool, primary key (id)) {
  (users.id = 1, users.name = "Alice", users.email = "alice@example.com", users.active = true),
  (users.id = 3, users.name = "Carol", users.email = "carol@example.com", users.active = true),
  (users.id = 4, users.name = "Dave", users.email = "dave@example.com", users.active = true)
}
```

## Pick columns with `project`

`project` takes a comma-separated list of column references and
keeps only those columns, in the order you list them. The
qualifiers stick to the columns they came from -- `users.name`
stays `users.name`, even after the projection narrows the output:

```
> users | restrict active | project name, email
relation (users.name: string, users.email: string) {
  (users.name = "Alice", users.email = "alice@example.com"),
  (users.name = "Carol", users.email = "carol@example.com"),
  (users.name = "Dave", users.email = "dave@example.com")
}
```

## Combine two tables with `cross`

`cross` produces the Cartesian product of its inputs. The output
schema is the left fields followed by the right fields, each
keeping its own qualifier -- which is what lets the next operator
disambiguate `users.id` from `orders.id`.

The output is rarely what you actually want: five users times six
orders is thirty rows, most of them pairing a user with an order
someone else placed. A predicate to discard the spurious pairings
comes next.

The first ten rows are shown below -- enough to see Alice paired
with every order in the system, and Bob's pairings beginning. The
trailing `...` is a doctest marker meaning "and so on for the
remaining twenty rows"; you'd see them all in the REPL.

```
> users | cross orders
relation (users.id: int64, users.name: string, users.email: string, users.active: bool, orders.id: int64, orders.user_id: int64, orders.description: string, orders.amount: int64) {
  (users.id = 1, users.name = "Alice", users.email = "alice@example.com", users.active = true, orders.id = 1, orders.user_id = 1, orders.description = "Coffee", orders.amount = 5),
  (users.id = 1, users.name = "Alice", users.email = "alice@example.com", users.active = true, orders.id = 2, orders.user_id = 1, orders.description = "Bagel", orders.amount = 4),
  (users.id = 1, users.name = "Alice", users.email = "alice@example.com", users.active = true, orders.id = 3, orders.user_id = 2, orders.description = "Tea", orders.amount = 3),
  (users.id = 1, users.name = "Alice", users.email = "alice@example.com", users.active = true, orders.id = 4, orders.user_id = 3, orders.description = "Sandwich", orders.amount = 8),
  (users.id = 1, users.name = "Alice", users.email = "alice@example.com", users.active = true, orders.id = 5, orders.user_id = 3, orders.description = "Cake", orders.amount = 6),
  (users.id = 1, users.name = "Alice", users.email = "alice@example.com", users.active = true, orders.id = 6, orders.user_id = 5, orders.description = "Cookie", orders.amount = 2),
  (users.id = 2, users.name = "Bob", users.email = "bob@example.com", users.active = false, orders.id = 1, orders.user_id = 1, orders.description = "Coffee", orders.amount = 5),
  (users.id = 2, users.name = "Bob", users.email = "bob@example.com", users.active = false, orders.id = 2, orders.user_id = 1, orders.description = "Bagel", orders.amount = 4),
  (users.id = 2, users.name = "Bob", users.email = "bob@example.com", users.active = false, orders.id = 3, orders.user_id = 2, orders.description = "Tea", orders.amount = 3),
  (users.id = 2, users.name = "Bob", users.email = "bob@example.com", users.active = false, orders.id = 4, orders.user_id = 3, orders.description = "Sandwich", orders.amount = 8),
...
```

## Join two tables with `join ... on`

`join right on predicate` is the natural pairing: same schema as
`cross`, but only rows where `predicate` holds. The predicate
language is the same one `restrict` uses, and qualified column
references (`users.id`, `orders.user_id`) name which side of the
join each column comes from.

Dave (user 4) doesn't appear in the output: he has no orders, so
no `orders.user_id` matches his `users.id`. Alice and Carol each
appear twice -- once per order.

```
> users | join orders on users.id = orders.user_id
relation (users.id: int64, users.name: string, users.email: string, users.active: bool, orders.id: int64, orders.user_id: int64, orders.description: string, orders.amount: int64) {
  (users.id = 1, users.name = "Alice", users.email = "alice@example.com", users.active = true, orders.id = 1, orders.user_id = 1, orders.description = "Coffee", orders.amount = 5),
  (users.id = 1, users.name = "Alice", users.email = "alice@example.com", users.active = true, orders.id = 2, orders.user_id = 1, orders.description = "Bagel", orders.amount = 4),
  (users.id = 2, users.name = "Bob", users.email = "bob@example.com", users.active = false, orders.id = 3, orders.user_id = 2, orders.description = "Tea", orders.amount = 3),
  (users.id = 3, users.name = "Carol", users.email = "carol@example.com", users.active = true, orders.id = 4, orders.user_id = 3, orders.description = "Sandwich", orders.amount = 8),
  (users.id = 3, users.name = "Carol", users.email = "carol@example.com", users.active = true, orders.id = 5, orders.user_id = 3, orders.description = "Cake", orders.amount = 6),
  (users.id = 5, users.name = "Eve", users.email = "eve@example.com", users.active = false, orders.id = 6, orders.user_id = 5, orders.description = "Cookie", orders.amount = 2)
}
```

## Project after the join

Operators chain freely. The canonical shape is a join followed by
a projection: combine the rows you need, then pick the columns you
want to see.

```
> users | join orders on users.id = orders.user_id | project name, description, amount
relation (users.name: string, orders.description: string, orders.amount: int64) {
  (users.name = "Alice", orders.description = "Coffee", orders.amount = 5),
  (users.name = "Alice", orders.description = "Bagel", orders.amount = 4),
  (users.name = "Bob", orders.description = "Tea", orders.amount = 3),
  (users.name = "Carol", orders.description = "Sandwich", orders.amount = 8),
  (users.name = "Carol", orders.description = "Cake", orders.amount = 6),
  (users.name = "Eve", orders.description = "Cookie", orders.amount = 2)
}
```

That's the canonical join-and-project shape. The full operator
set is wider -- the literal source forms, `unqualify`, `type`,
`tables`, `catalog`, the `insert into`, `create table`, and
`drop table` sinks -- and the
[pipeline operator reference](../query-language-pipeline-operators.md)
systematises each one. The
[expression and projection reference](../query-language-expressions.md)
covers the sublanguages used inside `restrict`, `project`, and the
`on` clause of `join`.
