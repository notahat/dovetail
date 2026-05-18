# Query language tutorial

Part of the [query-language guide](query-language.md). This file
grows one query, one operator at a time. By the end you'll have
built the canonical multi-operator query -- a join with a trailing
projection -- and seen enough of the pipeline shape to make the
operator reference feel familiar.

Every query reads against the example tables described in the
[guide overview](query-language.md#the-example-tables), so you can
compare each transformation to what came before.

## Start with a table

Name a table on its own and the REPL prints every row in primary-
key order. Notice that the headers are qualified: `users.id` rather
than `id`. Qualifiers come from the table the column was scanned
out of; they ride along through every later operator.

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

## Filter with `restrict`

A pipeline operator is added with `|`. `restrict` keeps rows for
which its predicate evaluates to true; the predicate can be any
expression that resolves to a Bool. A bare column reference works
when the column itself is a Bool, so the active-users filter is as
small as it gets:

```
> users | restrict active
│ users.id │ users.name │ users.email       │ users.active │
├──────────┼────────────┼───────────────────┼──────────────┤
│        1 │ Alice      │ alice@example.com │ true         │
│        3 │ Carol      │ carol@example.com │ true         │
│        4 │ Dave       │ dave@example.com  │ true         │
```

## Pick columns with `project`

`project` takes a comma-separated list of column references and
keeps only those columns, in the order you list them. The
qualifiers stick to the columns they came from -- `users.name`
stays `users.name`, even after the projection narrows the output:

```
> users | restrict active | project name, email
│ users.name │ users.email       │
├────────────┼───────────────────┤
│ Alice      │ alice@example.com │
│ Carol      │ carol@example.com │
│ Dave       │ dave@example.com  │
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
│ users.id │ users.name │ users.email       │ users.active │ orders.id │ orders.user_id │ orders.description │ orders.amount │
├──────────┼────────────┼───────────────────┼──────────────┼───────────┼────────────────┼────────────────────┼───────────────┤
│        1 │ Alice      │ alice@example.com │ true         │         1 │              1 │ Coffee             │             5 │
│        1 │ Alice      │ alice@example.com │ true         │         2 │              1 │ Bagel              │             4 │
│        1 │ Alice      │ alice@example.com │ true         │         3 │              2 │ Tea                │             3 │
│        1 │ Alice      │ alice@example.com │ true         │         4 │              3 │ Sandwich           │             8 │
│        1 │ Alice      │ alice@example.com │ true         │         5 │              3 │ Cake               │             6 │
│        1 │ Alice      │ alice@example.com │ true         │         6 │              5 │ Cookie             │             2 │
│        2 │ Bob        │ bob@example.com   │ false        │         1 │              1 │ Coffee             │             5 │
│        2 │ Bob        │ bob@example.com   │ false        │         2 │              1 │ Bagel              │             4 │
│        2 │ Bob        │ bob@example.com   │ false        │         3 │              2 │ Tea                │             3 │
│        2 │ Bob        │ bob@example.com   │ false        │         4 │              3 │ Sandwich           │             8 │
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
│ users.id │ users.name │ users.email       │ users.active │ orders.id │ orders.user_id │ orders.description │ orders.amount │
├──────────┼────────────┼───────────────────┼──────────────┼───────────┼────────────────┼────────────────────┼───────────────┤
│        1 │ Alice      │ alice@example.com │ true         │         1 │              1 │ Coffee             │             5 │
│        1 │ Alice      │ alice@example.com │ true         │         2 │              1 │ Bagel              │             4 │
│        2 │ Bob        │ bob@example.com   │ false        │         3 │              2 │ Tea                │             3 │
│        3 │ Carol      │ carol@example.com │ true         │         4 │              3 │ Sandwich           │             8 │
│        3 │ Carol      │ carol@example.com │ true         │         5 │              3 │ Cake               │             6 │
│        5 │ Eve        │ eve@example.com   │ false        │         6 │              5 │ Cookie             │             2 │
```

## Project after the join

Operators chain freely. The canonical shape is a join followed by
a projection: combine the rows you need, then pick the columns you
want to see.

```
> users | join orders on users.id = orders.user_id | project name, description, amount
│ users.name │ orders.description │ orders.amount │
├────────────┼────────────────────┼───────────────┤
│ Alice      │ Coffee             │             5 │
│ Alice      │ Bagel              │             4 │
│ Bob        │ Tea                │             3 │
│ Carol      │ Sandwich           │             8 │
│ Carol      │ Cake               │             6 │
│ Eve        │ Cookie             │             2 │
```

That's the working set of operators. The
[pipeline operator reference](query-language-pipeline-operators.md)
systematises each one; the
[expression and projection reference](query-language-expressions.md)
covers the sublanguages used inside `restrict`, `project`, and the
`on` clause of `join`.
