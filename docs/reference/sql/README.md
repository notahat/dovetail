# SQL reference

One file per item: the `SELECT` statement, each of its clauses, and the
expression forms that appear in a `WHERE` predicate. This is the SQL
surface; for Dovetail's other, fuller query surface see the
[relational-algebra reference](../ra/README.md). Both surfaces read
against the same
[example tables](../../tutorial/README.md#the-example-tables) and lower
to the same engine, so the typing and evaluation rules are shared --
only the syntax and the result formatting differ.

The SQL surface is selected at launch with `--sql`:

```
./dovetail --demo-data --sql dovetail-data
```

The prompt becomes `sql> ` and one statement is read per line. Today the
only statement is `SELECT`, over a single table. Keywords (`SELECT`,
`FROM`, `WHERE`, `AND`, `OR`, `NOT`, `TRUE`, `FALSE`) are
case-insensitive; identifiers -- table and column names -- are matched
case-sensitively against the catalog. A single trailing semicolon is
accepted.

Results render as a PostgreSQL-style table: a header of bare column
names, a dashed rule, then the rows -- integers right-aligned, strings
and booleans left-aligned -- and a trailing `(N rows)` count. Booleans
show as `true` / `false`.

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

## Statement

- [SELECT](select.md) — read rows from one table, with its select list,
  `FROM`, and optional `WHERE` clauses

## Expressions

The `WHERE` predicate is an expression sublanguage: comparisons, the
boolean connectives, parentheses, and a bare boolean column or literal
as a standalone predicate. It is the same set of operators and the same
precedence as the relational-algebra surface's expressions; the lexical
differences are single-quoted string literals and case-insensitive
keywords.

- [Literals](literals.md) — `42`, `'hello'`, `true`, `false`
- [Column references](column-references.md) — `id`
- [Comparisons](comparisons.md) — `=`, `<>`/`!=`, `<`, `<=`, `>`, `>=`
- [Boolean operators](boolean-operators.md) — `and`, `or`, `not`
- [Parentheses](parentheses.md) — grouping to override precedence
- [Precedence and associativity](precedence.md) — how the forms bind

## Types

The data model is shared with the relational-algebra surface: a `SELECT`
produces a relation of rows whose columns carry the same scalar types.
Those types have one description, in the RA reference:

- [Int64](../ra/int64.md), [String](../ra/string.md),
  [Bool](../ra/bool.md) — the scalar types
- [Row type](../ra/row-type.md),
  [Relation type](../ra/relation-type.md) — a row's columns, and a
  relation's row type plus its refinements
