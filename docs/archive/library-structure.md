# Library and module structure

This document captures the design for breaking `lib/` (and the
mirroring `test/`) into multiple dune sub-libraries with enforced
dependency boundaries. The aim is to make Dovetail's internal
layering explicit at the build-system level, so the dependency
graph is a tool-checked invariant rather than a discipline.

This is a design document, not a slice plan. *When* the
restructure happens, and how it breaks into commit-sized steps,
is a slice-plan decision. The point here is to settle the shape
so the slice plan can be written without re-litigating the
choices.

## Motivation

`lib/` has grown to twenty-two modules. Looking at the directory
listing, it's no longer immediately obvious which modules are
adjacent in the architecture and which are layers apart. The
mental model — core types, storage, plan IR, surface language,
execution, frontend — is real and consistent in the code, but
nothing in the file layout or build configuration makes it
visible or enforceable.

Two concrete pressures drive the change now rather than later:

1. **Comprehensibility.** A reader (Pete in six months;
   newcomer; future Claude) shouldn't have to grep imports to
   figure out which modules depend on which. The grouping should
   be present in the layout, and the dependency edges should be
   readable in one place.
2. **The SQL surface is coming.** Once a second surface language
   sits alongside the existing relational-algebra one, the
   pipeline group will contain two parallel sets of "ast,
   parser, lower" modules. Settling the structure now means the
   second surface slots into the existing shape rather than
   forcing a restructure under feature pressure.

The restructure has a mechanical, finite cost at call sites:
each cross-library reference gains either a module alias or a
qualified prefix. There's no logic change anywhere except in
the one module split (see "The Ddl split" below). The shape of
the conversion is the same in every file, so the migration is
boring and predictable rather than risky.

## Scope

In scope:

- Splitting `lib/` into multiple dune sub-libraries with
  explicit `(libraries ...)` deps.
- Mirroring that split in `test/`.
- Choosing the wrapping model.
- Naming convention for modules under that wrapping model,
  including the inner-module renames needed to avoid sharing
  names with their containing libraries.
- The shape that accommodates a future SQL surface without
  rework.
- Splitting the current `Ddl` module into AST and executor.

Out of scope:

- The slice plan itself: ordering, commit boundaries, how to
  avoid in-flight build breaks during the migration.
- Performance work, refactoring of module internals, changes to
  the `.mli` surface area beyond what the `Ddl` split requires.
- The SQL surface itself. This doc reserves space for it and
  names how it fits, but designing SQL is a separate exercise.

## The dependency tower

The modules in `lib/` form a clean DAG with five conceptual
layers and two side groups. After mapping every project-level
module reference (filtering out stdlib and doc-comment
cross-references) the layout is:

```
core         value, schema, expression, relation, relation_literal
  ↑
storage      engine, encoding, row_codec, catalog
  ↑
plan         logical, physical, translate, projection
ddl          statement (AST + classifier; no other deps)
surface_ra   ast, parser, lower             (depends on core, plan, ddl)
execution    eval, ddl_executor             (depends on core, storage,
                                             plan, ddl)
  ↑
frontend     cli, repl, demo_data           (depends on everything below)
```

(See "Inner modules don't share library names" below for why
the old `storage.ml` and `ddl.ml` are renamed to `engine.ml`
and `statement.ml`.)

The edges:

- **core** → nothing. Self-contained types.
- **storage** → core. Persistence layer over LMDB.
- **plan** → core. The intermediate-representation tower
  (logical IR, physical IR, the translation between them, and
  `projection` as a transverse helper). Plan modules don't
  touch storage and don't know about any surface language.
- **ddl** → nothing. The DDL AST (`Drop_table`, `Create_table`
  etc.) is shared by every surface language and consumed by
  execution. It's a small library, but giving it its own
  boundary keeps the role explicit: this is the cross-surface
  catalog-statement vocabulary.
- **surface_ra** → core, plan, ddl. The RA-based surface
  language: its AST, its parser, and the lowering pass from
  surface AST to `Logical.plan`.
- **execution** → core, storage, plan, ddl. The modules that
  actually run plans and statements against storage: `eval`
  for query plans, `ddl_executor` for DDL statements.
- **frontend** → everything below. The REPL, the CLI argv
  parser, and the demo-data seeder.

The shape was chosen so that future `surface_sql` slots in
beside `surface_ra` with the same deps (core, plan, ddl) and no
restructure. Plan, execution, and storage carry no
surface-specific knowledge; the surfaces produce `Logical.plan`
and `Statement.t` values (from `dovetail.plan` and
`dovetail.ddl` respectively), which is the contract every
surface meets.

## The Ddl split

The current `lib/ddl.ml` does two jobs that pull in opposite
directions:

1. It defines the DDL AST: `type statement = List_tables |
   Drop_table | ...`, `read_result`, `write_result`, and the
   `classify` function that pattern-matches on the constructor.
2. It executes those statements against the catalog: the
   `execute_read` and `execute_write` functions that take a
   `Storage.transaction` and run the operation.

Job (1) is a vocabulary shared by every surface language (both
the current RA surface and future SQL). Job (2) depends on
`Catalog` and `Storage` — it's the DDL twin of `Eval`.

In the current single-library setup the mixing is invisible.
Under sub-libraries it forces an awkward position: the AST half
wants to sit below the surface languages (which produce
statements) and below execution (which runs them), while the
executor half wants to sit beside `Eval`. The two halves don't
share a natural rung in the tower.

The fix is to split the module along the line that already
exists in `ddl.mli`. The pure half also gets renamed from
`Ddl` to `Statement` so the inner module doesn't share its
library's role-name (see "Inner modules don't share library
names" below):

```ocaml
(* lib/ddl/statement.mli *)

type t = List_tables | Drop_table of { table_name : string }
type read_result  = Listed  of string list
type write_result = Dropped of string

val classify : t -> [ `Read | `Write ]
```

```ocaml
(* lib/execution/ddl_executor.mli *)
(* Inside dovetail_execution; the file's .ml aliases the
   libraries it depends on:
     module Storage = Dovetail_storage
     module Ddl     = Dovetail_ddl                          *)

val execute_read :
  Storage.Engine.environment ->
  [> `Read ] Storage.Engine.transaction ->
  Ddl.Statement.t -> Ddl.Statement.read_result

val execute_write :
  Storage.Engine.environment ->
  [ `Read | `Write ] Storage.Engine.transaction ->
  Ddl.Statement.t -> Ddl.Statement.write_result
```

`Statement` becomes a pure types-and-classifier module with no
project deps. `Ddl_executor` lives beside `Eval` in
`execution/`, depends on `Catalog` and the storage `Engine`
primitives, and is the single place where DDL meets
persistence.

The result types stay with `Statement` rather than the
executor, because the REPL pattern-matches on them when
rendering output, and they have no Storage deps. Putting them
with the AST keeps the contract symmetric: surfaces produce
`Statement.t`, the executor consumes it and returns
`Statement.read_result` or `Statement.write_result`, and the
renderer consumes those.

This split is preparatory refactoring that the restructure
depends on. It can land as its own step in the slice plan,
before the libraries are introduced.

## Surfaces and how SQL fits in

The intended long-term shape is that Dovetail supports both an
RA-based surface language and SQL, with both translating to the
same `Logical.plan` IR. The current `lib/parser.ml`,
`lib/ast.ml`, and `lib/lower.ml` are RA-specific; the rest of
the pipeline (`logical`, `physical`, `translate`, `projection`,
`eval`) is surface-agnostic.

Under sub-libraries this becomes:

- `surface_ra` holds the RA-specific modules (currently three:
  `ast`, `parser`, `lower`).
- A future `surface_sql` library will hold the SQL-specific
  counterparts (its own AST, parser, and lowering pass), with
  the same deps as `surface_ra`.
- Both depend on `plan` and `ddl`; neither depends on the
  other. The REPL (in `frontend`) depends on whichever
  surfaces are enabled.

This is shape-3 from the discussion: two surface libraries
sitting beside each other on top of a shared plan + ddl
foundation. The alternative — one big `pipeline` library
containing both surfaces — was rejected because it muddles the
distinction between plan IR (shared) and surface representation
(per-language).

The contract between a surface and the rest of the system is
narrow:

- A surface parser produces either a `Logical.plan` (for query
  pipelines) or a `Statement.t` from the ddl library (for
  catalog operations). Internally a surface may wrap these in
  its own program type (`surface_ra/ast.ml` has `type program =
  Pipeline of Plan.Logical.plan | Ddl of Ddl.Statement.t` for
  exactly this reason), but the things that leave the surface
  boundary are the shared IR types.
- A surface knows nothing about execution, storage, or other
  surfaces.
- Execution knows nothing about which surface produced a plan
  or statement.

## Sub-libraries vs. nested modules

The two organising approaches considered:

**Nested modules in a single library.** Keep the current
`(library (name dovetail))`, group modules by writing wrapper
files (e.g. `lib/storage.ml` containing `module Catalog =
Storage_catalog`). Cheap to set up, no rename churn. The
problem: nothing enforces the grouping. Any module in the
library can reach any other. The grouping is a comment, not an
invariant. For dovetail's stated goal — making dependencies
clearly understandable — this is fundamentally the wrong tool.
It produces shapely-looking code with no guardrails.

**Sub-libraries with `(libraries ...)` deps.** Each group is
its own dune library. The `(libraries ...)` stanza is what each
library is allowed to see; cross-boundary references that
aren't declared fail at build time. The grouping is enforced by
the build system.

The sub-library approach is the standard way larger OCaml
projects organise themselves (dune itself, Jane Street's Core,
Merlin, ocaml-lsp, MirageOS). The setup cost is small — one
short `dune` file per group — and the boundary enforcement is
exactly what the goal called for. The choice is sub-libraries.

## Wrapping and the consuming pattern

Dune has two independent features:

- **Wrapping** synthesises a wrapper module named after the
  library, so callers reach modules as
  `Dovetail_storage.Catalog`.
- **Boundary enforcement** comes from the `(libraries ...)`
  stanza, regardless of wrapping. A library can only see
  modules from libraries it declares.

Each sub-library is wrapped (the dune default). The wrapper
serves two jobs at once: it groups modules into a per-library
namespace, and it removes the global-uniqueness pressure on
module names. `lib/surface_ra/parser.ml` and (eventually)
`lib/surface_sql/parser.ml` coexist without renaming because
they live under different wrappers: `Dovetail_surface_ra.Parser`
and `Dovetail_surface_sql.Parser`. The same logic lets every
inner module keep a short, role-named filename.

### Module aliases as the default consuming style

Cross-library references go through module aliases at the top
of the consuming file. The pattern is OCaml's equivalent of a
TypeScript `import * as ra from './surface_ra'`:

```ocaml
module Core    = Dovetail_core
module Plan    = Dovetail_plan
module Storage = Dovetail_storage

let scan environment transaction physical_plan =
  let table_name = Plan.Physical.table_of physical_plan in
  let entry =
    Storage.Catalog.lookup environment transaction table_name
  in
  ...
```

The aliases are file-local. Each file picks the aliases that
read best at its call sites. A file that only touches one
library and never needs disambiguation can either alias the
library or just qualify; a file that touches several aliases
all of them.

Reasons aliases are the default rather than `open
Dovetail_storage`:

- The alias declaration at the top of the file is a small
  manifest of *which libraries this file talks to*. A reader
  scanning the top of the file sees the dependency surface in
  one glance.
- `open` makes the cross-library names indistinguishable from
  in-library names at call sites. Aliases keep the group
  membership visible (`Storage.Catalog.lookup`), which matches
  the project rule of clarity over brevity.
- Aliases compose cleanly when a file uses two libraries with
  the same inner module name (the surfaces case). `open`ing
  both would shadow; aliasing both is unambiguous.

`open` is fine when a file leans heavily on a single library
and verbose qualification would crowd the call sites — it's a
tool, not banned. But the default is aliases.

### Inner modules don't share library names

Wrapping interacts awkwardly when a library has an inner
module that shares the library's role-name. The wrapper is
named after the library, so the inner module ends up at
`Dovetail_X.X` — and consumer code via `module X =
Dovetail_X` reads as `X.X.thing`, a doubled name with no
informational payload.

To avoid this uniformly, no library has an inner module that
shares its containing library's role-name. The two cases that
would have collided are renamed:

- **`storage.ml` → `engine.ml`.** The module wraps LMDB
  primitives — environments, transactions, named subDBs,
  byte-keyed KV ops. `Engine` reads cleanly at call sites:
  `Storage.Engine.open_environment`,
  `Storage.Engine.with_read_transaction`. The name `Lmdb` was
  considered and rejected because the external `lmdb` opam
  package already exposes a top-level module of that name;
  shadowing it from inside our `storage` library would be
  confusing. `Database`, `Backend`, and `Kv_store` were also
  considered; `Engine` matched the project rule of clarity
  without being too generic or too verbose.
- **`ddl.ml` → `statement.ml`.** After the AST/executor split,
  the module contains only the DDL statement vocabulary: a
  variant type for the statement itself, the read- and
  write-result types, and `classify`. `Statement` is what the
  module actually is. Side benefit: the dominant type goes
  from `type statement` to `type t`, matching the project's
  `.t` convention which the original module quietly breaks.

With these renames, the standard alias pattern works
uniformly across every library:

```ocaml
module Storage = Dovetail_storage
module Ddl     = Dovetail_ddl

let kind = Ddl.Statement.classify ddl_statement
let map  = Storage.Engine.open_map environment txn ~name
```

Going forward, the convention is **never name an inner module
after the library that contains it**. Each inner module is
named for what it specifically is; the library name carries
the grouping concept.

### Naming inside a single library

Within a library, sibling files reference each other
unprefixed: `lib/surface_ra/parser.ml` writes `Ast.t` and
`Lower.lower`, because the wrapper module brings the siblings
into scope for in-library code. The aliasing convention only
applies at *cross-library* references.

Filenames stay short and role-named everywhere: `parser.ml`,
`ast.ml`, `lower.ml` in both `surface_ra/` and (future)
`surface_sql/`. No `ra_` or `sql_` prefix needed — that
disambiguation lives at the consumer's alias, where each file
picks names that read well for its specific call sites.

## Directory and dune layout

```
lib/
  core/
    dune
    value.ml             value.mli
    schema.ml            schema.mli
    expression.ml        expression.mli
    relation.ml          relation.mli
    relation_literal.ml  relation_literal.mli
  storage/
    dune
    engine.ml            engine.mli     (renamed from storage)
    encoding.ml          encoding.mli
    row_codec.ml         row_codec.mli
    catalog.ml           catalog.mli
  plan/
    dune
    logical.ml           logical.mli
    physical.ml          physical.mli
    translate.ml         translate.mli
    projection.ml        projection.mli
  ddl/
    dune
    statement.ml         statement.mli (renamed from ddl;
                                        AST + classifier only,
                                        after the split)
    format.ml            format.mli    (canonical-form printer,
                                        added in slice 14)
  surface_ra/
    dune
    ast.ml               ast.mli
    parser.ml            parser.mli
    lower.ml             lower.mli
  execution/
    dune
    eval.ml              eval.mli
    ddl_executor.ml      ddl_executor.mli   (new; the executor
                                             half of old ddl.ml)
  frontend/
    dune
    cli.ml               cli.mli
    repl.ml              repl.mli
    demo_data.ml         demo_data.mli
```

The current `lib/dune` is removed. Dune walks into the
subdirectories automatically because each contains its own
`(library ...)` stanza.

Dune file shapes:

```dune
(* lib/core/dune *)
(library
 (name dovetail_core)
 (public_name dovetail.core))

(* lib/storage/dune *)
(library
 (name dovetail_storage)
 (public_name dovetail.storage)
 (libraries dovetail.core lmdb unix))

(* lib/plan/dune *)
(library
 (name dovetail_plan)
 (public_name dovetail.plan)
 (libraries dovetail.core))

(* lib/ddl/dune *)
(library
 (name dovetail_ddl)
 (public_name dovetail.ddl))

(* lib/surface_ra/dune *)
(library
 (name dovetail_surface_ra)
 (public_name dovetail.surface_ra)
 (libraries dovetail.core dovetail.plan dovetail.ddl angstrom))

(* lib/execution/dune *)
(library
 (name dovetail_execution)
 (public_name dovetail.execution)
 (libraries dovetail.core dovetail.storage dovetail.plan
            dovetail.ddl))

(* lib/frontend/dune *)
(library
 (name dovetail_frontend)
 (public_name dovetail.frontend)
 (libraries dovetail.core dovetail.storage dovetail.plan
            dovetail.ddl dovetail.surface_ra
            dovetail.execution))
```

`name` is the OCaml-side identifier (must be a valid module
name, so underscored). `public_name` is the findlib/opam
identifier (allows dots, used in `(libraries ...)` stanzas).
The two are deliberately decoupled.

The `(public_name dovetail.X)` form presumes a `(package (name
dovetail))` stanza in `dune-project`. If not already present,
that's a one-line addition.

External library deps land where they're used:

- `lmdb`, `unix` → `storage`
- `angstrom` → `surface_ra`

The executable in `bin/` doesn't change in structure. Its dune
file just lists the libraries it actually touches:

```dune
(* bin/dune *)
(executable
 (name main)
 (public_name dovetail)
 (libraries dovetail.frontend dovetail.storage))
```

## Test layout

Tests mirror the lib structure. Each lib subdirectory has a
matching test subdirectory:

```
test/
  core/         test_value.ml, test_schema.ml,
                test_expression.ml, test_expression_format.ml,
                test_relation.ml, test_relation_literal.ml
  storage/      test_engine.ml, test_encoding.ml,
                test_row_codec.ml, test_catalog.ml
  plan/         test_logical.ml, test_physical.ml,
                test_translate.ml, test_projection.ml,
                test_translate_index_lookup.ml,
                test_translate_indexed_nested_loop_join.ml
  ddl/          test_statement.ml, test_format.ml
  surface_ra/   test_parser.ml,
                test_expression_parser.ml,
                test_lower.ml
  execution/    test_eval_*.ml,
                test_ddl_executor.ml
  frontend/     test_cli.ml, test_repl.ml, test_demo_data.ml
  helpers/      test_helpers.ml, fixture.ml  (its own (library)
                                              so tests can share
                                              it; fixture is the
                                              low-level seeder
                                              relocated in slice 15)
  integration/  test_pipeline.ml, test_dovetail.ml,
                test_documentation.ml, test_doctest.ml,
                test_ddl_roundtrip.ml, doctest.ml
```

Each per-group test directory is a `(tests ...)` stanza
depending on `dovetail.<group>`, `alcotest`, and the
`test_helpers` library. `integration/` depends on every lib
library because end-to-end tests legitimately cross boundaries.

Mirroring `test/` to `lib/` was a deliberate choice over a flat
`test/`. The reasoning: the discipline benefit is smaller for
tests than for `lib/` (a misplaced test is harmless), but the
navigability benefit is real, and a flat `test/` of forty-plus
files has the same problem this design is solving for `lib/`.
The `integration/` bucket exists exactly because end-to-end
tests don't fit a single-group home; isolating them keeps the
per-group dependencies honest.

The exact placement of the `test_translate_*` files (which
exercise the path from logical through physical to eval)
depends on what they actually assert. Files that test the
logical-to-physical translation belong in `plan/`; files that
test the full execution path belong in `execution/`. Sorted out
when the slice plan lands.

## What this design accommodates without rework

The structure is shaped to absorb the most likely future
additions without further restructure.

- **A second surface language (SQL).** New `lib/surface_sql/`
  directory with its own dune file. Same deps as `surface_ra`
  (core, plan, ddl, angstrom or whatever it uses). Filenames
  inside `surface_sql/` follow the same short, role-named
  pattern as `surface_ra/` (`ast.ml`, `parser.ml`, `lower.ml`);
  the wrapping handles cross-surface disambiguation, and
  consumers alias whichever surfaces they reference.
- **Multiple surface backends sharing a planner.** If a third
  surface ever appears, the pattern repeats. The plan and ddl
  libraries don't change.
- **A planner / optimiser pass.** Likely lands inside `plan/`
  as new modules. No structural change; `plan` already owns
  the IRs and the translation between them.
- **Alternative storage backends.** Would replace or sit beside
  `storage/`. The contract between `storage` and `execution`
  becomes the interface to factor against.
- **A test framework swap or addition.** Each test
  subdirectory's dune controls its own dependencies; no global
  test-runner contract to renegotiate.
- **Tooling around dependency analysis.** With per-library
  `(libraries ...)` stanzas, the dependency graph is
  machine-readable. Generating a Graphviz or Mermaid diagram
  from the dune files is a small script away.

## Resolution status

This design lands across two slices:

- **Slice 13** introduced the first two sub-libraries (`core`
  and `ddl`), split the `Ddl` module into `Statement` and
  `Ddl_executor`, and established the cross-library alias
  conventions in `CLAUDE.md`. The `dune-project` package
  declaration was already present.
- **Slice 16** extracts the remaining five libraries
  (`storage` with the `storage.ml` → `engine.ml` rename,
  `plan`, `surface_ra`, `execution`, `frontend`), deletes
  `lib/dune`, mirrors the new structure into `test/`, and
  finalises the `CLAUDE.md` orientation section. The
  `frontend` library stays as one piece for now; splitting
  is cheap to revisit if it grows.

See [`16-full-sub-library-setup.md`](../plans/16-full-sub-library-setup.md)
for the slice-16 plan.
