# drop table

A pipeline sink. Part of the [query-language reference](README.md).

**Syntax:** `drop table <table-name>`

Removes `<table-name>` from the catalog and reclaims its storage,
and yields a one-row relation `(dropped: string)` reporting the
dropped table's name. Unlike the other sinks `drop table` takes
no upstream -- nothing sits to its left, and the whole pipeline
is just `drop table <name>`.

The example creates a throwaway table first, so it stands on its own:

```
> (id: int64, primary key (id)) | create table widgets
relation (created: string) {
  (created = "widgets")
}
> drop table widgets
relation (dropped: string) {
  (dropped = "widgets")
}
```
