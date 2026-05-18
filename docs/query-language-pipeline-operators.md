# Query language: pipeline operators reference

Part of the [query-language guide](query-language.md). One
subsection per pipeline operator: syntax, semantics, and a single
worked example against the example tables. For a narrative
introduction,
see the [tutorial](query-language-tutorial.md); for the expression
and projection sublanguages that appear inside `restrict`,
`project`, and the `on` clause of `join`, see the
[expression and projection reference](query-language-expressions.md).

## Relation references

**Syntax:** `<table-name>`

A bare identifier reads every row of the named table in primary-
key order. This is the only way to introduce a relation into a
pipeline; every other operator takes one as input. The output
schema is the table's schema, with each column's qualifier set to
the table name -- so a later operator can disambiguate columns
that share a name across tables.

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
│ users.id │ users.name │ users.email       │ users.active │
├──────────┼────────────┼───────────────────┼──────────────┤
│        1 │ Alice      │ alice@example.com │ true         │
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
│ users.name │ users.email       │
├────────────┼───────────────────┤
│ Alice      │ alice@example.com │
│ Bob        │ bob@example.com   │
│ Carol      │ carol@example.com │
│ Dave       │ dave@example.com  │
│ Eve        │ eve@example.com   │
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
│ users.id │ users.name │ users.email      │ users.active │ orders.id │ orders.user_id │ orders.description │ orders.amount │
├──────────┼────────────┼──────────────────┼──────────────┼───────────┼────────────────┼────────────────────┼───────────────┤
│        4 │ Dave       │ dave@example.com │ true         │         1 │              1 │ Coffee             │             5 │
│        4 │ Dave       │ dave@example.com │ true         │         2 │              1 │ Bagel              │             4 │
│        4 │ Dave       │ dave@example.com │ true         │         3 │              2 │ Tea                │             3 │
│        4 │ Dave       │ dave@example.com │ true         │         4 │              3 │ Sandwich           │             8 │
│        4 │ Dave       │ dave@example.com │ true         │         5 │              3 │ Cake               │             6 │
│        4 │ Dave       │ dave@example.com │ true         │         6 │              5 │ Cookie             │             2 │
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
│ users.id │ users.name │ users.email       │ users.active │ orders.id │ orders.user_id │ orders.description │ orders.amount │
├──────────┼────────────┼───────────────────┼──────────────┼───────────┼────────────────┼────────────────────┼───────────────┤
│        1 │ Alice      │ alice@example.com │ true         │         1 │              1 │ Coffee             │             5 │
│        1 │ Alice      │ alice@example.com │ true         │         2 │              1 │ Bagel              │             4 │
```
