# insert into

A pipeline sink. Part of the [query-language reference](README.md).

**Syntax:** `<input> | insert into <table-name>`

Writes every row of `<input>` to `<table-name>` and returns a one-row
relation `(insert_count: int64)` reporting how many rows were
written. `<input>` is currently a relation literal of the form
`relation (column: type, ...) { (column = value, ...), ... }`; the
literal's columns must be a permutation of the target's columns, and
each value must match its target column's type. Arbitrary upstream
pipelines (insert-from-query) are deferred to a later slice.

```
> relation (id: int64, user_id: int64, description: string, amount: int64) { (id = 7, user_id = 4, description = "Muffin", amount = 2) } | insert into orders
relation (insert_count: int64) {
  (insert_count = 1)
}
```

The literal's columns must be a permutation of the target's. A source
missing target columns is rejected before any rows are written:

```
> relation (id: int64, name: string) { (id = 1, name = "x") } | insert into users
error: Insert: into "users": missing column(s): email, active
```
