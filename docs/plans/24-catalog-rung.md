# Slice 24: Catalog rung

Lands the catalog rung from
[`docs/design/type-system.md`](../design/type-system.md). Introduces `Core.Catalog`
(kind + value), the bare `catalog` source, the `tables` operator,
and rendering for the catalog literal. Retires `:list tables` and
deletes `lib/ddl/` entirely.

Depends on [slice 23](23-create-and-drop-table.md) — only
`:list tables` remains in DDL after that slice; this one finishes
the retirement.

## Goal

After this slice:

```
catalog                 -> renders the full catalog value literal
catalog | type          -> renders the catalog type literal
catalog | tables        -> one-column relation (name: string), one
                           row per table
```

`lib/ddl/` is gone. The whole language is pipe-shaped.

## Scope

- **New module `lib/core/catalog.ml{,i}`** with both `kind` and
  `value`:
  ```ocaml
  type kind = {
    relation_kinds : (string * Relation.kind) list;
  }

  type 'tag value = {
    relations : (string * 'tag Relation.t) list;
  }
    constraint 'tag = [< `Set | `Bag ]
  ```
  Cross-table refinements (foreign keys, cross-table checks) are
  deliberately absent — see decisions below.
- **`Term.t` grows two arms:** `Catalog_value of 'tag Catalog.value`
  and `Catalog_kind of Catalog.kind`.
- **Bare `catalog` keyword as a leaf source.** Lower produces a
  `Catalog_source` node; Eval reads from `Storage.Catalog` and
  builds a `Catalog.value` whose `relations` field opens cursors
  lazily, one per table. Pulling the value's relations is the usual
  streaming behaviour, scoped to the read transaction.
- **`tables` operator.** Takes a `Catalog_value`, walks its
  `relations` list, emits a `Term.Relation_value` with kind `(name:
  string)`, one row per table.
- **`type` operator at the catalog rung.** Projects value to kind:
  strip the row sequences from each relation, keep only their kinds.
  Falls out of the existing `Type_op` machinery; this slice exercises
  it for the catalog arms.
- **Catalog literal rendering.** `Term.Catalog_value` formats as the
  full `catalog { users = relation (...) { ... }, ... }` form —
  every relation rendered with its rows. `Term.Catalog_kind`
  formats as `catalog { users: (...), orders: (...), ... }`. Lazy
  sequences pull as the formatter walks; transaction scope wraps
  the whole render.
- **Retire `:list tables` from `lib/ddl/`.** Parser rule, AST
  constructor, executor case, format-printer case, tests.
- **Delete `lib/ddl/` entirely.** With `:list tables` gone, no DDL
  statements remain. Remove the dune library, the directory, the
  `module Ddl = Dovetail_ddl` aliases. `Ast.program` loses its
  `Ddl` arm. REPL stops dispatching on it.
- **Type-system doc amendment.** `docs/design/type-system.md`'s line
  `catalog | type → catalog { users: ..., ... }` is consistent with
  this slice's design (value flows in, kind comes out) — no
  amendment needed there. But slice 17's "data deliberately absent"
  stance for catalog is reversed by this slice; add a one-line note
  in this slice's detailed plan explaining the reversal.

## Out of scope

- Foreign keys (parsing, rendering, storage, or enforcement). The
  syntax `foreign key (orders.user_id references users.id)` from
  type-system.md is committed but lands in a dedicated FK slice when
  the semantics (timing of checks, cascade behaviour, error
  reporting) are designed.
- Other cross-table refinements (`unique (...)` spanning tables,
  cross-table `check (...)`). Same reasoning — syntax committed, no
  feature design yet.
- Other `catalog | <op>` operators (`columns`, `refinements`, info-
  schema-style introspection). Slice 24 lands only `type` and
  `tables`; future slices grow the family as needed.
- `catalog | type | something` chained operations beyond what
  type-system.md commits. Today nothing in the grammar consumes a
  catalog-type on the left of a pipe.
- Multi-catalog support and a `create database` form. Single-catalog
  per database remains.

## Key design decisions made during planning

- **Catalog value is real, with full content.** The user can type
  `catalog` standalone and the REPL renders the entire catalog as a
  literal with every relation's rows. Symmetry with the rest of the
  ladder is preserved end to end; the cost (reading every row of
  every table) is bought knowingly. Streaming through lazy `Seq.t`
  on a single transaction keeps the implementation tractable for
  realistic test sizes.
- **`Catalog.value` is a real type, not a transparent wrapper around
  `Catalog.kind`.** Today its fields are exactly the relations with
  their data; in future, runtime-only fields (row counts, statistics,
  last-vacuum, sequence positions) join the value side without
  restructuring. Slice 17's "data deliberately absent" stance was
  right at the time and is reversed here, where consumers exist.
- **`tables` returns a relation, not a string list.** The doc's
  "list of table names" framing is informal; concretely it's a
  one-column relation `(name: string)`. Composes with `filter`,
  `project`, etc. for free. Opens the door to `columns`,
  `refinements`, info-schema-style operators in the same shape.
- **FKs out of scope.** Shipping FK syntax without enforcement
  ("sugar without substance") was rejected. Shipping enforcement
  bundles a separate design conversation into this slice. FK lands
  on its own.
- **`lib/ddl/` deleted in this slice.** Retire-as-you-go across
  slices 20/22/23 leaves the library empty after this one; the
  final deletion lands here as a clean diff at the end of the
  type-system work.

- **`Catalog.value` is not `'tag`-parameterised.** The plan's
  `'tag value = { relations : (string * 'tag Relation.t) list }`
  was simplified to a hardcoded `[`Set] Relation.t` per entry:
  every base table in storage is a set today, and uniformly
  tagging a container by a multiplicity it does not itself carry
  is sugar without substance. When a bag-table mode lands, the
  catalog grows a per-entry discriminator at the same time. As a
  consequence, `Term.Catalog_value` carries `Catalog.value`
  directly with no `'tag` parameter.

- **`tables` is the language's first `[`Set]`-tagged leaf.** Every
  existing source emits `[`Bag] Relation.t`. The `tables` operator
  emits a set (table names are unique by storage construction)
  with no primary-key refinement (kept deliberately minimal).
  The step that lands it watches for any latent assumption in the
  pipeline that a leaf is always a bag.

- **`type` at the catalog rung does not fall out of existing
  machinery.** The plan's "exercises the existing `Type_op`
  machinery" framing is misleading. `Physical.kind_of` returns
  `Relation.kind`, but the catalog rung's kind is
  `Catalog.kind` — a different type. `evaluate_type_op` already
  short-circuits the `Scalar_literal` and `Row_literal` cases
  for the same reason; the catalog case joins that club rather
  than going through `kind_of`. A TODO marker in the new arm
  flags the non-uniform `kind_of` family for a future refactor;
  this slice does not unify it.

- **`Relation.format` is reworked into Format boxes as a prep
  step.** Today it hand-rolls indentation with raw `\n  ` strings,
  so a relation rendered inside a catalog ends up with its rows
  at column 2 instead of column 4. The prep rewrite uses
  `vbox 2` + `@,` cuts so nesting auto-indents. No behaviour
  change at depth 0 (modulo trivial whitespace tweaks if Format
  produces slightly different output for the existing fixtures).

## Detailed plan

Ten steps. Each is one commit, ends with the watcher green,
leaves the project in a working state. TDD where the global rules
call for it (steps 2–4, 6–9 are behaviour changes — failing test
first; steps 1 and 5 are refactors that rely on existing tests
staying green; step 10 is a deletion with tests updated in the
same commit).

1. **Prep — `Relation.format` with Format boxes** (refactor, no
   behaviour change). Rewrite `format` in `lib/core/relation.ml`
   to use `Format.fprintf`'s `@[<v 2>…@]` and `@,` cuts so the
   rows-block auto-indents when the formatter is nested. Existing
   single-relation rendering at depth 0 is unchanged; existing
   tests stay green. If Format's output for the empty or
   single-row cases drifts at depth 0, fixture tweaks land in
   this commit.

2. **`Core.Catalog` types + `Term.t` arms.** New module
   `lib/core/catalog.ml{,i}` defining
   `kind = { relation_kinds : (string * Relation.kind) list }`
   and `value = { relations : (string * [`Set] Relation.t) list }`.
   Both ordered byte-sorted by table name (matching
   `Storage.Catalog.list_table_names`'s cursor order). `Term.t`
   gains `Catalog_value of Catalog.value` and `Catalog_kind of
   Catalog.kind`; neither constrains the existing `'tag`
   parameter. Unit tests construct hand-built values and kinds.

3. **`Catalog.format` (value + kind) + `Term.format` dispatch.**
   `format_kind` renders as
   `catalog { users: (id: int64, name: string), … }` (single-line
   if short, the inner kinds use `Relation.format_kind`). `format`
   for the value renders as
   `catalog { users = relation (…) { … }, … }` with each
   relation expanded via `Relation.format`; the step-1 prep
   makes the nesting auto-indent. Empty cases render as
   `catalog {}` for both value and kind. `Term.format` grows
   matching arms. Unit tests cover non-empty, empty, and nested
   (multi-table-with-rows) cases.

4. **Parser — `catalog` keyword.** Reserve `catalog` as a keyword
   in the parser (a quick `rg` over `test/` first to confirm no
   existing fixture uses it as a table name). Add
   `Ast.Catalog_source` (nullary). Add the parser branch so a
   bare `catalog` at source position produces the new AST node.
   Parser unit tests in `test/surface_ra/test_parser.ml`. No
   integration test for this step; step 6 backfills coverage.

5. **Eval prep refactor — extract per-table relation
   construction** (refactor, no behaviour change). Lift the body
   of `evaluate_full_scan` that builds a per-table `Relation.t`
   from an open transaction into a module-level helper
   (something like
   `build_table_relation ~environment ~transaction ~table_name`,
   returning a `[`Set] Relation.t` whose `value` seq opens the
   cursor lazily). `evaluate_full_scan` rewritten in terms of
   the helper; existing scan tests stay green.

6. **Vertical — `catalog` end-to-end.** Add
   `Logical.Catalog_source` (and the `required_access` arm
   returning `` `Read ``), `Lower` arm for `Ast.Catalog_source`,
   `Physical.Catalog_source` (and `kind_of` arm returning a
   placeholder `Relation.kind` is wrong — instead, `kind_of`
   must remain undefined for this arm; the step-7 short-circuit
   in `evaluate_type_op` is what handles `catalog | type`, so
   `kind_of` over a bare `Catalog_source` should `assert false`
   with an invariant comment), `Translate` arm, and
   `Eval.evaluate_catalog_source`. The evaluator calls
   `Storage.Catalog.list_table_names`, then for each name calls
   `Storage.Catalog.get` to recover the kind and the step-5
   helper to build the per-table relation (lazy cursor opening,
   scoped to the same read transaction), assembles a
   `Catalog.value`, and hands `Term.Catalog_value` to the
   continuation. Per-layer unit tests at each rung. Integration
   test in `test/integration/`: seed a multi-table catalog,
   evaluate bare `catalog`, assert the rendered literal matches
   a fixed expected string (covers the parser-to-AST hop step 4
   left untested).

7. **`type` at the catalog rung.** Add a `Catalog_source` arm to
   `evaluate_type_op` in `lib/execution/eval.ml`, mirroring the
   existing `Scalar_literal` / `Row_literal` short-circuits: emit
   `Term.Catalog_kind` built from the catalog's relation kinds
   without opening any row cursors. Add a TODO comment naming
   the limitation (the `kind_of` family is non-uniform across
   rungs; a future refactor unifies it). Integration tests:
   `catalog | type` renders the kind literal; `catalog | tables
   | type` renders the one-column relation kind (falls out of
   the default `kind_of` branch for free — confirming this in a
   test is the point).

8. **`tables` operator end-to-end.** Add `Ast.Tables of { input
   : t }`, the parser branch, `Logical.Tables` (with
   `required_access` recursing into input), `Lower` arm,
   `Physical.Tables`, `Translate` arm, and
   `Eval.evaluate_tables`. The evaluator pattern-matches the
   incoming term: on `Term.Catalog_value`, walks the strict
   `relations` list and emits a `Relation_value` carrying a
   `[`Set] Relation.t` with kind `(name: string)` (bare name, no
   qualifier, no refinements) and a `Seq.t` of one row per table
   name; on any other arm, `failwith "Eval: tables: expected
   catalog value, got <description>"`. Per-layer unit tests.
   Integration test: `catalog | tables` returns the expected
   rows for a seeded catalog; `42 | tables` raises the
   user-facing error.

9. **Retire `:list tables`.** Drop the parser rule, the
   `Ddl.Statement.List_tables` constructor, the executor case in
   `lib/execution/ddl_executor.ml`, the format-printer case in
   `lib/ddl/format.ml`, and all related tests. The library still
   compiles (empty after this step); the REPL still dispatches on
   the `Ddl` arm but no `Ddl.Statement.t` constructor remains, so
   the dispatch is unreachable. Tests updated in the same commit.

10. **Delete `lib/ddl/`.** Remove the `lib/ddl/` directory and
    its dune library entirely. Remove `module Ddl = Dovetail_ddl`
    aliases from every file that opens them (per the project's
    cross-library alias convention — `lib/surface_ra/`,
    `lib/execution/`, `lib/frontend/`, and matching test files).
    Drop the `Ast.program.Ddl` arm; the wrapper becomes a single
    `Pipeline of t` alternative, so the REPL stops dispatching
    on it (the wrapper itself can also be retired if nothing
    else needs the distinction — a `Pipeline of t` alternative
    around a `t` is just `t`). Amend `docs/design/type-system.md` per
    the slice-17 reversal noted in scope (catalog values are no
    longer "deliberately absent"). If this step exceeds ~5 files
    / ~200 lines after the alias and `Pipeline` cleanups, split
    into 10a (`lib/ddl/` deletion + alias removals) and 10b
    (`Ast.program` collapse + REPL cleanup + doc amendment).

## Notes for follow-on slices

- An FK slice (whenever it lands) adds:
  - A `cross_table_refinements` field on `Catalog.kind`.
  - Parser rules for `foreign key (...)` and other refinement
    clauses inside catalog literals.
  - Storage support — `Storage.Catalog` learns to persist catalog-
    wide refinements alongside the per-table kinds it already stores.
  - Enforcement on inserts/deletes/updates that touch FK-bound
    columns.
- Future info-schema-style operators (`columns`, `refinements`,
  `indexes`, …) follow `tables`' shape: a relation-producing pipe
  stage that walks the catalog value's structure.
- Catalog literal as a *source* (e.g. `catalog { ... } | create
  database mydb`) is sketched in type-system.md but not committed;
  it lives beyond single-catalog support and isn't this slice's
  problem.
