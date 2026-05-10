# 03 — Slice 3: Projection (π) via the RA language

The third vertical slice. End-state: typing `users | project name, email`
at the REPL returns the named columns. The projection sublanguage starts
at its smallest — a comma-separated list of bare column names that must
exist in the input schema.

> **Save location:** When work begins, this plan should live at
> `docs/plans/03-slice-3-projection.md` (per the project convention of
> numbered, accumulating plan files), and be committed before the first
> sub-step starts. The version under `~/.claude/plans/` is the planning
> workspace.

## Context

Slices 1 and 2 built the layer cake (storage → eval → physical →
logical → ast → parser → REPL) for two operators: `Scan` and
`Restrict`. Slice 3 adds `Project`, the third core relational-algebra
operator. It is the first slice where an operator rewrites the schema
rather than passing it through unchanged, which forces decisions about
how derived schemas relate to base-table schemas (notably:
`primary_key`).

Slice 4 (cross product) explicitly defers two questions to whatever
slice 3 establishes: the convention for `primary_key` on intermediate
results, and the precedent for set/bag handling on operators where
the multiplicity rule is non-trivial.

## Goal

```
> users | project name, email
| name  | email             |
|-------|-------------------|
| Alice | alice@example.com |
| Bob   | bob@example.com   |
| Carol | carol@example.com |
| Dave  | dave@example.com  |
| Eve   | eve@example.com   |

> users | project name
... five rows, single column ...

> users | project email, id
... five rows, columns reordered ...

> users | restrict active = true | project name
... three rows: Alice, Carol, Dave ...

> users | project name | restrict name = "Alice"
... one row ...
```

Error cases reach the REPL and don't crash it:

```
> users | project unknown_col
error: Projection.resolve: unknown column "unknown_col"

> users | project name, name
error: Projection.resolve: duplicate column "name"

> users | project
parse error: ...

> users | project ,name
parse error: ...
```

Everything from slices 1 and 2 keeps working.

## Slice-3 architectural decisions

### Projection scope at slice start

Bare column names only. No expressions (`name + 1`), no aliases (`name
as full_name`), no qualifiers (`users.name` — those arrive in slice 4
alongside cross product). Just a comma-separated list of column names
that must exist in the input schema.

This mirrors slice 2's decision to start the predicate sublanguage at
its smallest. Expressions, aliases, and rename are natural follow-ups.

### Qualified column references

Out of scope. Slice 4 introduces qualifier infrastructure
(`Schema.field.qualifier`, `column_reference`) because cross product
produces same-name columns from different relations and disambiguation
becomes necessary. Until then, `users | project users.name` is a parse
error.

When slice 4 lands, it will need to extend projection's column-list
shape from `string list` to `column_reference list` alongside the same
change to `Predicate.t`'s `Column` term — one more bullet inside
slice 4's qualifier-infrastructure step. Same refactor pattern,
applied consistently across both column-ref-carrying types.

### Primary keys on projected schemas

`primary_key = []` for any projection result, regardless of whether
the projected columns happen to include the input PK.

`primary_key` is currently used only by `Scan` (to decode keys via
`Schema.assemble_tuple`). No operator downstream of a projection
queries it. Slice 4's cross product will follow the same convention.
When PK info on intermediate results starts mattering (probably with
`IndexScan` in slice 6, certainly with the optimizer later), this is
the right time to revisit; until then, `[]` is the honest answer:
"we don't track this on derived relations."

### Set/bag handling

`Project` downgrades to `Bag`: removing columns can introduce
duplicates that weren't present in the input. This is the first
operator with a non-trivial multiplicity rule (`Filter` and the
slice-4 `CrossProduct` both preserve the input's tag).

Following the convention established in slices 2 and 4, the rule is
recorded here in prose; `Eval.eval` continues to return
`` [`Bag] Relation.t ``. Real type-level tracking — whether via GADTs,
runtime tags, or another mechanism — is deferred to slice 8, the
first slice where set producers (`distinct`) and set-only consumers
(`union`, `intersect`) actually meet and the choice has consumers
that benefit from it.

### Projection module

Lives in `lib/projection.{ml,mli}`. Mirrors `Predicate`'s shape:

```ocaml
type t = string list

val resolve : Schema.t -> t -> Schema.t * (Schema.tuple -> Schema.tuple)
```

`resolve` is called once when the project operator starts. It
validates that each named column exists, validates that no column
appears twice in the list, caches each column's position, and returns
both the projected schema (with `primary_key = []`) and a closure
that builds the projected tuple by indexing into the cached
positions. Errors (unknown column, duplicate column) raise `Failure`
before any tuples are pulled.

The dual return — schema *and* row transformer — is the shape
difference from `Predicate.resolve`: projection rewrites the schema,
predicate doesn't. Beyond that, the module follows the same
validate-and-cache-then-closure pattern.

### Pipeline AST shape

Projection joins restriction as a recursive case in each layer.
Mirrors the existing structural rewrite style:

```ocaml
(* Ast *)
type t =
  | Relation_name of string
  | Restrict of { input : t; predicate : Predicate.t }
  | Project of { input : t; columns : Projection.t }

(* Logical *)
type t =
  | Scan of { table : string }
  | Restrict of { input : t; predicate : Predicate.t }
  | Project of { input : t; columns : Projection.t }

(* Physical *)
type t =
  | FullScan of { table : string }
  | Filter of { input : t; predicate : Predicate.t }
  | Project of { input : t; columns : Projection.t }
```

Same constructor name (`Project`) in all three layers. Cross product
(slice 4) will adopt the same convention. The IR field carries
`Projection.t` rather than `string list` directly, mirroring how
`Restrict` carries `Predicate.t` — signals the field's role and
keeps the conceptual link to the module.

### Surface syntax

`users | project name, email` — `project` is a new pipeline keyword,
parsed the same way as `restrict`. The column list is
`identifier ("," identifier)*` with at least one identifier.
Whitespace around the comma is flexible (`name,email`, `name, email`,
and `name ,email` all parse). Leading and trailing commas are parse
errors. Empty projection (`project` with no column list) is also a
parse error.

### Keyword reservation

None, same call as slice 2. A column or relation called `project`
parses fine and produces a semantic error only if the name doesn't
resolve.

### Validation placement

- **Parser**: enforces non-empty column list, well-formed comma
  syntax.
- **`Projection.resolve`**: enforces unknown column, duplicate column.
- **Eval**: trusts the resolve closure; per-row work is just indexing
  into the cached positions.

No smart constructor on `Projection.t` and no defensive empty-list
check inside `resolve` — the parser is the only producer of
projection lists in this slice, and the project's "don't validate
what can't happen" rule applies.

### Eval implementation

Streaming map. The right-side materialisation pattern slice 4 uses
for cross product isn't needed here: projection is a pure
single-input transformation, so `Seq.map` carries it.

```ocaml
| Project { input; columns } ->
    let { Relation.schema; tuples } =
      eval environment transaction input
    in
    let projected_schema, project_tuple =
      Projection.resolve schema columns
    in
    { schema = projected_schema
    ; tuples = Seq.map project_tuple tuples
    }
```

### Error type

`Parser.error` stays `string`. `Projection.resolve` raises `Failure`,
caught by the REPL's existing handler. No structural change to the
error story for slice 3.

## Sub-steps

Five steps. Each is one commit, with tests, leaving the project in a
working state. Build from the bottom: each step adds one layer, and
from step 2 onward each step ends with a runnable transformation at
the layer just introduced.

### 1. Projection module

Create `lib/projection.{ml,mli}` with the `t` and `resolve`
introduced above. `resolve` validates column existence, validates
no-duplicates, caches positions, returns the projected schema (with
`primary_key = []`) and a per-tuple closure.

Tests: `test/test_projection.ml`. Single-column projection,
multi-column projection, projection that reorders columns, projection
that picks a single non-leading column (exercises the position
cache), unknown column raises with a clear message, duplicate column
raises with a clear message. Verify the returned schema has
`primary_key = []`.

End state: pure module, no integration yet.

### 2. `Physical.Project` + Eval

Add `| Project of { input : t; columns : Projection.t }` to
`Physical.t`. Add the `Project` case to `Eval.eval`:

```ocaml
| Project { input; columns } ->
    let { Relation.schema; tuples } =
      eval environment transaction input
    in
    let projected_schema, project_tuple =
      Projection.resolve schema columns
    in
    { schema = projected_schema
    ; tuples = Seq.map project_tuple tuples
    }
```

Tests: `test_eval.ml` grows with end-to-end Project cases. Build a
`Physical.Project` by hand around a `FullScan` (and around a
`Filter`), evaluate, assert rows. Cover: single-column projection;
multi-column projection; projection reordering columns;
project-then-filter pipeline (`project name, active | filter active =
true`-equivalent built by hand); filter-then-project pipeline;
unknown column raises; duplicate column raises.

End state: projection works at the physical layer.

### 3. `Logical.Project` + Translate

Add `| Project of { input : t; columns : Projection.t }` to
`Logical.t`. Update `Translate.translate` to map `Project { input;
columns } → Project { input = translate input; columns }`.

Tests: `test_translate.ml` adds a Project case — structural unit
(`Project → Project`) plus the pipeline integration (build
`Logical.Project`, translate, evaluate, assert rows).

End state: projection works at the logical layer.

### 4. `Ast.Project` + Lower

Add `| Project of { input : t; columns : Projection.t }` to `Ast.t`.
Update `Lower.lower` similarly. One-line structural rewrite.

Tests: `test_lower.ml` adds the structural unit and the pipeline
integration (build `Ast.Project`, lower, translate, evaluate, assert
rows).

End state: projection works at the AST layer.

### 5. Parser `project`

Grammar additions:

- **`project` keyword** as a pipeline-step alternative alongside
  `restrict`. Use the existing `keyword` helper from slice 2.
- **Column-list parser**: `identifier ("," identifier)*` with at
  least one identifier. Reuse the existing `identifier` parser.
  Whitespace flexible around the comma. No leading or trailing
  comma.

Tests: `test_parser.ml` covers `users | project name`, `users |
project name, email`, `users | project name,email` (no spaces),
`users | project email, id` (reorder), `users | project name |
project email` (chained projection), `users | restrict id = 3 |
project name, email` (combined with restrict). Reject `project` (no
columns), `project ,name`, `project name,`, `project name email`
(missing comma). End-to-end pipeline integration test: parse, lower,
translate, evaluate, assert rows.

After step 5, run the binary manually to confirm the demo from the
Goal section. Update `README.md` to extend the layer-diagram
description to mention projection — probably a sentence in the
Layers table for `Logical`/`Physical`.

End state: the demo from the Goal section works end-to-end via the
REPL.

## Verification

End-to-end checks performed at the close of slice 3:

1. `opam exec -- dune build` succeeds with no warnings.
2. `opam exec -- dune test` passes — including the new
   `test_projection.ml` and the Project additions to `test_eval.ml`,
   `test_translate.ml`, `test_lower.ml`, `test_parser.ml`.
3. `opam exec -- dune build @fmt --auto-promote` is clean.
4. Manual REPL session reproduces every example in the Goal section,
   including the four error cases.
5. Slice 1 and slice 2 demos still work (`users` alone, `users |
   restrict id = 3`, etc.) as a regression smoke test.

## Critical files

Existing files modified (in dependency order):

- `lib/projection.ml`, `lib/projection.mli` — *new module*
- `lib/physical.ml`, `lib/physical.mli` — add `Project` constructor
- `lib/eval.ml`, `lib/eval.mli` — add `Project` case
- `lib/logical.ml`, `lib/logical.mli` — add `Project` constructor
- `lib/translate.ml`, `lib/translate.mli` — add `Project` case
- `lib/ast.ml`, `lib/ast.mli` — add `Project` constructor
- `lib/lower.ml`, `lib/lower.mli` — add `Project` case
- `lib/parser.ml`, `lib/parser.mli` — add column-list parser and
  `project` pipeline step
- `lib/dune` — add `projection` to the library's modules if not
  picked up automatically (dune usually finds it; check after
  step 1)

Existing tests extended:

- `test/test_eval.ml`
- `test/test_translate.ml`
- `test/test_lower.ml`
- `test/test_parser.ml`

New tests:

- `test/test_projection.ml`

Documentation:

- `README.md` — layers table mentions projection (after step 5)

## Patterns and helpers reused

- `Predicate` module's shape and validate-and-cache-then-closure
  pattern (`lib/predicate.ml`).
- `Schema.find_field` for column-existence checks
  (`lib/schema.ml:find_field`).
- `Schema.tuple` (a `Value.t array`) for O(1) position-indexed reads.
- `Relation.print` for output rendering — no changes needed; it
  already adapts to whatever schema it's handed.
- `keyword`, `identifier`, `whitespace` helpers in `lib/parser.ml`.
- `Test_helpers.with_temp_dir`, `with_environment`,
  `tuple_list_testable`, `expected_users_rows`
  (`test/test_helpers.ml`).
- `Fun.protect`-based scope-bound resource management for any
  end-to-end tests that need a fresh LMDB env.

## Open questions

Captured here as they come up; resolved at end of slice.

- (none currently)
