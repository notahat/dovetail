# Projections

The projection language, used inside `project`. Part of the
[query-language reference](README.md).

**Syntax:** `<column-reference> [, <column-reference>]*`

A projection is a comma-separated list of one or more column
references; each entry uses the same bare-or-qualified syntax
described in [Column references](column-references.md). Whitespace
around the commas is tolerated.

The output schema is the projection list in order. Each retained
column keeps the qualifier it had on input, so projecting from a
joined relation preserves which side each column came from. Bare
names must resolve unambiguously against the input schema (just as
in a predicate); a column reference may not appear more than once
in the list (`project id, id` is rejected). The duplicate check is
on the reference's source form, so a bare and a qualified
reference to the same underlying column are not currently treated
as duplicates of each other.

That last point is a quirk worth seeing. Because `name` and
`users.name` are different source spellings, listing both passes the
duplicate check and yields two columns of the same name — a result
you almost certainly didn't intend:

```
> users | project name, users.name
relation (users.name: string, users.name: string) {
  (users.name = "Alice", users.name = "Alice"),
  (users.name = "Bob", users.name = "Bob"),
  (users.name = "Carol", users.name = "Carol"),
  (users.name = "Dave", users.name = "Dave"),
  (users.name = "Eve", users.name = "Eve")
}
```

Deduplicating by resolved column identity rather than source spelling
would catch this; it is tracked in the code as
`TODO(projection-dedup-by-resolution)`.

```
> orders | project description, amount, id
relation (orders.description: string, orders.amount: int64, orders.id: int64) {
  (orders.description = "Coffee", orders.amount = 5, orders.id = 1),
  (orders.description = "Bagel", orders.amount = 4, orders.id = 2),
  (orders.description = "Tea", orders.amount = 3, orders.id = 3),
  (orders.description = "Sandwich", orders.amount = 8, orders.id = 4),
  (orders.description = "Cake", orders.amount = 6, orders.id = 5),
  (orders.description = "Cookie", orders.amount = 2, orders.id = 6)
}
```
