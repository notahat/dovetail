# Slice 9: Indexed nested-loop join over the primary key

**The durable design rationale here is promoted to
[`docs/internals/optimization.md`](../internals/optimization.md),
which tracks the code as it evolves; this plan is frozen history.**

The ninth vertical slice. End-state: `users | join orders on
users.id = orders.user_id` produces an `IndexedNestedLoopJoin`
that streams one side and probes the other by primary key via
`Storage.get` once per outer row, instead of materialising the
right side and running a per-pair predicate.

This is the first physical operator that has *asymmetric*
inputs — one side is a streamed sub-plan, the other is a base
table probed per row. It is also the first time `Translate` has
to choose which side of a `CrossProduct` to flip into the
"indexed" role, and the first time a physical operator carries
a small piece of presentation metadata to keep its output
column order aligned with the user's logical ordering.

## Context

Slice 5 introduced `NestedLoopJoin`: `Translate` rewrites
`Restrict(CrossProduct(...), predicate)` into a fused inner
join, but the join still materialises one side and evaluates
the predicate per pair. Slice 8 introduced `IndexLookup` and
its `Translate` rewrite: the first time `Translate` picks a
physical strategy based on the predicate's shape, and the
first time `Translate` calls into the catalog. Slice 9 builds
on both: a new operator that does per-row PK probes inside a
join, recognised by `Translate` from the same `Restrict`-over-
`CrossProduct` shape that already feeds `NestedLoopJoin`.

The optimisation matters because today's `NestedLoopJoin`
materialises the right side and evaluates the join predicate
on every (left, right) pair: cost is O(|left| × |right|). When
one side's join column is the PK, a probe is O(log |right|),
giving O(|left| × log |right|) end-to-end. For the fixture
this is a small constant difference; the structural shape
matters more than the numbers — it's the pattern that secondary
indexes and hash joins will slot in alongside.

Secondary indexes are deferred until a workload motivates them
(echoing the slice-8 deferral of range scans); slice 9 only
recognises PK probes against base tables.

## Goal

```
> users | join orders on users.id = orders.user_id | project name, description, amount
│ users.name │ orders.description │ orders.amount │
├────────────┼────────────────────┼───────────────┤
│ Alice      │ Coffee             │             5 │
│ Alice      │ Bagel              │             4 │
│ Bob        │ Tea                │             3 │
│ Carol      │ Sandwich           │             8 │
│ Carol      │ Cake               │             6 │
│ Eve        │ Cookie             │             2 │

> users | join orders on users.id = orders.user_id and orders.amount >= 5
(same six rows filtered to amount >= 5)

> users | join orders on users.id = orders.user_id | restrict orders.amount >= 5
(same physical plan as the previous query; same rows)
```

The first query's physical plan is an `IndexedNestedLoopJoin`
that streams `orders` and probes `users` by PK. The second
becomes `Filter(orders.amount >= 5, IndexedNestedLoopJoin(...))`
— the join PK-eq conjunct folds into the indexed join, the
remaining conjunct stays in a wrapping `Filter`. The third has
the same physical plan as the second: a key invariant of this
slice is that syntactically equivalent queries (the `and`-form
on the `on`-clause versus a trailing `| restrict`) produce the
same plan and so the same performance.

Every existing query keeps producing the same results, in the
same column order. Joins where neither side's PK is in the
equality predicate still run through `NestedLoopJoin`.

## Slice-9 architectural decisions

### Operator shape: physical roles, with `inner_position` for output ordering

```ocaml
| IndexedNestedLoopJoin of {
    outer : t;
    inner_table : string;
    outer_key_column : Schema.column_reference;
    inner_position : [ `Left | `Right ];
  }
```

The operator describes execution honestly: `outer` is whatever
sub-plan supplies the streamed side, `inner_table` is the base
table whose storage map is probed once per outer tuple, and
`outer_key_column` names the column from the outer's schema
whose per-row value becomes the probe key.

`inner_position` records where the inner sat in the *logical*
`CrossProduct`. Eval consults it when assembling the output
schema and combined tuples: `Left` means `inner.fields @
outer.fields`, `Right` means `outer.fields @ inner.fields`.
Without this tag, picking the syntactically-right side as the
outer (which is what the canonical `users | join orders on
users.id = orders.user_id` calls for, since `users` is the
inner PK side) would silently reorder the output's columns.
The tag costs one extra field plus a four-line `if` in eval to
preserve a property worth holding: optimisations are
observable in the plan and in performance, not in the result's
shape.

The `primary_key` of the output is `[]`, matching
`NestedLoopJoin` and `CrossProduct`. Derived relations don't
carry PK information at this point in the project.

Rejected alternatives:

- **Schema follows execution order (no `inner_position` tag).**
  Simpler operator, but existing queries silently change output
  column order when the optimisation fires. The
  performance-only invariant is worth the small extra field.
- **`outer_key_column` as `Expression.t`.** Over-general:
  `Expression.resolve` returns a bool predicate, not a value
  extractor, and the only meaningful per-row key derivation is
  "value at this column". A column reference says exactly that.
- **Inner as a sub-plan (`inner : t`) rather than a table
  name.** A sub-plan can't actually be probed by key — eval has
  to bottom out at "open this table's storage map". When
  secondary indexes arrive, they will want a different operator
  (probe a specific index, not a table); folding that future
  generality into this operator is premature.

### Trigger shape: conjunct partitioning over `Restrict(CrossProduct, predicate)`

`Translate` already recognises `Restrict(CrossProduct(left,
right), predicate)` as the inner-join shape and folds it into
`NestedLoopJoin`. Slice 9 widens that arm: first try to fold a
cross-side PK-equality conjunct into an `IndexedNestedLoopJoin`;
fall through to `NestedLoopJoin` when the predicate has no such
conjunct.

The recognition flattens `predicate` into a conjunction list
(reusing slice 8's `flatten_conjunction`). Each conjunct is
classified:

- **Join PK-equality conjunct:** `Compare { Column a; Equal;
  Column b }` (or mirrored) where exactly one of `a`/`b` is a
  qualified reference to an inner candidate's PK column. Folds
  into the `IndexedNestedLoopJoin`'s `outer_key_column` and
  `inner_table`.
- **Residual conjunct:** everything else. Joined back together
  with `And` and emitted as the predicate of a `Filter`
  wrapping the join.

Doing partitioning here (rather than bare-equality-only
recognition) is what guarantees the syntactic-equivalence
invariant from the Goal section. Without it, adding `and
other_condition` to the `on`-clause would drop back to plain
`NestedLoopJoin` while moving the same conjunct into a trailing
`| restrict` would keep the optimisation — a 10×–1000×
performance change driven by a stylistic choice. With
partitioning, both forms produce the same physical plan
because the partitioning step doesn't care which `Restrict` the
conjunct lives inside.

If no PK-equality conjunct exists, no folding happens — the
plan stays as `NestedLoopJoin` with the full predicate. If
more than one PK-equality conjunct exists (two inner
candidates that both qualify on the same equality, or two
different cross-side equalities), the first one in
left-to-right conjunct order is folded and the rest go into
the residual — correct, even if not maximally clever.

Predicate pushdown through `Project` or chained `Restrict`s
remains deferred (carried forward from slice 8); `users | join
orders on PK-eq | join more on users.id = more.user_id` —
where the second join's PK-eq references a column buried under
the first join — does not light up the optimisation on the
second join.

### Recognition algorithm

Given `Restrict(CrossProduct(left, right), predicate)`:

1. **Identify inner candidates.** For each of `left`/`right`
   that is a bare `Logical.Scan { table }` whose catalog
   schema has a single-column `Int64` primary key, record
   `(side, table, pk_name)`. Zero, one, or two candidates.
2. **Flatten** `predicate` into a conjunct list.
3. **For each candidate in turn**, walk the conjunct list
   looking for the first conjunct of shape `Compare { Column
   a; Equal; Column b }` (or mirrored) where exactly one of
   `a`/`b` is `{ qualifier = Some table; name = pk_name }`.
   The matching column is the inner-PK side; the other
   becomes the `outer_key_column`.
4. **Tiebreaker** when both candidates match: prefer left as
   outer, right as inner. This preserves the logical column
   order when there is no reason to flip.
5. **Emit** `IndexedNestedLoopJoin { outer = translate(other
   side); inner_table = table; outer_key_column; inner_position
   }` with the matched conjunct removed. If the residual
   conjunct list is non-empty, wrap in `Filter` with the
   conjuncts rebuilt into an `And` tree via slice 8's
   `build_conjunction`.
6. **Fall through** to today's `NestedLoopJoin` rewrite if no
   candidate matches any conjunct.

Matching is by *qualifier name*, not by reachability analysis
over the outer sub-plan. The simple form covers the canonical
cases (two-table joins, and chained joins where the inner of
each successive join is a base table). The more elaborate
cases (PK-eq buried under prior joins on the outer side)
defer to a future optimiser pass.

### Kind check at eval time

The inner's PK is constrained to `Int64`. The outer column
referenced by `outer_key_column` must therefore also have kind
`Int64`, so its per-row value can be encoded by
`Encoding.encode_int64_key`. The check happens at eval time,
inside the `Schema.find_field` lookup that resolves the outer
column against the outer relation's schema — same pattern as
`Filter`'s predicate resolution. `Translate` cannot reasonably
type-check arbitrary outer sub-plans without an external pass,
and a runtime error here is the same shape as today's
expression-resolve errors.

### No new storage or catalog primitives

`Storage.get` already takes a byte key and returns `string
option`; `Row_codec.decode_row` already turns a `(key_bytes,
value_bytes)` pair into a `Schema.tuple`;
`Encoding.encode_int64_key` already exists.
`Catalog.get` and `lookup_table_resources` already handle the
"give me schema and storage map for a table" pattern (and were
extended in slice 8 to make this available from `Translate` as
well as `Eval`). Slice 9 needs no new low-level primitives —
it composes existing ones.

## Sub-steps

Each step is one commit, ends with `dune test` green, and
leaves the project in a working state. Per-layer unit tests
and per-step integration tests at every step.

### Step 1 — `IndexedNestedLoopJoin` constructor and eval support

Add the `IndexedNestedLoopJoin` constructor to `Physical.t`.
Extend `Physical.format_at` with a case that renders the
operator-local fields on the header line and recurses into
`outer` at the next indent:

```
IndexedNestedLoopJoin(inner=users, outer_key=orders.user_id, inner_position=Left)
  FullScan(orders)
```

(The inner is a table name, not a sub-plan, so there is no
sub-tree to render for it.)

Add `evaluate_indexed_nested_loop_join` in `Eval`:

1. Open the inner via `lookup_table_resources` to get the
   inner schema and storage map.
2. `eval` the outer.
3. Resolve `outer_key_column` against the outer's schema with
   `Schema.find_field`; verify the resolved field's kind is
   `Int64` (raise `Failure` with a clear message otherwise).
4. Build the combined schema: `inner.fields @ outer.fields` if
   `inner_position = Left`, else `outer.fields @ inner.fields`.
   `primary_key = []`.
5. For each outer tuple: extract the `Int64` at the resolved
   position, `Encoding.encode_int64_key`, `Storage.get`,
   decode if `Some` (via `Row_codec.decode_row` on the inner's
   schema), combine in `inner_position` order. Skip the outer
   tuple if the probe misses.

Tests:

- `test_physical.ml` — formatter unit test for
  `IndexedNestedLoopJoin`, exercising both `inner_position`
  values.
- `test_eval_indexed_nested_loop_join.ml` (new file, parallel
  to the existing per-operator eval test files) — hand-build
  plans against the fixture for both `inner_position` values.
  Assert correct rows, correct schema (including column order),
  and the missing-key behaviour (an outer tuple whose key
  column has no inner match drops out without error).
- `test_pipeline.ml` — hand-build the plan and thread it
  through `Repl`'s pipeline; assert the end-to-end rendered
  output. (Pulls its weight here because the per-operator eval
  test checks shape; the pipeline test checks that the rendered
  table matches the existing presentation conventions.)

No `Translate` changes yet. `users | join orders on users.id
= orders.user_id` still parses and runs through
`NestedLoopJoin`.

### Step 2 — `Translate` recognises the simple case

Extend the existing `Restrict { input = CrossProduct { left;
right }; predicate }` arm to first try the indexed rewrite;
fall through to today's `NestedLoopJoin` when it doesn't fire.

Only the simplest predicate shape is recognised in this step:
the entire predicate is a single `Compare { Column a; Equal;
Column b }` (or mirrored) matching the algorithm above. No
conjunct flattening yet — predicates containing `And` at any
level fall through.

Pull the inner-candidate identification (single-`Int64`-PK
schema lookup) into a small helper, reusing the
`single_int64_primary_key` helper from slice 8. The
column-matching predicate is new and lives in `translate.ml`
as a sibling to slice 8's `try_primary_key_equality_literal`.

Tiebreaker (both sides qualify): prefer left as outer, right
as inner.

Tests:

- `test_translate.ml` — unit tests on the rewrite. Build a
  fake catalog callback in-test. Assert:
  - Canonical case: `Restrict(CrossProduct(Scan users, Scan
    orders), users.id = orders.user_id)` →
    `IndexedNestedLoopJoin { outer = FullScan orders;
    inner_table = "users"; outer_key_column = orders.user_id;
    inner_position = Left }`.
  - Mirrored equality (`orders.user_id = users.id`) produces
    the same plan.
  - Syntactic flip on the input
    (`Restrict(CrossProduct(Scan orders, Scan users), users.id
    = orders.user_id)`) picks users as inner with
    `inner_position = Right`.
  - Both sides qualify (`Restrict(CrossProduct(Scan users,
    Scan admins), users.id = admins.id)` where the fake
    catalog gives both tables a single-`Int64` PK named `id`):
    tiebreaker picks right as inner (`inner_position = Right`).
  - No bare-`Scan` candidate (e.g., either side wrapped in
    `Project` or `Restrict` in the logical plan) → falls back
    to `NestedLoopJoin`.
  - Predicate isn't an equality, or refers to non-PK columns,
    or both sides of the equality reference the same scan →
    falls back.
  - Predicate contains an `And` at any level → falls back
    (covered in step 3).
  - Inner table catalog miss → falls back, mirroring slice 8.
- `test_pipeline.ml` — integration tests:
  - `users | join orders on users.id = orders.user_id`
    returns the expected rows in today's column order
    (preserved by `inner_position`).
  - `users | join orders on users.id = orders.user_id | project
    name, description, amount` matches the existing README
    example.
  - Regression: `users | cross orders | restrict users.id <
    orders.user_id` (non-PK-eq) still uses `NestedLoopJoin`.

After this step, joins where the entire `on`-clause is a
single PK-equality use `IndexedNestedLoopJoin`. Joins with
any additional conjunct (e.g., `... and orders.amount > 5`)
still drop to `NestedLoopJoin`; step 3 closes that gap.

### Step 3 — Conjunct partitioning

Generalise the match: walk the conjunct list (reusing
`flatten_conjunction`), search for the first conjunct that
matches one of the inner candidates, fold it into
`IndexedNestedLoopJoin`'s key, and wrap the result in a
`Filter` carrying the residual if non-empty (built via
`build_conjunction`). If there's no residual, emit a bare
`IndexedNestedLoopJoin`. If no PK-eq conjunct matches any
candidate, keep the existing `NestedLoopJoin` path.

Add a sibling helper in `translate.ml` (alongside slice 8's
`partition_primary_key_conjunct`) — call it
`partition_join_pk_conjunct` — parameterised on
`~inner_table ~inner_pk_name` and applying the column-matching
predicate from step 2 to each conjunct in turn. Both helpers
keep their narrow shapes and live as siblings; extract to a
shared module if and when a third caller arrives.

Tests:

- `test_translate.ml` — additional unit tests:
  - `users.id = orders.user_id and orders.amount > 5` →
    `Filter(orders.amount > 5, IndexedNestedLoopJoin(...))`.
  - Reversed conjunct order (`orders.amount > 5 and users.id
    = orders.user_id`) → same plan.
  - Multiple PK-eqs across different candidates →
    left-to-right precedence; first match wins, rest go to
    residual.
  - Deeply nested `and`s (`(users.id = orders.user_id and
    orders.amount > 5) and users.active`) flatten correctly.
  - No PK-eq conjunct (`users.name = orders.description and
    orders.amount > 5`) → falls back to `NestedLoopJoin`
    carrying the full predicate.
  - **Syntactic-equivalence invariant** (asserted directly at
    the Translate layer, where it lives): build both
    `Restrict(CrossProduct(...), users.id = orders.user_id
    and orders.amount > 5)` and `Restrict(Restrict(
    CrossProduct(...), users.id = orders.user_id),
    orders.amount > 5)`. Translate both. Assert the resulting
    `Physical.t` values are equal.
- `test_pipeline.ml` — integration tests:
  - `users | join orders on users.id = orders.user_id and
    orders.amount >= 5` returns the expected rows.
  - `users | join orders on users.id = orders.user_id |
    restrict orders.amount >= 5` returns the same rows. The
    syntactic-equivalence invariant is checked at the
    `Translate` layer; the pipeline test confirms both forms
    work end-to-end.

## Verification

REPL smoke at the end of slice 9:

```
> users | join orders on users.id = orders.user_id
> users | join orders on users.id = orders.user_id and orders.amount >= 5
> users | join orders on users.id = orders.user_id | restrict orders.amount >= 5
> users | join orders on users.id = orders.user_id | project name, description, amount
> users | cross orders | restrict users.id < orders.user_id
```

With `--show-physical`, the first four render
`IndexedNestedLoopJoin` in the plan tree (the second wrapped
in a `Filter`, the third wrapped in a `Filter` from the
trailing `restrict`, the fourth wrapped in a `Project`); the
fifth still uses `NestedLoopJoin`.

## Out of scope

- Secondary indexes. Deferred until a workload motivates them.
- Hash join (for joins where neither side has a useful index).
- Predicate pushdown through `Project` or chained `Restrict`s.
- Reassociation across join chains to bubble PK-eq into reach
  (where slice 9's qualifier-matching algorithm gives up).
- Non-`Int64` PK kinds, composite PKs (carried forward from
  slice 8).
- Outer joins.
- Choosing the *smaller* side as outer when both qualify, via
  statistics. Slice 9's tiebreaker is structural (preserve
  logical order); a cost-based choice is a future optimiser
  concern.
