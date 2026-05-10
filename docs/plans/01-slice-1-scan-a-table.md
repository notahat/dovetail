# 02 — Slice 1: Scan a table via the RA language

The first vertical slice. End-state: the binary opens an LMDB env, populates
a `users` fixture if the catalog is empty, drops to a REPL, and typing
`users` returns five rows pretty-printed.

The slice exercises every layer of the eventual architecture at its
absolute minimum: storage, catalog, encoding, types, the three IRs, the
two transforms (`lower`, `translate`), `eval`, the RA parser, the REPL.
Each layer has one operator's worth of code at most, often less.

## Goal

```
$ dune exec dovetail
> users
| id | name        | email                   | active |
|----|-------------|-------------------------|--------|
|  1 | Alice       | alice@example.com       | true   |
|  2 | Bob         | bob@example.com         | false  |
|  3 | Carol       | carol@example.com       | true   |
|  4 | Dave        | dave@example.com        | true   |
|  5 | Eve         | eve@example.com         | false  |
> ^D
$
```

Pretty-print format is illustrative; the only requirements are that the
five fixture rows come out and the columns are identifiable.

## Slice-1 architectural decisions

These pin choices made during planning. Decisions that apply project-wide
live in `00-initial-plan.md`; this section captures the slice-1 specifics.

### Project bootstrap

- OCaml 5.2, local opam switch.
- Build system `dune`. Test framework `alcotest`. Parser library
  `angstrom`.
- No additional dependencies in slice 1 — `lmdb` is the only non-stdlib,
  non-build, non-test runtime dependency.
- Single library `dovetail` under `lib/`; single executable `dovetail`
  under `bin/`; tests under `test/`.

### Module layout (eager split, will move around as we learn)

```
lib/
  value.ml/.mli       value type + kind submodule
  schema.ml/.mli      schema type with PK info; tuple alias
  encoding.ml/.mli    key encoding (byte-comparable); tuple value Marshal
  storage.ml/.mli     LMDB env + txn wrappers + cursor → Seq.t
  catalog.ml/.mli     schema get/put
  relation.ml/.mli    phantom-typed relation; pretty-printing
  ast.ml/.mli         RA surface AST
  logical.ml/.mli     logical IR
  physical.ml/.mli    physical IR
  lower.ml/.mli       AST → Logical
  translate.ml/.mli   Logical → Physical
  eval.ml/.mli        Physical → Relation (Volcano)
  parser.ml/.mli      angstrom parser: text → AST
  fixture.ml/.mli     populate_if_empty
bin/
  main.ml             REPL entry point
test/
  …                   alcotest suites per module + integration
```

Every lib module gets a `.mli`. They are the public-API documentation.

### Core types

- `Value.t = Int64 of int64 | String of string | Bool of bool`. No
  nullability in slice 1.
- `Value.Kind.t = Int64 | String | Bool` for declaring schema field
  types.
- `Schema.field = { name : string; kind : Value.Kind.t }`.
- `Schema.t = { fields : field list; primary_key : string list }`. Slice 1
  uses single-column PKs but the type supports multi.
- `Schema.tuple = Value.t array`.
- `Relation.t` is phantom-typed for set/bag from day one:
  `type 'tag t = { schema : Schema.t; tuples : Schema.tuple Seq.t }
   constraint 'tag = [< `Set | `Bag ]`. Slice 1's only producer (`scan`)
  emits `[`Bag] t`.

### Encoding strategy

- **Keys**: hand-rolled byte-comparable. For slice 1 we need only `int64`
  (sign-flipped big-endian, so negatives sort below positives under
  `memcmp`). `bool` and single-column `string` key encoding will be added
  when something needs them; composite-key prefixing is deferred to
  slice 6.
- **Tuple values** (the LMDB value side): `Marshal.to_string` /
  `Marshal.from_string`. The tuple's non-PK column values, in schema
  field order, encoded as an OCaml `Value.t list`.
- **Catalog**: `Marshal` of `Schema.t`. Key is the table name as UTF-8
  bytes.
- We accept Marshal's coupling to OCaml's internal representation for now.
  When debugging forces a more inspectable format, we revisit. The plan
  for migration: introduce hand-rolled binary alongside secondary indexes
  in slice 6, where composite-key encoding work is happening anyway.

### LMDB and transaction lifecycle

- One LMDB env per `dovetail` process, opened at startup, closed on
  clean shutdown. `MDB_dbs` set generously (e.g. 4096) so we have room
  to grow.
- Default env path: `./dovetail-data` (override via CLI arg in step 9).
- One subDB per logical store: `catalog`, `table:users` (slice 1's only
  table). More subDBs arrive in later slices.
- `Storage.with_read_txn` and `Storage.with_write_txn` are higher-order
  functions around `Fun.protect` — txn opens, callback runs, txn
  closes (or aborts on exception) before returning. The REPL pattern is
  to consume the resulting `Relation.t` *inside* the callback (printing
  to stdout) so its `Seq.t`'s underlying cursor is alive while it's
  pulled.
- The `Relation.t` type does not track its txn lifetime statically. The
  footgun (returning a `Relation.t` from `with_read_txn` and trying to
  iterate it after the txn closes) is accepted for slice 1 and revisited
  if a future slice needs to bind a query result to a name.

### Execution

- Volcano via `Seq.t`. Tables scan as cursors-wrapped-as-sequences.
  Decoding copies into OCaml-owned values, so each yielded `Schema.tuple`
  is independent of LMDB's mapped memory; only the iterator itself
  remains tied to the cursor's txn.

### Out of scope for slice 1 (deferred to later slices)

- Any operator other than `Scan` / `FullScan`.
- `option`-typed columns / nullability.
- DDL or DML inside either query language.
- Multi-column primary keys (the type supports them; nothing exercises
  it).
- Secondary indexes.
- Composite-key encoding.
- Optimizer of any kind.
- Concurrent reads beyond what falls out of LMDB's MVCC.
- Pretty error messages; basic angstrom errors and stack traces are
  fine.
- CLI argument richness beyond an optional env path.

## Sub-steps

Nine steps. Each is one commit, with tests, leaving the project in a
working state. Build from the bottom: each step adds one layer, and from
step 5 onward each step ends with a runnable query at the layer just
introduced.

### 1. Bootstrap

`dune-project`, `dovetail.opam`, local opam switch on OCaml 5.2,
`.ocamlformat`. Empty `lib/dune`, `bin/dune` with a hello-world
`main.ml`, `test/dune` with alcotest wired and one trivial passing
test.

End state: `dune build`, `dune test`, `dune exec dovetail` all work.

### 2. Storage round-trip

`Storage` module. Env open/close (configurable path, generous
`MDB_dbs`). `with_read_txn` and `with_write_txn` via `Fun.protect`.
SubDB open/create. Cursor wrapping that yields `(bytes, bytes) Seq.t`.

Tests: temp directory env; write a few keys via a write txn, read them
back via a read txn; iterate via cursor; verify `with_*_txn` aborts
cleanly when the body raises.

End state: we can put and get arbitrary bytes through LMDB, scoped
properly. No types, no encoding yet.

### 3. Catalog round-trip

Introduce types: `Value.Kind`, `Schema.field`, `Schema.t` (with PK
info). Note: we do not need `Value.t` itself yet — the catalog only
*describes* schemas; it doesn't carry values.

`Catalog` module: `get : Storage.txn -> name:string -> Schema.t option`,
`put : Storage.txn -> name:string -> Schema.t -> unit`. Value bytes are
`Marshal.to_string`. Catalog subDB is named `catalog`.

Tests: round-trip a schema; missing-table returns `None`; multiple
schemas don't collide.

End state: we can save and load schemas.

### 4. Fixture writes data

Introduce `Value.t` and `Schema.tuple`. Add hand-rolled byte-comparable
encoding for `int64` keys (sign-flipped BE). Add `Marshal`-based encode
and decode for tuple values (the non-PK columns as a `Value.t list`,
in schema field order). Round-trip and ordering tests for the key
encoding. Round-trip tests for tuple value encoding.

`Fixture.populate_if_empty : Storage.env -> unit`. If `Catalog.get` for
`users` returns `None`, open a write txn and: write the `users` schema
to the catalog; create the `table:users` subDB; write the five fixture
rows.

Tests: fixture is idempotent (run twice, no duplicates, no errors); raw
bytes in LMDB after fixture decode back to the expected schema and
tuples.

End state: data on disk, verifiable through encoding round-trip and raw
inspection. No `Relation`, no `Eval` yet.

### 5. Physical IR can run a scan

Introduce `Relation.t` with the phantom set/bag tag. Add tuple
assembly: given a schema, a list of PK column values, and a list of
non-PK column values, produce a `Schema.tuple` in field order. Add key
*decoding* for `int64`.

`Physical.t = FullScan of { table : string }`. `Eval.eval :
Storage.txn -> Physical.t -> [`Bag] Relation.t`. The `FullScan` case
looks up the schema in the catalog, opens a cursor on `table:<name>`,
and yields decoded tuples lazily. `Relation.print` pretty-prints a
relation's contents.

Tests: a test populates a fresh env via `Fixture`, then runs
`Physical.FullScan { table = "users" }` inside a read txn and asserts
the five rows come back. **First end-to-end read.**

End state: `Eval` works against the physical IR.

### 6. Logical IR can run a scan

`Logical.t = Scan of { table : string }`. `Translate.translate :
Logical.t -> Physical.t`. The slice-1 case is one line.

Tests: construct `Logical.Scan { table = "users" }`, translate,
evaluate; same five rows.

End state: queries can be issued at the logical IR.

### 7. RA AST can run a scan

`Ast.t = Relation_name of string`. `Lower.lower : Ast.t -> Logical.t`.
The slice-1 case is one line.

Tests: construct `Ast.Relation_name "users"`, lower, translate,
evaluate; same five rows.

End state: queries can be issued at the AST level.

### 8. RA parser

`Parser` module using `angstrom`. Whitespace handling. One production:
identifier (letter then letter/digit/underscore) → `Ast.Relation_name`.
Top-level `parse : string -> (Ast.t, error) result`.

Tests: parse `"users"` to `Ast.Relation_name "users"`; tolerate leading
and trailing whitespace; reject empty input and obviously-malformed
input. Pipeline test: parse a string and run it through the full
pipeline, asserting rows.

End state: queries can be issued from a string.

### 9. REPL

`bin/main.ml`: parse args (optional LMDB env path, default
`./dovetail-data`); open the env; call `Fixture.populate_if_empty`;
enter a loop reading a line from stdin, parsing, lowering,
translating, evaluating inside `Storage.with_read_txn`, pretty-printing
the relation, and looping. Exit on EOF. Print errors and continue.

Tests: an integration test drives the binary with scripted stdin and
verifies stdout contains the five rows when given `users\n` as input.

End state: the demo from the top of this document works.

## Open questions, resolved

- **Pretty-print format for `Relation.t`.** Resolved in step 5: aligned
  ASCII pipe-table, header + separator + rows, numeric columns
  right-aligned. `Relation.print` takes an optional formatter so tests
  can capture output without going through stdout.
- **Error type shape for `Parser.parse`.** Resolved in step 8 with the
  smallest commitment: `type error = string`, forwarding angstrom's
  message unchanged. The `.mli` flags this as a slice-1 placeholder so
  callers already speak in terms of `Parser.error`; structured errors
  can land later without breaking the signature shape.
- **Cursor-leak protection in `Storage.iter_seq`.** Sidestepped: the
  step-2 implementation materialises the cursor's pairs into a list
  eagerly and wraps it as a `Seq.t`, so there is no live cursor for a
  dropped consumer to leak. The `.mli` flags this as a deliberate
  slice-1 simplification to revisit when a slice needs to scan enough
  rows that materialisation is the wrong choice.
