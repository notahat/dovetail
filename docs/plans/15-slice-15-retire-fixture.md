# 15 — Slice 15: Retire the fixture

The first slice with no new query-language surface. End-state:
the REPL boots empty, and a `--demo-data` flag seeds the
historic `users`/`orders` example tables on demand through the
public DDL/DML surface. The `lib/fixture.ml` module retires
into `test/helpers/` as a test-only seeder; production code
ships no hardcoded demo data.

Slice 14 closed out the DDL surface (`:create table` and
`:describe` joined the existing `:list tables` and `:drop
table`). With both create-table and insert in place, the
fixture's reason to live as production code — "queries need
something to query against, and there's no other way to put
data there" — is gone. This slice retires it.

## Context

After slice 14, the fixture has reach in four places:

- `bin/main.ml`: every REPL boot calls
  `Dovetail.Fixture.populate_if_empty`, lazily seeding `users`
  and `orders` into a fresh data directory.
- `lib/fixture.ml` + `lib/fixture.mli`: the module itself,
  re-exported as `Dovetail.Fixture`. Schemas and row data are
  hardcoded; the seeder writes through the low-level
  `Catalog.put` + `Storage.put` + `Row_codec.encode_row`
  path.
- `test/helpers/test_helpers.ml`: a `with_fixture_environment`
  helper that opens a temp env and seeds it via
  `Fixture.populate_if_empty`. About ten unit-test files use
  it. The helper also exposes `expected_users_rows` and
  `expected_orders_rows` constants that mirror the fixture's
  rows for use in assertions.
- All six markdown docs (`docs/query-language.md`,
  `docs/query-language-tutorial.md`,
  `docs/query-language-pipeline-operators.md`,
  `docs/query-language-expressions.md`,
  `docs/query-language-data-definition.md`,
  `README.md`): doctested via
  `test/test_documentation.ml`, which uses
  `with_fixture_environment` to seed each markdown file's env.
  Most docs reference `users`/`orders` directly in example
  queries; `query-language.md` has a "## The fixture" section
  describing the schemas and rows.

The slice splits these into two paths:

1. **Tests keep low-level setup**, moved into the test-helper
   library. Unit-test correctness stays independent of DDL/DML
   correctness — an `Insert` bug shouldn't make
   `test_eval_filter` mysteriously fail. The fixture module
   relocates from `lib/` to `test/helpers/` unchanged.
2. **The REPL and docs grow a new path**: a `Demo_data`
   module in `lib/` carrying the example tables as
   surface-form DDL/DML, an opt-in `--demo-data` CLI flag
   that runs the script, and a doctest harness switch that
   seeds via the same script. Drift between the two
   fixtures is allowed — they coincide today; they can
   diverge later if it helps either purpose.

## Goal

End-state artefacts:

1. **New `lib/demo_data.ml` + `.mli`.** Public surface:

   ```ocaml
   val script : string list
   (* One DDL or pipeline statement per element, in the order
      they must execute. *)

   val run : Storage.environment -> unit
   (* Idempotent. If the demo tables are already present in
      the catalog, returns without writes. Otherwise feeds
      each [script] element through {!Repl.run} against
      [environment], propagating any failure. *)
   ```

2. **CLI flag.** `Cli.options` gains `demo_data : bool`;
   `Cli.parse` admits a `--demo-data` flag in any position.
3. **`bin/main.ml` rewired.** The unconditional
   `Fixture.populate_if_empty` call is dropped. When
   `demo_data` is set, `Demo_data.run` runs against the
   opened environment before the REPL takes over.
4. **`lib/fixture.ml` and `lib/fixture.mli` deleted.**
   `Dovetail.Fixture` no longer exists.
5. **`test/helpers/fixture.ml` + `.mli`** created with the
   same contents as the old `lib/fixture.ml`, accessed as
   `Test_helpers.Fixture`. Folds in the
   `expected_users_rows` and `expected_orders_rows`
   constants that previously lived in
   `test/helpers/test_helpers.ml`.
6. **`test/helpers/test_helpers.ml` updates.**
   `with_fixture_environment`'s body switches to
   `Test_helpers.Fixture.populate_if_empty`. Row constants
   moved into the new module. A new
   `with_demo_seeded_environment` helper opens a temp env
   and calls `Demo_data.run`.
7. **`test/test_documentation.ml`** switches its per-file
   helper from `with_fixture_environment` to
   `with_demo_seeded_environment`.
8. **`test/test_fixture.ml` deleted.** Once `Fixture` is a
   test helper, dedicated tests of the helper become
   ceremony — its consumers (the ten-ish unit-test files)
   will fail loudly if it breaks.
9. **`test/test_demo_data.ml`** created with two tests:
   running `Demo_data.run` on a fresh env populates the
   expected catalog tables; running it twice on the same
   env is a no-op.
10. **Doc rewrites in `docs/query-language.md` and
    `README.md`** to reflect "empty by default,
    `--demo-data` to seed." The "## The fixture" section
    in `query-language.md` renames to "## The example
    tables" with prose updated to drop the
    "REPL seeds these on boot" framing.

End-state non-artefacts:

- **No DDL/DML for the example tables inline in docs.** The
  schemas and rows continue to be documented in markdown
  prose and tables, not as `:create table` / `| insert
  into` blocks. Readers learn those surfaces from
  `docs/query-language-data-definition.md`; the example
  tables exist because `--demo-data` makes them, not
  because the docs teach the reader to make them.
- **No file-based seed scripts.** The script lives as an
  OCaml `string list` in `Demo_data`, not as a `.dovetail`
  resource file. The future "load DDL/DML from a file"
  story will move it; today's surface doesn't need it.
- **No multi-statement parser.** Each script element is
  parsed independently by `Repl.run`'s existing single-line
  loop. No grammar changes.
- **No drift-detection between the test fixture and the
  demo fixture.** They happen to coincide today; either is
  free to evolve.

## Architectural decisions

### Two fixtures, deliberately decoupled

Tests use a low-level seeder; docs and the REPL flag use a
surface-driven seeder. Reasons:

1. **Unit-test independence from DDL/DML correctness.**
   `test_eval_filter` exists to verify the filter
   operator. If it sets up its data through `Eval` of an
   `Insert` pipeline, a bug in `Insert` would make
   `test_eval_filter` fail with a confusing setup error.
   The low-level path keeps unit tests narrowly aimed at
   the thing they test.
2. **Doctest harness rightly tests the surface.** The
   docs are about the surface language. Bootstrapping the
   doctest environment through that same surface is
   accurate, not circular: a DDL/DML bug *should* make
   the doctests fail, because users would hit it
   immediately.

The two fixtures are allowed to drift. They happen to seed
the same `users`/`orders` shape today because that's what
the docs reference and what the unit tests assert against.
If a future test wants a different fixture shape — say a
table without a primary key, or with a different kind set
— the unit-side fixture can grow without touching the
docs, and vice versa.

Rejected alternative: single source of truth that both
paths share. Two shapes are possible (both go through
DDL/DML, or both go through low-level writes), each
breaks one of the goals above.

### Demo data lives in `lib/`, not `test/`

`Demo_data` is production code, used by `bin/main.ml`.
That's the right home even though the only non-production
consumer is a test (the doctest harness). The alternative
— putting the demo script in `test/helpers/` and having
`bin/main.ml` import it — would invert the dependency
direction (production code depending on test code), which
violates the layering the build system enforces.

The cost is mild: `lib/demo_data.ml` ships in the
production binary even though most production runs won't
touch it. That's the same arrangement as any binary
shipping a `--help` text or a config-loader for a config
file that's optional in practice.

### Demo runner wraps `Repl.run`

`Demo_data.run` calls `Repl.run` with a list-backed
read-line callback and a discarding formatter, feeding the
script statements one per call to the read-line. Two
alternatives considered and rejected:

- **Direct calls into the pipeline** (`Parser.parse` →
  `Lower` → `Translate` → `Eval`). Skips `Repl.run`'s
  dispatch loop; duplicates its sequencing logic; demo
  data exercises a slightly different path than a real
  user types. Not worth the lines.
- **A list-of-`Ast.program`-values script.** Skips the
  parser entirely. Loses the free coverage of "every
  shape in the script's grammar parses correctly," which
  is one of the points of going through the surface.

`Repl.run`'s existing `?show_physical` defaults to `false`,
output goes to a `Format.formatter_of_buffer` whose
contents we discard, and `read_line` walks the script
list. About fifteen lines of glue.

### Idempotency at the table level

`Demo_data.run` checks the catalog for each table named in
the script before running. If all tables are present, it
returns immediately; otherwise it runs the whole script.
Matches the current `Fixture.populate_if_empty`
table-level idempotency: re-running the REPL with
`--demo-data` against an existing data directory is safe,
not a `DDL: create table "users": table already exists`
error.

Per-statement try/swallow idempotency is rejected: it
would hide real ordering bugs in the script. Strict
"empty env required" idempotency is rejected: it would
fight the development workflow of relaunching the REPL
against the same data directory.

The set of "demo tables to check" is hardcoded in
`Demo_data` (currently `users` and `orders`). If the
script grows, the check list grows alongside — a comment
in the module surfaces this coupling.

### Doc text: rename, don't restructure

The "## The fixture" section in `query-language.md`
already does the right job: documents the schemas of
`users` and `orders` in human-readable form, with the
rows shown as REPL output. The rename to "## The example
tables" and the prose update to drop "is seeded on boot"
is a light edit. The schemas, rows, and example queries
stay.

The boot-instructions passage (just before the fixture
section) gets one sentence added: "Pass `--demo-data` to
seed the example tables described below."

`README.md` gets the same `--demo-data` mention in its
usage example, if it has one.

No other doc file mentions fixture-boot behaviour
(verified by grep before writing this plan). They just
use `users` and `orders` in queries.

### Step ordering: ship new path, then retire old

Five steps in order:

1. `Demo_data` module — new code, unused.
2. CLI flag and binary rewire — new behaviour
   user-facing, old behaviour gone from `bin/main.ml`.
   `lib/fixture.ml` is now unreferenced from production
   code but still exists.
3. Doctest harness switch — `test_documentation.ml`
   begins seeding through `Demo_data`. Doctests pass
   end-to-end through the new path.
4. Fixture move — `lib/fixture.ml` → `test/helpers/`,
   row constants folded in, `test/test_fixture.ml`
   deleted, build files updated.
5. Doc text and stale-comment sweep.

Steps 1–3 are the slice's vertical: each leaves the build
green and adds one observable piece of the new behaviour.
Step 4 is mechanical cleanup once everything else has
migrated. Step 5 is the user-facing surface change in the
docs.

Rejected order: do the move first (step 4 before
step 3). The move is pure relocation with no behavioural
change to test against, and lands while the doctest
harness still routes through the old name (just at a new
path). Doing the switch first means the harness exercises
`Demo_data` before the fixture's last consumer
(`with_fixture_environment` in the helper library)
relocates. Failures during the move then point cleanly
at the move itself, not at the new path's correctness.

### `Demo_data` tests: catalog state + idempotency

Two unit tests in `test/test_demo_data.ml`:

1. **Catalog state after `run`.** Open a fresh env, call
   `Demo_data.run`, open a read transaction, assert
   `Catalog.get` returns `Some _` for each expected
   table name (`users`, `orders`). Don't assert row
   contents — that's the doctests' job (and adding row
   assertions here would duplicate `Test_helpers.Fixture`'s
   data).
2. **Idempotency.** Open a fresh env, call `Demo_data.run`,
   call it a second time, assert it doesn't raise and
   that the catalog/storage state is unchanged between
   the two calls.

Full schema-and-row coverage — the old `test_fixture.ml`'s
job — isn't useful here. The data is in the script's
string literals, which are read-once and don't have an
OCaml-side constant to drift from.

## Steps

Five commits across five numbered steps. Each ends with
`dune test` green and formatter clean.

### Step 1 — `Demo_data` module

New `lib/demo_data.ml` + `.mli`. Surface as listed in the
Goal section: `val script : string list`,
`val run : Storage.environment -> unit`.

Implementation:

- `script` is a hand-written list of statement strings
  matching the current `Fixture`'s users/orders shape:
  one `:create table` per table, followed by per-row
  `{...} | insert into <table>` pipelines.
- `run` first checks the catalog (under a read
  transaction) for `users` and `orders`. If both are
  present, return without writes. Otherwise drive
  `Repl.run` with a list-backed `read_line`, a
  discarding `output`, and the script as input.

Add `demo_data` to `lib/dune`'s module list. Re-export via
`Dovetail.Demo_data` so `bin/main.ml` can reach it without
opening `Dovetail`.

Tests in `test/test_demo_data.ml`:

- `populates expected tables`: fresh env, `run` once,
  read-transaction assertion that `Catalog.get` returns
  `Some _` for both `users` and `orders`.
- `is idempotent`: fresh env, `run` twice, second call
  doesn't raise; catalog state unchanged between calls
  (sampled by checking that both `users` and `orders`
  remain present and that no error was thrown — full
  state diff is overkill).

Add `test_demo_data` to `test/dune`'s `(names ...)` list.

TDD: tests first; verify they fail; implement `Demo_data`;
verify they pass.

This step adds new code only. The REPL still seeds
unconditionally via `Fixture.populate_if_empty` at boot —
nothing user-visible changes yet.

### Step 2 — `--demo-data` flag and empty-by-default boot

`lib/cli.ml` and `lib/cli.mli`:

- `Cli.options` gains `demo_data : bool`.
- `Cli.parse` accepts `--demo-data` in any position;
  duplicate is `Error "duplicate --demo-data flag"`.
- `Cli.usage` (the line in `bin/main.ml`) gains the flag
  alongside `--show-physical`.

`bin/main.ml`:

- Remove the unconditional
  `Dovetail.Fixture.populate_if_empty environment` line.
- When `options.demo_data` is `true`, call
  `Dovetail.Demo_data.run environment` before launching
  `Repl.run`.

Tests in `test/test_cli.ml`:

- `--demo-data` alone sets `demo_data = true`, defaults
  elsewhere.
- `--demo-data --show-physical /tmp/path` parses all
  three.
- `--demo-data --demo-data` is the duplicate error.

After this commit the REPL boots empty by default; a user
who wants the old behaviour passes `--demo-data`. The
fixture module still exists in `lib/` but is unreferenced
from production code.

### Step 3 — Doctest harness switches to demo-data seeding

`test/helpers/test_helpers.ml` gains
`with_demo_seeded_environment`:

```ocaml
val with_demo_seeded_environment :
  (Storage.environment -> 'a) -> 'a
```

Composition mirrors `with_fixture_environment`:
`with_temp_dir` → `with_environment` →
`Demo_data.run environment` → body. `with_fixture_environment`
stays untouched and continues to use the (still-in-`lib/`)
`Dovetail.Fixture.populate_if_empty`.

`test/test_documentation.ml`: replace
`with_fixture_environment` with
`with_demo_seeded_environment` in `verify_one`.

Add `dovetail.demo_data` to `test/helpers/dune`'s
`(libraries ...)` if dune doesn't pick it up transitively
through `dovetail`.

No new tests in this step — the doctest harness itself
*is* the test. Doctests should pass unchanged: the demo
script produces the same `users`/`orders` shape the
fixture did, so every example query matches.

If any doctest fails here, the cause is one of:

- Script statement order or content drifted from the
  fixture rows;
- `Demo_data.run` is leaving the env in a state that
  doesn't match what the fixture left it in (e.g. row
  insertion order affecting full-scan output).

Either is a real bug to fix in step 1's `Demo_data`
implementation, not a doc fix.

### Step 4 — Move `Fixture` to `test/helpers/`

Pure relocation. `lib/fixture.ml` and `lib/fixture.mli`
move to `test/helpers/fixture.ml` and
`test/helpers/fixture.mli` with their contents unchanged
modulo the module-prefix rebinding at the top
(`module Schema = Dovetail_core.Schema`,
`module Catalog = Dovetail.Catalog`,
`module Storage = Dovetail.Storage`,
`module Row_codec = Dovetail.Row_codec` — whichever
imports the old file had).

`test/helpers/test_helpers.ml`:

- `Fixture.users_rows` and `Fixture.orders_rows` (the
  moved row constants, renamed to drop the `expected_`
  prefix now that the module name carries the meaning)
  become the single source of truth.
- `test_helpers.ml` keeps `expected_users_rows` and
  `expected_orders_rows` as one-line re-bindings:
  `let expected_users_rows = Fixture.users_rows` and
  similarly for orders. All ~22 unit-test call sites
  reference these by bare name after `open Test_helpers`
  (verified by grep: `test_eval_filter`,
  `test_eval_full_scan`, `test_eval_index_lookup`,
  `test_eval_indexed_nested_loop_join`,
  `test_eval_insert`, `test_eval_nested_loop_join`,
  `test_lower`, `test_pipeline`, `test_projection`,
  `test_translate`, `test_translate_index_lookup`,
  `test/core/test_expression.ml`), so the re-binding
  leaves every call site untouched.
- `with_fixture_environment`'s body switches from
  `Dovetail.Fixture.populate_if_empty` to
  `Test_helpers.Fixture.populate_if_empty`.

Build files:

- `lib/dune`: nothing to remove (the module list is
  empty; modules are discovered by filename).
- `test/helpers/dune`: add `fixture` only if explicit
  module listing is required; otherwise the new file
  is picked up automatically.
- `test/dune`: remove `test_fixture` from `(names ...)`.

Delete `test/test_fixture.ml`.

After this step the slice's mechanical surgery is done.
No behaviour changes for anyone.

### Step 5 — Doc text and stale-comment sweep

`docs/query-language.md`:

- The boot-instructions paragraph that mentions seeding
  on boot is rewritten: the data directory is created
  empty by default; pass `--demo-data` to seed the
  example tables.
- The "## The fixture" heading becomes "## The example
  tables." The first paragraph drops "the REPL boots
  with" framing in favour of "the examples in this
  guide query against two small tables, created by
  `--demo-data`."
- The CLI invocation line near the top of the file
  gains `[--demo-data]` in the usage shape.

`README.md`:

- Any "the REPL is seeded with…" mention gains the
  `--demo-data` qualifier.
- Usage examples that show launching the binary gain
  the flag if they expect data to be present.

Stale-comment sweep (locations verified by grep):

- `lib/translate.ml:404-409`: the block comment justifies
  why insert-from-query isn't a tested path by appealing
  to "slice 11 (no DDL means fixture PKs would always
  collide)." After this slice the framing is doubly
  stale: DDL exists (slice 14), and the fixture is no
  longer production. Trim the parenthetical and the
  slice-11 framing; the remaining point — "non-literal
  sources aren't a tested path yet; the sink enforces
  column coverage at eval time" — is still accurate.
- `lib/ddl_executor.ml:43-50`: the block comment on
  `schema_of_create_fields` says the executor stamps
  `Some table_name` "matching the shape that
  fixture-seeded schemas carry, which the rest of the
  read path expects." Inverts after this slice — the
  executor's behaviour now defines that shape; the test
  fixture matches it. Reword to drop "fixture-seeded"
  and frame the invariant from the executor's side.
- `bin/main.ml:2`: the file-top comment "populate the
  fixture if needed" — already gone after step 2's edit,
  but worth confirming it didn't survive in a stale form.
- `lib/fixture.mli`: deleted with the file in step 4.
  No-op here.

Doctest the rewritten markdown sections by running
`dune test` against the new docs; verify
`test/test_documentation.ml` still passes for every
verified file.

## Verification

End-of-slice manual smoke against a freshly-built
binary:

- `./dovetail /tmp/empty` (fresh path, no flag) — REPL
  starts, no fixture data. `> users` returns `error: ...:
  no such table` (whatever the exact wording is — verify
  against current behaviour for scanning a missing
  table). `:list tables` returns an empty list.
- `./dovetail --demo-data /tmp/seeded` — REPL starts
  with `users` and `orders` populated. `> users` shows
  the five-row table; `> orders` shows six rows.
  `:list tables` returns both names.
- `./dovetail --demo-data /tmp/seeded` again — no
  errors on startup; data unchanged.
- `./dovetail /tmp/seeded` (no flag, existing seeded
  path) — REPL starts; existing data still present
  (the flag is for seeding, not for gating access).
- `./dovetail --demo-data --demo-data /tmp/x` — CLI
  parse error with the duplicate-flag message.
- All doctests pass: `dune test` is green; the
  documentation suite verifies each markdown file
  cleanly against the demo-data-seeded environment.
- `grep -rn "fixture\|Fixture" lib/ bin/` returns
  nothing (or only legitimate unrelated occurrences).

Plus the usual: formatter clean
(`dune build @fmt --auto-promote` is a no-op).

## Out of scope

- **A `.dovetail` script file format and a CLI to load
  it.** The demo script lives as an OCaml string list.
  When export-from-DB lands later, that's the moment to
  move to a file format and a loader; this slice doesn't
  pre-empt that design.
- **Multi-statement parsing.** Each script element is
  one statement, parsed independently. No grammar
  change.
- **A `--clean` or `--reset` flag.** Idempotency makes
  re-seeding safe; wiping an environment isn't a story
  this slice tackles.
- **Drift detection between the test fixture and the
  demo fixture.** They coincide today; either may
  evolve. If a future slice needs them to stay in sync,
  that's the right slice to add the check.
- **More demo tables, alternative demo shapes, or
  parameterised demo data.** One shape, hardcoded. The
  shape grows when a slice needs it to.
- **Removing the `expected_users_rows` /
  `expected_orders_rows` constants entirely** in favour
  of inline literals at each call site. They're folded
  into `Test_helpers.Fixture` to stay close to the
  rows they mirror; consolidating further is a
  separate readability call.
- **Restructuring or rewriting the four doc files
  beyond `query-language.md` and `README.md`.** The
  tutorial, reference, and data-definition guides
  continue to use `users` and `orders` as established;
  they don't gain or lose surface in this slice.
