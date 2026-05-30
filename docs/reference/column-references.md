# Column references

An expression form. Part of the [query-language reference](README.md).

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
