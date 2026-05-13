# 08 — Slice 8: Primary-key range scans

The eighth vertical slice. End-state: `users | restrict id >= 10
and id <= 100` produces an `IndexScan` physical operator that
seeks the LMDB cursor to the lower bound and stops at the upper
bound, instead of a `FullScan` reading the whole table.

**This file is a stub.** The decisions below were captured
during slice 7's grilling so they don't fade between now and
slice 8. Slice 8 still needs its own grilling pass before
implementation: cursor seek mechanics, catalog/PK lookup
plumbing, encoding helpers, sub-step breakdown, verification.

## Context

The original `00-initial-plan.md` had primary-key range scans as
slice 6. Two detour slices have since been inserted: slice 6
(streaming CPS executor) and slice 7 (expression language).
Slice 7 was forced because PK range recognition needs ordering
comparisons (`<`, `<=`, `>`, `>=`) and `and`-conjunctions in
the predicate language, neither of which existed before.

With slice 7 in place, the predicate language can express the
patterns we want to recognise; slice 8 is now solely about the
physical operator, the storage primitive, and the
logical→physical pattern matching in `Translate`.

## Decisions already taken (from slice 7 grilling)

### Scope of recognised predicates

Equality + the four bounded comparisons + conjunctions that
combine bounds:

- `pk = K` (point lookup; closed range `[K, K]`).
- `pk < K`, `pk <= K`, `pk > K`, `pk >= K` (single bound).
- `pk OP1 K1 and pk OP2 K2` (two bounds, possibly conflicting).
- `pk OP K and <other predicate>` — PK parts recognised, the
  rest is residual.

**Out of scope: disjunctions** (`pk = 1 or pk = 5`). A union of
range scans is a different operator with different storage
mechanics; defer.

### Residual predicate goes in a `Filter` above `IndexScan`

`Translate` partitions the conjunction tree:

- Conjuncts that constrain the PK get folded into `IndexScan`'s
  bounds.
- Conjuncts that don't get rebuilt into a single residual
  expression and emitted as `Filter { input = IndexScan ...;
  predicate = residual }`.
- If every conjunct is PK-handled, no `Filter` wraps the scan.

Rejected alternatives:

- **Leave the original predicate intact as a Filter, alongside
  the IndexScan bounds.** Wastes work re-evaluating bounds the
  storage already enforced.
- **Carry the residual inside `IndexScan` itself.** Couples
  index scanning to predicate evaluation; gives the operator
  two concerns.

Translate's job to do the split. The logic is small and
localised, and the same split will be reused when secondary
indexes arrive.

### PK type and arity scope

Single-column `int64` PKs only. Matches existing fixtures and
existing key encoding. Other PK types arrive alongside indexes
on other columns in a later slice; composite PKs need composite
key encoding and prefix-matching predicate analysis, both
deferred.

### `IndexScan` operator shape

```ocaml
type bound = { value : int64; inclusive : bool }
type range = { lower : bound option; upper : bound option }

| IndexScan of { table : string; range : range }
```

Notes:

- Equality folds in: `pk = K` becomes
  `lower = Some { K; true }; upper = Some { K; true }`. No
  separate `Equal` constructor on the operator.
- Inclusive/exclusive carried explicitly. Avoids normalising
  `<` to `<=` by subtracting 1, which doesn't generalise to
  non-numeric kinds and has `int64` overflow edge cases.
- Field type is `int64`, not `Value.t`. Matches the slice's
  PK-type scope; widens to `Value.t` (one-line change) when
  other key kinds arrive.
- `lower = None, upper = None` is degenerate (equivalent to
  `FullScan`); Translate shouldn't emit it, but semantics are
  still correct if it does.
- Contradictions like `pk >= 6 and pk <= 5` yield empty bounds;
  the storage primitive returns zero rows when `lower > upper`.
  No constant folding in `Translate` required.
- `bound` and `range` live inline in `lib/physical.ml`
  alongside `IndexScan`. Promote to their own module only if
  something else needs them.

## Still to grill

- Storage primitive for ranged cursor iteration — shape of
  `Storage.with_range_iter_seq` (or similar), seek semantics,
  upper-bound short-circuit.
- Catalog plumbing in `Translate` — `Translate` currently doesn't
  take a catalog handle; PK detection needs one.
- Encoding helper for "encode an `int64` value as a key,
  decremented/incremented for an exclusive bound, if we ever go
  that route" — or, more likely, encode the value as-is and let
  the storage layer handle inclusivity at the cursor level.
- Predicate-partitioning algorithm — walk the conjunction tree,
  classify each conjunct, rebuild the residual. Confirm shape
  against `Expression.t` after slice 7's restructure.
- Sub-step breakdown and ordering.
- Verification queries for the REPL smoke.

## Out of scope (preliminary list)

- Disjunctions of PK ranges.
- Secondary indexes.
- Composite PKs.
- Non-`int64` PK kinds.
- Predicate pushdown that crosses operator boundaries
  (slice-5-era topic).
