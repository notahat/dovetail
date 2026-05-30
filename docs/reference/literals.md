# Literals

An expression form. Part of the [query-language reference](README.md).

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
