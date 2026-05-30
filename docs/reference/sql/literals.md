# Literals

An expression form. Part of the [SQL reference](README.md).

**Syntax:** `42` (Int64) | `'hello'` (String) | `true` / `false` (Bool)

The three scalar literal forms that can appear in a predicate:

- **Int64** -- one or more digits, with an optional leading `-`. Out-of-
  range values are a parse error rather than a silent wraparound.
- **String** -- single-quoted, as in standard SQL. The double-quoted
  form is not a string here. Embedded quotes are not yet supported, so a
  string containing a `'` is a parse error.
- **Bool** -- `true` or `false`, case-insensitive (`TRUE`, `False`, and
  `true` are the same literal).

A bare `true` or `false` is itself a valid predicate, though rarely a
useful one. String literals usually appear on one side of a comparison:

```
sql> SELECT * FROM users WHERE name = 'Alice'
 id | name  |       email       | active 
----+-------+-------------------+--------
  1 | Alice | alice@example.com | true   
(1 row)
```
