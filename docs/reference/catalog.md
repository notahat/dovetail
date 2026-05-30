# catalog

A pipeline source. Part of the [query-language reference](README.md).

**Syntax:** `catalog`

A bare `catalog` at the head of a pipeline yields the database's
catalog as a value -- every table's name paired with its rows. The
catalog is the top rung of the type ladder; unlike scalars, rows,
and relations it has no surface literal form, so this keyword is
the only way to produce one. The operators that consume a catalog
are [`tables`](tables.md), which projects out the table-name column
as a one-column relation, and [`type`](type.md), which renders the
catalog's type rather than its rows.

A bare `catalog` against the example tables prints both tables in
full -- a few dozen rows of structured output. The shape (a `catalog
{ ... }` literal whose entries are `<name> = relation (...) { ... }`)
is more useful than the rows, so the type form below is the more
common interrogation:

```
> catalog | type
catalog { orders: (orders.id: int64, orders.user_id: int64, orders.description: string, orders.amount: int64, primary key (id)), users: (users.id: int64, users.name: string, users.email: string, users.active: bool, primary key (id)) }
```
