# Slice 26: Typecheck extraction

Extract a dedicated `Typecheck` pass that consolidates the
kind-discipline and column-resolution checks currently scattered
across `Lower`, `Translate`, and `Eval`. This is phase A of the
larger architectural shift described in
[`docs/ir-types.md`](../ir-types.md): one home for user-facing
type errors, structured error values for a future LSP, and a
cleanly separable Logical → Translate boundary.

The pass works against today's untyped `Logical.t`. The
GADT-indexed `Typed_logical.t` form is a later slice (phase D); this
slice introduces no new IR types.

## Goals

- A single `Typecheck` pass between `Lower` and `Translate` that
  produces all kind/resolution errors a query can hit.
- Structured error values (`Typecheck.error` tagged variant), one
  arm per error class, with operator-named prefixes when rendered.
- Error accumulation: one walk reports every problem, not just the
  first.
- `Lower`, `Translate`, and `Eval` shed their kind-discipline code;
  what remains in those modules is purely
  surface-to-semantic translation, operator-name swapping, and
  storage interaction.

## Non-goals

- No GADT. `Typed_logical.t` arrives in a later slice.
- No source positions. Threading byte ranges through the AST is
  its own slice (phase C in the doc).
- No AST decoupling from `core` / `plan`. That's its own slice
  (phase A0), tracked separately.
- No runtime-check migration. Primary-key collisions on `Insert`,
  `Create_table_seeded`'s kind derivation, and storage I/O errors
  stay where they are.

## Design choices

- **Signature:** `typecheck : catalog:Catalog.kind -> Logical.t ->
  (Logical.t, Typecheck.error list) result`. Returns the
  (unchanged in this slice) `Logical.t` on success or an
  accumulated error list on failure. In phase D the success arm
  widens to `Typed_logical.t`; the shape stays the same.
- **Pipeline integration:** `Frontend.Repl` orchestrates. Sequence:
  Parse + Lower → `required_access` → open transaction → snapshot
  catalog from transaction → Typecheck → on empty errors, Translate
  + Eval; on non-empty, raise to abort the transaction, catch and
  render at the outer CLI.
- **Catalog snapshot:** new helper `Storage.Catalog.snapshot_kind :
  [> `Read] Engine.transaction -> Catalog.kind`. Walks the catalog
  sub-database, builds the in-memory `Catalog.kind`. Snapshot is
  taken inside the transaction that Eval will use, so the
  catalog can't shift between typecheck and eval.
- **Error type:** tagged variant, one constructor per error class.
  No flat-record / category-enum form; the LSP wants structure,
  not pre-rendered strings. `Typecheck.render : error -> string`
  produces the user-facing rendering.
- **Error prefixes:** operator-named (`Insert:`, `Tables:`,
  `Restrict:`), not module-of-origin. Today's `Translate:` /
  `Eval:` prefixes are an inherited anti-pattern; this slice
  retires them as the corresponding checks move. The CLAUDE.md
  rule ("prefix names the user-facing concept") is the alignment
  target.
- **Transaction abort on error:** `Frontend.Repl` raises a typed
  `Typecheck_failed of error list` inside the transaction block.
  `Storage.Engine.with_write_transaction`'s existing exception
  path aborts. Outer CLI catches and renders. Avoids adding a
  non-commit exit to the storage API.
- **TDD per step:** structured-error unit tests in
  `test/plan/typecheck.ml` (single file, grow it as the variant
  grows), plus an integration test update per step where the
  rendered prefix changes (`Translate: …` → `Insert: …`).

## Steps

### Step 0: `Storage.Catalog.snapshot_kind`

Add the catalog-snapshot helper that phase A depends on. No
Typecheck code yet; no CLI changes; no Lower/Translate/Eval
changes.

- `lib/storage/catalog.{ml,mli}` — add `snapshot_kind`.
- `test/storage/catalog.ml` — unit tests for empty / single-table /
  multi-table snapshots; verify the returned `Catalog.kind` round-
  trips against the stored schemas.

Independent of every other step. Could land in isolation.

### Step 1: Typecheck bootstrap

Introduce `Typecheck` as a no-op pass and wire it into the
pipeline. The `error` type starts empty; the renderer is
exhaustive over `|`.

- `lib/plan/typecheck.{ml,mli}` — new module.
  - `type error = |`
  - `val render : error -> string`
  - `val typecheck : catalog:Catalog.kind -> Logical.t ->
    (Logical.t, error list) result`, returning `Ok logical`
    always.
- `lib/plan/dune` — add `typecheck` if dune doesn't auto-pick.
- `lib/frontend/repl.ml` — wire the call between Lower and
  Translate. Snapshot catalog from the open transaction. On `Ok`
  (the only path today), continue to Translate. The `Error`
  branch is plumbed but unreachable in this step.
  - Introduce `exception Typecheck_failed of Typecheck.error list`.
  - Wrap the in-transaction work so the outer CLI catches and
    renders.
- `test/plan/typecheck.ml` — single Alcotest file. One test: empty
  pass returns input unchanged with no errors.

### Step 2: Move `Translate.check_columns_match`

Add the `Insert_column_mismatch` error constructor; move the
column-name check.

- `lib/plan/typecheck.{ml,mli}` — add
  `Insert_column_mismatch of { table_name : string; missing :
  string list; extra : string list }`; extend renderer with
  `Insert: column mismatch …`.
- `lib/plan/typecheck.ml` — walker visits `Insert` nodes, looks up
  the target's kind in `Catalog.kind`, compares source row kind's
  column names against target's.
- `lib/plan/translate.ml` — remove `check_columns_match` and its
  call site; the assumption is now that Typecheck has validated.
- `test/plan/typecheck.ml` — unit test asserting the structured
  variant for a mismatching insert.
- Integration test (existing) — update the rendered error string
  from `Translate: …` to `Insert: …`.

### Step 3: Move `Translate.check_value_kinds`

Add the `Insert_kind_mismatch` constructor; move the per-column
kind check. Mirror structure of step 2.

- `lib/plan/typecheck.{ml,mli}` — add
  `Insert_kind_mismatch of { table_name : string; column : string;
  expected : Scalar.kind; actual : Scalar.kind }`; extend renderer.
- `lib/plan/typecheck.ml` — extend the `Insert` walker.
- `lib/plan/translate.ml` — remove `check_value_kinds`.
- Tests as for step 2.

### Step 4: Move `Eval`'s eager column resolution

The biggest of the migrations. `Eval`'s `Filter` / `Project` /
related operators run `Expression.resolve` and
`Projection.resolve` eagerly at operator entry, raising on failure
(`Eval: …`). Move these to a single tree-walk in Typecheck.

- `lib/plan/typecheck.{ml,mli}` — add
  `Unresolved_column of { column_reference : Row.column_reference;
  available : Row.kind; operator : string }`; extend renderer with
  `<Operator>: unresolved column …`.
- `lib/plan/typecheck.ml` — walker derives the input row kind at
  each operator boundary (using a `kind_of` helper analogous to
  `Physical.kind_of`, but on `Logical.t`; introduce as a private
  function), and calls into `Expression.resolve` /
  `Projection.resolve` to validate column references.
- `lib/execution/eval.ml` — remove the eager-resolve calls at
  operator entries. `Expression.resolve` and `Projection.resolve`
  still exist (Eval needs them per-row to evaluate predicates and
  projections), but the "validate at entry" idiom goes away.
- Unit tests cover: unresolved column in restrict, unresolved
  column in project, qualified-unqualified mismatch, ambiguous bare
  name (when applicable).
- Integration tests update prefixes.

### Step 4.5: Move unknown-table detection

The catalog snapshot Typecheck already takes makes "no such table"
into a cheap structural check. `Scan { table }` and `Insert { table; _ }`
both look the name up; today they trip `Eval: unknown table` (FullScan /
IndexLookup) and `Translate: insert into ... unknown table` separately,
each with its own prefix. Move both into Typecheck so the user sees
one operator-named error and downstream layers can `assert false` on
the missing-table arm.

- `lib/plan/typecheck.{ml,mli}` -- add
  `Unknown_table of { operator : string; table_name : string }`;
  extend the renderer (`Scan: unknown table %S`,
  `Insert: into %S: unknown table`).
- `lib/plan/typecheck.ml` -- walker arms for `Scan` and `Insert`
  consult the catalog snapshot.
- `lib/plan/translate.ml` / `lib/execution/eval.ml` -- replace the
  table-missing failwiths with `assert false`; the Typecheck guarantee
  makes them unreachable.
- Tests -- new structured-error cases in `test/plan/test_typecheck.ml`
  (Scan and Insert), retire the direct-target failure tests in
  `test/plan/test_translate.ml`, `test/execution/test_eval_full_scan.ml`,
  `test/execution/test_eval_index_lookup.ml`. Integration tests
  continue to pass through `with_query_failure`, which now picks up
  the Typecheck wording.

Out of scope: `Physical.kind_of`'s "unknown table" failwith. It's a
static helper Translate calls after the catalog lookup it now trusts
Typecheck for; the failwith remains as a guard against future callers
that might bypass Typecheck.

### Step 5: Move `Eval`'s operator-shape preconditions

The "input is not a catalog" / "input is not a relation or row"
checks. These are runtime asserts today; they become typecheck-
time asserts after this step.

- `lib/plan/typecheck.{ml,mli}` — add
  `Tables_input_wrong_rung of { actual : rung_description }` and
  `Unqualify_input_wrong_rung of { actual : rung_description }`.
  (`rung_description` is a small string-ish summary for rendering;
  the GADT-time form replaces it in phase D.)
- `lib/plan/typecheck.ml` — walker derives each operator's input
  rung (relation / row / scalar / catalog) and checks against
  what the operator demands.
- `lib/execution/eval.ml` — remove the now-unreachable runtime
  asserts at those operators.
- Unit and integration tests as before.

### Step 6: Move `Lower.validate_typed_row`

`Lower` today validates that each row in a `Relation_literal`
matches the declared kind. Move that validation to Typecheck;
Lower emits the `Logical.Relation_literal` unchecked.

- `lib/plan/typecheck.{ml,mli}` — add
  `Relation_literal_row_mismatch of { row_index : int; expected :
  Row.kind; actual : Row.kind }` (and any related constructors —
  duplicate-field, missing-field — as the migration reveals them).
- `lib/plan/typecheck.ml` — walker checks each row literal against
  its declared kind.
- `lib/surface_ra/lower.ml` — strip `validate_typed_row`'s
  checks; Lower now does the structural emit only.
- Tests as before.

### Step 7: Move `Lower.lower_relation_type`'s validation pieces

`lower_relation_type` is two things in one: it builds a
`Relation.kind` from a `type_expression`, and it validates the
fields (no duplicates, refinements reference real columns).
Separate the validation from the construction.

- `lib/plan/typecheck.{ml,mli}` — add
  `Relation_type_duplicate_field of { name : string }`,
  `Refinement_unknown_column of { refinement : string; column :
  string }` (and any others surfaced by the existing checks).
- `lib/plan/typecheck.ml` — walker visits `Create_table_empty`
  (and any other operator that carries a `Relation.kind`) and
  re-validates. Note this is partial duplication: Lower still
  builds the `Relation.kind` value, but it builds it
  optimistically and Typecheck reports problems with the result.
  Future slice (phase A0 or beyond) can collapse the duplication
  once the AST owns its own relation-type expression.
- `lib/surface_ra/lower.ml` — `lower_relation_type` becomes
  construction-only.
- Tests as before.

### Step 8: Cleanup and prefix sweep

Final pass to remove any remaining `Translate:` / `Eval:` user-
facing prefixes that should now read operator-named, retire any
dead error branches, and confirm Typecheck owns the entire error
surface.

- Sweep the codebase for `Translate:` and `Eval:` string literals
  in error paths. Anything remaining either gets renamed
  (operator-named) or has its raise retired (Typecheck owns this
  case now).
- Confirm `Frontend.Repl`'s `Typecheck_failed` path is the only way
  user-typed kind/resolution errors reach the user.
- Final integration test pass — every error scenario rendered as
  `<Operator>: …`, never `Translate:` or `Eval:`.

This step may be empty if each prior step cleaned up after itself
thoroughly; leave it in the plan as a verification slot regardless.

## What this slice doesn't change

Worth being explicit because the diff will be large:

- The Logical IR types are unchanged. No new constructors, no
  reshaping of existing ones.
- The Physical IR types are unchanged. Translate's output is
  byte-for-byte the same as today's; what changes is that
  Translate's input is now guaranteed-typechecked.
- Eval's `Term.t` envelope is unchanged. Eval's signature is
  unchanged. What changes is what Eval no longer has to validate.
- The surface AST is unchanged. The parser is unchanged.

Phase A's whole investment is in extracting the cross-cutting
concern; structural change happens in later phases.

## Risk and verification

The big risk is behavioural drift — a check that subtly behaved
differently in its old home than in Typecheck. Mitigations:

- Each step is a single check; small enough to read end-to-end.
- Each step's unit test asserts the structured variant *and*
  updates the corresponding integration test asserting the
  rendered string. Both layers verify the migration.
- The error renderer is a separate function with its own targeted
  tests, so rendering changes are visible in test diffs.
- Step 8's sweep catches anything missed.

No expected performance impact: Typecheck adds a tree walk before
Translate, but the operators it visits are the same ones Translate
visits, with cheaper per-node work. Net: comparable to one extra
pass over the IR, which is dwarfed by execution costs.
