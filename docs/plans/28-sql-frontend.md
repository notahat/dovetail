# 28 — SQL frontend: SELECT / FROM / WHERE (single table)

The first SQL slice. Adds a second surface language alongside the
relational-algebra (RA) pipeline language, fulfilling the foundational
goal of "two surfaces, one algebraic IR". This slice delivers
`SELECT ... FROM <table> [WHERE <predicate>]` over a single table, with
no joins, no aliasing, no aggregation, and no SQL-side DML/DDL.

## Scope

In scope:

- `SELECT * FROM t`
- `SELECT a, b FROM t`
- `SELECT a, b FROM t WHERE <predicate>`
- A new `surface_sql` sub-library: `ast`, `parser`, `lower`.
- A `--sql` launch flag selecting the surface for the session.

Out of scope (later slices, noted so the boundaries are explicit):

- Joins, comma-FROM, multiple tables — qualified column references
  (`users.name`) land with joins, where they earn their keep.
- `AS` aliasing and computed select-list expressions (`a + 1 AS x`) —
  no IR target today (no `Rename`; `Projection.t` is a bare
  `column_reference list`).
- Aggregation, `GROUP BY`, `HAVING`, `ORDER BY`, `LIMIT`, `DISTINCT`.
- SQL-syntax `INSERT` / `CREATE TABLE` / `DROP TABLE` (the IR supports
  them; this is purely deferred parser surface).
- `NULL` / `IS NULL` / three-valued logic — no `option` scalar kind
  exists yet.
- SQL comments (`-- ...`), multi-statement lines, keyword-as-identifier
  edge cases.

## Decisions (from the planning interview)

1. **Peer surfaces.** SQL and RA coexist indefinitely; both lower to the
   same `Dovetail_plan.Logical.t`. RA stays as the close-to-the-metal
   surface; SQL is the familiar one.
2. **Launch-time surface flag.** `./dovetail --sql` selects SQL for the
   session; default (no flag) stays RA. One surface per REPL run — no
   per-line auto-detection, no stateful mode command. This keeps faith
   with the project's removal of `:`-style meta-commands.
3. **First slice = SELECT / FROM / WHERE, single table.** Lowers to the
   existing `Scan` / `Restrict` / `Project` logical operators. No new IR.
4. **SQL-standard lexis.** Single-quoted string literals (`'alice'`),
   case-insensitive keywords (`SELECT` = `select`), both `<>` and `!=`
   accepted for not-equal. Lowers to the shared
   `Dovetail_core.Expression.t`.
5. **Case-sensitive identifiers.** Table and column names are matched
   byte-for-byte against the catalog (which RA populates). No case
   folding, no quoted-identifier handling this slice. Documented
   divergence from Postgres; there's no SQL DDL yet to anchor a folding
   convention.
6. **New `surface_sql` sub-library**, mirroring `surface_ra`
   (`ast` / `parser` / `lower`, built on `angstrom`). Shares only
   `core` (Expression, Row, Scalar) and `plan` (Logical) — nothing
   shared with `surface_ra`. The and/or/not/compare grammar is
   duplicated rather than extracted; a shared surface-expression module
   is a future refactor if a third surface or drift makes it pay.
7. **`SELECT *` is identity** — lowers to the bare FROM/WHERE sub-plan
   with no `Project` node, preserving the primary key and set/bag tag.
   `SELECT a, b` lowers to `Project([a; b], ...)`. This matches RA
   semantics exactly (RA users omit the `project` step to keep
   everything).
8. **REPL dispatch by variant tag.** `Repl.run` gains
   `~surface:[ \`Ra | \`Sql ]`; the REPL matches and calls the right
   `Parser` / `Lower` pair internally. The `frontend` library depends on
   both surface libs.
9. **Optional trailing semicolon.** `SELECT * FROM t` and
   `SELECT * FROM t;` parse identically; trailing junk after `;` is a
   parse error. The whole line must still parse as one statement.
10. **Prompt `sql> `** for the SQL session (RA keeps `> `), so
    transcripts show which surface is live. Derived from the surface tag.
11. **WHERE predicate mirrors RA's expression sublanguage.**
    Comparisons (`=`, `<>`/`!=`, `<`, `<=`, `>`, `>=`), boolean
    `AND` / `OR` / `NOT`, parentheses, and a bare boolean column or
    `TRUE`/`FALSE` as a standalone predicate (`WHERE is_active`). A
    non-boolean atom in predicate position is rejected at the logical
    layer via the existing `Typecheck` path — same as RA.
12. **Bare columns only** in SELECT and WHERE this slice; `users.name`
    is a parse error (deferred to the joins slice).
13. **Reuse existing REPL error prefixes.** angstrom failures print
    `parse error: ...`; lowering/typecheck/eval failures print
    `error: ...` (or their module prefix, e.g. `Scan:`, `Typecheck:`).
    No SQL-specific prefix — the prompt already conveys the surface.

## Surface grammar (this slice)

```
statement   := select_stmt ";"?
select_stmt := SELECT select_list FROM identifier (WHERE predicate)?
select_list := "*" | column ("," column)*
column      := identifier                      (* bare only this slice *)
predicate   := or_expr                         (* same shape as RA *)
or_expr     := and_expr (OR and_expr)*
and_expr    := not_expr (AND not_expr)*
not_expr    := NOT not_expr | comparison
comparison  := atom (cmp_op atom)?             (* bare atom allowed *)
cmp_op      := "=" | "<>" | "!=" | "<" | "<=" | ">" | ">="
atom        := int64_lit | string_lit | TRUE | FALSE | column | "(" predicate ")"
string_lit  := "'" ... "'"                     (* single-quoted *)
```

Keywords (`SELECT FROM WHERE AND OR NOT TRUE FALSE`) are
case-insensitive. Identifiers are case-sensitive. Int64 literals and
single-quoted strings only — no floats/decimals (matches the
`Int64 | String | Bool` scalar kinds).

## SQL AST shape (sketch)

A single-statement AST for now. The expression AST mirrors
`Surface_ra.Ast.expression` (its own copy, SQL-lexed):

```
type expression =
  | Literal of Scalar.value
  | Column of column_reference            (* qualifier always None this slice *)
  | Compare of { left; op; right }
  | And of expression * expression
  | Or of expression * expression
  | Not of expression

type select_list = All | Columns of column_reference list

type t =
  | Select of {
      select_list : select_list;
      from : string;
      where : expression option;
    }
```

## Lowering (`surface_sql/lower.ml`)

`Select { select_list; from; where }` lowers to:

```
let base = Logical.Scan { table = from } in
let filtered =
  match where with
  | None -> base
  | Some predicate -> Logical.Restrict { input = base; predicate = lower_expr predicate }
in
match select_list with
| All -> filtered
| Columns cols -> Logical.Project { input = filtered; columns = lower_cols cols }
```

`lower_expr` maps the SQL expression AST onto `Core.Expression.t`
(identical structure to `Surface_ra.Lower.lower_expression`). Both `<>`
and `!=` map to the same not-equal operator.

## Steps (walking skeleton: thin end-to-end first, then extend)

Build the thinnest end-to-end path — `SELECT * FROM t` running through
the binary — before widening the grammar. Steps 1–5 stand up that
skeleton (library bottom-up, then wired through the REPL, cli, and bin);
steps 6–9 extend it with `WHERE` and column-list projection, each adding
its own integration coverage now that the pipeline is live.

Within the library, **parse and lower are separate steps**: each feature
lands its parse-to-AST half (with its parser unit test) before its
lower-to-`Logical` half (with its lower unit test). Each step ends green,
stays well under the ~5-file / ~200-line ceiling, and is one layer of one
feature. TDD throughout: failing test first.

The feature order is `SELECT *` → `WHERE` → column-list, so each lower
step targets exactly one new logical operator (none → `Restrict` →
`Project`).

### Skeleton: `SELECT * FROM t` end-to-end

**Step 1 — scaffold + parse `SELECT * FROM t`.**
New `lib/surface_sql/` with `dune` mirroring `surface_ra`'s
(`(name dovetail_surface_sql)`, `(public_name dovetail.surface_sql)`,
`(libraries dovetail.core dovetail.plan angstrom)`). Add `ast.ml(i)`
with just the `Select`/`select_list` shape needed for `*`, and
`parser.ml(i)` parsing `SELECT * FROM <identifier>` with optional
trailing `;`, case-insensitive keywords, case-sensitive identifier. New
`test/surface_sql/dune` + `test_parser.ml`. (Largest library step, since
it creates the lib + test scaffolding, but the parser itself is one
production.)

**Step 2 — lower `SELECT *` → `Scan`.**
Add `lower.ml(i)`: `Select { select_list = All; from; where = None }` →
`Logical.Scan { table = from }` (the identity case — no `Project`). New
`test_lower.ml`. (~2 files.)

**Step 3 — REPL surface seam (SQL first runnable in-process).**
`repl.ml` / `repl.mli`: add `~surface:[ \`Ra | \`Sql ]` to `run`;
`process_line` matches the tag to pick the Parser/Lower pair; the prompt
derives from the tag (`sql> ` vs `> `). `frontend`'s `dune` gains
`dovetail.surface_sql`. A `test/frontend/` test drives an in-process SQL
session through `Repl.run ~surface:\`Sql` and asserts on output — this is
where SQL first runs end-to-end, without touching `cli` or `bin`.

**Step 4 — `--sql` cli flag.**
`cli.ml`: add `sql : bool` to `options`, parse `--sql` (reject
duplicates, mirroring the existing flags), expose a `sql_flag` constant.
`test/frontend/` cli test for the new flag and its duplicate-rejection.
No behaviour change to the REPL yet — just argument parsing.

**Step 5 — bin wire + first integration test.**
`bin/main.ml`: destructure the new `sql` field, pass
`~surface:(if sql then \`Sql else \`Ra)` into `Repl.run`, add `--sql` to
the `usage` string. `test/integration/dune` gains `dovetail.surface_sql`;
an integration test runs a real `--sql` session through `bin/main.exe`
against a fixture, asserting `SELECT * FROM t` prints the fixture rows
and a no-such-table query prints an `error:`. After this step SQL is a
fully wired, demoable surface — every later step extends a live pipeline.

### Extend: `WHERE`, then column-list projection

**Step 6 — parse `WHERE <predicate>`.**
Extend the parser with the expression sublanguage: comparisons,
`AND`/`OR`/`NOT`, parens, single-quoted strings, `<>`/`!=`,
`TRUE`/`FALSE`, bare boolean atom. Extend `ast` with the `expression`
type and `where` field. Parser unit tests cover precedence and
associativity, mirroring the RA expression tests. (parser + ast + test.)

**Step 7 — lower `WHERE` → `Restrict`.**
`Some predicate` → `Logical.Restrict` wrapping the lowered expression;
`lower_expr` maps the SQL expression AST onto `Core.Expression.t` (both
`<>` and `!=` → not-equal). Lower unit tests, plus an integration case:
`SELECT * FROM t WHERE <pred>` filters rows, `WHERE is_active` (bare bool
col) works, and a non-bool atom yields a typecheck `error:`.
(lower + test.)

**Step 8 — parse column-list select.**
Extend the select-list grammar to `column ("," column)*`; `ast`'s
`select_list` gains the `Columns` arm. Parser unit tests, including that
`*` and a column list parse distinctly. (parser + ast + test.)

**Step 9 — lower column-list → `Project`.**
`Columns cols` → `Logical.Project { input; columns }`; `*` still lowers
to no `Project`. Lower unit tests for column order and the `*`-vs-columns
distinction, plus an integration case: `SELECT a, b FROM t` projects in
column order, and an unknown column yields a typecheck `error:`.
(lower + test.)

## Testing

Per the project pattern, tests land with the step that introduces the
behaviour they cover, at the lowest layer that can prove it:

- **Library unit tests (`test/surface_sql/`)** carry the bulk. The
  parser steps (1, 6, 8) extend `test_parser.ml`; the lower steps
  (2, 7, 9) extend `test_lower.ml`. The suite needs its own `dune`
  (alcotest + the libraries it touches) and, per the test-aliasing
  convention, opens the library under test (`Dovetail_surface_sql`).
- **Frontend tests (`test/frontend/`)** cover the REPL seam (step 3,
  an in-process `Repl.run ~surface:\`Sql` session) and the cli flag
  (step 4).
- **Integration tests (`test/integration/`)** run real `--sql` sessions
  through `bin/main.exe`: the skeleton end-to-end pass lands in step 5
  (`SELECT *` + no-such-table `error:`), with `WHERE` (step 7) and
  projection (step 9) adding their own cases as those features land.
  `test/integration/dune` gains `dovetail.surface_sql`; integration
  tests alias every library with `module X = Dovetail_X` (no single SUT).

The redundancy between the in-process frontend test and the subprocess
integration tests is intentional and consistent with the project's
existing per-layer + end-to-end pattern.

## Open follow-ups (future slices, not this one)

- Joins + qualified refs + table aliases (`FROM a, b` / `JOIN ON`).
- `AS` aliasing and computed select-list — needs a `Rename` /
  generalised-projection IR addition.
- SQL `INSERT VALUES` / `CREATE TABLE` / `DROP TABLE`.
- Aggregation / `GROUP BY` / `HAVING` / `ORDER BY` / `LIMIT` /
  `DISTINCT`.
- `NULL` semantics once an `option` scalar kind exists.
- Possible extraction of a shared surface-expression grammar if drift
  between the two hand-written expression parsers becomes a maintenance
  cost.
