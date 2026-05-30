# Query language: expression and projection reference

Part of the [query-language guide](../tutorial/README.md). Two
sublanguages appear inside the pipeline operators: the expression
language used as a predicate in `restrict` and in `join`'s `on`
clause, and the projection language used in `project`. This file
covers both.

For the pipeline operators themselves, see the
[operator reference](pipeline-operators.md); for a
narrative introduction, see the
[tutorial](../tutorial/walkthrough.md).

## Literals

**Syntax:** `<int64-literal>` | `"<string-literal>"` |
`true` | `false`

Three literal forms match the three value types in the schema:

- **Int64** literals are signed decimal: `-1`, `0`, `42`. There is
  no separate unsigned form.
- **String** literals are double-quoted. The only recognised
  escapes are `\"` (a literal double-quote) and `\\` (a literal
  backslash); other backslash sequences are rejected.
- **Bool** literals are the keywords `true` and `false`.

A literal evaluates to itself at every row.

```
> users | restrict name = "Alice"
relation (users.id: int64, users.name: string, users.email: string, users.active: bool, primary key (id)) {
  (users.id = 1, users.name = "Alice", users.email = "alice@example.com", users.active = true)
}
```

## Column references

**Syntax:** `<column-name>` | `<qualifier>.<column-name>`

A column reference names a column of the surrounding relation.
The bare form is just the column name; the qualified form prefixes
the qualifier and column with a dot. No whitespace is allowed
around the dot.

Bare references must resolve unambiguously against the surrounding
schema. After a `cross` or `join` introduces same-named columns
from two inputs (`users.id` and `orders.id`, for example), a bare
`id` is ambiguous and the qualified form is required. Inside a
single-table query, the bare and qualified forms refer to the
same column.

```
> users | restrict users.id = 1
relation (users.id: int64, users.name: string, users.email: string, users.active: bool, primary key (id)) {
  (users.id = 1, users.name = "Alice", users.email = "alice@example.com", users.active = true)
}
```

## Comparisons

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

## Boolean operators

**Syntax:** `<left> and <right>` | `<left> or <right>` | `not <operand>`

`and`, `or`, and `not` combine Bool-valued sub-expressions. Both
operands of `and` and `or`, and the single operand of `not`, must
be of type Bool; non-Bool operands are rejected at resolve time
(so `not active` is fine but `not name` is not).

`and` and `or` short-circuit left-to-right: the right operand is
only evaluated when needed. Both are left-associative; `not` is a
prefix unary operator and stacks (`not not active` parses).

```
> users | restrict active and not id = 4
relation (users.id: int64, users.name: string, users.email: string, users.active: bool, primary key (id)) {
  (users.id = 1, users.name = "Alice", users.email = "alice@example.com", users.active = true),
  (users.id = 3, users.name = "Carol", users.email = "carol@example.com", users.active = true)
}
```

## Parentheses

**Syntax:** `(<expression>)`

Parentheses group sub-expressions to override the default
precedence. They can wrap any expression, including a single atom
(`(1)` parses), but their usual job is changing how `and`, `or`,
and `not` bind.

The example below restricts to users whose id is *neither* 1 nor
2; without the parentheses, `not id = 1 or id = 2` would parse as
`(not (id = 1)) or (id = 2)` and produce a different set.

```
> users | restrict not (id = 1 or id = 2)
relation (users.id: int64, users.name: string, users.email: string, users.active: bool, primary key (id)) {
  (users.id = 3, users.name = "Carol", users.email = "carol@example.com", users.active = true),
  (users.id = 4, users.name = "Dave", users.email = "dave@example.com", users.active = true),
  (users.id = 5, users.name = "Eve", users.email = "eve@example.com", users.active = false)
}
```

## Precedence and associativity

From tightest to loosest binding:

| Level | Construct                            | Associativity     |
| ----- | ------------------------------------ | ----------------- |
| 1     | Atoms (literals, column refs, `(…)`) | n/a               |
| 2     | Comparisons (`=`, `<>`, `<`, `<=`, `>`, `>=`) | non-associative |
| 3     | `not <operand>`                      | prefix unary; stacks |
| 4     | `<left> and <right>`                 | left-associative  |
| 5     | `<left> or <right>`                  | left-associative  |

So `a or b and not c = 1` parses as `a or (b and (not (c = 1)))`.
When that's not what you want, parenthesise.

## Projections

**Syntax:** `<column-reference> [, <column-reference>]*`

A projection is a comma-separated list of one or more column
references; each entry uses the same bare-or-qualified syntax
described in [Column references](#column-references). Whitespace
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
