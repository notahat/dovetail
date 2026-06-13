# restrict

A pipeline operator. Part of the [query-language reference](README.md).

**Syntax:** `<input> | restrict <predicate>`

Keeps rows of `<input>` for which `<predicate>` evaluates to true.
The predicate is any expression that resolves to a Bool; see the
[expression reference](README.md) for the full grammar. The
short version: literals, column references, comparisons (`=`, `<>`,
`<`, `<=`, `>`, `>=`), and the boolean operators `and`, `or`, `not`.
Output schema and column qualifiers are `<input>`'s, unchanged.

```
> users | restrict id = 1
relation (users.id: int64, users.name: string, users.email: string, users.active: bool, primary key (id)) {
  (users.id = 1, users.name = "Alice", users.email = "alice@example.com", users.active = true)
}
```

A predicate that doesn't resolve to a Bool is a type error, caught
before the query runs:

```
> users | restrict name
error: Restrict: predicate position requires Bool, got String
```
