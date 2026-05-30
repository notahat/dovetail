# Relation literals

A pipeline source. Part of the [query-language reference](README.md).

**Syntax:** `relation (<row-type> [, <refinement>...]) { <row-literal>, ... }`

A `relation` keyword followed by a parenthesised relation type and
a brace-delimited body of row literals yields a relation of that
type. The head's parenthesised list is a row type (`<name>: <type>`
declarations) optionally interleaved with refinements (today just
`primary key (...)`); the body is zero or more row literals,
comma-separated, with a permitted trailing comma. Every row's
fields must be a permutation of the declared row type's fields,
and each value must match its field's type. The empty body is
allowed and produces a header-only table.

Relation literals are the form `insert into` accepts as its
upstream; see [`insert into`](insert-into.md).

```
> relation (id: int64, name: string) { (id = 1, name = "alice"), (id = 2, name = "bob") }
relation (id: int64, name: string) {
  (id = 1, name = "alice"),
  (id = 2, name = "bob")
}
> relation (id: int64, name: string) {} | type
(id: int64, name: string)
```
