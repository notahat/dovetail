# cross

A pipeline operator. Part of the [query-language reference](README.md).

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
relation (users.id: int64, users.name: string, users.email: string, users.active: bool, orders.id: int64, orders.user_id: int64, orders.description: string, orders.amount: int64) {
  (users.id = 4, users.name = "Dave", users.email = "dave@example.com", users.active = true, orders.id = 1, orders.user_id = 1, orders.description = "Coffee", orders.amount = 5),
  (users.id = 4, users.name = "Dave", users.email = "dave@example.com", users.active = true, orders.id = 2, orders.user_id = 1, orders.description = "Bagel", orders.amount = 4),
  (users.id = 4, users.name = "Dave", users.email = "dave@example.com", users.active = true, orders.id = 3, orders.user_id = 2, orders.description = "Tea", orders.amount = 3),
  (users.id = 4, users.name = "Dave", users.email = "dave@example.com", users.active = true, orders.id = 4, orders.user_id = 3, orders.description = "Sandwich", orders.amount = 8),
  (users.id = 4, users.name = "Dave", users.email = "dave@example.com", users.active = true, orders.id = 5, orders.user_id = 3, orders.description = "Cake", orders.amount = 6),
  (users.id = 4, users.name = "Dave", users.email = "dave@example.com", users.active = true, orders.id = 6, orders.user_id = 5, orders.description = "Cookie", orders.amount = 2)
}
```
