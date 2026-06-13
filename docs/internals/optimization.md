# Optimization

All of Dovetail's query optimisation lives in
[`Translate`](../../lib/plan/translate.mli), as rewrite rules applied
while lowering `Logical.t` to `Physical.t`. There are two rules
today — the primary-key point lookup and the indexed nested-loop
join — and they share one piece of machinery: conjunct partitioning.
This doc records the rules' trigger shapes, the deliberate limits on
each, and the invariants the shapes were chosen to protect.

## Shared machinery: conjunct partitioning

Both rewrites face the same problem: the conjunct they can use is
usually buried in a larger predicate (`id = 5 and active`), and how
the user grouped their `and`s shouldn't matter. The machinery in
[`translate.ml`](../../lib/plan/translate.ml):

- `flatten_conjunction` walks the `And` tree into a flat conjunct
  list — `(a and b) and c` and `a and (b and c)` both flatten to
  `[a; b; c]`.
- A partition walk (`partition_primary_key_conjunct`,
  `partition_join_pk_conjunct` — siblings with the same structure
  and different per-conjunct matchers) takes the **first** conjunct
  that matches and returns it along with the residual conjuncts,
  order preserved.
- The matched conjunct folds into the new operator's key; the
  residual rebuilds into a left-associative `And` via
  `build_conjunction` and wraps the operator in a `Filter`. No
  residual means a bare operator, no `Filter`.

When more than one conjunct matches (`id = 5 and id = 7`), the
first folds and the rest land in the residual — still correct,
because the residual filter evaluates the other equality against
the fetched row and yields nothing. There is no constant folding in
`Translate`.

### The syntactic-equivalence invariant

Partitioning — rather than only recognising predicates that are
*exactly* a PK equality — is what guarantees that syntactically
equivalent queries get the same plan:

```
users | join orders on users.id = orders.user_id and orders.amount >= 5
users | join orders on users.id = orders.user_id | restrict orders.amount >= 5
```

Both produce the same `Physical.t`. Without partitioning, adding
`and other_condition` to the `on`-clause would drop the query back
to a plain `NestedLoopJoin` while moving the same conjunct into a
trailing `| restrict` would keep the optimisation — a large
performance change driven by a stylistic choice. The invariant is
asserted directly at the `Translate` layer in the test suite.

## Point lookup: `IndexLookup`

**Trigger shape:** `Restrict { input = Scan { table }; predicate }`
where `table` has a single-column `Int64` primary key and some
conjunct of `predicate` is an equality between that column and an
`Int64` literal.

The recognition rules, all of which must hold for a conjunct to
fold:

- **Column form.** Bare `id` or qualified `<table>.id` where
  `<table>` is the scanned table; any other qualifier is a
  non-match.
- **Direction.** `id = 5` and `5 = id` both match — `Equal` is
  commutative.
- **Literal kind.** Only an `Int64` literal folds. A
  type-mismatched literal (`id = "five"`) stays in the residual for
  `Typecheck` to reject.
- **Primary-key preconditions.** The table's kind must declare a
  single-column `Int64` primary key. Composite, non-`Int64`, and
  missing primary keys all skip the rewrite.

Anything that doesn't fold stays on the `Filter(FullScan)` path.

The operator carries `key : int64` — a concrete value, not an
`Expression.t`. Its only job is "fetch one row by literal primary
key"; keeping the key concrete resists overgeneralising the
operator, and the field widens to `Scalar.value` when other key
kinds arrive.

### The catalog callback

Recognising a primary key means looking up the scanned table's
kind, so `translate` takes
`~catalog:(string -> Relation.kind option)`. A closure rather than
the storage handles, because the dependency is "look up a kind by
name", not "talk to the storage layer" — the REPL builds the
closure over `Storage.Catalog.get` at the call site, and tests pass
a function over a list. A callback returning `None` skips the
rewrite; the missing-table error surfaces downstream as usual.

## Indexed join: `IndexedNestedLoopJoin`

**Trigger shape:** `Restrict { input = CrossProduct { left; right };
predicate }` — the same shape the `NestedLoopJoin` rewrite already
fires on. The indexed rewrite is tried first and falls through to
`NestedLoopJoin` when it doesn't match.

A side of the cross product is an **inner candidate** when it is a
bare `Scan` of a table with a single-column `Int64` primary key
(any wrapping `Project` or `Restrict` disqualifies it — matching is
by qualifier name, not reachability analysis). A conjunct matches a
candidate when it is a column-on-column equality where *exactly
one* side is the candidate's primary-key column — "exactly one"
rules out self-join equalities like `users.id = users.id`. The
other column becomes the probe key.

The operator's shape encodes three deliberate choices:

- **`inner_table` is a table name, not a sub-plan.** A sub-plan
  cannot be probed by key; evaluation bottoms out at "open this
  table's storage map". When secondary indexes arrive they will
  want a different operator (probe a specific index), not extra
  generality in this one.
- **`outer_key_column` is a column reference, not an
  `Expression.t`.** The only meaningful per-row key derivation is
  "the value at this column"; a column reference says exactly that.
  Its kind must be `Int64` (the inner's PK kind), checked at eval
  time when the reference resolves against the outer's row kind.
- **`inner_position` records where the inner sat in the logical
  `CrossProduct`.** Eval consults it when assembling output: the
  inner's fields go on the left or right to match the user's
  logical ordering. Without the tag, picking the syntactic right
  side as the streamed outer would silently reorder the output's
  columns. The principle it protects: optimisations are observable
  in the plan and in performance, never in the result's shape.

Two layered tiebreakers when more than one match qualifies: across
conjuncts, left-to-right order wins (first match folds); within a
single conjunct that names *both* candidates' primary keys
(`a.id = b.id` where both tables qualify), the right side becomes
the inner so the streamed outer preserves the cross product's
column order. The tiebreakers are structural, not cost-based —
choosing the smaller side as outer via statistics is a future
optimiser concern.

See [executor.md](executor.md) for what the operator buys at run
time: the inner side is never materialised at all, replacing
`NestedLoopJoin`'s O(|left| × |right|) pair scan with one
O(log |inner|) probe per outer row.

## Deliberately deferred

Recorded so the absence reads as a decision, not an oversight:

- Range scans on the primary key (`<`, `<=`, bounds pairs).
- Disjunctions of lookups (`id = 1 or id = 2`) — a union of point
  lookups is a different operator.
- Predicate pushdown. The `NestedLoopJoin` rewrite fires on shape
  alone, so a one-sided conjunct is not pushed down to its input,
  and a PK equality buried under a `Project` or a prior join does
  not light up either rewrite.
- Non-`Int64` and composite primary keys, secondary indexes, hash
  and merge joins.
