# Slice 16: Full sub-library setup

The structural extraction that slice 13 began. Five more
libraries come out of residual `lib/` — `storage`, `plan`,
`surface_ra`, `execution`, `frontend` — completing the
seven-library layout designed in `library-structure.md`. Tests
mirror the new layout in parallel. No user-visible behaviour
changes anywhere.

The design that shapes this slice lives in
[`docs/plans/library-structure.md`](library-structure.md). That
document covers the seven-library layout, the wrapping model,
the alias conventions, and the inner-module rename for
`storage`. This slice plan implements the remainder of that
design.

## Context

After slice 15, `lib/` contains:

- Two already-extracted sub-libraries: `core/` (slice 13 step
  4) and `ddl/` (slice 13 step 7, with `format.ml` added in
  slice 14).
- Eighteen residual files in the flat `dovetail` library:
  `storage.ml`, `encoding.ml`, `row_codec.ml`, `catalog.ml`
  (slated for `storage`); `logical.ml`, `physical.ml`,
  `translate.ml`, `projection.ml` (slated for `plan`);
  `ast.ml`, `parser.ml`, `lower.ml` (slated for
  `surface_ra`); `eval.ml`, `ddl_executor.ml` (slated for
  `execution`); `cli.ml`, `repl.ml`, `demo_data.ml` (slated
  for `frontend`). Each ships with a `.mli`.

The tests are mostly flat too. `test/core/`, `test/ddl/`, and
`test/helpers/` exist from slice 13; the remaining ~30 test
files sit in `test/` directly.

The work is preparatory for the SQL frontend, which is the
next slice. Per the design doc: "Lands ahead of the SQL
frontend so the second surface slots into the existing shape
rather than forcing a restructure under feature pressure."

## Goal

End-state artefacts:

1. `lib/` contains seven sub-library directories: `core/`,
   `storage/`, `plan/`, `ddl/`, `surface_ra/`, `execution/`,
   `frontend/`. No `.ml` or `.mli` files at the `lib/` root,
   and no `lib/dune`.
2. `bin/main.ml` reaches library code via `Dovetail_frontend`
   and `Dovetail_storage` (the latter for env open/close).
   `bin/dune` lists `(libraries dovetail.frontend
   dovetail.storage)`.
3. `test/` contains nine subdirectories — `core/`, `storage/`,
   `plan/`, `ddl/`, `surface_ra/`, `execution/`, `frontend/`,
   `helpers/` (shared library), and `integration/` (cross-
   library end-to-end). No `test/dune` at the root.
4. `lib/storage/engine.ml` is the renamed-and-extracted form
   of the previous `lib/storage.ml`. Callers reach LMDB
   primitives via `Storage.Engine.X` (with `module Storage =
   Dovetail_storage`).
5. `library-structure.md` is current with the post-slice-16
   reality. `README.md`'s "Next up" reflects shipped slices.
   `CLAUDE.md`'s orientation section names the sub-library
   layout.
6. Every test that existed at the start of the slice still
   exists and still passes, possibly in a new directory.

No behaviour changes. No new tests. No `.mli` surface changes
beyond the `storage` → `engine` rename and the alias-style
adoption.

## Architectural decisions

### Bottom-up extraction order

The five remaining libraries extract in dependency order:
`storage` → `plan` → `surface_ra` → `execution` →
`frontend`. The order is forced by the dep graph — each
library depends only on libraries already extracted (`core`,
`ddl`, or earlier slice-16 extractions). No real choice.

Sizes vary asymmetrically. `storage` has the largest fan-out
(every test, `test_helpers`, `bin/main.ml`, and most residual
lib modules reference it). `plan`, `surface_ra`, `execution`,
and `frontend` have progressively fewer consumers. Step sizes
reflect this.

### Storage extraction splits into two commits

The other four lib extractions land as single commits each:
move files, add dune, rewrite consumers in one go. Storage is
the exception. Its fan-out is too wide to land cleanly in one
commit, so the extraction splits in two:

- **Step 2a — Extract behind shims.** Move the four storage
  modules to `lib/storage/`, rename `storage.ml` → `engine.ml`,
  add the dune file. Leave temporary shim files in residual
  `lib/{storage,encoding,row_codec,catalog}.ml` whose contents
  are one-line `include Dovetail_storage.Engine` (and
  similarly for Encoding/Row_codec/Catalog). Consumers
  continue to use `Dovetail.Storage.foo`,
  `Dovetail.Encoding.foo`, etc. — the shims forward through.
  Build green; no consumer changes.
- **Step 2b — Migrate consumers; delete shims.** Add `module
  Storage = Dovetail_storage` aliases to every consumer
  (residual lib, `test_helpers`, `bin/main.ml`, every flat
  test file referencing storage). Rewrite call sites. Delete
  the four shim files. Build green.

The shim approach lets step 2a be small and structural (move
files + rename + four-line shims + one dune edit) while step
2b absorbs the fan-out as a single coherent kind of edit
(alias add + qualified ref rewrite, applied uniformly). Step
2b is still the largest single commit in the slice, but it's
homogeneous.

Alternatives considered:

- **Bundled into one commit.** Mixes structural moves with
  consumer rewrites in a ~30-file diff. Harder to review.
- **Extract first under the doubled name** (`Storage.Storage.X`
  at every call site). Forces the doubled-name anti-pattern
  even briefly, which the design doc spends paragraphs
  rejecting.
- **Split by consumer audience** (residual lib first, then
  test_helpers + bin, then tests). Each phase would need its
  own scaffolding to keep the build green between commits.
  Doesn't simplify per-file work; triples intermediate states.

### Test mirror is a separate commit per sub-library

Slice 13's precedent: lib extract first, test mirror second.
Two commits per sub-library. Slice 16 continues this for
storage, plan, surface_ra, execution. The frontend mirror and
integration-bucket creation get one commit each (see below)
because they have different shapes.

The lib-extract commit is already the larger of each pair;
bundling the test mirror would inflate it without structural
payoff. Mirror commits are smaller and uniform: rename test
directory, write a new dune file, drop the moved names from
the residual `test/dune`.

### Frontend tests and integration bucket separate

The final test reorg splits across two commits rather than
one. After step 9 (`test/execution/` mirror), the flat
`test/` still contains eight test-like files: `test_cli`,
`test_repl`, `test_demo_data`, `test_pipeline`, `test_dovetail`,
`test_documentation`, `test_doctest`, plus `doctest.ml`
(shared module) and `test_ddl_roundtrip` (which stayed flat
because it's cross-library). These split across two
destinations:

- **`test/frontend/`** (step 11): the three tests that call
  `Cli`, `Repl`, and `Demo_data` directly.
- **`test/integration/`** (step 12): the cross-library tests
  — `test_pipeline` (parse → lower → translate → eval),
  `test_dovetail` (binary subprocess), `test_documentation`
  (end-to-end markdown doctests through `Repl.run`),
  `test_doctest` (tests the shared `doctest.ml` module),
  `test_ddl_roundtrip` (parse composed with format-print),
  and `doctest.ml` itself as a shared sibling module. Step
  12 also takes over the `(deps ../bin/main.exe
  ../docs/*.md)` stanza from the residual `test/dune` and
  deletes the residual file.

Two commits is the natural shape: one per landing site, each
reviewable in isolation.

### Test placement: where the interface lives

Each test goes in the directory of the sub-library whose
interface it calls. Tests that compose interfaces from
multiple sub-libraries — verifying a property of the
composition rather than any single interface — go in
`test/integration/`.

This resolves every test deterministically except for one
judgment call: `test_ddl_roundtrip` asserts `Parser.parse
(Format.statement s) = Ok (Ast.Ddl s)`, calling Parser
(surface_ra) composed with Format (ddl); the property is the
composition, so it lands in `integration/`.

No file-content refactoring during the move. A test file like
`test_translate.ml` that mostly exercises `Translate.translate`
plus one end-to-end pipeline case moves whole to `test/plan/`
on its dominant character. Splitting those mixed files is out
of scope for slice 16.

### Frontend stays as one library

The design doc punts on whether to split `frontend` further:
"`cli`, `repl`, and `fixture` are different jobs but small.
Worth revisiting if `frontend` grows; not now." This slice
keeps `cli`, `repl`, and `demo_data` in one `dovetail.frontend`
library.

`cli` is sixty-odd lines depending only on stdlib; `repl` and
`demo_data` depend on the whole tower below. Splitting would
let `dovetail.cli` exist without dragging in the tower, but
nothing currently consumes `Cli.parse` without also wanting
`Repl.run` — `bin/main.ml` and `test_cli` are the only
consumers, and `bin/main.ml` uses `Frontend.Repl.run`
immediately after parsing argv.

The decision can be revisited cheaply if `frontend` grows —
splitting one library into smaller pieces is the same kind of
extraction slice 16 is doing, just smaller.

### CLAUDE.md updates land consolidated at the end

The design doc leaves CLAUDE.md updates' timing open. Two
plausible shapes: inline (each lib-extract step adds a small
CLAUDE.md note) or consolidated (one closing step rewrites
the relevant sections once the new layout is in front of
you).

This slice takes the consolidated approach. Step 13 is the
single CLAUDE.md commit. Inline updates would each be 2–3
lines and risk drift across steps; one closing commit
describes the shape coherently.

The orientation section expands from "`lib/` for library code"
to name the seven sub-libraries. The cross-library aliases
section already exists from slice 13 and gets reviewed for
currency rather than rewritten.

### Step granularity

Fourteen steps plus the plan commit. Sized to match slice 13
(eight steps for two libs) and slice 14 (eight steps for
DDL part 2). Per-sub-library lib + test pair, plus the
doc-cleanup head and CLAUDE.md tail, plus the storage 2a/2b
split, plus the frontend/integration test reorg split.

Step 2b is the largest single commit by file count (~25 files
touched, all alias rewrites). Every other commit is in the
same size range as slice 13's step 4.

## Steps

Fourteen steps plus the plan commit. Each step ends with
`dune test` green, formatter clean, and a sensible commit. No
new tests; existing tests either keep working unchanged or
follow their source modules into new locations.

### Step 1 — Roadmap and design-doc cleanup

No code moves. Three doc files updated:

- **README.md.** "Next up" section rewritten. Shipped slices
  (13/14/15) drop off; what was item 5 (Minimal SQL frontend)
  becomes the next forward-looking entry after slice 16. Body
  text reflects slice 16 in progress, slice 17 ahead.
- **docs/plans/library-structure.md.** Brought current:
  `lib/ddl/` content listed as `statement.ml` plus
  `format.ml`; `frontend` content listed as `cli`, `repl`,
  `demo_data` (not `fixture`); the directory layout sketch
  updated. "Open items" section trimmed: the `dune-project`
  package declaration is struck (already present); the
  frontend-split decision is struck (no, decided in slice
  16); ordering and CLAUDE.md updates are struck (resolved
  by this slice plan). Trailing empty section replaced with
  a single sentence noting the design is fully resolved by
  slice 16, or deleted outright.
- **No new file created.** The slice plan file (this one)
  was committed before step 1.

### Step 2a — Extract `lib/storage/` behind shims

Move four module pairs from `lib/` to `lib/storage/`:

- `lib/storage/engine.ml` and `.mli` (renamed from
  `lib/storage.ml` and `.mli`).
- `lib/storage/encoding.ml` and `.mli`.
- `lib/storage/row_codec.ml` and `.mli`.
- `lib/storage/catalog.ml` and `.mli`.

New `lib/storage/dune`:

```dune
(library
 (name dovetail_storage)
 (public_name dovetail.storage)
 (libraries dovetail.core lmdb unix))
```

Internal cross-references inside `lib/storage/` files are
unprefixed (siblings under the same wrapper). `Catalog` keeps
referencing `Engine` and the others without aliases.

Replace the four files at the old paths with temporary shim
files:

```ocaml
(* lib/storage.ml — temporary migration shim for slice 16 step 2b *)
include Dovetail_storage.Engine
```

(and analogous one-liners for `lib/encoding.ml`,
`lib/row_codec.ml`, `lib/catalog.ml`.) Delete the
corresponding `.mli` files at the old paths — `.mli`
enforcement returns in step 2b when consumers go through
`Dovetail_storage` directly.

`lib/dune` updated:

```dune
(library
 (name dovetail)
 (libraries dovetail.core dovetail.ddl dovetail.storage angstrom))
```

(`lmdb` and `unix` removed — transitively available via
`dovetail.storage`.)

No consumer code changes. `Dovetail.Storage.open_environment`,
`Dovetail.Encoding.encode_int64`, etc. continue to resolve
through the shims. Build green.

### Step 2b — Migrate storage consumers; delete shims

Touch every consumer of the four migrated modules. Each gets
a top-of-file `module Storage = Dovetail_storage` alias and
qualified-ref rewrites:

- `Dovetail.Storage.open_environment` →
  `Storage.Engine.open_environment`
- `Dovetail.Encoding.encode_int64` →
  `Storage.Encoding.encode_int64`
- `Dovetail.Row_codec.encode_row` →
  `Storage.Row_codec.encode_row`
- `Dovetail.Catalog.lookup` → `Storage.Catalog.lookup`

Files touched:

- Residual `lib/`: `eval`, `ddl_executor`, `repl`, `demo_data`,
  and any module currently referencing the four shimmed names.
- `test/helpers/test_helpers.ml`. The `open Dovetail` stays
  for now (other residual modules — `Eval`, `Physical`, etc.
  — still live in `Dovetail`).
- `bin/main.ml`. Adds `module Storage = Dovetail_storage`;
  rewrites the two `Dovetail.Storage` references.
- Every test file under `test/` that references a storage
  module via `open Dovetail`. From the current tree: most
  `test_eval_*`, `test_catalog`, `test_storage`,
  `test_encoding`, `test_row_codec`, `test_translate*`,
  `test_ddl_executor`, `test_demo_data`, `test_pipeline`,
  `test_dovetail` (transitively via test_helpers env open),
  `test_documentation`, `test_doctest`, `test_ddl_roundtrip`,
  `test_repl`. Pragmatic discovery: `dune test` after
  deleting the shims surfaces every remaining unresolved
  reference.

`bin/dune` updated:

```dune
(executable
 (name main)
 (public_name dovetail)
 (libraries dovetail dovetail.storage))
```

`test/helpers/dune` updated:

```dune
(library
 (name test_helpers)
 (libraries alcotest dovetail dovetail.core dovetail.storage unix))
```

`test/dune` updated to add `dovetail.storage` to its
`(libraries ...)` list.

Delete the four shim files at `lib/{storage,encoding,row_codec,catalog}.ml`.

### Step 3 — Mirror `test/storage/`

Move four test files from `test/` to `test/storage/`:

- `test_storage.ml` (tests `Engine`; file name unchanged for
  now — see "Out of scope").
- `test_encoding.ml`.
- `test_row_codec.ml`.
- `test_catalog.ml`.

New `test/storage/dune`:

```dune
(tests
 (names test_storage test_encoding test_row_codec test_catalog)
 (libraries alcotest dovetail.core dovetail.storage test_helpers))
```

Remove these four names from `test/dune`'s `(names ...)`.

### Step 4 — Extract `lib/plan/`

Move four module pairs from `lib/` to `lib/plan/`:

- `logical.ml`/`.mli`
- `physical.ml`/`.mli`
- `translate.ml`/`.mli`
- `projection.ml`/`.mli`

New `lib/plan/dune`:

```dune
(library
 (name dovetail_plan)
 (public_name dovetail.plan)
 (libraries dovetail.core))
```

`lib/dune` updated:

```dune
(library
 (name dovetail)
 (libraries dovetail.core dovetail.ddl dovetail.storage dovetail.plan angstrom))
```

Consumers (residual `lib/`, `test_helpers`, every test
referencing `Logical`, `Physical`, `Translate`, or
`Projection`) get `module Plan = Dovetail_plan` aliases and
qualified-ref rewrites (`Logical.X` → `Plan.Logical.X`, etc.).

`test_helpers/dune` adds `dovetail.plan`. `test/dune` adds
`dovetail.plan`.

### Step 5 — Mirror `test/plan/`

Move six test files from `test/` to `test/plan/`:

- `test_logical.ml`
- `test_physical.ml`
- `test_projection.ml`
- `test_translate.ml`
- `test_translate_index_lookup.ml`
- `test_translate_indexed_nested_loop_join.ml`

New `test/plan/dune`:

```dune
(tests
 (names test_logical test_physical test_projection test_translate
        test_translate_index_lookup test_translate_indexed_nested_loop_join)
 (libraries alcotest dovetail dovetail.core dovetail.storage dovetail.plan test_helpers))
```

The `test_translate_*` files include pipeline tests that call
`Eval.eval`; `Eval` still lives in the residual `dovetail`
library at this point, so the dep stays. After step 8
extracts `execution`, this test dir's `dovetail` dep can be
narrowed — handled in passing during step 8.

Remove these names from `test/dune`'s `(names ...)`.

### Step 6 — Extract `lib/surface_ra/`

Move three module pairs from `lib/` to `lib/surface_ra/`:

- `ast.ml`/`.mli`
- `parser.ml`/`.mli`
- `lower.ml`/`.mli`

New `lib/surface_ra/dune`:

```dune
(library
 (name dovetail_surface_ra)
 (public_name dovetail.surface_ra)
 (libraries dovetail.core dovetail.plan dovetail.ddl angstrom))
```

`lib/dune` updated:

```dune
(library
 (name dovetail)
 (libraries dovetail.core dovetail.ddl dovetail.storage dovetail.plan dovetail.surface_ra))
```

(`angstrom` removed — migrates to `dovetail.surface_ra`.)

Consumers get `module Surface_ra = Dovetail_surface_ra`
aliases. Files touched: residual `lib/` (`repl`, `demo_data`,
and anything piping the AST through), `test_helpers` if it
references `Ast` or `Lower`, and tests still in flat `test/`
that reference these modules (`test_ddl_roundtrip` for
`Parser` and `Ast`; `test_pipeline` for parse-through-eval).

`test/dune` updated to add `dovetail.surface_ra` to its
`(libraries ...)` list.

### Step 7 — Mirror `test/surface_ra/`

Move three test files:

- `test_parser.ml`
- `test_expression_parser.ml`
- `test_lower.ml`

New `test/surface_ra/dune`:

```dune
(tests
 (names test_parser test_expression_parser test_lower)
 (libraries alcotest dovetail dovetail.core dovetail.ddl dovetail.surface_ra test_helpers))
```

Remove these names from `test/dune`'s `(names ...)`.

### Step 8 — Extract `lib/execution/`

Move two module pairs from `lib/` to `lib/execution/`:

- `eval.ml`/`.mli`
- `ddl_executor.ml`/`.mli`

New `lib/execution/dune`:

```dune
(library
 (name dovetail_execution)
 (public_name dovetail.execution)
 (libraries dovetail.core dovetail.storage dovetail.plan dovetail.ddl))
```

`lib/dune` updated:

```dune
(library
 (name dovetail)
 (libraries dovetail.core dovetail.ddl dovetail.storage dovetail.plan
            dovetail.surface_ra dovetail.execution))
```

Consumers get `module Execution = Dovetail_execution` (or
per-module aliases — settle when implementing). Residual
`lib/`: `repl`, `demo_data`. `test_helpers` gains the alias
and updates `evaluate_against_fixture` and similar helpers.
Flat tests referencing `Eval` or `Ddl_executor`: most of the
remaining test files, since `Eval` is what runs the
pipelines.

`test_helpers/dune` adds `dovetail.execution`. `test/dune`
adds `dovetail.execution`.

`test/plan/dune`'s `dovetail` dep can drop now that
`test_translate_*`'s pipeline subtests reach `Eval` via
`dovetail.execution` — settle by reading the actual deps
each test pulls.

### Step 9 — Mirror `test/execution/`

Move ten test files:

- `test_eval_full_scan.ml`
- `test_eval_filter.ml`
- `test_eval_project.ml`
- `test_eval_cross_product.ml`
- `test_eval_nested_loop_join.ml`
- `test_eval_index_lookup.ml`
- `test_eval_indexed_nested_loop_join.ml`
- `test_eval_relation_literal.ml`
- `test_eval_insert.ml`
- `test_ddl_executor.ml`

New `test/execution/dune`:

```dune
(tests
 (names test_eval_full_scan test_eval_filter test_eval_project
        test_eval_cross_product test_eval_nested_loop_join
        test_eval_index_lookup test_eval_indexed_nested_loop_join
        test_eval_relation_literal test_eval_insert test_ddl_executor)
 (libraries alcotest dovetail dovetail.core dovetail.storage
            dovetail.plan dovetail.ddl dovetail.surface_ra
            dovetail.execution test_helpers))
```

(Test files exercise the full plan→exec path; several read
parsed expressions, so `dovetail.surface_ra` is in the deps.
Confirmed against actual `open`s during implementation.)

Remove these names from `test/dune`'s `(names ...)`.

### Step 10 — Extract `lib/frontend/`; rewire `bin/`; delete `lib/dune`

Move three module pairs from `lib/` to `lib/frontend/`:

- `cli.ml`/`.mli`
- `repl.ml`/`.mli`
- `demo_data.ml`/`.mli`

New `lib/frontend/dune`:

```dune
(library
 (name dovetail_frontend)
 (public_name dovetail.frontend)
 (libraries dovetail.core dovetail.storage dovetail.plan dovetail.ddl
            dovetail.surface_ra dovetail.execution))
```

`bin/main.ml` rewritten to use the new aliases:

```ocaml
module Storage  = Dovetail_storage
module Frontend = Dovetail_frontend

let usage program_name =
  Printf.sprintf "usage: %s [%s] [%s] [environment-path]" program_name
    Frontend.Cli.show_physical_flag Frontend.Cli.demo_data_flag

(* ... and Cli.parse, Storage.Engine.open_environment / close_environment,
   Demo_data.run, Repl.run follow the same pattern. *)
```

`bin/dune` finalised:

```dune
(executable
 (name main)
 (public_name dovetail)
 (libraries dovetail.frontend dovetail.storage))
```

**Delete `lib/dune`.** Residual `lib/` now contains only the
seven sub-library subdirectories — no `.ml` files at the
root, no flat dune. dune walks into the subdirectories
automatically.

`test_helpers/dune` finalised — drop `dovetail`, list the
sub-libraries the helper actually uses:

```dune
(library
 (name test_helpers)
 (libraries alcotest dovetail.core dovetail.storage dovetail.plan
            dovetail.execution dovetail.ddl unix))
```

(Exact dep list audited at implementation.)

The residual `test/dune` survives this step but no longer
lists `dovetail`. Its `(libraries ...)` becomes the per-test
sub-library list, and its `(names ...)` still includes the
seven flat tests (`test_cli`, `test_repl`, `test_demo_data`,
`test_pipeline`, `test_dovetail`, `test_documentation`,
`test_doctest`) plus `test_ddl_roundtrip`. Each of these test
files gets its `open Dovetail` replaced with the appropriate
sub-library aliases.

This step is the second-largest in the slice after step 2b.
The work is mostly mechanical alias rewrites in the seven
flat-test files plus `bin/main.ml`, with the structural
filesystem changes (move three files, delete `lib/dune`) as a
small additional change.

### Step 11 — Mirror `test/frontend/`

Move three test files from `test/` to `test/frontend/`:

- `test_cli.ml`
- `test_repl.ml`
- `test_demo_data.ml`

New `test/frontend/dune`:

```dune
(tests
 (names test_cli test_repl test_demo_data)
 (libraries alcotest dovetail.core dovetail.storage dovetail.ddl
            dovetail.frontend test_helpers))
```

Remove these three names from the residual `test/dune`.

### Step 12 — Create `test/integration/`; delete `test/dune`

Create `test/integration/` and move the remaining test-like
files plus the shared `doctest` module:

- `test_pipeline.ml`
- `test_dovetail.ml`
- `test_documentation.ml`
- `test_doctest.ml`
- `test_ddl_roundtrip.ml` (cross-library composition per the
  test-placement decision)
- `doctest.ml` (and `.mli` if it exists) — shared module, not
  a test executable.

New `test/integration/dune`:

```dune
(tests
 (names test_pipeline test_dovetail test_documentation test_doctest
        test_ddl_roundtrip)
 (libraries alcotest dovetail.core dovetail.storage dovetail.ddl
            dovetail.plan dovetail.surface_ra dovetail.execution
            dovetail.frontend test_helpers)
 (deps
  ../../bin/main.exe
  ../../docs/query-language.md
  ../../docs/query-language-tutorial.md
  ../../docs/query-language-pipeline-operators.md
  ../../docs/query-language-expressions.md
  ../../docs/query-language-data-definition.md
  ../../README.md))
```

(Relative paths in `(deps ...)` gain an extra `../` because
the test directory moved one level deeper.)

`doctest.ml` is compiled into each test executable via the
implicit `(modules :standard)` — it's not listed in `(names
...)`, so dune doesn't try to build it as a standalone test
binary, but it's available as the `Doctest` module to the
tests that use it.

**Delete the residual `test/dune`.** The flat `test/`
directory now contains only subdirectories: `core/`,
`storage/`, `plan/`, `ddl/`, `surface_ra/`, `execution/`,
`frontend/`, `helpers/`, `integration/`.

### Step 13 — CLAUDE.md updates

Edit `CLAUDE.md` to reflect the new layout. Two sections
touched:

- **Orientation.** The bullet "`lib/` for library code,
  `bin/` for the executable, `test/` for tests" expands to
  name the seven sub-libraries and note the test mirror.
  Suggested rewrite:

  > `lib/` for library code, organised into seven sub-libraries
  > under their own dune libraries: `core`, `storage`, `plan`,
  > `ddl`, `surface_ra`, `execution`, `frontend`. `bin/` for
  > the executable. `test/` mirrors `lib/` (`test/core/`,
  > `test/storage/`, …), plus `test/helpers/` for shared test
  > infrastructure and `test/integration/` for end-to-end
  > tests that cross library boundaries.

- **Cross-library aliases.** The section exists from slice 13.
  Review for currency — the existing examples (`module Ddl =
  Dovetail_ddl`, `module Value = Dovetail_core.Value`) still
  read well, but the prose can mention the five additional
  libraries that slice 16 brought in. Add or adjust the
  rule-of-thumb wording if any new alias-style decisions
  emerged during slice 16's work (e.g. `Plan.`, `Storage.`,
  `Frontend.` library-style aliases sit alongside `core`'s
  per-module style).

No other CLAUDE.md sections need edits.

## Verification

End-of-slice sanity checks:

- `dune build` clean. The dependency graph walks through
  seven sub-libraries (`dovetail.core`, `dovetail.ddl`,
  `dovetail.storage`, `dovetail.plan`, `dovetail.surface_ra`,
  `dovetail.execution`, `dovetail.frontend`) plus
  `test_helpers` plus nine test-group `(tests ...)` stanzas.
- `dune test` green. Every alcotest suite that existed at the
  start of the slice is still present, possibly in a new
  directory.
- `dune build @fmt --auto-promote` clean.
- REPL smoke test: `./dovetail` with no args boots empty;
  `./dovetail --demo-data` seeds `users` and `orders`; a
  representative pipeline query (`users | join orders on
  users.id = orders.user_id`) returns the expected rows.
- Filesystem invariants:
  - No `.ml` or `.mli` files directly under `lib/`.
  - No `lib/dune`.
  - No `.ml` or `.mli` test files directly under `test/`.
  - No `test/dune`.
  - `lib/storage/engine.ml` exists; no `lib/storage.ml`
    exists.
- Boundary enforcement is real: no file under `lib/core/`
  references anything outside `core`; no file under
  `lib/storage/` references anything outside `core` or
  storage primitives; no file under `lib/plan/` references
  storage or anything above plan in the tower.

## Out of scope

- **Test file content refactoring.** Files like
  `test_translate.ml` that mix unit and end-to-end
  assertions move whole on their dominant character.
  Splitting them is a separate concern.
- **Renaming `test_storage.ml` to `test_engine.ml`.** The
  file's current name matches its original module subject.
  Renaming to match the new `Engine` module name is a fine
  cleanup but not part of the structural extraction. Defer.
- **Splitting `frontend` into smaller libraries.** Decided
  no for now; revisit if `frontend` grows.
- **The SQL frontend (`surface_sql`).** Slice 17.
- **Re-exposing storage primitives through `frontend`** so
  `bin/dune` could list only `(libraries dovetail.frontend)`.
  The current shape — `bin/main.ml` owns env lifecycle and
  depends on `dovetail.storage` directly — is fine and
  matches the design doc's example. Refactoring env
  lifecycle into `frontend` is a content change, not a
  structural extraction.
- **Behaviour changes anywhere.** This is a pure
  restructure; existing tests stay green at every commit
  boundary; no new tests land for behaviour that hasn't
  changed.
