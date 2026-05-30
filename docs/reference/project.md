# project

A pipeline operator. Part of the [query-language reference](README.md).

**Syntax:** `<input> | project <column-list>`

Keeps only the named columns from `<input>`, in the order listed.
Each entry is either a bare name (`name`) or qualified
(`users.name`); see the
[projection reference](expressions.md#projections)
for the precise rules. Bare names must resolve unambiguously
against `<input>`'s schema, duplicates in the column list are
rejected, and each retained column keeps its qualifier from
`<input>`.

```
> users | project name, email
relation (users.name: string, users.email: string) {
  (users.name = "Alice", users.email = "alice@example.com"),
  (users.name = "Bob", users.email = "bob@example.com"),
  (users.name = "Carol", users.email = "carol@example.com"),
  (users.name = "Dave", users.email = "dave@example.com"),
  (users.name = "Eve", users.email = "eve@example.com")
}
```
