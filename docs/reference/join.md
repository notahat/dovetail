# join

A pipeline operator. Part of the [query-language reference](README.md).

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
relation (users.id: int64, users.name: string, users.email: string, users.active: bool, orders.id: int64, orders.user_id: int64, orders.description: string, orders.amount: int64) {
  (users.id = 1, users.name = "Alice", users.email = "alice@example.com", users.active = true, orders.id = 1, orders.user_id = 1, orders.description = "Coffee", orders.amount = 5),
  (users.id = 1, users.name = "Alice", users.email = "alice@example.com", users.active = true, orders.id = 2, orders.user_id = 1, orders.description = "Bagel", orders.amount = 4)
}
```
