# 12 — Slice 12: List and drop tables

The twelfth vertical slice, and the first to extend the surface
language beyond pipelines. End-state: a user at the REPL can type
`:list tables` to see what's in the catalog, and `:drop table
<name>` to remove one. The slice lands the entire DDL surface
infrastructure — sigil, `Ast.program` wrapper, `Ddl` module, REPL
dispatch arm, storage primitives for deletion — so the second DDL
slice (describe + create) drops in additively.

The README's roadmap previously rolled all of DDL into a single
slice 12. This slice narrows that to **list and drop only**;
create and describe are the round-trip pair and benefit from
landing together, and fixture retirement deserves its own slice
once the create path exists.

The design that shapes this slice lives in
[`docs/plans/ddl-design.md`](ddl-design.md). That document covers
all four DDL statements (create, drop, describe, list) coherently
so that any single statement's shape isn't quietly determined by
the cases it doesn't have to handle. This slice plan implements
the list-and-drop subset of that design.

## Context

Slices 1–10 grew Dovetail's read path; slice 11 opened the write
path with the insert mutation. Every top-level input today is a
pipeline — either a query (printed as a bordered table) or a
mutation (returning an affected-row count).

The catalog and storage layers have always supported the operations
DDL needs — `Catalog.put`, `Storage.create_map`, and the LMDB
machinery underneath — but only `Fixture` has ever exercised them,
and only at startup. The query language has had no way to inspect
the catalog or remove tables. Slice 12 closes that gap with the
smallest user-driven DDL surface that exercises every piece of new
machinery the DDL design introduces.

The fixture continues to seed `users` and `orders` on first run
through this slice; a user `drop`ping a fixture table will see it
re-appear on next REPL startup. That's the correct pre-slice-14
behaviour and worth flagging in the verification smoke test.

## Goal

End-state artefacts:

1. A `:` sigil at top of input that distinguishes DDL statements
   from pipelines. Whitespace around the sigil is tolerated.
2. Two DDL statements parsed and executed:
   - `:list tables` — lists table names from the catalog, one per
     line, in byte-sorted order. Empty catalog prints nothing.
   - `:drop table <name>` — removes the named table's catalog entry
     and its storage subDB inside a single write transaction.
3. New `Ast.program = Pipeline of plan | Ddl of Ddl.statement`
   wrapper at the top of the parser's output. The `Pipeline` arm
   continues through Lower/Translate/Physical/Eval unchanged; the
   `Ddl` arm bypasses those layers and is handed straight to
   `Ddl.execute_read` / `Ddl.execute_write` from the REPL.
4. New `Ddl` module with `statement = List_tables | Drop_table of
   { table_name : string }`; `classify : statement -> [`Read |
   `Write]`; `execute_read` and `execute_write` as separate entry
   points with split result types (`read_result = Listed of string
   list`, `write_result = Dropped of string`).
5. New storage and catalog primitives:
   - `Storage.delete : map -> [`Read|`Write] transaction
     -> key:string -> unit`.
   - `Storage.drop_map : environment -> [`Read|`Write] transaction
     -> name:string -> unit`.
   - `Catalog.delete : environment -> [`Read|`Write] transaction
     -> table_name:string -> unit`.
   - `Catalog.list_table_names : environment -> [> `Read]
     transaction -> string list`.
   - `Catalog.table_subdb_name : string -> string` (promoted from
     the private one-liner in `Eval`; `Eval` updated to use it).
6. REPL output: `dropped table "<name>"` after a successful drop;
   one table name per line for a list; the existing `error: ...`
   formatting for failures (catalog-aware `no such table` from
   `execute_write`, parse errors for malformed input).

After slice 12, the canonical worked examples are:

```
> :list tables
orders
users
> :drop table orders
dropped table "orders"
> :list tables
users
```

Validation policy:

- Catalog-aware "no such table" → caught in `Ddl.execute_write`,
  inside the write transaction.
- All other failures (malformed input, unknown statement, sigil
  mid-pipeline) are parse errors.
- No structural validation in this slice — neither statement has a
  body to check. `Ddl.validate` arrives in slice 13 with `create
  table`'s structural rules.

## Slice-12 architectural decisions

### Scope: list and drop only

The four DDL statements (list, drop, describe, create) split
naturally into three slices because they're less tightly coupled
than insert/update/delete were:

- **Slice 12 (this slice): list + drop.** The "simple" pair.
  `list tables` is the cleanest vertical opener — it carries the
  full wrapper machinery (sigil, `Ast.program`, REPL dispatch arm,
  new module) but the statement itself is trivial. `drop table`
  then adds the first DDL write path (storage primitives, catalog
  delete) without needing the structural validator or canonical
  printer that create/describe will introduce.
- **Slice 13: describe + create table.** Paired because the
  round-trip property `parse(format(s)) ≡ s` is the design's
  strongest correctness anchor and lands cleanest when both ends
  are in one PR.
- **Slice 14: fixture retirement.** Removes `lib/fixture.ml` and
  migrates tests to construct tables via DDL. Held back until
  create exists.

Each slice is independently shippable. Slice 12 leaves the system
in a coherent state: users can inspect the catalog and remove
tables; the only tables they can drop are fixture-seeded ones, and
those re-seed on next startup.

### Sigil `:` at top of input

The sigil is the only top-of-input mark of a DDL statement. The
parser dispatches on it: a leading `:` (after any whitespace)
switches to DDL parsing; anything else parses as a pipeline.

DDL keywords (`list`, `drop`, and future `describe`/`create`) are
not globally reserved. Inside any pipeline, expression, or future
column-list position they remain regular identifiers. The sigil is
what reserves them, and only at top of input. This bounds the
surface cost of DDL's universe to a single character.

See [`docs/plans/ddl-design.md`](ddl-design.md) §"The sigil" for
the full justification.

### Wrapper lives only at Ast

`Ast.program = Pipeline of plan | Ddl of Ddl.statement` is the new
wrapper. The `Pipeline` arm carries the existing `Ast.plan =
Query | Mutation`; the `Ddl` arm carries a `Ddl.statement`.

Crucially, **the wrapper does not propagate to Logical or
Physical.** DDL doesn't go through Lower or Translate at all — the
`Ddl` arm is handed straight to `Ddl.execute_read` /
`execute_write` from the REPL. So `Lower.lower`'s signature stays
`Ast.plan -> Logical.plan`, `Translate.translate`'s stays
`Logical.plan -> Physical.plan`, and the existing layers carry no
knowledge of DDL.

This is a deliberate departure from slice 11, where `Query |
Mutation` was threaded through every layer. The slice 11 wrapper
paid its keep because the type system enforced "mutations don't
nest inside relations" at every layer. For DDL there's nothing to
enforce at intermediate layers — the universe split is bridged
once, at the REPL.

Rejected: a `Logical.program` / `Physical.program` wrapper.
Symmetric on paper, but the `Ddl` arm at those layers would be a
no-op pass-through that no consumer reads. The DDL design doc
warns against making "DDL dress up as relational"; threading the
wrapper through Lower/Translate would be exactly that.

### Ddl module: split execute, flat statement type

```ocaml
(* lib/ddl.mli *)

type statement =
  | List_tables
  | Drop_table of { table_name : string }

type read_result =
  | Listed of string list

type write_result =
  | Dropped of string

val classify : statement -> [ `Read | `Write ]

val execute_read :
  Storage.environment ->
  [> `Read ] Storage.transaction ->
  statement ->
  read_result
(* Handles List_tables only. Drop_table → assert false, guarded by
   classify having been called at the REPL dispatch site. *)

val execute_write :
  Storage.environment ->
  [ `Read | `Write ] Storage.transaction ->
  statement ->
  write_result
(* Handles Drop_table only. List_tables → assert false. Catalog-aware
   "no such table" check happens here, inside the write transaction. *)
```

The shape mirrors slice 11's two-entry-point pattern for `Eval`:
`execute_read` accepts the polymorphic `[> `Read]` transaction so
read DDL doesn't unnecessarily serialise against LMDB's writer
lock; `execute_write` requires `[`Read|`Write]` at the type level.
The classifier and the chosen entry point both read off the
`Ddl.statement` constructor, so the REPL dispatch has a single
source of truth.

The statement type is flat (rather than split into
`read_statement` and `write_statement`) because the constructor
count is small, `classify`'s pattern-match is one line per
constructor, and the `assert false` arms are guarded by the
classify-then-execute contract at the REPL. Splitting the type
would add ceremony for no runtime safety gain.

Both constructors are defined upfront in step 2.
`execute_write`'s `Drop_table` arm is `assert false` until step
5a, where it gets a real implementation. The shape of the universe
shouldn't change mid-slice.

Rejected:

- **A single `Ddl.execute` with always-write transactions.**
  Simpler signature, but pays a (small) writer-lock cost on every
  `list tables` and breaks the parallel with slice 11's read/write
  split.
- **Splitting the statement type by permission.** Type-safe but
  heavier; the `assert false` arms are CLAUDE.md-compliant ("the
  right form for arms the layering upstream is supposed to
  guarantee") and never reachable in practice.

### Result types split, mirroring execute

`read_result` and `write_result` are separate types rather than a
single `Ddl.result` variant. Each grows additively in slice 13:
`read_result` gains `Described of Schema.t`; `write_result` gains
`Created of string`. The split keeps the renderers in the REPL
shaped along the same axis as the execute entry points.

### No `Ddl.validate` in slice 12

Neither `List_tables` nor `Drop_table` has a structural body to
check. The only validation rule in this slice — "table must exist
in the catalog" for drop — is catalog-aware, so it lives inside
`execute_write` (where it shares scope with the mutation, ruling
out TOCTOU races by sharing the write transaction).

`Ddl.validate` arrives in slice 13 alongside `create table`, which
introduces real structural rules (empty column list, duplicate
column names, PK references columns not in the list, etc.) that
are catalog-independent and worth running before opening any
transaction.

### Renderers in REPL

For slice 12 the two render paths are short enough to live next to
slice 11's `format_mutation_status` in `Repl`:

- `Listed names` → one name per line via `Format.fprintf`.
- `Dropped name` → `dropped table "<name>"`.

When slice 13 lands `describe`, the canonical-form printer is part
of the DDL surface (not the REPL — its output is literally
re-executable as `:create table ...`), so the formatters migrate
to a `Ddl_format` module (or into `Ddl` directly). For slice 12
the REPL home is fine.

### Storage and catalog primitives

Three new primitives at the storage layer and two new catalog
helpers, all small and independently testable.

- **`Storage.delete : map -> [`Read|`Write] transaction
  -> key:string -> unit`.** Wraps LMDB's `mdb_del`. Required so
  `Catalog.delete` has a primitive to call. No-op if the key is
  absent (matches `mdb_del` with no data argument).
- **`Storage.drop_map : environment -> [`Read|`Write] transaction
  -> name:string -> unit`.** Wraps LMDB's `mdb_drop` with the
  delete flag, destroying the named subDB and its contents.
  Required for `Drop_table`'s storage half. Raises if the subDB
  doesn't exist (caller's responsibility to check the catalog
  first).
- **`Catalog.delete : environment -> [`Read|`Write] transaction
  -> table_name:string -> unit`.** Removes the named catalog
  entry. Uses `Storage.delete` against the catalog subDB.
  Idempotent on missing entries (the catalog-aware "no such table"
  error lives in `execute_write`, not here).
- **`Catalog.list_table_names : environment -> [> `Read]
  transaction -> string list`.** Enumerates the catalog subDB's
  keys via `Storage.with_iter_seq`, collects them, returns them.
  Cursor order is byte-sorted, which matches alphabetical for ASCII
  identifiers. Returns `[]` if the catalog subDB has not yet been
  created.
- **`Catalog.table_subdb_name : string -> string`.** Promoted from
  `let table_subdb_name table = "table:" ^ table` at the top of
  `Eval`. Single source of truth for the `table:` namespace
  convention. `Eval` updated to call `Catalog.table_subdb_name` in
  step 4d.

### Transaction dispatch

The REPL's top-level dispatch grows one outer arm and uses
`Ddl.classify` symmetrically to the existing `Logical.classify`:

```ocaml
match Parser.parse input with
| Error message -> ... (* parse error *)
| Ok (Ast.Pipeline plan) ->
    (* existing: Lower → Translate → Eval, with Logical.classify
       picking the transaction kind *)
| Ok (Ast.Ddl statement) ->
    match Ddl.classify statement with
    | `Read ->
        Storage.with_read_transaction environment (fun transaction ->
          let result =
            Ddl.execute_read environment transaction statement in
          render_read_result output result)
    | `Write ->
        Storage.with_write_transaction environment (fun transaction ->
          let result =
            Ddl.execute_write environment transaction statement in
          render_write_result output result)
```

The classifier and the renderer dispatch both read off the
statement constructor. Failures inside `execute_write` raise
`Failure`; the existing `try ... with Failure ->` in
`evaluate_and_print` aborts the transaction and prints the error.

### Error message wording

Per `CLAUDE.md`, user-facing errors start with a module prefix:

```
Ddl: drop table "<name>": no such table
```

(Slice 13 adds `Ddl: create table "<name>": ...`-shaped errors.)

Parse errors retain the existing `parse error: ...` shape — the
parser doesn't know it's parsing a DDL statement vs a pipeline at
the failure point in most cases.

## Steps

Nine steps. Steps 1–3 land `list tables` end-to-end through a
vertical opener at step 3. Steps 4a–5b stack the storage
primitives and drop-table execute path before exposing it through
the parser. Step 6 is documentation.

Each step ends with `dune test` green, formatter clean, and a
sensible commit.

### Step 1 — `Catalog.list_table_names`

Pure infrastructure. New function on `Catalog` that enumerates the
catalog subDB's keys via `Storage.with_iter_seq` and returns them
as a list. Cursor order is byte-sorted; returns `[]` if the
catalog subDB has not been created.

Tests:

- `test_catalog.ml` gains a case that puts a few schemas, lists,
  and asserts the order.
- Empty-environment case returns `[]`.

### Step 2 — Ddl module skeleton

Create `lib/ddl.ml` and `lib/ddl.mli`. Define `statement =
List_tables | Drop_table of { table_name : string }`;
`read_result`; `write_result`; `classify`; `execute_read`
(implements `List_tables`, asserts false on `Drop_table`);
`execute_write` (asserts false on both arms for now).

`execute_read`'s `List_tables` arm calls
`Catalog.list_table_names` and wraps the result in `Listed`.

Tests:

- `test_ddl.ml` (new) exercises `classify` for both constructors.
- `execute_read` happy path via a hand-populated catalog.

### Step 3 — Parser sigil + `Ast.program` + REPL dispatch

The vertical opener. Make `:list tables` work end-to-end at the
REPL.

- **Ast:** new `program = Pipeline of plan | Ddl of
  Ddl.statement`.
- **Parser:** entry point peeks for a leading `:` (with leading
  whitespace tolerated). If present, parses a DDL body; otherwise
  parses a pipeline as today. DDL body grammar for slice 12 admits
  `list tables` only (one production). `Parser.parse` now returns
  `(Ast.program, error) result`.
- **REPL:** `process_line` pattern-matches on `Ast.program`. The
  `Pipeline` arm threads through to the existing
  `evaluate_and_print`. The `Ddl` arm dispatches on `Ddl.classify`:
  `` `Read `` opens a read transaction and calls
  `Ddl.execute_read`; `` `Write `` opens a write transaction and
  calls `Ddl.execute_write`. Both render paths land in REPL
  alongside `format_mutation_status`. Failures flow through the
  existing `try Failure ->` handler.

After this step `:list tables` works at the REPL and shows the
fixture-seeded tables (`orders`, `users`).

Tests:

- Parser unit tests for the sigil dispatch and the `:list tables`
  production. Sigil mid-pipeline (`users | :drop table x`) is a
  parse error.
- REPL end-to-end test via `Repl.run` against the fixture.

### Step 4a — `Storage.delete`

LMDB `mdb_del` binding. Single primitive, scope-bound to a write
transaction. No-op on absent keys.

Tests in `test_storage.ml`: put, delete, `get` returns `None`;
delete on absent key is a no-op.

### Step 4b — `Storage.drop_map`

LMDB `mdb_drop` binding with the delete flag. Destroys the named
subDB. Raises if the subDB doesn't exist.

Tests in `test_storage.ml`: create, drop, `open_map` returns
`None`; drop on a never-existed name raises.

### Step 4c — `Catalog.delete`

Thin wrapper around `Storage.delete` on the catalog subDB.
Idempotent on missing entries (the catalog-aware "no such table"
check lives in `execute_write`, not here).

Tests in `test_catalog.ml`: put, delete, `get` returns `None`;
delete on absent table is a no-op.

### Step 4d — Promote `Catalog.table_subdb_name`

Move `let table_subdb_name table = "table:" ^ table` from the top
of `Eval` into `Catalog`. Expose it from `Catalog.mli`. Update
`Eval` to call `Catalog.table_subdb_name`. Pure refactor; no
behaviour change.

Tests: existing tests should pass unchanged.

### Step 5a — `Ddl.execute_write` Drop_table arm

Implement the `Drop_table` arm of `execute_write`. The body:

1. Look up the table in the catalog (`Catalog.get`). If absent,
   raise `Failure "Ddl: drop table \"<name>\": no such table"`.
2. Compute the subDB name (`Catalog.table_subdb_name`).
3. Drop the storage subDB (`Storage.drop_map`).
4. Remove the catalog entry (`Catalog.delete`).
5. Return `Dropped table_name`.

Both writes happen inside the same write transaction, so the
catalog entry and the storage subDB stay consistent (LMDB commits
both atomically, or aborts both on raise).

Tests in `test_ddl.ml` (extended): hand-construct `Drop_table`
statements, invoke `Ddl.execute_write` under
`with_write_transaction`, assert state changes. Cover the happy
path and the "no such table" error.

### Step 5b — Parser grammar for `:drop table <name>` + renderer

Extend the DDL body grammar with `drop table <identifier>`. Add
the REPL renderer for `Dropped name`.

After this step `:drop table foo` works end-to-end. Integration
test via `Repl.run` against the fixture: drop a table, list, see
it gone.

Tests:

- Parser unit tests for the new production.
- REPL integration test for the end-to-end drop flow, including
  the "no such table" error.

### Step 6 — Documentation

Extend `docs/query-language.md` with a new "Data definition"
section. Cover both statements with worked examples. Doctest the
examples via the slice-10 extractor.

A note on doctest state: a `:drop table foo` example would persist
across doctest runs and need either a fresh environment per
example or a careful setup/teardown. If the extractor doesn't
already support fresh environments, we either extend it or
structure a doctest block that creates-then-drops within itself.
Address when we get there.

README — layer tables and roadmap update wait until the full DDL
surface is in place to describe (end of slice 13 or 14).

## Verification

End-of-slice manual smoke (in the REPL against the fixture):

- `:list tables` — confirm both fixture tables (`orders`, `users`)
  appear, byte-sorted, one per line.
- `:drop table orders` — confirm `dropped table "orders"`.
- `:list tables` — confirm `orders` is gone, only `users` remains.
- `:drop table nonexistent` — confirm error naming the missing
  table; catalog unchanged.
- Pipeline queries continue to work; `users | restrict id = 1`
  returns expected output.
- Exit the REPL and restart it against the same data directory.
  Confirm the fixture re-seeds `orders`. This is the correct
  pre-slice-14 behaviour but worth confirming so the smoke
  surfaces any surprise.
- Parse error path: `:list` (unknown DDL body), `:` (bare sigil),
  `users | :drop table x` (sigil mid-pipeline) — all should fail
  with parse errors and not corrupt state.

Plus the usual: `opam exec -- dune test` is green; `opam exec --
dune build @fmt --auto-promote` leaves the tree clean.

## Out of scope

- **`describe` and `create table`.** Slice 13, paired so the
  round-trip property `parse(format(s)) ≡ s` lands in one PR.
- **`Ddl.validate`.** Arrives in slice 13 with `create table`'s
  structural rules.
- **Fixture retirement.** Slice 14, once `create table` exists to
  replace the seeded tables.
- **`if exists` / `if not exists` idempotency clauses.** Pure
  ergonomics; additive when scripts become a real story.
- **`alter table`, `rename table`, `truncate table`.** Deferrable
  per the DDL design doc.
- **`Ddl_format` module.** The canonical-form printer lives in the
  REPL for slice 12 because list/drop output is trivial; migrates
  to its own module when slice 13's `describe` lands.
- **Multi-statement input, explicit transactions.** Already on the
  Beyond list in the README.
- **Update and delete (the slice-11 deferrals).** Currently on the
  Beyond list; not part of any planned DDL or SQL slice.
