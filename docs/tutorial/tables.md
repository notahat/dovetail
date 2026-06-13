# Tables: create, insert, drop

Part of the [query-language tutorial](README.md). The
[walkthrough](walkthrough.md) reads against the demo tables that
`--demo-data` seeds; this chapter goes the other way and *builds* a
table of its own — declaring it, filling it, querying it, and dropping
it again — introducing the literal source forms and the `type` and
`catalog` operators along the way.

Every example here is run through the REPL during `dune test` against
the same demo-seeded environment, in the order shown, so the `products`
table created below really does come and go as you read down the page.

## Literals: values without a table

Not every pipeline starts from a stored table. The simplest source is
a bare scalar — an integer, a double-quoted string, or a boolean — which
yields itself:

```
> 42
42
> "Sprocket"
"Sprocket"
> true
true
```

A parenthesised list of `name = value` bindings is a **row literal**: a
single row, with no table behind it. Piping any value through `type`
yields its type instead of its value — no cursors open, no rows are
pulled:

```
> (id = 1, name = "Widget")
(id = 1, name = "Widget")
> (id = 1, name = "Widget") | type
(id: int64, name: string)
```

A **relation literal** is a whole table written inline: the `relation`
keyword, a parenthesised relation type (a row type plus optional
refinements like `primary key (...)`), and a brace-delimited body of
row literals. This is the form `insert into` and the seeded `create
table` consume, so it is worth recognising before we reach them:

```
> relation (id: int64, name: string, price: int64, primary key (id)) { (id = 1, name = "Widget", price = 5), (id = 2, name = "Gadget", price = 12) }
relation (id: int64, name: string, price: int64, primary key (id)) {
  (id = 1, name = "Widget", price = 5),
  (id = 2, name = "Gadget", price = 12)
}
```

## Creating a table

`create table` is a pipeline sink. Its empty form takes a *type
expression* on the left — a parenthesised `name: type` list with a
`primary key` refinement — and registers an empty table of that type.
A primary key is required, because tables are index-organised on it.
The sink reports the new table's name as a one-row `(created: string)`
relation:

```
> (id: int64, name: string, price: int64, primary key (id)) | create table products
relation (created: string) {
  (created = "products")
}
```

(The other form, `<value-pipeline> | create table <name>`, derives the
type from an upstream relation and seeds the rows in one step; see the
[`create table` reference](../reference/ra/create-table.md).)

## Seeing it in the catalog

The bare `catalog` keyword yields the database's catalog — every
table's name paired with its rows. Against seeded data its rows are
bulky, so `catalog | type` is the more useful interrogation: it renders
each table's type, in name order. `products` now sits alongside the
demo tables:

```
> catalog | type
catalog { orders: (orders.id: int64, orders.user_id: int64, orders.description: string, orders.amount: int64, primary key (id)), products: (products.id: int64, products.name: string, products.price: int64, primary key (id)), users: (users.id: int64, users.name: string, users.email: string, users.active: bool, primary key (id)) }
```

Naming the table on its own scans it. It is empty so far, so the result
is header-only — the type, with no rows between the braces:

```
> products
relation (products.id: int64, products.name: string, products.price: int64, primary key (id)) {}
```

Note the headers are qualified — `products.id`, not `id` — just as they
are for a scanned demo table. Qualifiers come from the table a column
was scanned out of.

## Inserting rows

`insert into` writes the rows of a relation literal to a table and
reports how many it wrote as a one-row `(insert_count: int64)`
relation. The literal's columns must be a permutation of the target's,
and each value must match its column's type. The literal carries no
`primary key` refinement here — it describes the rows being supplied,
not the target's schema, which is already fixed:

```
> relation (id: int64, name: string, price: int64) { (id = 1, name = "Widget", price = 5), (id = 2, name = "Gadget", price = 12), (id = 3, name = "Sprocket", price = 8) } | insert into products
relation (insert_count: int64) {
  (insert_count = 3)
}
```

Scanning `products` again shows the three rows, in primary-key order:

```
> products
relation (products.id: int64, products.name: string, products.price: int64, primary key (id)) {
  (products.id = 1, products.name = "Widget", products.price = 5),
  (products.id = 2, products.name = "Gadget", products.price = 12),
  (products.id = 3, products.name = "Sprocket", products.price = 8)
}
```

## Querying it

A table you built reads exactly like a demo table: the same operators
chain off it. Here is a restrict-then-project over `products`:

```
> products | restrict price > 6 | project name, price
relation (products.name: string, products.price: int64) {
  (products.name = "Gadget", products.price = 12),
  (products.name = "Sprocket", products.price = 8)
}
```

And `type` reports the stored schema without reading any rows:

```
> products | type
(products.id: int64, products.name: string, products.price: int64, primary key (id))
```

## Dropping it

`drop table` removes the table from the catalog and reclaims its
storage. Unlike the other sinks it takes no upstream — the whole
pipeline is just `drop table <name>` — and it reports the dropped name
as a one-row `(dropped: string)` relation:

```
> drop table products
relation (dropped: string) {
  (dropped = "products")
}
```

With `products` gone, the catalog is back to just the demo tables:

```
> catalog | type
catalog { orders: (orders.id: int64, orders.user_id: int64, orders.description: string, orders.amount: int64, primary key (id)), users: (users.id: int64, users.name: string, users.email: string, users.active: bool, primary key (id)) }
```

That is the full table lifecycle. The
[pipeline operator reference](../reference/ra/README.md) documents each
source and sink in isolation — `create table`, `insert into`, `drop
table`, the literal forms, `catalog`, `tables`, and `type` — with a
worked example apiece.
