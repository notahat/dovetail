# Scalar literals

A pipeline source. Part of the [query-language reference](README.md).

**Syntax:** `<int64-literal>` | `"<string-literal>"` | `true` | `false`

A bare scalar at the head of a pipeline yields that scalar value.
The supported forms are the same three the
[expression reference](expressions.md#literals)
describes: signed decimal integers, double-quoted strings (with
`\"` and `\\` escapes), and the keywords `true` and `false`. The
only operator that consumes a scalar is `type`, which yields the
scalar's type.

```
> 42
42
> "hello"
"hello"
> true
true
> 42 | type
int64
```
