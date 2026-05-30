# SELECT

A statement. Part of the [SQL reference](README.md).

**Syntax:** `SELECT <select-list> FROM <table> [WHERE <predicate>]`

Reads rows from a single table and returns them. A statement is a select
list, a `FROM`, and an optional `WHERE`, in that order; a single trailing
semicolon is accepted. This is the only statement the SQL surface
understands today: one table, no joins, no aggregation, no `ORDER BY` or
`LIMIT`. It lowers to the same logical plan the relational-algebra
surface builds -- a scan, an optional restrict, an optional projection --
so the same catalog lookup, type checking, and evaluation apply, and the
same errors surface.

```
sql> SELECT * FROM users
 id | name  |       email       | active 
----+-------+-------------------+--------
  1 | Alice | alice@example.com | true   
  2 | Bob   | bob@example.com   | false  
  3 | Carol | carol@example.com | true   
  4 | Dave  | dave@example.com  | true   
  5 | Eve   | eve@example.com   | false  
(5 rows)
```

## Select list

Chooses which columns the result keeps. `*` keeps every column of the
table, in its natural order. A comma-separated list keeps only the named
columns, in the order written -- so the list is also how you reorder
columns. It must name at least one column; leading and trailing commas
are rejected. Columns are bare names (see
[column references](column-references.md)); a column-list select lowers
to a projection.

```
sql> SELECT name, email FROM users
 name  |       email       
-------+-------------------
 Alice | alice@example.com 
 Bob   | bob@example.com   
 Carol | carol@example.com 
 Dave  | dave@example.com  
 Eve   | eve@example.com   
(5 rows)
```

Naming a column the table does not have is an error:

```
sql> SELECT nope FROM users
error: Project: unknown column "nope"
```

## FROM

Names the table to read: a single bare table name, matched
case-sensitively against the catalog and read in primary-key order. A
single table is the only shape today -- no joins, comma-separated table
lists, or subqueries.

```
sql> SELECT * FROM nonexistent
error: Scan: unknown table "nonexistent"
```

## WHERE

The optional `WHERE` clause keeps only the rows for which its predicate
is true; the result keeps the table's columns unchanged. The predicate is
an expression that must resolve to a Bool -- a
[comparison](comparisons.md), the
[boolean operators](boolean-operators.md) `and` / `or` / `not`, or as the
simplest case a bare boolean column or literal standing alone. The
expression pages linked from the [reference index](README.md) cover the
full grammar.

```
sql> SELECT * FROM users WHERE active
 id | name  |       email       | active 
----+-------+-------------------+--------
  1 | Alice | alice@example.com | true   
  3 | Carol | carol@example.com | true   
  4 | Dave  | dave@example.com  | true   
(3 rows)
```

A non-boolean predicate is rejected:

```
sql> SELECT * FROM users WHERE id
error: Restrict: predicate position requires Bool, got Int64
```
