# String

A scalar type. Part of the [query-language reference](README.md).

`string` is a sequence of bytes. Literals are double-quoted; the only
recognised escapes are `\"` (a literal double-quote) and `\\` (a
literal backslash), and other backslash sequences are rejected.
String comparison is lexicographic by byte. It is one of the three
scalar types, alongside [Int64](int64.md) and [Bool](bool.md).

```
> "hello" | type
string
```
