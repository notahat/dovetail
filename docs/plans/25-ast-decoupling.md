# Slice 25: AST decoupling from core / plan

Break the AST's dependency on the semantic types it currently
reaches into from `dovetail.core` and `dovetail.plan`. The AST
becomes the surface form, owning its own composition vocabulary:
column references, expressions, projections, refinements, and
relation types are AST-side types. `Lower` becomes the wall that
translates each to its semantic counterpart.

This is phase A0 from
[`docs/ir-types.md`](../ir-types.md): preparation that makes the
AST genuinely an island. It lands before slice 26
(Typecheck extraction) so Typecheck's work targets a stable AST
shape, and unblocks phase D's GADT work (no name collisions
between `Ast.Restrict` / `Logical.Restrict`) and phase E's AST
restructure (function-call form lands against AST-side types
that don't need re-decoupling first).

## Goals

- AST-side counterparts for the semantic / resolved types the
  AST currently borrows from `core` and `plan`:
  - `Row.column_reference`
  - `Relation.refinement`
  - `Relation.kind` (where it appears inside `Relation_literal`)
  - `Plan.Projection.t`
  - `Expression.t` (and its `comparison_op`)
- `surface_ra/dune` drops the `dovetail.plan` dependency. The
  `dovetail.core` dependency stays (`Scalar.kind` and
  `Scalar.value` are primitive tags/payloads, not semantic
  forms).
- `Lower` grows the translation logic for each decoupled type.
  No behaviour change at the parser → Lower → Logical boundary.

## Non-goals

- **No AST shape restructure.** `type_expression` stays
  conflated (row-type and relation-type forms in one). Splitting
  it is a phase E concern.
- **No textual/identifier shift.** Kind names stay as
  `Scalar.kind` variants, not parsed as string identifiers that
  Lower resolves. That shift belongs to phase E (function-call
  AST).
- **No new behaviour.** Parsing produces the same Logical.t for
  the same input; tests verify behaviour-preservation throughout.
- **No GADT, no source positions, no Typecheck.** Those are
  later slices.

## Design choices

- **Scope: pragmatic.** Semantic / resolved types move; primitive
  type tags and payloads (`Scalar.kind`, `Scalar.value`) stay
  shared. `surface_ra` keeps a `dovetail.core` dep — `core` is
  the kind ladder, shared across the whole project.
- **AST type organisation: flat.** New types live as top-level
  declarations in `ast.{ml,mli}` alongside today's `type_field`,
  `type_expression`, and `t`. No submodules. Constructor names
  (e.g. AST-side `Compare`) shadow their `core` counterparts
  inside Lower; OCaml's type-directed disambiguation handles it.
- **Lower organisation: single file.** Translation helpers
  (`lower_column_reference`, `lower_expression`, etc.) live in
  the existing `lower.ml`. The file grows from ~120 lines to
  ~300; not enough to warrant splitting.
- **Order: foundational-first.** `column_reference` first because
  Expression, Projection, and the row/relation literals all
  contain it. Decoupling it first means later steps land against
  AST-side `column_reference` directly, with no intermediate
  state where an AST-side type holds a `Row.column_reference`
  inside.
- **TDD: refactor-and-update.** Phase A0 changes no behaviour, so
  the global "TDD for behaviour changes" rule doesn't fire. Each
  step updates the existing parser, lower, and integration tests
  to use the new types. Step 0 audits coverage and fills gaps
  before any structural change starts.

## Steps

### Step 0: Integration coverage audit

Before any structural change, verify integration tests cover the
behaviours phase A0 will preserve. The integration suite is the
safety net for every later step.

- Walk `test/integration/` (and any cross-cutting tests in
  `test/surface_ra/`) for end-to-end coverage of:
  - **Expressions in predicates** — restrict and join with
    representative expression shapes (literal, column,
    comparison, and/or/not, qualified vs unqualified columns).
  - **Projections** — bare, qualified, multi-column.
  - **Row literals** — bare and qualified field names.
  - **Relation literals** — declared kind + rows in declared
    order.
  - **Refinements** — `create table` with a primary key (the
    only refinement today).
- Fill gaps with new integration tests where they exist.
  Existing-good areas need no change.
- This step may be empty if coverage is already solid; leave the
  step in the plan for explicit verification.

### Step 1: Decouple `Row.column_reference`

Introduce AST-side `column_reference`. Update every AST site that
uses `Row.column_reference` to use the AST-side form. Lower
translates at the boundary.

- `lib/surface_ra/ast.{ml,mli}` — add:
  ```ocaml
  type column_reference = { qualifier : string option; name : string }
  ```
  Update `Row_literal` and `Relation_literal` to hold
  `column_reference` instead of `Row.column_reference`.
- `lib/surface_ra/parser.ml` — produce AST-side `column_reference`
  in the relevant atom and field-reference parsers. Helpers that
  currently build `Row.column_reference` become AST-builders.
- `lib/surface_ra/lower.ml` — add
  `lower_column_reference : Ast.column_reference -> Row.column_reference`.
  Today it's a structural identity; the helper exists for the
  layering, not the work.
- Tests — `test_parser.ml`, `test_lower.ml`, and any expression-
  parser tests that inspect column references update to the
  AST-side type.

### Step 2: Decouple `Relation.refinement`

Move the refinement variant into the AST.

- `lib/surface_ra/ast.{ml,mli}` — add:
  ```ocaml
  type refinement = Primary_key of column_reference list
  ```
  (Note: `column_reference` is AST-side after step 1; refinements
  reference columns by AST-side reference rather than bare strings,
  preserving the qualifier-aware form should it ever need it.)
  Update `type_expression.refinements` to hold the AST-side type.
- `lib/surface_ra/parser.ml` — `parse_relation_type`'s refinement
  parser produces the AST-side `refinement`.
- `lib/surface_ra/lower.ml` — add
  `lower_refinement : Ast.refinement -> Relation.refinement`.
  Note: today's `Relation.refinement` carries `string list` for the
  primary-key columns; the translation discards the AST-side
  column_reference's qualifier slot (refinements over qualified
  columns aren't supported today — and aren't meaningful at the
  schema level). The Lower-side translation either rejects
  qualified refinements with a user-facing error (consistent with
  today's parser-level rejection) or strips the qualifier silently
  if the parser already rejects qualified refinements upstream.
  Verify which path applies and document it.
- Tests update to the AST-side type.

### Step 3: Decouple `Relation.kind` from `Relation_literal`

`Relation_literal`'s `kind` field today is `Relation.kind`. Move
it to `type_expression` (the AST-side type that already exists,
plus the AST-side `refinement` from step 2). Lower builds the
`Relation.kind` from the type expression.

- `lib/surface_ra/ast.{ml,mli}` — update `Relation_literal` from
  ```ocaml
  | Relation_literal of { kind : Relation.kind; rows : ... }
  ```
  to
  ```ocaml
  | Relation_literal of { relation_type : type_expression; rows : ... }
  ```
  No structural split of `type_expression` (deferred to phase E).
- `lib/surface_ra/parser.ml` — `Relation_literal` literal parsing
  no longer constructs a `Relation.kind`; it carries the
  `type_expression` through unchanged.
- `lib/surface_ra/lower.ml` — the existing `lower_relation_type`
  is already the right shape; the change is that `Relation_literal`'s
  lowering routes through it instead of receiving a pre-built
  `Relation.kind`.
- Tests update accordingly.

### Step 4: Decouple `Plan.Projection.t`

The `Project` operator carries `Plan.Projection.t` (a list of
column references). Replace with the AST-side type. This is the
step that drops the `dovetail.plan` dependency from
`surface_ra/dune`.

- `lib/surface_ra/ast.{ml,mli}` — add:
  ```ocaml
  type projection = column_reference list
  ```
  Update `Project` to hold `projection`.
- `lib/surface_ra/parser.ml` — the projection parser produces
  the AST-side type.
- `lib/surface_ra/lower.ml` — add
  `lower_projection : Ast.projection -> Plan.Projection.t`.
  Trivially structural since `Plan.Projection.t` is also a list of
  column references.
- `lib/surface_ra/dune` — remove `dovetail.plan` from the
  `libraries` list. Verify the build still passes; this is the
  architectural achievement of the step.
- Tests update to the AST-side type.

### Step 5: Decouple `Expression.t`

The largest step. The Expression sublanguage moves to the AST,
along with its `comparison_op`. The parser stops producing
`Expression.t`; Lower's new `lower_expression` translates.

This step is expected to be larger than the project's preferred
~200-line norm (estimate 400–500 lines across all files).
Splitting along sub-types (comparison_op alone, expression structure
alone) isn't viable because they're interlocked (Compare carries
comparison_op). The bulk of the diff is mechanical one-to-one
constructor mapping; the only genuinely new code is Lower's
translation helpers.

- `lib/surface_ra/ast.{ml,mli}` — add:
  ```ocaml
  type comparison_op =
    | Equal | NotEqual
    | Less | LessEqual
    | Greater | GreaterEqual

  type expression =
    | Literal of Scalar.value
    | Column of column_reference
    | Compare of { left : expression; op : comparison_op; right : expression }
    | And of expression * expression
    | Or of expression * expression
    | Not of expression
  ```
  Update `Restrict` and `Join` to hold AST-side `expression`.
- `lib/surface_ra/parser.{ml,mli}` — `parse_expression` returns
  `(Ast.expression, error) result`. The internal builders shift
  from constructing `Expression.t` to constructing
  `Ast.expression`.
- `lib/surface_ra/lower.ml` — add:
  ```ocaml
  val lower_comparison_op : Ast.comparison_op -> Expression.comparison_op
  val lower_expression : Ast.expression -> Expression.t
  ```
  Both are pattern-match-and-rebuild — structurally identity.
- Tests — `test_expression_parser.ml` (448 lines) updates wholesale
  to assert AST-side `expression` shapes instead of `Expression.t`.
  `test_parser.ml`'s predicate-bearing tests follow. `test_lower.ml`
  tests that exercise restrict/join predicates update their input
  types.

After this step, `surface_ra` is fully decoupled from semantic
types. `dovetail.core` remains in the dep list for `Scalar.kind`
and `Scalar.value`; that's the design's stopping point.

## What this slice doesn't change

- **No Logical / Physical changes.** Lower still produces the
  same `Logical.t`; Translate still produces the same
  `Physical.t`; Eval still does the same work.
- **No new error paths.** Lower's new translation helpers are
  structural — they don't validate, don't lookup, don't fail in
  new ways. Behaviour-preserving translation only.
- **No parser grammar changes.** The same surface syntax accepts;
  the same syntax rejects.
- **No `type_expression` split.** Phase E does that.

## Risk and verification

The risk profile is "did I miss a call site" or "did I get a
translation arm slightly wrong" — both caught by existing tests.
The slice's safety relies on:

- **Step 0's coverage audit.** Gaps get filled before the slice
  starts, so every later step has integration-level verification.
- **Per-step test updates.** Each step's diff covers both source
  changes and corresponding test updates in one commit. A step
  that compiles but breaks tests is incomplete.
- **The build's library-dependency check.** Step 4 verifies the
  `dovetail.plan` dep can be dropped; if the build fails, an
  unmigrated site remains.

No expected performance impact: Lower's new translation helpers
add a constant-factor walk per AST node, identical in shape to
the AST walk Lower already does.
