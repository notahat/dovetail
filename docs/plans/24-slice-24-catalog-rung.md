# 24 — Slice 24: Catalog rung

Lands the catalog rung from
[`docs/type-system.md`](../type-system.md). Introduces `Core.Catalog`
(kind + value), the bare `catalog` source, the `tables` operator,
and rendering for the catalog literal. Retires `:list tables` and
deletes `lib/ddl/` entirely.

Depends on [slice 23](23-slice-23-create-and-drop-table.md) — only
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
- **Type-system doc amendment.** `docs/type-system.md`'s line
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
