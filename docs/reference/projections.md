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
