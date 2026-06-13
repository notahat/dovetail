# SQL: a familiar surface on the same engine

Part of the [query-language tutorial](README.md). The
[walkthrough](walkthrough.md) and [tables chapter](tables.md) use the
relational-algebra (RA) pipeline surface. Dovetail also speaks a small
dialect of SQL, and this chapter shows the same query both ways — to
make concrete that the two surfaces are front ends over *one* engine,
not two databases.

Launch the REPL with `--sql` to get the SQL surface: a psql-style
`sql>` prompt and bordered result tables.

```
./dovetail --demo-data --sql dovetail-data
```

The supported surface is a single-table `SELECT <list> FROM <table>
[WHERE <predicate>]` — no joins, grouping, or ordering yet. Keywords
are case-insensitive (`select` = `SELECT`); table and column names are
case-sensitive; string literals use single quotes. The full grammar is
in the [SQL reference](../reference/sql/README.md).

## The same query, both ways

Here is the walkthrough's active-users filter and projection on the RA
surface, naming the table and chaining `restrict` and `project` with
`|`:

```
> users | restrict active | project name, email
relation (users.name: string, users.email: string) {
  (users.name = "Alice", users.email = "alice@example.com"),
  (users.name = "Carol", users.email = "carol@example.com"),
  (users.name = "Dave", users.email = "dave@example.com")
}
```

The same question in SQL — a `WHERE` for the filter, a select list for
the projection:

```
sql> SELECT name, email FROM users WHERE active
 name  |       email       
-------+-------------------
 Alice | alice@example.com 
 Carol | carol@example.com 
 Dave  | dave@example.com  
(3 rows)
```

Identical rows, different dressing. The RA surface prints the
relation-literal form (the same syntax you could type back in as
input); the SQL surface prints an aligned table with a trailing row
count, strings unquoted and booleans spelled `true`/`false`. Underneath
both lower to the very same scan/restrict/project plan and run through
the same evaluator — `WHERE` *is* `restrict`, and the select list *is*
`project`. The [SQL frontend](../internals/sql-frontend.md) internals
note traces how the lowering lines up.

## `SELECT *` keeps everything

A bare `*` selects every column, with no projection step at all:

```
sql> SELECT * FROM users WHERE active
 id | name  |       email       | active 
----+-------+-------------------+--------
  1 | Alice | alice@example.com | true   
  3 | Carol | carol@example.com | true   
  4 | Dave  | dave@example.com  | true   
(3 rows)
```

This is more than a convenience. A projection that happened to list
every column would still *be* a projection — it would drop the
relation's primary key and downgrade its set/bag character. `SELECT *`
lowers with no projection node, so it faithfully means "keep
everything", primary key and all — exactly as omitting the `project`
step does on the RA side.

## What SQL can't do yet

The SQL surface is deliberately small. Joins, aggregation, `ORDER BY`,
and SQL-side `CREATE`/`INSERT`/`DROP` are not built — the walkthrough's
final join, and the table-building of the [tables chapter](tables.md),
stay on the RA surface for now. The shared IR is what makes growing SQL
toward them a matter of lowering more syntax onto operators the engine
already runs, rather than building a second engine. The
[SQL reference](../reference/sql/README.md) documents exactly what the
surface accepts today.
