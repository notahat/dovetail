# Relation type

A composite type. Part of the [query-language reference](README.md).

A relation type is a row type plus any refinements on the contents --
today just `primary key (...)`. Columns scanned from a table carry a
qualifier (`users.id` rather than bare `id`). It is what `| type`
reports for a relation.

```
> users | type
(users.id: int64, users.name: string, users.email: string, users.active: bool, primary key (id))
```
