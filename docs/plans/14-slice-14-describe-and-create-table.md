# 14 — Slice 14: Describe and create table

The second DDL slice. End-state: a user at the REPL can type
`:create table widgets (id: Int64, name: String) primary key (id)`
to declare a new table, and `:describe widgets` to print its
canonical schema. Pairs `describe` with `create table` so the
round-trip property `parse(format(s)) ≡ s` lands in one PR — the
strongest correctness anchor for the DDL surface.

The design that shapes this slice continues to live in
[`docs/plans/ddl-design.md`](ddl-design.md). Slice 12 landed the
DDL wrapper (sigil, `Ast.program`, REPL dispatch arm) and the
list/drop subset of the design. Slice 13 split the `Ddl` module
into `Statement` (AST) and `Ddl_executor` (executor) and
extracted the `dovetail.ddl` sub-library. Slice 14 lands the
remaining two statements in the design, plus the validator and
canonical-form printer.

## Context

After slice 13, the DDL surface looks like:

- `lib/ddl/statement.ml` — `Statement.t = List_tables |
  Drop_table of { table_name : string }`, plus `read_result`,
  `write_result`, and `classify`. Lives in `dovetail.ddl`.
- `lib/ddl_executor.ml` — `execute_read` and `execute_write`
  entry points keyed off the statement constructor. Lives in
  the residual `dovetail` library.
- `lib/parser.ml` — sigil dispatch at top of input, DDL body
  grammar admits `list tables` and `drop table <name>` only.
- `lib/repl.ml` — `Ast.program` dispatch with renderers for
  `Listed names` and `Dropped name`.

The slice grows that surface in four directions:

1. **AST additions.** Two new statement constructors
   (`Describe`, `Create_table`), two new result constructors
   (`Described`, `Created`), and a `Statement.of_schema`
   adapter that converts a stored `Schema.t` back into a
   `Create_table`-shaped value.
2. **Pure pre-eval pieces.** `Statement.validate` (structural
   checks, no catalog access) and a new `Format` module (the
   canonical-form printer that pairs with the parser).
3. **Parser grammar.** Two new productions — `:describe
   <identifier>` and `:create table <identifier> (col, …)
   primary key (col, …)` — plus parse-time kind resolution
   (`Int64`, `String`, `Bool` → `Value.Kind.t`).
4. **Executor and REPL wiring.** A Describe arm in
   `execute_read`, a Create_table arm in `execute_write`, REPL
   renderers for `Described` and `Created`, and validate
   hooked in at the REPL between parse and transaction.

No new storage primitives. `Storage.create_map` already exists
(used by `Fixture`); `Catalog.put` already exists. The slice
composes them inside one write transaction.

## Goal

End-state artefacts:

1. `Statement.t` extended with `Describe of { table_name :
   string }` and `Create_table of { table_name : string;
   fields : field list; primary_key : string list }`. New
   `Statement.field = { name : string; kind : Value.Kind.t }`
   type — deliberately distinct from `Schema.field` (no
   qualifier; surface DDL has no notion of qualified columns).
2. `Statement.read_result` gains `Described of { table_name :
   string; schema : Schema.t }`. `Statement.write_result`
   gains `Created of string`.
3. `Statement.classify` updated: `Describe` → `` `Read ``,
   `Create_table` → `` `Write ``.
4. `Statement.validate : t -> (unit, string) result` —
   structural checks, no catalog access. Five rules, each
   with a user-facing error string prefixed `DDL: create
   table "<name>": …`.
5. `Statement.of_schema : table_name:string -> Schema.t ->
   t` — produces a `Create_table` by stripping per-field
   qualifiers. Used by the REPL renderer for `Described` to
   feed the printer.
6. New `lib/ddl/format.ml` and `.mli`. Single entry point
   `Format.statement : Statement.t -> string` that handles all
   four constructors: `List_tables` → `:list tables`,
   `Drop_table { table_name }` → `:drop table <name>`,
   `Describe { table_name }` → `:describe <name>`,
   `Create_table` → the canonical multi-line form.
7. Parser admits two new DDL productions. Column declarations
   resolve `Int64`/`String`/`Bool` to `Value.Kind.t` at parse
   time; an unknown kind name is a parse error.
8. `Ddl_executor.execute_read` handles `Describe`: looks up
   the table in the catalog, raises `DDL: describe
   "<name>": no such table` if absent, returns
   `Described { table_name; schema }`.
9. `Ddl_executor.execute_write` handles `Create_table`:
   inside the write transaction, checks the catalog for an
   existing entry (raises `DDL: create table "<name>": table
   already exists` if present), creates the storage subDB
   via `Storage.create_map`, writes the catalog entry via
   `Catalog.put`, returns `Created table_name`.
10. REPL dispatch calls `Statement.validate` after parse and
    before opening a transaction. A validate error flows
    through the existing `error: …` formatting.
11. REPL renderers: `Described { table_name; schema }` →
    `Format.statement (Statement.of_schema ~table_name
    schema)`; `Created name` → `created table "<name>"`.
12. Documentation in `docs/query-language.md` gains a "Data
    definition" section covering all four DDL statements,
    doctested via the existing extractor against fixture-free
    table names.

End-state non-artefacts:

- **No new storage or catalog primitives.** Everything the
  executor needs already exists.
- **No property-based testing harness.** Round-trip is
  covered by hand-rolled golden cases; `qcheck` would be a
  heavy dependency for a single property over a small grammar
  surface. Worth revisiting if a second property emerges.
- **No fixture retirement.** The fixture continues to seed
  `users` and `orders` on first run. Slice 15 removes it
  once create table is available to substitute.
- **No `alter table`, `rename table`, idempotency clauses.**
  All deferred per the DDL design doc.

## Architectural decisions

### Module layout: hybrid

The two new pure artefacts (`validate` and the printer) land
on opposite sides of one architectural seam:

- **`Statement.validate` lives in `Statement`**, alongside the
  existing `classify`. Both are "pure computations on a
  statement value, no I/O." Keeping them sibling functions in
  one module preserves the "everything you can compute from a
  statement value without touching the catalog" envelope.
  Validate is also small — five structural rules, maybe 50
  lines including error strings — so it doesn't earn its own
  module on size grounds.
- **The printer lives in a new `Format` module** at
  `lib/ddl/format.ml`. The printer is the inverse of the
  parser, and pairs with it as the round-trip property's two
  ends. Two reasons it stands as its own module rather than
  bundling into `Statement`:
  1. The `Create_table` arm carries most of the canonical-form
     rules (indentation, trailing commas, line breaks) and is
     where future surface evolution lands. Giving it module
     scope makes that locus easy to find and modify.
  2. It's the natural module to import from any future caller
     that wants statement text without taking on the full
     `Statement` module's surface. Today that's just the REPL
     renderer for `Described` and the round-trip test;
     tomorrow it might be a `schema` migration emitter or a
     `:explain create` form.

Rejected: putting everything in `Statement`. Fits the slice
but pushes the "Statement is a god module" decision into a
future slice where it has to happen reactively under pressure
from a third or fourth pure helper. Better to spin off
`Format` now while the call is clean.

### Parser resolves kinds; unknown kind is a parse error

`Int64`, `String`, and `Bool` are parsed as identifiers at the
kind position and immediately mapped to `Value.Kind.t`. The
mapping is a four-line `function` in the parser; an unknown
identifier raises a parse error naming the offending token,
e.g. `parse error: unknown kind "Int32"`.

The alternative — letting the field type carry a raw string
and resolving in `validate` — would mean that every
`Statement.t` value before validation has the type lying about
the data: `field.kind : string` claims a kind, but the value
isn't yet structurally a kind. That's exactly the smell the
design doc cites when justifying `Statement.field` as a
separate type from `Schema.field`. Applying the same principle
here puts the resolution at the earliest layer that can do it
safely, so all downstream code (`validate`, `format`,
`execute_write`) deals in resolved kinds.

The design doc's IR shape (`field = { name : string; kind :
Value.Kind.t }`) implies parser-side resolution; its
validation-rules list mentions "unknown kind name" as a
structural check, which is the inconsistency this decision
settles. Validate's rules in slice 14 are the five remaining
genuinely structural checks; kind resolution moves to parse
time.

### Printer covers all four constructors

`Format.statement : Statement.t -> string` formats every
constructor, not just `Create_table`. Three of the four are
one-liners (`:list tables`, `:drop table <name>`, `:describe
<name>`); `Create_table` carries the canonical multi-line
form.

The benefit is a uniform round-trip property: for every
`Statement.t s`, `Parser.parse (Format.statement s) =
Ok (Pipeline-or-Ddl wrapper around s)`. The hand-rolled
corpus exercises every shape against a single test harness,
which is more useful than a `Create_table`-only round-trip
that leaves the simpler shapes uncovered.

Cost: ~6 lines of code for the three one-liner arms. Cheap.

### `Described` carries the table name explicitly

The design doc declares `read_result = … | Described of
Schema.t`. This slice promotes the payload to a record:

```ocaml
type read_result =
  | Listed   of string list
  | Described of { table_name : string; schema : Schema.t }
```

The change is a deliberate departure from the design doc.
`Schema.t` doesn't carry a top-level table name; the catalog
*happens* to store schemas with `qualifier = Some table_name`
on every field (set by `Fixture` and by step-7's
`Create_table` executor arm), so the table name is recoverable
from the per-field qualifier. But that recovery is fragile:

- A future refactor that stores qualifier-less schemas in the
  catalog (the obvious cleanup once nothing depends on
  stored-qualifier shape) would silently break the renderer.
- A schema with mixed qualifiers (which shouldn't happen for a
  table's own schema, but isn't ruled out at the type level)
  would render with whichever qualifier the first field
  happened to have.

The executor *knows* the table name — it's what the user
typed and what got looked up in the catalog. Passing it
explicitly in the result removes the dependency on a
contingent fact about how schemas are stored.

The adapter that bridges executor result and printer input is
`Statement.of_schema`:

```ocaml
val of_schema : table_name:string -> Schema.t -> t
(* Produces Create_table { table_name; fields; primary_key }
   by stripping per-field qualifiers. *)
```

REPL renderer for `Described`:

```ocaml
Format.statement (Statement.of_schema ~table_name schema)
```

Three named operations, each doing one thing.

### Validate runs at the REPL, between parse and transaction

`Statement.validate` is invoked at the top of the REPL's `Ddl`
dispatch arm, after parsing and before `with_read_transaction`
or `with_write_transaction`. A validation error raises via
`failwith` and flows through the existing
`try Failure -> error: …` handler.

The alternative — calling `validate` at the top of
`Ddl_executor.execute_*` — would put structural checks inside
a transaction's scope, paying a writer-lock cost on every
`create table` for failures that have nothing to do with the
catalog. The design's call here (validate before the
transaction opens, catalog-aware checks inside it) is right.

### Create_table executor: storage first, catalog second

Inside the write transaction:

```
1. Catalog.get → if Some _, raise "table already exists".
2. Storage.create_map ~name:(Catalog.table_subdb_name table_name).
3. Catalog.put ~table_name schema.
4. Return Created table_name.
```

Both steps 2 and 3 are inside the same LMDB write
transaction, so either both commit or neither does. The order
is purely about readability and which failure surfaces if (say)
the subDB cap is exhausted: with this order, a `create_map`
failure aborts before any catalog write happens, which reads
more naturally ("build the thing, then declare it exists").

This mirrors slice 12's `Drop_table` sequence (`Storage.drop_map`
first, then `Catalog.delete`): destroy data before
de-registering, build data before registering. The symmetry
helps when reading the executor top to bottom side by side.

Step 7 constructs the catalog-side `Schema.t` from the
`Statement.field list` plus `primary_key`. The schema is
stored with `qualifier = Some table_name` on every field, to
match how `Fixture` stores schemas — Eval and the rest of the
read path expect that shape today, and slice 14 is not the
slice that touches that contract.

### Validate's rules

After kind resolution moves to parse time, validate covers
five structural checks. Each runs over a `Create_table`
statement (the only constructor with structural content);
other constructors pass trivially.

1. **Empty column list.** `:create table foo () primary key
   (id)` → `DDL: create table "foo": column list is empty`.
2. **Duplicate column in column list.** Two fields share a
   name → `DDL: create table "foo": column "email" appears
   twice`.
3. **Empty PK list (defensive).** Grammar rules this out, but
   the validator checks it so `Statement.t` values
   constructed by hand (in tests, in future surfaces) can't
   sneak through. → `DDL: create table "foo": primary key
   is empty`.
4. **PK references unknown column.** A PK column not in the
   column list → `DDL: create table "foo": primary key
   column "id" not in column list`.
5. **Duplicate column in PK list.** `primary key (id, id)`
   → `DDL: create table "foo": primary key column "id"
   appears twice`.

Errors are reported one at a time; the first failure short-
circuits the validator. Reporting multiple errors at once is
ergonomics that isn't worth designing for the slice's surface
size.

### Error prefix: `DDL:` for everything

Per slice 13's reframe, user-facing DDL errors start with
`DDL:` (the user-facing layer name) rather than `Ddl:` or
`Ddl_executor:` (implementation module names). Concretely, the
slice introduces:

```
DDL: create table "foo": column list is empty
DDL: create table "foo": column "email" appears twice
DDL: create table "foo": primary key is empty
DDL: create table "foo": primary key column "id" not in column list
DDL: create table "foo": primary key column "id" appears twice
DDL: create table "foo": table already exists
DDL: describe "foo": no such table
```

The existing `DDL: drop table "foo": no such table` from
slice 13 stays unchanged. No other error strings move.

### Round-trip testing: hand-rolled corpus, no qcheck

The round-trip property `parse(format(s)) ≡ s` is checked over
a hand-rolled corpus of `Statement.t` values. Target coverage:

- One case per non-`Create_table` constructor.
- `Create_table` cases: single-column PK with each kind
  (Int64, String, Bool); compound PK (two columns); single-
  field table; max-field table (5–6 fields).
- The corpus includes the design doc's canonical form
  examples (`users` and `order_items`) verbatim, so the
  format is anchored to the document.

`qcheck-alcotest` is deliberately not adopted. The grammar
surface is small enough to enumerate by hand; adding a
property-testing harness for one property is heavy in
dependency terms; and the project hasn't needed property
testing yet. Revisit if a second property emerges (validate
idempotence, parser left-inverse for other grammar fragments).

### Doctest: per-file state, fixture-free names

The slice's new doc section in `docs/query-language.md` adds
worked examples for `:create table`, `:describe`, and the
existing `:list tables` and `:drop table`. The doctest
extractor runs every markdown file through `Repl.run` against
a fresh fixture-populated environment per file; sessions
within a file share state.

The new section uses fixture-free table names (`widgets`,
`measurements`, or similar) so it doesn't collide with the
seeded `users` and `orders`. The section is self-contained:
it creates tables, describes them, lists them, drops them,
returning state to the fixture baseline at the end of the
section. Subsequent (existing) sections in the same file see
the same state they did before.

Per-session isolation in the extractor is rejected. The
shared-state model lets examples build a narrative (create,
then describe what was just created, then drop), which is the
actual user journey; per-session isolation would force each
block to re-create state inline as setup.

### Fixture interaction caveat

Once `create table` lands, a user can in principle
`:create table users (…)` against the fixture-seeded `users`.
The executor's catalog check raises `DDL: create table
"users": table already exists`, so the operation fails as the
design intends. The user could `:drop table users` first and
then `:create table users (…)` with a different schema; on
the next REPL restart, the fixture re-seeds `users` with its
original schema, silently overwriting the catalog binding
(`Catalog.put`'s documented "overwrites silently" behaviour).

This is the slice-12 pre-fixture-retirement caveat extended:
fixture-seeded tables, once mutated by DDL, revert on next
restart. Worth a single line in the verification section so
the smoke surfaces it; no design change. Slice 15 retires the
fixture and the caveat with it.

## Steps

Ten commits across eight numbered steps. Steps 1–3 land the
pure AST/validate/format additions inside `dovetail.ddl`. Step
4 is the vertical opener — describe end-to-end against the
existing fixture — split into 4a (executor arm) and 4b (parser,
renderer, REPL integration) so each commit is a focused piece.
Steps 5–7 stack `create table` from parser to executor, with
step 7 similarly split into 7a (executor arm) and 7b (renderer,
REPL integration). Step 8 is documentation and forward-
reference cleanup.

The a/b splits mirror slice 12's 5a/5b pattern: land the
executor's new arm in isolation under direct testing first,
then wire it through the parser and renderer in a second
commit. The "executor first, REPL second" rhythm keeps each
commit small and the user-visible moments at predictable
boundaries.

Each commit ends with `dune test` green, formatter clean, and
a sensible message.

### Step 1 — AST additions in `Statement`

Pure module surgery in `lib/ddl/statement.ml` and `.mli`:

- Add `type field = { name : string; kind : Value.Kind.t }`.
- Extend `type t` with `Describe of { table_name : string }`
  and `Create_table of { table_name : string; fields : field
  list; primary_key : string list }`.
- Extend `type read_result` with `Described of { table_name :
  string; schema : Schema.t }`.
- Extend `type write_result` with `Created of string`.
- Extend `classify`: `Describe` → `` `Read ``, `Create_table`
  → `` `Write ``.
- Add `val of_schema : table_name:string -> Schema.t -> t`.
  Strips per-field qualifiers and produces a `Create_table`.

Doc comments on the `.mli` cover each new value and link to
`Format.statement` and `Ddl_executor` where appropriate.

Tests in `test/ddl/test_statement.ml` (extend existing):

- `classify` for `Describe` and `Create_table`.
- `of_schema` round-trip: a fixture-shaped schema produces
  a `Create_table` with stripped qualifiers and the same
  field names, kinds, and PK.

After this step `Ddl_executor.execute_read` and
`execute_write` get an `assert false` arm for each new
constructor (guarded by the classify-then-execute contract at
the REPL). No behaviour reaches users yet.

### Step 2 — `Statement.validate`

Add `val validate : t -> (unit, string) result` to
`Statement.mli`. Implementation in `Statement.ml` runs the
five structural checks against `Create_table`; all other
constructors return `Ok ()`. Short-circuits on the first
failure.

Error strings exactly as listed in the architectural decision:
`DDL: create table "<name>": …`.

Tests in `test/ddl/test_statement.ml`:

- One test per rule, asserting the error string verbatim.
- Happy path: a well-formed `Create_table` returns `Ok ()`.
- Non-`Create_table` constructors: `Ok ()`.

Not yet invoked anywhere — that wires in at step 6.

### Step 3 — `Format` module

New `lib/ddl/format.ml` and `.mli`. Single public function:

```ocaml
val statement : Statement.t -> string
```

Implementation handles all four constructors:

- `List_tables` → `":list tables"`.
- `Drop_table { table_name }` → `":drop table " ^ table_name`.
- `Describe { table_name }` → `":describe " ^ table_name`.
- `Create_table { table_name; fields; primary_key }` →
  canonical multi-line form per the design doc: opening
  `":create table " ^ table_name ^ " ("`, one column per
  line with two-space indent and trailing comma, closing
  `")"`, then `" primary key (" ^ pks ^ ")"` on its own
  line.

Update `lib/ddl/dune` to list `format` alongside `statement`
in the library's modules.

Tests in `test/ddl/test_format.ml` (new):

- The three one-liner cases.
- `Create_table` with a single-column PK and one each of the
  three kinds.
- `Create_table` with a compound PK.
- The design doc's `users` and `order_items` examples
  verbatim, asserting the output matches the design doc's
  canonical form exactly.

No round-trip yet — the parser doesn't admit the new
productions until steps 4 and 5.

### Step 4a — `Ddl_executor.execute_read` Describe arm

The executor side of describe, with no parser or REPL change.
No user-visible behaviour yet — the parser still rejects
`:describe`, so the new arm is reached only by direct test
calls.

`Ddl_executor.execute_read`'s Describe arm calls `Catalog.get`;
raises `failwith` with `DDL: describe "<name>": no such table`
if `None`; else returns `Described { table_name; schema }`. The
`assert false` arm from step 1 is replaced.

Tests in `test/test_ddl_executor.ml`:

- Happy path: hand-populate a catalog with a known schema,
  call `execute_read` for `Describe { table_name }` under
  `with_read_transaction`, assert the result equals
  `Described { table_name; schema }` with the schema bit-for-
  bit identical.
- Missing table: call `execute_read` for `Describe` against
  an empty catalog, assert the `Failure` carries
  `DDL: describe "nonexistent": no such table`.

### Step 4b — Parser, REPL renderer, and integration

The vertical opener proper. After this commit `:describe users`
works at the REPL.

Two coordinated changes plus the round-trip corpus:

- **Parser:** extend the DDL body grammar with `describe
  <identifier>`. Returns `Statement.Describe { table_name }`.
  Parse-time identifier rules match the existing `:drop table`
  form.
- **REPL renderer:** `Described { table_name; schema }` →
  `Format.statement (Statement.of_schema ~table_name schema)`
  printed via the existing output channel.

Tests:

- `test/test_parser.ml`: `:describe foo` parses to the
  expected `Statement.Describe`. Malformed (`:describe` with
  no name, `:describe foo bar`) is a parse error.
- `test/test_repl.ml`: end-to-end `:describe users` against
  the fixture, asserting the canonical-form output. Also
  `:describe nonexistent` rendering the expected
  `error: DDL: describe "nonexistent": no such table` line.
- `test/test_ddl_roundtrip.ml` (new): round-trip corpus for
  the three constructors the parser now handles
  (`List_tables`, `Drop_table`, `Describe`). The
  `Create_table` rows of the corpus are populated as
  `(_ignore = true)` stubs that step 5 turns on.

### Step 5 — Parser for `:create table`

Extend the DDL body grammar with the full `create table`
production. Grammar shape per the design doc:

```
:create table <identifier> (
  <identifier>: <kind>,
  …
) primary key (<identifier>, …)
```

Comma is the column separator; trailing comma is tolerated in
both the column list and the PK list. Whitespace and line
breaks are flexible inside parentheses, matching how the
canonical printer formats output.

`<kind>` is parsed as an identifier and mapped to
`Value.Kind.t` via a single `match`:

```ocaml
match identifier with
| "Int64"  -> Value.Kind.Int64
| "String" -> Value.Kind.String
| "Bool"   -> Value.Kind.Bool
| other    -> fail ("unknown kind " ^ quoted other)
```

Returns `Statement.Create_table { table_name; fields;
primary_key }`. No executor wiring yet — `Create_table` parses
but raises `assert false` if reached at the executor.

Tests:

- `test/test_parser.ml`: a small corpus of successful parses
  covering single-column PK, compound PK, all three kinds,
  trailing commas. Parse failures for unknown kind, empty
  parens, missing `primary key`, etc.
- `test/test_ddl_roundtrip.ml`: the `Create_table` corpus
  rows from step 4 now run for real, asserting
  `Parser.parse (Format.statement s) = Ok (Ast.Ddl s)` for
  each `s`. The full round-trip corpus is now green.

### Step 6 — Validate wired into REPL dispatch

Hook `Statement.validate` into the REPL's `Ddl` arm. After
parse and before `classify`:

```ocaml
match Statement.validate statement with
| Error message -> raise (Failure message)
| Ok () -> (
  match Statement.classify statement with
  | `Read  -> Storage.with_read_transaction …
  | `Write -> Storage.with_write_transaction …)
```

The raise flows through the existing `try Failure -> error: …`
handler in `evaluate_and_print`.

This step adds no new validate rules. The wiring is a few
lines; the test surface is the per-rule REPL-level coverage.

Tests in `test/test_repl.ml`:

- Each of the five validate rules: feed an offending input
  to `Repl.run`, assert the rendered error string. Empty
  column list and the two duplicate-column cases are
  ungrammatical via the parser path (e.g. `:create table
  foo () primary key (id)`); the others may need to be
  fed via the test layer if the grammar rules them out.
  Where the grammar rules out a case, the validate test
  in step 2 stands alone and there's no REPL-level case.
- A failing validate leaves the catalog unchanged — no
  transaction opens.

### Step 7a — `Ddl_executor.execute_write` Create_table arm

The executor side of create, with no renderer change. After
this commit a user typing `:create table widgets (…)` at the
REPL reaches the executor — but the REPL renderer for
`Created` is still missing, so the renderer match would
`assert false`. In practice this commit is tested via direct
calls to `execute_write`, not via `Repl.run`; step 7b adds
the renderer and the end-to-end exercise.

`Ddl_executor.execute_write`'s Create_table arm, inside the
write transaction:

1. `Catalog.get ~table_name` → if `Some _`, raise
   `failwith "DDL: create table \"<name>\": table already
   exists"`.
2. Build a `Schema.t` from `Statement.field list` and
   `primary_key`. Each field's `qualifier` is set to
   `Some table_name` (matches the `Fixture` shape the rest
   of the read path expects).
3. `Storage.create_map ~name:(Catalog.table_subdb_name
   table_name)`.
4. `Catalog.put ~table_name schema`.
5. Return `Created table_name`.

The `assert false` arm from step 1 is replaced.

Tests in `test/test_ddl_executor.ml`:

- Happy path: hand-construct `Create_table` statements,
  invoke `execute_write` under `with_write_transaction`,
  assert the catalog binding exists with the expected
  schema and the storage subDB is open.
- "Table already exists": pre-populate the catalog, invoke
  `execute_write`, assert the expected `Failure` and that
  no storage subDB was created.
- Rollback on raise: the transaction is aborted on raise,
  so any partial state from steps 2–4 is rolled back. The
  test re-opens a fresh transaction and confirms catalog
  and storage are at the pre-call state.

### Step 7b — `Created` renderer and end-to-end integration

The slice's second user-visible commit. After this step
`:create table widgets (id: Int64, name: String) primary key
(id)` works at the REPL, and the new table can be inspected
with `:describe widgets` or appears in `:list tables`.

The change is one line of renderer plus an integration test:

- **REPL renderer:** `Created name` →
  `"created table \"" ^ name ^ "\""` printed via the
  existing output channel.

Tests in `test/test_repl.ml`:

- End-to-end sequence against a clean environment: create
  `widgets`, list (sees it), describe (canonical form
  matches), drop, list (gone).
- The "table already exists" error renders as
  `error: DDL: create table "widgets": table already
  exists` at the REPL.

### Step 8 — Documentation

Extend `docs/query-language.md` with a "Data definition"
section. Cover all four DDL statements; the existing
`:list tables` and `:drop table` may already be lightly
mentioned and get reorganised into the new section.

Worked examples use fixture-free table names (e.g.
`widgets`) and are self-cleaning: any table created in the
section is dropped before the section ends, so subsequent
sections in the same file see baseline state.

Doctest the examples via the slice-10 extractor. Verify
`test/test_documentation.ml` continues to pass for every
markdown file.

Three small cleanups bundled into this commit:

- `docs/plans/12-slice-12-list-and-drop-tables.md` has an
  internal numbering inconsistency: the intro lists "Slice
  12 / 13 / 14" while the out-of-scope section lists "14 /
  15". Bring the intro into line with the renumbering that
  slice 13 step 1 was meant to apply.
- `docs/plans/ddl-design.md` previously used `Ddl:` error
  prefixes in its examples (e.g. `Ddl: create table
  "users": column "email" appears twice`). Update those
  examples to `DDL:` per slice 13's reframe so the doc
  matches the code.
- A one-line note in the slice 14 verification section about
  fixture re-seeding behaviour after user-driven create
  against a fixture-seeded name.

## Verification

End-of-slice manual smoke (in the REPL against the fixture):

- `:list tables` — confirm `orders` and `users`.
- `:create table widgets (id: Int64, name: String) primary
  key (id)` — confirm `created table "widgets"`.
- `:list tables` — confirm `orders`, `users`, `widgets`.
- `:describe widgets` — confirm output exactly matches:

  ```
  :create table widgets (
    id: Int64,
    name: String,
  ) primary key (id)
  ```

- `:describe users` — confirm canonical form against the
  fixture's schema.
- `:create table widgets (…)` again — confirm error
  `DDL: create table "widgets": table already exists`.
- `:describe nonexistent` — confirm error
  `DDL: describe "nonexistent": no such table`.
- `:create table foo () primary key (id)` — parse error or
  validate error (depending on grammar shape), no catalog
  change.
- `:create table foo (a: Int32) primary key (a)` — parse
  error naming `Int32`, no catalog change.
- `:create table foo (id: Int64, id: String) primary key
  (id)` — validate error `column "id" appears twice`, no
  catalog change.
- `:create table foo (id: Int64, name: String) primary key
  (xyz)` — validate error `primary key column "xyz" not in
  column list`, no catalog change.
- `:drop table widgets` — confirm `dropped table "widgets"`.
- Pipeline queries continue to work; `users | restrict id =
  1` returns expected output.
- Exit the REPL and restart it. Confirm the fixture
  re-seeds; `widgets` is gone (we dropped it, and even if
  it weren't, the fixture wouldn't re-create it). If the
  user had instead left a `widgets` table behind, it would
  persist across restart — only fixture-seeded names get
  re-seeded.

Plus the usual: `dune test` is green; `dune build @fmt
--auto-promote` leaves the tree clean.

## Out of scope

- **Fixture retirement.** Slice 15. The fixture still seeds
  `users` and `orders` on first run.
- **`alter table` in any form.** A separate design exercise.
- **`if exists` / `if not exists` idempotency clauses.** Pure
  ergonomics; additive when scripts become a real story.
- **`rename table`, `truncate table`.** Deferrable per the
  DDL design doc.
- **`create index` / `drop index`.** Presupposes secondary
  indexes as a user-visible concept, which don't exist.
- **Property-based testing harness.** Hand-rolled corpus is
  enough for slice 14; revisit if a second property emerges.
- **Multi-statement input, explicit transactions.** Already
  on the Beyond list in the README.
- **System-tables-style introspection (`_tables`, `_columns`
  as queryable relations).** A legitimate future direction,
  but `describe` and `:list tables` are the ergonomic forms
  the design commits to first.
- **Additional kinds (Float64, Date, etc.).** Adding a kind
  extends the parser's kind table by one identifier match;
  nothing else in the DDL surface or IR depends on the
  current kind set.
- **The `Ddl_format` to `dovetail.ddl`-internal aliasing
  decision for non-residual callers.** `Format` is consumed
  today only by `Ddl_executor` (within the residual `dovetail`
  library) and the round-trip test (flat `test/`). Both use
  the library-alias style established in slice 13. Future
  callers in other sub-libraries will follow that pattern.
