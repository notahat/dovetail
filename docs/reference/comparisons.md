# Comparisons

An expression form. Part of the [query-language reference](README.md).

**Syntax:** `<left> <op> <right>` where `<op>` is one of `=`, `<>`,
`<`, `<=`, `>`, `>=`

Comparisons take two sub-expressions and produce a Bool. The two
sides' types must agree:

- `=` and `<>` accept any matching type (Int64, String, or Bool).
- The four ordering operators (`<`, `<=`, `>`, `>=`) accept Int64
  or String only -- comparing Bool with an ordering operator is
  rejected at resolve time.

String comparison is lexicographic by byte. Comparisons are non-
associative; chains like `a < b < c` don't parse.

```
> orders | restrict amount >= 5
relation (orders.id: int64, orders.user_id: int64, orders.description: string, orders.amount: int64, primary key (id)) {
  (orders.id = 1, orders.user_id = 1, orders.description = "Coffee", orders.amount = 5),
  (orders.id = 4, orders.user_id = 3, orders.description = "Sandwich", orders.amount = 8),
  (orders.id = 5, orders.user_id = 3, orders.description = "Cake", orders.amount = 6)
}
```
