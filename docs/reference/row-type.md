# Row type

A composite type. Part of the [query-language reference](README.md).

A row type is an ordered list of named, typed columns, written
`(name: type, ...)`. The empty row type is `()`. It is what `| type`
reports for a [row literal](row-literal.md).

```
> (id = 1, name = "alice") | type
(id: int64, name: string)
```
