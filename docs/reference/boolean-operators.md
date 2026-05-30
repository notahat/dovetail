# Boolean operators

An expression form. Part of the [query-language reference](README.md).

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
