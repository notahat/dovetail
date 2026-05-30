# Column references

An expression form. Part of the [SQL reference](README.md).

**Syntax:** `<column-name>`

Names a column of the `FROM` table. A column reference is a bare
identifier today -- the qualified `users.id` form is a parse error,
because a single table never needs disambiguation. Identifiers are
matched case-sensitively against the table's columns, so `name` and
`NAME` are different (and the latter is an unknown column unless the
table really has it). Qualified references arrive with joins.

A boolean column used as a predicate stands alone -- no `= true` needed:

```
sql> SELECT name, id FROM users WHERE active and not id = 4
 name  | id 
-------+----
 Alice |  1 
 Carol |  3 
(2 rows)
```
