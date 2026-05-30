# Row literals

A pipeline source. Part of the [query-language reference](README.md).

**Syntax:** `(<name> = <scalar>, ...)`

A parenthesised, comma-separated list of `<name> = <value>`
bindings yields a single row whose fields are those bindings, in
written order. The empty form `()` yields the empty row. Field
names must be unique within the literal; values are scalar
literals (no expressions or column references at the row-literal
level). The only operator that consumes a row is `type`, which
yields the row's type.

```
> (id = 1, name = "alice")
(id = 1, name = "alice")
> (id = 1, name = "alice") | type
(id: int64, name: string)
> ()
()
```
