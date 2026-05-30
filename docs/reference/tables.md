# tables

A pipeline operator. Part of the [query-language reference](README.md).

**Syntax:** `<input> | tables`

Takes a catalog on the left and yields a one-column relation
`(name: string)` with one row per table, in the catalog's cursor
order. `<input>` must be a catalog; any other input is a user-facing
error. The canonical use is `catalog | tables` for a quick "what
tables exist" listing.

```
> catalog | tables
relation (name: string) {
  (name = "orders"),
  (name = "users")
}
```
