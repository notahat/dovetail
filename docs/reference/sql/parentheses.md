# Parentheses

An expression form. Part of the [SQL reference](README.md).

**Syntax:** `( <expression> )`

Group a sub-expression to override the default
[precedence](precedence.md). A parenthesised expression is an atom: it
binds as tightly as a literal or a column reference, so it can sit
anywhere one of those can.

Without parentheses, `and` binds tighter than `or`, so
`id = 2 or id = 1 and active` reads as `id = 2 or (id = 1 and active)`:

```
sql> SELECT id FROM users WHERE id = 2 or id = 1 and active
 id 
----
  1 
  2 
(2 rows)
```

Parenthesising the `or` changes which rows survive:

```
sql> SELECT id FROM users WHERE (id = 2 or id = 1) and active
 id 
----
  1 
(1 row)
```
