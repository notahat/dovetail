# SQL frontend

Dovetail has two surface languages — the relational-algebra (RA)
pipeline language and SQL — and they meet at a single shared IR:
both lower to the same [`Logical.t`](../../lib/plan/logical.mli).
This doc explains how the SQL surface in
[`lib/surface_sql/`](../../lib/surface_sql/) is structured and the
design choices that keep it a thin front end over the existing
algebra rather than a second engine.

The supported surface today is `SELECT <list> FROM <table> [WHERE
<predicate>]` over a single table — no joins, aggregation, ordering,
or SQL-side DDL/DML. The [SQL reference](../reference/sql/README.md)
documents the surface for users; this doc is about the
implementation.

## Two surfaces, one algebra

The foundational goal is "two surfaces, one algebraic IR". RA stays
the close-to-the-metal surface; SQL is the familiar one. They coexist
indefinitely, and crucially they share *only* `core` (Expression,
Row, Scalar) and `plan` (Logical) — `surface_sql` and `surface_ra`
share nothing with each other.

That independence is a deliberate cost. The boolean/comparison
expression grammar is duplicated between the two surfaces' parsers
and ASTs rather than extracted into a shared module. The bet is that
a hand-written grammar per surface is cheaper to maintain than a
shared abstraction until a third surface arrives or the two
hand-written parsers actually drift. The duplication is called out in
[`ast.mli`](../../lib/surface_sql/ast.mli) so it reads as a decision,
not an accident.

## Parse / lower separation

The pipeline mirrors the RA surface: `Parser` (built on `angstrom`)
produces an `Ast.t`; `Lower` translates that AST to `Logical.t`. The
two halves are kept strictly separate — the parser knows SQL syntax
and nothing about algebra; the lowerer knows the AST-to-IR mapping
and nothing about angstrom.

The SQL `Ast.t` is its own type, structurally close to the RA AST's
expression sublanguage but lexed for SQL. A `Select` node carries a
`select_list` (`All` or `Columns`), a bare `from` table name, and an
optional `where` expression.

### Lexis worth noting

The parser follows SQL convention where it cheaply can, and documents
where it diverges:

- **Keywords are case-insensitive** (`SELECT` = `select`),
  identifiers are **case-sensitive** — table and column names are
  matched byte-for-byte against the catalog. This diverges from
  PostgreSQL's case-folding; there is no SQL DDL yet to anchor a
  folding convention, so the simpler rule wins for now.
- **String literals are single-quoted** (`'alice'`), matching SQL
  rather than RA's double quotes.
- **Both `<>` and `!=`** spell not-equal; they produce the same
  `NotEqual` AST node and lower to the same operator.
- **A trailing semicolon is optional**; junk after it is a parse
  error.
- **Bare columns only** — `users.name` is a parse error this slice,
  deferred to when joins make qualified references earn their keep.

## Lowering targets the shared IR

`Lower` adds no new logical operators — it composes the existing
`Scan` / `Restrict` / `Project`. From
[`lower.ml`](../../lib/surface_sql/lower.ml), a `Select` becomes a
`Scan` of the FROM table, optionally wrapped in a `Restrict` for the
WHERE clause, optionally wrapped in a `Project` for a column list:

```ocaml
let scan = Scan { table = from } in
let filtered = match where with
  | None -> scan
  | Some predicate -> Restrict { input = scan; predicate = lower_expression predicate }
in
match select_list with
| All -> filtered
| Columns columns -> Project { input = filtered; columns = lower_projection columns }
```

### `SELECT *` is identity

`SELECT *` lowers to the bare FROM/WHERE sub-plan with **no `Project`
node**. This is not an optimisation — it is the correct lowering. A
`Project` over every column would drop the relation's primary key and
downgrade its set/bag multiplicity (projection can introduce
duplicates), so emitting one for `*` would change the result's
algebraic properties. Omitting it keeps `SELECT *` faithful to "keep
everything", and matches RA exactly: an RA user omits the `project`
step for the same reason.

Because lowering targets the same `Logical.t`, everything downstream
is shared with no SQL awareness: the same `Typecheck` pass validates
the plan (a non-boolean WHERE predicate is rejected there, same as
RA), the same `Translate` picks execution strategies (a
`WHERE id = 5` on a primary key becomes an `IndexLookup` for free —
see [optimization.md](optimization.md)), and the same executor runs
it.

## The REPL seam and result rendering

`Repl.run` takes `~surface:[ `Ra | `Sql ]`. The REPL matches the tag
to pick the Parser/Lower pair, and derives the prompt from it
(`sql> ` versus `> `) so a transcript shows which surface is live.
One surface per session, chosen by the `--sql` launch flag — there is
no per-line auto-detection and no stateful mode command, keeping
faith with the project's removal of `:`-style meta-commands.

Errors reuse the existing REPL prefixes: angstrom failures print
`parse error: ...`, and lowering/typecheck/eval failures print
`error: ...` (or their module prefix, e.g. `Scan:`). There is no
SQL-specific error prefix — the prompt already conveys the surface.

The one piece of genuinely SQL-specific presentation is the result
table. A `--sql` session renders a result relation through
[`Sql_table`](../../lib/frontend/sql_table.mli) as the aligned text
table a psql user expects: centred bare-name headers over a dashed
rule, int64 cells right-aligned and string/bool cells left-aligned, a
trailing `(N rows)` count. Two deliberate divergences from a raw
scalar rendering: strings appear unquoted so the table reads as data,
and booleans render as `true`/`false` (this project's spelling)
rather than psql's `t`/`f`.

`Sql_table` lives in `frontend`, not `core`, precisely because it is
a presentation *policy* of the SQL surface rather than a canonical
value form — unlike `Relation.format`, its output does not round-trip
as input. The RA surface keeps the relation-literal form, which does.
Headers show the bare field name with any qualifier stripped, which
is safe only while results are single-table (no two columns can
collide on their bare name); qualified-name display returns with
joins.
