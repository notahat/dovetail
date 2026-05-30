# Bool

A scalar type. Part of the [query-language reference](README.md).

`bool` is a truth value, written `true` or `false`. The ordering
operators (`<`, `<=`, `>`, `>=`) reject Bool operands; only `=` and
`<>` compare bools. It is one of the three scalar types, alongside
[Int64](int64.md) and [String](string.md).

```
> true | type
bool
```
