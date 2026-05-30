# unqualify

A pipeline operator. Part of the [query-language reference](README.md).

**Syntax:** `<input> | unqualify`

Strips the qualifier from every field of `<input>`'s row type,
leaving the bare names. `<input>` is either a relation (yields a
relation with the same rows under the unqualified type) or a row
(yields a row under the unqualified type). It's a no-op on an input
that already has no qualifiers, and is rejected when two fields
would collide on their bare name after stripping -- the error names
the colliding bare name and the two original qualified spellings.

The typical use is reshaping a join's output so a downstream sink
that wants bare names -- `insert into`, for instance, which rejects
qualified source rows -- will accept it.

```
> users | restrict id = 1 | join orders on users.id = orders.user_id | project orders.id, orders.description, orders.amount | unqualify
relation (id: int64, description: string, amount: int64) {
  (id = 1, description = "Coffee", amount = 5),
  (id = 2, description = "Bagel", amount = 4)
}
```
