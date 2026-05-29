# Slice 13: DDL and library prep

A preparatory restructure slice with no user-visible behaviour
change. Splits the current `Ddl` module into `Statement` (the DDL
AST) and `Ddl_executor` (the catalog-touching executor), then
extracts `core` and `ddl` as the first two dune sub-libraries.
Sets the patterns — alias style, test mirroring, error-prefix
policy — that slice 16's full sub-library extraction will follow
uniformly.

The design that shapes this slice lives in
[`docs/plans/library-structure.md`](library-structure.md). That
document covers the eventual seven-library layout, the wrapping
model, the alias conventions, and the `Ddl` split rationale.
This slice plan implements the seed of that design: the `Ddl`
split plus the first two libraries.

## Context

Slice 12 landed `:list tables` and `:drop table`, growing the
`Ddl` module to its current shape: a single file that holds both
the DDL AST (constructors, result types, `classify`) and the
executor that runs DDL statements against the catalog. The two
halves serve opposite-direction roles — the AST is a vocabulary
every surface language produces and the REPL pattern-matches on;
the executor is the DDL twin of `Eval`, depending on `Catalog`
and `Storage`. Under the single-library layout the mixing is
invisible; under the sub-library layout planned in
`library-structure.md` it forces the AST and executor halves
into different rungs of the dependency tower.

Two pressures drive the prep now:

1. **Slice 14 grows the DDL module substantially.** It adds
   `Ddl.validate`, the canonical-form printer, the
   `Create_table` and `Describe` constructors, and result-type
   constructors `Created` and `Described`. Splitting AST from
   executor before that growth means slice 14's additions land
   in the right modules, rather than into a fatter monolith
   that we then have to cleave.
2. **Slice 16's full restructure needs precedent.** Extracting
   all seven libraries at once would be a large, risky commit
   with no working intermediate states. Establishing `core` and
   `ddl` now — the two least entangled libraries — exercises
   the dune mechanics, the wrapping model, and the alias style
   on a smaller surface, so slice 16 can follow the pattern
   rather than invent it.

The pure refactor framing means no behaviour changes anywhere.
Existing tests must stay green at every commit boundary; no new
test cases land for behaviour that hasn't changed.

## Goal

End-state artefacts:

1. `lib/ddl.ml`/`.mli` no longer exist. The DDL AST, result
   types, and `classify` live in `lib/ddl/statement.ml`/`.mli`
   under the new `dovetail.ddl` library. The executor lives in
   `lib/ddl_executor.ml`/`.mli` in the residual main library.
2. The dominant type of the DDL AST module is `Statement.t`
   (renamed from `Ddl.statement`), matching the project's `.t`
   convention.
3. `core` is its own dune sub-library at `lib/core/`. Holds
   `value`, `schema`, `expression`, `relation`, and
   `relation_literal`. Public name `dovetail.core`; internal
   name `dovetail_core`.
4. `ddl` is its own dune sub-library at `lib/ddl/`. Holds
   `statement`. Public name `dovetail.ddl`; internal name
   `dovetail_ddl`.
5. The residual `dovetail` library at `lib/` lists both
   `dovetail.core` and `dovetail.ddl` in its `(libraries ...)`
   stanza.
6. Cross-library references from the residual `dovetail`
   library use per-module aliases for `core`
   (`module Value = Dovetail_core.Value`) and a library alias
   for `ddl` (`module Ddl = Dovetail_ddl` →
   `Ddl.Statement.t`).
7. `test/` mirrors `lib/` for the extracted libraries:
   `test/core/` holds the five `core` test files plus
   `test_expression_format.ml`; `test/ddl/` holds the renamed
   `test_statement.ml`. The flat `test/` directory keeps every
   other test file.
8. `test_helpers` is its own dune library at
   `test/helpers/`, so any per-group test stanza can depend on
   it.
9. The DDL executor's user-facing error string starts with
   `DDL:` rather than `Ddl:`. CLAUDE.md's error-prefix rule is
   reframed around the user-facing layer name rather than the
   module name.
10. CLAUDE.md gains a short note about the cross-library alias
    convention, landing alongside the first aliases.

End-state non-artefacts:

- No behaviour changes anywhere. Existing tests are reorganised
  (file moves, name updates) but no new test cases are added
  and no existing test bodies change semantically.
- No changes to the public `Statement.t` / `Ddl_executor`
  surface beyond renames. Slice 14 adds `validate`, the
  canonical-form printer, and new constructors.
- The remaining five libraries (`storage`, `plan`,
  `surface_ra`, `execution`, `frontend`) stay inside the
  residual main library. Slice 16 extracts them.

## Architectural decisions

### Three logical phases

The slice has three phases that produce eight commits:

- **Phase 1 (steps 1–3): the `Ddl` split.** Happens entirely
  inside the current single-library layout. No dune changes.
  Pure module surgery — the AST and result types move to a new
  `Statement` module, the executor functions move to a new
  `Ddl_executor` module, and `lib/ddl.ml`/`.mli` are deleted.
- **Phase 2 (steps 4–6): extract `core`.** First dune
  sub-library. Five module pairs move into `lib/core/`; the
  residual `lib/dune` gains `(libraries dovetail.core)`. Test
  mirroring is established at the same time: `test_helpers`
  becomes its own library so `test/core/` can depend on it,
  and the six relevant test files move into `test/core/`.
- **Phase 3 (steps 7–8): extract `ddl`.** Second sub-library.
  The `Statement` module migrates from `lib/` to `lib/ddl/`;
  test mirroring follows.

The phase boundaries aren't called out in the step numbering —
the steps run 1–8 flat — but each phase ends in a coherent
state. Phase 1 leaves the project still single-library but with
the AST/executor split in place. Phase 2 leaves a two-library
layout with `core` extracted. Phase 3 brings `ddl` in.

### Alias style: per-module for `core`, library for `ddl`

Two cross-library alias styles exist:

- **Library alias** — `module Ddl = Dovetail_ddl` at the top of
  the file; references become `Ddl.Statement.t`. Keeps group
  membership visible at the call site.
- **Per-module alias** — `module Value = Dovetail_core.Value`
  for each used module; references stay unchanged (`Value.t`).
  Smaller per-file diff and less prefix noise.

For `core`, **per-module aliases**. The `core` types (`Value`,
`Schema`, `Relation`, `Expression`, `Relation_literal`) are
pervasive — half the lines of any given file mention one.
Prefixing every reference with `Core.` would add noise without
signal because "this is a core type" is true of nearly
everything. Per-module aliases mean step 4's diff is
concentrated in dune files plus a small alias block at the top
of each consuming file, with zero churn at type signatures and
pattern matches.

For `ddl` (and any future library), **library alias**. The
prefix `Ddl.` actually carries information — "this is the DDL
vocabulary" — because DDL is a localised concern. The
design's stated rationale ("`Storage.Catalog.lookup` keeps
group membership visible") cuts hard here.

The general rule, captured in CLAUDE.md after step 4:
library alias by default; per-module alias for `core` and any
other library where the prefix would be noise rather than
signal.

### Test mirroring starts in this slice

The design doc puts test mirroring in scope for the full
restructure. This slice establishes the pattern from the first
extraction rather than waiting for slice 16: `test/core/` and
`test/ddl/` are their own `(tests ...)` stanzas with their own
dependency lists. The remaining 30+ test files stay flat for
now; slice 16 mirrors the rest when it extracts the remaining
libraries.

Mirroring requires `test_helpers` to be its own dune library —
otherwise the new per-group stanzas can't reach the shared
helpers. Step 5 promotes it.

When step 6 moves the `core` tests, we audit `test_helpers`
usage. If any helpers are only used by `core` tests, they get
pulled into a `test/core/`-local helper file rather than
staying in the shared library. The shared library should
contain only genuinely cross-cutting helpers.

### Error-prefix convention: user-facing, not module-named

The current CLAUDE.md rule says every user-facing error string
starts with a module-name prefix. After the `Ddl` split, the
only error-raising path is `Ddl_executor.drop_table`'s "no
such table" check. Strict module-name compliance would give
`Ddl_executor: drop table "foo": no such table` — exposing
an internal implementation split at the user surface. The
user typed `:drop table foo`; they're in "DDL land"; "executor"
is implementation noise.

This slice reframes the rule around the user-facing layer
rather than the implementation module. The error string
becomes `DDL: drop table "foo": no such table`. The CLAUDE.md
rewrite (step 2) makes the rule explicit: prefixes name the
user-facing concept, which usually matches a module name but
doesn't have to.

The change is scoped to slice 13's error string. Existing
prefixes elsewhere (`Translate:`, `Eval:`, `Projection.resolve:`,
`Schema.assemble_tuple:`) all incidentally match both their
module name and the user-facing layer, so they're unchanged.
Any future divergence will be settled per case.

### Step granularity matches slice 12

Slice 12 averaged ~10 commits of 1–3 files each. This slice
has eight commits of comparable size, except step 4 (extract
`core` lib-side). Step 4 is the irreducibly big one: once
`Value` and the other four core modules move out of `lib/`,
every file referencing them needs the alias in the same
commit or the build breaks. There's no honest way to
half-extract a library, so step 4 stands as the slice's largest
single commit. The alternative — extracting one module at a
time across five commits — would produce asymmetric
intermediate states where some `core` modules are extracted and
others aren't, which reads worse than one coherent move.

### Forward-references in older docs

`docs/plans/12-list-and-drop-tables.md` and
`docs/plans/ddl-design.md` mention "slice 13: describe and
create" and "slice 14: fixture retirement" — both off by one
under the new numbering. Step 1 updates these references as a
small docs cleanup. Slice plans aren't load-bearing historical
records; they're current guides, and bringing them in sync
with the README's roadmap avoids future "wait, which slice 13?"
confusion.

## Steps

Eight steps. Steps 1–3 land the `Ddl` split inside the existing
single-library layout. Steps 4–6 extract `core` and establish
test mirroring. Steps 7–8 extract `ddl`.

Each step ends with `dune test` green, formatter clean, and a
sensible commit. No new test cases are added; existing tests
either keep working unchanged or follow their source modules
into new locations.

### Step 1 — Extract `Statement` module

Move the AST half of `lib/ddl.ml` into a new `lib/statement.ml`
and `lib/statement.mli`:

- `type t = List_tables | Drop_table of { table_name : string }`
  (renamed from `type statement`).
- `type read_result = Listed of string list`.
- `type write_result = Dropped of string`.
- `val classify : t -> [ `Read | `Write ]`.

The new module's `.mli` carries forward the module-level doc
comment about DDL's role, with the slice-13 reference updated
to point at slice 14 for describe/create. Per-`val` doc
comments stay close to their current text, adjusted for the
new module name.

`lib/ddl.ml` and `lib/ddl.mli` keep `execute_read` and
`execute_write` for the moment; their signatures change from
`statement` to `Statement.t` and from `read_result` /
`write_result` to `Statement.read_result` /
`Statement.write_result`.

Call-site updates:

- `lib/ast.ml`, `lib/ast.mli`: `Ddl of Ddl.statement` →
  `Ddl of Statement.t`.
- `lib/parser.ml`: `Ddl.List_tables` → `Statement.List_tables`,
  `Ddl.Drop_table` → `Statement.Drop_table`.
- `lib/parser.mli`: doc-comment cross-ref updates.
- `lib/repl.ml`: `Ddl.Listed`, `Ddl.Dropped`, `Ddl.classify` →
  `Statement.Listed`, `Statement.Dropped`, `Statement.classify`.
- `lib/ddl.ml` internals: `List_tables` and `Drop_table`
  constructors in pattern matches stay bare (in-scope siblings
  inside the same wrapper).
- `test/test_ddl.ml`, `test/test_parser.ml`: references updated.

Documentation cleanup bundled into this commit:

- `docs/plans/12-list-and-drop-tables.md`: forward
  references to slices 13/14 updated to 14/15.
- `docs/plans/ddl-design.md`: same.

### Step 2 — Extract `Ddl_executor` module

Move the executor half of `lib/ddl.ml` into a new
`lib/ddl_executor.ml` and `lib/ddl_executor.mli`:

- `val execute_read : Storage.environment -> [> `Read ] Storage.transaction -> Statement.t -> Statement.read_result`.
- `val execute_write : Storage.environment -> [ `Read | `Write ] Storage.transaction -> Statement.t -> Statement.write_result`.
- The private `drop_table` helper from the current `Ddl` body.

`lib/ddl.ml` and `lib/ddl.mli` are deleted at the end of this
step.

Call-site updates:

- `lib/repl.ml`: `Ddl.execute_read` → `Ddl_executor.execute_read`,
  `Ddl.execute_write` → `Ddl_executor.execute_write`.
- `lib/catalog.mli`, `lib/storage.mli`, `lib/ast.mli`:
  doc-comment cross-refs from `{!Ddl.execute_write}` to
  `{!Ddl_executor.execute_write}`.

Error-string and CLAUDE.md update bundled into this commit:

- The `failwith` in `drop_table` changes its prefix from
  `Ddl:` to `DDL:`.
- `CLAUDE.md`'s "Error messages" section is rewritten to frame
  the prefix rule around the user-facing layer rather than the
  module name. Existing examples stay, since they happen to
  satisfy both rules; the `DDL:` example is added.

### Step 3 — Split `test/test_ddl.ml`

Reorganise the test file to match the new module split:

- `test/test_statement.ml` (new) holds the two `classify` tests.
- `test/test_ddl_executor.ml` (new) holds the five execute tests.
- `test/test_ddl.ml` is deleted.
- `test/dune`'s `(names ...)` list drops `test_ddl` and adds
  `test_statement`, `test_ddl_executor`.

Test bodies are unchanged except for the file split and any
module references that now point at `Statement` or
`Ddl_executor` rather than `Ddl`.

### Step 4 — Extract `core` library (lib-side)

The big one. Five module pairs move from `lib/` to
`lib/core/`:

- `value.ml`/`.mli`
- `schema.ml`/`.mli`
- `expression.ml`/`.mli`
- `relation.ml`/`.mli`
- `relation_literal.ml`/`.mli`

New `lib/core/dune`:

```dune
(library
 (name dovetail_core)
 (public_name dovetail.core))
```

`lib/dune` updated:

```dune
(library
 (name dovetail)
 (libraries dovetail.core lmdb unix angstrom))
```

Per-module alias blocks added to every residual `lib/` file
that references a core module. Files that reference one core
module get a one-line alias; files that reference several get
a small block. Internal references inside the moved files
remain unprefixed — they're siblings under the new
`dovetail_core` wrapper.

Files that need alias blocks added (per-module, only where
referenced): `ast.ml`/`.mli`, `catalog.ml`/`.mli`,
`encoding.ml`/`.mli`, `eval.ml`/`.mli`, `fixture.ml`,
`logical.ml`/`.mli`, `parser.ml`/`.mli`, `physical.ml`/`.mli`,
`projection.ml`/`.mli`, `repl.ml`, `row_codec.ml`/`.mli`,
`translate.ml`/`.mli`, `statement.mli` and
`ddl_executor.ml`/`.mli` (if they touch core types — they
don't in the slice-13 shape, but step 4 sweeps consistently).

CLAUDE.md gains a "Cross-library aliases" subsection in the
conventions area: library alias by default; per-module alias
for `core` and any future library where the prefix would be
noise rather than signal. The note lands in this commit,
where a reader encountering the alias blocks at the top of
files can find the convention.

After this step the build still produces the same artefacts,
but `core` is its own opam-visible package and the dependency
boundary is enforced.

### Step 5 — Promote `test_helpers` to its own library

`test/test_helpers.ml` moves to `test/helpers/test_helpers.ml`.
New `test/helpers/dune`:

```dune
(library
 (name test_helpers))
```

`test/dune`'s `libraries` stanza adds `test_helpers`. Every
flat test that currently references `Test_helpers` continues
to work without change.

No test code changes. The file move and the two dune lines are
the entire commit.

### Step 6 — Mirror `test/core/`

Six test files move from `test/` to `test/core/`:

- `test_value.ml`
- `test_schema.ml`
- `test_expression.ml`
- `test_expression_format.ml`
- `test_relation.ml`
- `test_relation_literal.ml`

New `test/core/dune`:

```dune
(tests
 (names
  test_value
  test_schema
  test_expression
  test_expression_format
  test_relation
  test_relation_literal)
 (libraries alcotest dovetail.core test_helpers))
```

`test/dune`'s `(names ...)` list drops the six moved entries.

`test_helpers` audit: walk through the helpers
`test_schema.ml`, `test_expression.ml`, and any other moved
test references. If a helper is used only by `core` tests,
pull it into a new `test/core/test_helpers_local.ml` (or
similar — name to be settled when we get there) rather than
keeping it in the shared library. The shared library should
hold only genuinely cross-cutting helpers (temp directories,
environment scope guards, etc.).

After this step the build still passes, and a `core` test
that tried to reference `Storage` or `Plan` would fail at
build time — the dependency boundary is enforced for the
extracted tests.

### Step 7 — Extract `ddl` library (lib-side)

`lib/statement.ml` and `lib/statement.mli` move to
`lib/ddl/statement.ml` and `lib/ddl/statement.mli`.

New `lib/ddl/dune`:

```dune
(library
 (name dovetail_ddl)
 (public_name dovetail.ddl))
```

`lib/dune` updated:

```dune
(library
 (name dovetail)
 (libraries dovetail.core dovetail.ddl lmdb unix angstrom))
```

Call-site updates (library-alias style, not per-module):

- `lib/ast.ml`, `lib/ast.mli`: add
  `module Ddl = Dovetail_ddl` at the top; change `Statement.t`
  to `Ddl.Statement.t`. The existing `Ddl` constructor of
  `Ast.program` is unaffected (constructors and modules are
  separate namespaces); `Ast.Ddl Ddl.Statement.List_tables`
  reads correctly.
- `lib/parser.ml`: same alias; `Statement.List_tables` →
  `Ddl.Statement.List_tables`, `Statement.Drop_table` →
  `Ddl.Statement.Drop_table`.
- `lib/repl.ml`: same alias; `Statement.classify`,
  `Statement.Listed`, `Statement.Dropped` qualify with `Ddl.`.
- `lib/ddl_executor.ml`/`.mli`: same alias; `Statement.t`,
  `Statement.read_result`, `Statement.write_result` qualify.

### Step 8 — Mirror `test/ddl/`

`test/test_statement.ml` moves to `test/ddl/test_statement.ml`.

New `test/ddl/dune`:

```dune
(tests
 (names test_statement)
 (libraries alcotest dovetail.ddl test_helpers))
```

`test/dune`'s `(names ...)` list drops `test_statement`.

Test body adds a `module Ddl = Dovetail_ddl` alias at the top
and qualifies constructor references accordingly.
`test_ddl_executor.ml` stays in the flat `test/` directory for
now — it lives with the residual `dovetail` library and
slice 16 will move it into `test/execution/` once `execution`
is extracted.

## Verification

End-of-slice sanity checks (no behaviour-change tests added,
so verification is structural):

- `opam exec -- dune build` is clean. The dependency graph
  walks through three libraries (`dovetail.core`,
  `dovetail.ddl`, `dovetail`) plus `test_helpers` plus the
  two test-group libraries.
- `opam exec -- dune test` is green. Every alcotest suite
  that was present at the start of the slice is still
  present, possibly in a new directory.
- `opam exec -- dune build @fmt --auto-promote` leaves the
  tree clean.
- REPL smoke test (the slice-12 verification list, plus one
  for `:list tables`): `:list tables`, `:drop table orders`,
  `:list tables`, `:drop table nonexistent` all behave
  identically to before. The "no such table" error string
  now reads `DDL: drop table "nonexistent": no such table`.
- `lib/core/`, `lib/ddl/`, `test/core/`, `test/ddl/`, and
  `test/helpers/` each have a single dune file. The residual
  `lib/dune` declares `(libraries dovetail.core dovetail.ddl
  lmdb unix angstrom)`.
- No file under `lib/core/` references anything from outside
  `core` (no `Dovetail_storage`, no `Storage.`, no `Catalog.`,
  etc.). Boundary enforcement is real.

## Out of scope

- **Behaviour changes to DDL.** Slice 14 adds `validate`,
  the canonical-form printer, `Create_table`, `Describe`,
  `Created`, `Described`. None of those land here.
- **Extracting the remaining five libraries.** `storage`,
  `plan`, `surface_ra`, `execution`, `frontend` stay inside
  the residual `dovetail` library until slice 16.
- **Mirroring the remaining test directories.** The flat
  `test/` directory keeps every test file not associated
  with `core` or `ddl`. Slice 16 handles the rest in one
  pass alongside the lib extractions.
- **Inner-module renames for future libraries.** The design
  doc renames `storage.ml` → `engine.ml` to avoid the
  `Dovetail_storage.Storage` collision; that rename lands
  with `storage`'s extraction in slice 16, not now.
- **The `dune-project` package stanza.** Already present
  from earlier work; no changes needed for `public_name`
  declarations to resolve.
- **Fixture retirement.** Slice 15. The fixture still seeds
  `users` and `orders` after this slice.
- **The full sub-library setup CLAUDE.md note about
  directory layout.** Slice 16 lands that, once the layout
  is actually complete. Slice 13's CLAUDE.md edits are
  scoped to the error-prefix rule rewrite and the
  cross-library alias convention.
