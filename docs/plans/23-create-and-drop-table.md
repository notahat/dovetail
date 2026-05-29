# Slice 23: `create table` and `drop table` as pipeline operators

Lands the pipe-form for `create table` and `drop table` from
[`docs/design/type-system.md`](../design/type-system.md). Retires the
corresponding `:`-sigil DDL statements.

Depends on [slice 21](21-literal-syntax-flip.md) for the
type-expression grammar and the new relation literal (`create
table`'s left side), and on
[slice 22](22-qualifiers.md) for the no-silent-drop rule
that `create table`'s input validation reuses (qualified field on
the left → error pointing at `unqualify`).

## Goal

After this slice:

```
(id: int64, name: string, primary key (id)) | create table users
relation (id: int64, name: string) {
  (id = 1, name = "alice"),
} | create table users
drop table users
```

all work. `:create table` and `:drop table` are gone.

## Scope

- **Three new pipeline operators.**
  - `Create_table_empty of { name : string; kind : Relation.kind }`
    — takes a relation-type on the left, creates an empty table.
  - `Create_table_seeded of { name : string; source : t }` — takes a
    relation-value on the left, creates the table *and* seeds it with
    the rows. Implemented as the two-step composition of
    `Create_table_empty` then an Insert-equivalent loading pass over
    `source`'s rows, all in one write transaction.
  - `Drop_table of { name : string }` — a *leaf* operator (no
    left-side input). The table name lives in the keyword.
- **Parser disambiguates `create table` at parse time.** The parser
  knows whether the left side is a type-expression or a value-
  yielding pipeline (different starting tokens — type-exprs start
  with `(` and contain `:` between names and types; values start
  with literals or identifiers and use `=`). It picks the right AST
  constructor up front. Lower doesn't re-classify at runtime.
- **`drop table` is a leaf source, joining `relation_expr`'s
  disjunction.** Grammar accepts `drop table <name>` at pipeline-
  source position (no `|` before it). Treated as a normal source,
  so downstream pipeline steps over its result are syntactically
  allowed (`drop table users | project dropped` parses — pointless
  but well-defined under "everything returns a relation"). The
  identifier dispatcher `identifier_relation_or_bool_literal` gains
  a `"drop"` branch that commits to the leaf grammar, mirroring how
  `"relation"` commits to the relation-literal grammar today; a
  table named `drop` becomes a parse error, matching the existing
  rule for `relation`.
- **`create table` is a sink, parallel to `insert into`.** Joins
  the tail-position disjunction in `pipeline_parser`. At most one
  sink, in terminal position — same rule as Insert.
- **Result shapes.**
  - `create table` returns a one-row relation
    `(created: string) { (created = "users") }`.
  - `drop table` returns the same shape with `dropped` instead of
    `created`: `(dropped: string) { (dropped = "users") }`.
  - The column name carries the verb, matching Insert's
    `(insert_count: int64)` convention. Distinct column names per
    operator keep the result honest about what happened; a future
    "uniform sink result" shape would be a refactor across Insert,
    `create_table_*`, and `drop_table` together.
- **AST shape.** Three new `Ast.t` constructors:
  - `Create_table_empty of { table_name : string; type_expression :
    Ast.type_expression }` — carries the parsed type expression
    unchanged; `Lower` calls `lower_relation_type` to resolve to a
    `Relation.kind`.
  - `Create_table_seeded of { table_name : string; source : Ast.t }`
    — source is a pipeline, lowered recursively (parallel to
    `Insert`'s `source` field).
  - `Drop_table of { table_name : string }` — leaf at AST level too.
- **Logical/Physical shape.** Three mirrored constructors carrying a
  resolved `Relation.kind` (empty), source plan (seeded), or bare
  name (drop). `required_access` returns `` `Write `` for all three
  (seeded recurses into source via `access_max`).
- **`Create_table_seeded` target-kind derivation.** Computed in the
  evaluator from `Physical.kind_of ~catalog source`:
  - **Require unqualified source.** Reuses
    `reject_qualified_source_for_target` (extracted from Insert).
    Qualified field on the source → error pointing at `unqualify`.
  - **Stamp `Some table_name`** on every field of the derived row
    kind, matching how the existing DDL executor builds catalog
    entries.
  - **Inherit refinements verbatim** from the source kind.
  - **Reject if the resulting kind has no primary key.** User-facing
    error suggests declaring one in the source's type
    (`relation (… primary key (…)) { … }`). Most non-trivial
    pipelines drop the PK (`Project`, `CrossProduct`, joins all clear
    it), so this is the path users will trip on.
- **Validation lives in `Eval`.** All five structural checks (non-
  empty fields, no duplicate field names, non-empty primary key, PK
  columns ⊆ field list, no duplicate PK columns) plus the qualifier-
  rejection and "table already exists" / "no such table" catalog
  checks run inside the evaluator for both create forms and for
  drop. Error prefix shifts from `DDL:` to `Eval:` (e.g. `Eval:
  create table "users": column list is empty`), matching `Eval:
  insert into "orders": ...`.
- **Validate before any storage mutation.** `evaluate_create_table_
  seeded` runs target-kind derivation, qualifier-rejection,
  structural checks, and the "table already exists" check *before*
  creating the subDB or catalog entry. Failed validation means no
  storage mutation at all (rather than relying on transaction
  rollback), which keeps failure semantics visible at the evaluator
  level and lets tests assert "catalog unchanged on failure"
  directly.
- **Shared row-writing helpers extracted from Insert.** `evaluate_
  insert`'s internal helpers (`reject_qualified_source`, `build_
  source_position_map`, `insert_one_row`) lift to module-level
  helpers with target-agnostic names (`reject_qualified_source_for_
  target`, `build_source_to_target_position_map`, `write_one_row`,
  plus a `write_source_rows_into_table` wrapper that holds the
  seq-iter loop). Two callers — Insert and Create_table_seeded —
  justify the extraction; the abstraction isn't speculative.
- **Retire `:create table` and `:drop table` wholesale.** The
  fan-out:
  - `Ddl.Statement.t` collapses to `type t = List_tables` (single
    nullary constructor).
  - `Ddl.Statement.write_result`, `Ddl.Statement.field`,
    `Ddl.Statement.validate`, and `Ddl.Statement.classify` are
    deleted — with no write DDL left, there's nothing for them to
    do.
  - `Ddl_executor.execute_write` is deleted; `execute_read` becomes
    a single-case function over `List_tables`.
  - `Repl.print_ddl_write_result` is deleted; `execute_and_print_
    ddl` collapses to the read branch (no `classify` dispatch).
  - `Parser.ddl_drop_table`, `Parser.ddl_create_table`, and their
    helpers (`create_table_kind`, `create_table_field`, `create_
    table_field_list`, `create_table_primary_key_list`) are
    deleted; `ddl_body` collapses to just `ddl_list_tables`.
  - `lib/ddl/format.ml`'s `Drop_table` and `Create_table` cases go
    away, along with their round-trip tests.
  - `lib/ddl/` shrinks but still holds `:list tables` until slice
    24 retires that and removes the library wholesale.
- **Transaction classification.** The three new operators all
  require `[`Write]`. Existing tree-walk from slice 19 picks them up
  by declaring their required access.
- **Permission contravariance: reuse the slice 19 `Obj.magic`
  template.** `Eval.eval`'s transaction parameter is `[> `Read]`, but
  any storage `put` / `create_map` / `drop_map` needs
  `[`Read | `Write]`. Slice 19's `evaluate_insert` solved this by
  locally coercing with `Obj.magic` inside the write branch, justified
  by the invariant that `Logical.required_access` made the REPL pick a
  write transaction whenever an `Insert` appeared in the tree. The
  same template applies to `Create_table_*` and `Drop_table`: coerce
  locally, with a comment naming `required_access` as the upstream
  invariant. Don't relax `Eval.eval`'s signature to `[`Read | `Write]`
  — that would force pure-read pipelines to open a write transaction.

## Out of scope

- `alter table` and any other catalog-mutation operators. Future
  slices, parallel shape (one keyword-named sink per mutation kind).
- Schema-versioning on disk. Today's storage assumes the kind shape
  matches what's stored; `create_table_seeded` writes a kind and
  then rows in the same transaction, consistent with how `:create
  table` + `insert into` work today.
- Catalog rung (`catalog | tables`, etc.) — slice 24.
- Composite primary keys aren't a slice 23 concern; the existing
  `Relation.kind` already supports multi-column PKs.

## Key design decisions made during planning

- **Two AST nodes for `create table`, not one with a sum input.**
  The grammar already distinguishes type-expressions from value-
  yielding pipelines, so the parser disambiguates upfront. Lower has
  one obvious lowering per node; error messages stay local to the
  parse.
- **`create_table_seeded` is `create_table_empty` + insert-loading.**
  Executor implements it as the natural composition. Keeps the
  mental model "one transaction, schema write then row writes" with
  no new path.
- **Sinks aren't a category.** The slice 19 collapse made every
  operator return a relation; `create_table` and `drop_table` follow
  the same rule. Their result shapes are a small design call — match
  whatever shape Insert settled on, with whatever fields make sense
  per operator.

## Detailed plan

Twelve steps. Each is one commit, ends with the watcher green, leaves
the project in a working state. TDD where the global rules call for
it (steps 1–4 and 6–10 are behaviour changes — failing test first;
step 5 is a refactor — relies on existing Insert tests staying
green; step 11 is a removal — relies on tests being updated in the
same commit; step 12 is a sweep).

1. **Logical IR.** Add `Drop_table`, `Create_table_empty`,
   `Create_table_seeded` constructors to `Logical.t`. Extend
   `required_access` (all three return `` `Write ``; seeded
   recurses) and `format` (debug-printer cases). Unit tests in
   `test/plan/test_logical.ml`.

2. **Physical IR.** Mirror the same three constructors in
   `Physical.t`. Extend `kind_of` (drop and create_empty return the
   one-row result kind directly; create_seeded derives the target
   row kind from source then returns the result kind) and `format`.
   Unit tests in `test/plan/test_physical.ml` cover all three plus
   the kind derivation for create_seeded.

3. **Translate.** One-to-one for `Drop_table` and `Create_table_
   empty`; recurse into source for `Create_table_seeded`. Unit
   tests in `test/plan/test_translate.ml`.

4. **AST + Lower.** Add three constructors to `Ast.t`. `Lower`
   gains three cases: drop is a direct mapping, create_empty calls
   `lower_relation_type` on the carried `Ast.type_expression` and
   emits `Logical.Create_table_empty { table_name; kind }`,
   create_seeded recurses into source. Unit tests in
   `test/surface_ra/test_lower.ml`.

5. **Extract shared write helpers in `Eval`** (refactor, no
   behaviour change). Lift `reject_qualified_source`, `build_
   source_position_map`, `insert_one_row` to module-level helpers
   with target-agnostic names (`reject_qualified_source_for_
   target`, `build_source_to_target_position_map`, `write_one_row`).
   Add `write_source_rows_into_table ~target_kind ~target_map
   ~target_table ~write_transaction ~source_relation continue` that
   wraps the seq-iter loop and returns the affected-row count.
   `evaluate_insert` rewritten in terms of the new helpers.
   Existing Insert tests stay green.

6. **Evaluator for `Drop_table`.** Catalog-aware "no such table"
   check inside the write transaction (mirrors the current
   `Ddl_executor.drop_table` ordering: drop subDB then catalog
   entry). Returns `(dropped: string) { (dropped = "<name>") }`.
   Uses the slice-19 `Obj.magic` template to widen `transaction`
   inside the write branch, with a comment naming
   `Logical.required_access` as the upstream invariant.
   Per-step integration test in `test/integration/`: seed a
   catalog, evaluate the leaf, assert the table is gone and the
   result row matches.

7. **Evaluator for `Create_table_empty`.** Runs the five
   structural checks on the carried kind, then the catalog "table
   already exists" check, then `create_map` + `Catalog.put` in
   transaction order. Returns `(created: string) { (created =
   "<name>") }`. Same `Obj.magic` template as step 6. Per-step
   integration test exercising both success and the five
   structural-failure modes.

8. **Evaluator for `Create_table_seeded`.** Sequence: derive
   source kind via `Physical.kind_of ~catalog source`; qualifier-
   rejection; stamp `Some table_name`; structural checks on
   derived kind (no-PK check is the user-visible one); "table
   already exists" check; create subDB + catalog entry; iterate
   source via `write_source_rows_into_table` (step 5's helper).
   Per-step integration tests cover: success path with a
   `Relation_literal` source; success path with a same-shape
   `Scan` source; qualifier-rejection error pointing at
   `unqualify`; no-PK error; "table already exists" error.

9. **Parser — `drop table` leaf.** Add `"drop"` branch to
   `identifier_relation_or_bool_literal` that commits to parsing
   `table <name>` and returns `Ast.Drop_table { table_name }`. A
   bare identifier `drop` followed by anything other than the
   `table` keyword is a parse error (matching how `relation`
   commits to the literal grammar today). Parser unit tests.

10. **Parser — `create table` sink.** The grammar admits two
    surface forms with the same trailing `| create table <name>`
    sink:
    - `<type-expr> | create table <name>` →
      `Create_table_empty { table_name; type_expression }`.
    - `<value-pipeline> | create table <name>` →
      `Create_table_seeded { table_name; source }`.

    The two cases differ on what sits at pipeline-source position.
    A type expression and a row literal both start with `(`, so the
    `(`-branch in `relation_expr` (or a sibling dispatcher) uses
    bounded lookahead — scan past whitespace and an optional
    identifier, then look at the first significant character: `:`
    means type-expression, `=` means value literal. Commit on the
    lookahead result. The empty form `()` dispatches to the
    value-literal branch (preserves existing behaviour); a user
    who writes `() | create table foo` gets the structural
    `column list is empty` error from step 7/8's checks via the
    empty-derived kind. The peek logic lives in one place and
    produces either an `Ast.type_expression` (carried through to
    the sink as the only legal continuation — a type expression
    piped into anything other than `create table` is a parse
    error) or a normal pipeline-source `Ast.t`.

    The sink itself, added to `pipeline_parser`'s tail disjunction
    alongside `insert_sink`, takes whatever the upstream produced
    and emits the matching AST constructor. If the upstream was a
    type expression, only the `create table` sink is legal — a
    type expression piped into `restrict` or `insert into` is a
    parse error.

    Parser unit tests cover both forms, the peek-disambiguation
    corner cases (empty parens `()`, parens with both `:` and `=`,
    `relation (…) {…}` literal as source), and the "type
    expression piped into something other than `create table`"
    error. End-to-end REPL integration test exercises all three
    new pipe forms.

11. **Retire `:create table` and `:drop table`** per the scope
    fan-out above. Update or delete the affected tests in the same
    commit so the build stays green. Largest fan-out of the slice
    — touches `lib/ddl/`, `lib/execution/`, `lib/frontend/`,
    `lib/surface_ra/`, and matching test files. If it overshoots
    ~200 lines, split into "remove from `ddl/` + executor + repl"
    and "remove from parser + format" as 11a / 11b.

12. **Sweep test fixtures and `demo_data.ml`** for `create`,
    `drop`, and `table` used as table or column names. Rename any
    hits before the new grammar lands (which would otherwise be in
    step 9/10 — re-order if a hit blocks earlier steps). Likely a
    small or empty commit.

## Notes for follow-on slices

- Slice 24 retires `:list tables` and removes the now-empty
  `lib/ddl/` library wholesale. After slice 23, only `:list tables`
  remains in DDL.
- The `create table` / `drop table` result-row shapes ship with this
  slice. If the project later decides on a uniform "operation
  result" shape across all sinks, that's a refactor that touches
  Insert (slice 19), this slice's two operators, and any future
  sinks. Worth keeping the shapes consistent or at least
  intentionally distinct.
- Reserved-word check before grammar lands: `create`, `drop`, `table`
  enter the keyword set in this slice. Check test fixtures and
  examples for any column or table named `create`, `drop`, or
  `table`.
