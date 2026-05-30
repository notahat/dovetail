# Int64

A scalar type. Part of the [query-language reference](README.md).

`int64` is a signed 64-bit integer. Literals are signed decimal with
no separate unsigned form: `-1`, `0`, `42`. It is one of the three
scalar types, alongside [String](string.md) and [Bool](bool.md).

Ask any int64-valued pipeline for its type with `| type`:

```
> 42 | type
int64
```
