# create table

A pipeline sink. Part of the [query-language reference](README.md).

**Syntax:** `<type-expression> | create table <table-name>` (empty
form) or `<value-pipeline> | create table <table-name>` (seeded
form).

Adds a new table to the catalog. The empty form takes a relation
type on the left (a parenthesised `<name>: <type>` list with
optional refinements like `primary key (...)`) and creates an empty
table of that type. The seeded form takes any value-yielding
pipeline; the new table's type is derived from the upstream's row
type, and its rows are the upstream's rows. Either form yields a
one-row relation `(created: string)` reporting the new table's
name.

The seeded form rejects sources whose row type carries qualifiers
-- pipe through `unqualify` first if the upstream is a base
relation -- and rejects sources whose derived type has no primary
key. A primary key is required because tables are index-organised.

```
> (id: int64, name: string, primary key (id)) | create table widgets
relation (created: string) {
  (created = "widgets")
}
> users | unqualify | create table users_copy
relation (created: string) {
  (created = "users_copy")
}
```

A declared type with no primary key is rejected — every table must be
index-organised on one:

```
> (name: string) | create table bad
error: Create table: "bad": primary key is empty
```
