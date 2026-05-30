# type

A pipeline operator. Part of the [query-language reference](README.md).

**Syntax:** `<input> | type`

Yields `<input>`'s type rather than its value -- no cursors open,
no rows are pulled. `<input>` can be a scalar, a row, a relation,
or a catalog; the output renders in the surface type-expression
syntax appropriate to the input's rung (a bare type name like
`int64` for a scalar, a parenthesised field list for a row or
relation, a `catalog { ... }` for a catalog).

The one rung `type` does not accept is its own output: piping a
type back through `type` (`<input> | type | type`) is rejected,
because the second `type`'s input is already a type.

```
> users | type
(users.id: int64, users.name: string, users.email: string, users.active: bool, primary key (id))
```
