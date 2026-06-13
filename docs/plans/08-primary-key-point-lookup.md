# Slice 8: Primary-key point lookup

**The durable design rationale here is promoted to
[`docs/internals/optimization.md`](../internals/optimization.md),
which tracks the code as it evolves; this plan is frozen history.**

The eighth vertical slice. End-state: `users | restrict id = 5`
produces an `IndexLookup` physical operator that fetches the
single matching row by primary key via `Storage.get`, instead of
scanning the whole table.

This is the first time `Translate` chooses between physical
strategies based on the predicate's shape, and the first slice
where `Translate` needs to inspect schemas (and so needs catalog
access). Range scans are deliberately deferred: they're a wider
piece of work (cursor seek mechanics, inclusive/exclusive bounds,
range-pattern recognition over comparison conjunctions) and
nothing slated for the next few slices needs them. Slice 9's
indexed nested-loop join just needs point lookups.

## Context

The original `00-initial-plan.md` had primary-key range scans as
slice 6. Two detour slices have since been inserted: slice 6
(streaming CPS executor) and slice 7 (expression language).
Slice 7 was originally forced because PK *range* recognition
needs ordering comparisons and `and`-conjunctions in the
predicate language. With the scope here narrowed to point
lookups, slice 7 is no longer strictly required for slice 8 —
but its expression-language work is still load-bearing for the
conjunct partitioning below, and slice 7's other motivations
stand on their own.

Slice 9 (indexed nested-loop join over the PK) is the immediate
downstream consumer. Slice 9 will not embed `IndexLookup` as a
sub-plan — it'll be a separate operator with its own per-row
lookup logic — but slice 8 establishes the precedent: the
physical-operator shape, the catalog plumbing through
`Translate`, and the eval helper that wraps a single
`Storage.get` as a one-tuple relation.

## Goal

```
> users | restrict id = 1
│ users.id │ users.name │ users.email       │ users.active │
├──────────┼────────────┼───────────────────┼──────────────┤
│        1 │ Alice      │ alice@example.com │ true         │

> users | restrict id = 1 and active
│ users.id │ users.name │ users.email       │ users.active │
├──────────┼────────────┼───────────────────┼──────────────┤
│        1 │ Alice      │ alice@example.com │ true         │

> users | restrict id = 99
(no rows)
```

The first query's physical plan is `IndexLookup`. The second is
`Filter(active, IndexLookup(id = 1))`. The third is
`IndexLookup` (no rows because the key isn't present). Every
existing query keeps producing the same results; the only
observable difference for queries that don't match the new
pattern is that the plan still uses `FullScan`.

## Slice-8 architectural decisions

### Scope: equality literal only, with conjunct partitioning

Slice 8 recognises one logical shape:

```
Restrict { input = Scan { table }; predicate }
```

The predicate is flattened into a conjunction list (walking
`And` nodes). Each conjunct is classified:

- **PK-equality conjunct:** `Compare { Column to PK; Equal;
  Literal (Int64 _) }` or the mirrored form
  `Compare { Literal (Int64 _); Equal; Column to PK }`. Folds
  into the `IndexLookup`'s key.
- **Residual conjunct:** everything else. Joined back together
  with `And` and emitted as the predicate of a `Filter` wrapping
  the `IndexLookup`.

If no PK-equality conjunct exists, no folding happens — the plan
stays as `Filter(FullScan)`. If more than one PK-equality
conjunct exists (`id = 5 and id = 7`), one is folded and the
rest go into the residual; the runtime result is still correct
(the residual `Filter` evaluates the other equality against the
fetched row and yields nothing). No constant folding in
`Translate`.

**Out of scope, deferred:**

- Range scans (`<`, `<=`, `>`, `>=`, two-sided bounds).
- Disjunctions of PK lookups (`id = 1 or id = 2`). A union of
  point lookups is a different operator.
- Predicate pushdown through `Project` or chained `Restrict`s.
  `users | project name, id | restrict id = 5` stays unoptimised
  in this slice.
- Non-`Int64` PK kinds, composite PKs, missing-PK tables. All
  fall back to `Filter(FullScan)`.

### Conjunct-recognition rules

The matching algorithm:

- **Column form.** Both bare `id` and qualified `<table>.id` (where
  `<table>` is the scanned table) match the PK column. Any other
  qualifier is a non-match.
- **Direction.** Both `id = K` and `K = id` are recognised
  (`Equal` is commutative).
- **Literal kind.** Only `Literal (Int64 _)` folds. A
  type-mismatched literal (`id = "five"`) stays in the residual;
  `Expression.resolve` will fail it at resolve time, same as
  today.
- **PK preconditions.** No folding unless `schema.primary_key`
  is exactly `[col]` and `col`'s kind is `Int64`. Multi-column
  PKs, non-`Int64` PKs, and zero-PK tables all skip folding.

### `IndexLookup` operator shape

```ocaml
| IndexLookup of { table : string; key : int64 }
```

Field type is `int64`, not `Value.t`. Matches the slice's PK-kind
scope; widens to `Value.t` (one-line change) when other key kinds
arrive.

The operator carries a literal `int64`, not an `Expression.t`.
Slice 9's indexed NLJ will be a separate operator with its own
per-row key derivation — it won't compose `IndexLookup` as a
sub-plan with a column-reference key. Keeping `IndexLookup`'s
key concrete avoids the temptation to overgeneralise an operator
whose only current job is "look up one row by literal PK".

### `Translate` gains a catalog callback

`Translate.translate` currently takes only the logical plan. To
recognise PKs, it needs to look up the schema for the scanned
table. The signature becomes:

```ocaml
val translate :
  catalog:(string -> Schema.t option) -> Logical.t -> Physical.t
```

The REPL builds the closure at the call site:

```ocaml
let catalog table_name =
  Catalog.get environment transaction ~table_name
in
Translate.translate ~catalog plan
```

Rejected alternatives:

- **Pass `environment` and `transaction` through.** Couples
  `Translate` to `Storage`. The dependency is "look up a schema
  by name", not "talk to the storage layer".
- **Bake schemas into `Logical.Scan` at `Lower` time
  (`Logical.Scan { table; schema }`).** Pushes catalog awareness
  one layer earlier and duplicates schema info in two IRs. The
  benefit (Translate stays pure) doesn't pay for the cost.

If a scan references a table the catalog doesn't know about,
the callback returns `None` and `Translate` skips the
optimisation. The error will surface at eval time exactly as it
does today (catalog miss in `Eval.lookup_table_resources`).

### Storage and eval

No new storage primitive. `Storage.get` already returns
`string option` for a byte key, which is exactly what
`IndexLookup` needs. `Row_codec.decode_row` already takes a
`(key_bytes, value_bytes)` pair and produces a `Schema.tuple`.

`Eval` for `IndexLookup`:

1. Resolve the schema and table map via the existing
   `lookup_table_resources` helper.
2. `Encoding.encode_int64_key key` to produce the byte key.
3. `Storage.get table_map transaction ~key`.
4. If `Some value_bytes`: yield a one-element seq from
   `Row_codec.decode_row schema (key_bytes, value_bytes)`. If
   `None`: yield `Seq.empty`.

The relation tag is `[`Bag`]`, same as `FullScan` — set/bag
semantics are a wider topic and aren't sharpened by this
operator.

## Sub-steps

Each step is one commit, ends with `dune test` green, and
leaves the project in a working state. Per-layer unit tests and
per-step integration tests at every step.

### Step 1 — `IndexLookup` constructor and eval support

Add the `IndexLookup` constructor to `Physical.t`. Extend
`Physical.format_at` with a one-line case (`IndexLookup(table,
key=K)`). Extend `Eval.eval` with a new arm that calls a
`evaluate_index_lookup` helper of the shape described above.

Tests:

- `test_physical.ml` — formatter unit test for `IndexLookup`.
- `test_eval.ml` — hand-build an `IndexLookup` plan against the
  fixture, assert one tuple with the right values for an existing
  key (e.g. `users` key `1L` → Alice's row), and zero tuples for
  a missing key (e.g. key `99L`).
- `test_pipeline.ml` — integration test: hand-build the plan,
  thread it through `Repl`'s pipeline so the resulting rendered
  output is asserted end-to-end.

No `Translate` changes yet. `users | restrict id = 5` still
parses and runs through `Filter(FullScan)`.

### Step 2 — Catalog plumbing and clean-case `Translate` rewrite

Change `Translate.translate`'s signature to take
`~catalog:(string -> Schema.t option)`. Update the REPL call
site to build the closure from `Catalog.get`. Add a new pattern
to `translate`:

```
Restrict { input = Scan { table }; predicate }
```

where `predicate` is a single PK-equality `Compare`. No
partitioning yet — only the bare case where the entire predicate
is `Compare { Column id; Equal; Literal (Int64 _) }` (or
mirrored). All other predicates keep going through
`Filter(FullScan)`.

Tests:

- `test_translate.ml` — unit tests on the rewrite. Build a fake
  catalog callback in-test. Assert:
  - `Restrict { Scan "users"; Compare (id, Equal, Int64 5) }`
    becomes `IndexLookup { "users"; 5L }`.
  - Mirrored form (`Int64 5 = id`) also matches.
  - Qualified column reference (`users.id = 5`) matches; a
    mis-qualified one (`orders.id = 5`) on a `Scan "users"` does
    not.
  - Non-`Int64` literal on the PK column does not fold.
  - Non-PK column equality (`name = "Alice"`) does not fold.
  - Inequality (`id < 5`, `id <> 5`) does not fold.
  - Table with composite PK / missing PK / non-`Int64` PK does
    not fold (fake catalog returns such a schema).
- `test_pipeline.ml` — integration tests: `users | restrict id =
  1` returns Alice's row; `users | restrict id = 99` returns no
  rows; an unchanged regression case (e.g. `users | restrict
  active`) still works.

After this step, the conjunction case (`id = 5 and active`)
still doesn't optimise — it stays as `Filter(FullScan)`.

### Step 3 — Conjunct partitioning

Generalise the `Translate` match: walk the conjunction tree,
classify each leaf, fold one PK-equality conjunct into
`IndexLookup`'s key, and wrap the result in a `Filter` carrying
the residual if any. If there's no residual, emit a bare
`IndexLookup`. If there's no PK-equality conjunct, keep the
existing `Filter(FullScan)` path.

Tests:

- `test_translate.ml` — additional unit tests:
  - `id = 5 and active` → `Filter(active, IndexLookup(id=5))`.
  - `active and id = 5` (PK conjunct on the right) → same.
  - `id = 5 and id = 7` → one folded, the other in the residual.
  - `id = 5 and name = "Alice" and active` →
    `Filter(name = "Alice" and active, IndexLookup(id=5))`.
  - Deeply nested ands like `(id = 5 and active) and name = "X"`
    flatten correctly.
- `test_pipeline.ml` — integration tests:
  - `users | restrict id = 1 and active` returns Alice's row.
  - `users | restrict id = 2 and active` returns no rows (Bob is
    inactive, the filter rejects).
  - `users | restrict id = 99 and active` returns no rows.

## Verification

REPL smoke at the end of slice 8:

```
> users | restrict id = 1
> users | restrict id = 99
> users | restrict id = 1 and active
> users | restrict id = 2 and active
> users | restrict id = 1 and name = "Alice"
```

If `--show-physical` (or whatever the EXPLAIN-style hook is by
slice 8) is wired up, each of the above should render with
`IndexLookup` in the plan tree rather than `FullScan`.

## Out of scope

- Range scans on the PK. Deferred until a workload (sort, limit,
  range-predicate restrict) motivates them.
- Disjunctions: `id = 1 or id = 2`. Needs a union-of-lookups
  operator.
- Predicate pushdown through `Project` or chained `Restrict`s.
- Non-`Int64` PK kinds, composite PKs.
- Secondary indexes.
