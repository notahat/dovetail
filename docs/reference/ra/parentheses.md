# Parentheses

An expression form. Part of the [query-language reference](README.md).

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
