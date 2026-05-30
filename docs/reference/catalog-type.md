# Catalog type

A composite type. Part of the [query-language reference](README.md).

A catalog type pairs each table name with its relation type, written
`catalog { name: (relation-type), ... }`. The catalog is the top rung
of the type ladder and has no literal form; produce one with the
[catalog](catalog.md) source. It is what `| type` reports for a
catalog.

```
> catalog | type
catalog { orders: (orders.id: int64, orders.user_id: int64, orders.description: string, orders.amount: int64, primary key (id)), users: (users.id: int64, users.name: string, users.email: string, users.active: bool, primary key (id)) }
```
