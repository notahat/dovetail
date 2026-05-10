# 05 — Slice 5: Inner join (`Join`)

The fifth vertical slice. End-state: typing
`users | join orders on users.id = orders.user_id` at the REPL yields
the six matched (user, order) pairs, executing as
`Physical.NestedLoopJoin` rather than `Filter(CrossProduct(...))`.

## Context

Slice 4 shipped cross product, qualified column references, and
column=column predicates. Today, the user can already write
`users | cross orders | restrict users.id = orders.user_id` and get
the right answer — slice 5 doesn't add new query *capability*, it
adds:

1. A dedicated `join ... on ...` surface syntax that's idiomatic for
   the relational algebra most readers expect.
2. A new physical operator (`NestedLoopJoin`) that fuses cross product
   with its filter predicate into one node, matching how real
   engines describe joins in their plans.
3. The project's first **logical-to-physical rewrite rule**: a
   pattern-match in `Translate` that recognises
   `Restrict(CrossProduct(L, R), pred)` and emits `NestedLoopJoin(L,
   R, pred)`. This is the beachhead for an actual query optimiser
   (deferred per `00-initial-plan.md`); slice 5 ships exactly one
   rewrite rule.

The *runtime* speedup over cross+filter is negligible at this point
(see *Why bother* below). Slice 5's purpose is structural: the
operator and the rewrite are the place where indexed nested-loop
(slice 6/7), hash join (later), and predicate pushdown will hang.

## Goal

```
> users | join orders on users.id = orders.user_id
| users.id | users.name | ... | orders.id | orders.user_id | ... |
... 6 rows: matched (user, order) pairs ...

> users | cross orders | restrict users.id = orders.user_id
... same 6 rows; same physical plan (NestedLoopJoin) under the hood ...
```

Everything from earlier slices keeps working.

## Slice-5 architectural decisions

### Logical IR is decomposed; Physical IR is fused

The original plan in `00-initial-plan.md` contemplated
`Logical.Join`. We deliberately reject it for now:

- **Logical IR stays as it is.** No `Logical.Join`. The logical
  representation of `users | join orders on P` is
  `Restrict(CrossProduct(left, right), P)` — exactly the shape the
  user could already write by hand.
- **Physical IR gains `NestedLoopJoin`.** That's where the
  algorithmic choice lives, alongside the future `IndexScan`-driven
  indexed nested-loop, future `HashJoin`, etc.
- **Translate carries the rewrite.** The pattern-match
  `Restrict(CrossProduct(L, R), pred) → NestedLoopJoin(L, R, pred)`
  is the bridge.

This trades a small amount of cleverness in `Translate` for two
benefits: the logical layer stays minimal, and there is exactly one
logical shape for "inner join" regardless of whether the user wrote
`cross | restrict` or `join ... on`.

### Why bother if the runtime is the same as cross+filter?

Honest answer: per-pair work is identical between
`Filter(CrossProduct(...))` and `NestedLoopJoin`. The fusion saves
one layer of `Seq.t` plumbing — measurable but small. The reasons to
introduce the node *now* are structural:

1. Slice 6/7 will replace the inner side of `NestedLoopJoin` with an
   index probe (indexed nested-loop). That's where order-of-magnitude
   wins live, and it needs the node to hang on.
2. Future hash/merge joins are siblings of `NestedLoopJoin`; the IR
   shape becomes hospitable to them.
3. `Translate` learning to do *one* rewrite rule is the educational
   point of slice 5 — the pattern is what every later optimiser rule
   will follow.

### Naive rewrite is fine

The rewrite fires on *any* `Restrict(CrossProduct(L, R), pred)`,
regardless of which inputs the predicate references. So
`users | cross orders | restrict users.age > 21` becomes
`NestedLoopJoin(users, orders, users.age > 21)` — semantically
correct, but a poor plan: the right thing is to push the filter onto
`users` before the cross. **That's predicate pushdown, deferred.**
Accepting the sub-optimal plan keeps the rewrite rule trivially
correct and the slice scoped.

### Surface syntax

`users | join orders on <predicate>`. Two new keywords (`join`,
`on`); the right-hand side is a relation name (slice-2 grammar; no
sub-pipelines). Predicate sublanguage unchanged from slice 4 — any
predicate is allowed.

`using <columns>` is **not** in scope; it's schema-altering (one
joined column instead of two) and a separable feature.

### Self-joins are out of scope

`users | join users on users.id = users.id` requires aliasing
(`users as u | join users as v on u.id = v.id`) — slice 4's
qualifier-based resolution would error with "ambiguous column
reference" on every column. Aliasing/`rename` is its own future
slice. The slice-5 plan documents this; no validation code is added.

### IR shapes

```ocaml
(* Ast (new) *)
| Join of { left : t; right : t; predicate : Predicate.t }

(* Logical (unchanged) *)

(* Physical (new) *)
| NestedLoopJoin of { left : t; right : t; predicate : Predicate.t }
```

`predicate : Predicate.t` for internal consistency with `Restrict
{ predicate }`.

### Lower

```ocaml
| Join { left; right; predicate } ->
    Restrict
      { input = CrossProduct { left = lower left; right = lower right }
      ; predicate
      }
```

Pure desugaring — Lower is the only place that sees `Ast.Join`.

### Translate

Pattern-match the more-specific case before the general `Restrict`:

```ocaml
| Restrict
    { input = CrossProduct { left; right }; predicate } ->
    NestedLoopJoin
      { left = translate left; right = translate right; predicate }
| Restrict { input; predicate } -> ...existing...
| CrossProduct { left; right } -> ...existing...
```

Order matters; OCaml's match is first-match.

### Eval implementation

Same shape as `CrossProduct`'s evaluator (slice 4), with the
predicate fused into the inner loop:

```ocaml
| NestedLoopJoin { left; right; predicate } ->
    let left_relation = eval environment transaction left in
    let right_relation = eval environment transaction right in
    let combined_schema =
      { fields = left_relation.schema.fields @ right_relation.schema.fields
      ; primary_key = []
      }
    in
    let evaluate_predicate = Predicate.resolve combined_schema predicate in
    let right_tuples = List.of_seq right_relation.tuples in
    let combined_tuples =
      Seq.flat_map
        (fun left_tuple ->
          List.to_seq right_tuples
          |> Seq.filter_map (fun right_tuple ->
                 let combined = Array.append left_tuple right_tuple in
                 if evaluate_predicate combined then Some combined else None))
        left_relation.tuples
    in
    { schema = combined_schema; tuples = combined_tuples }
```

Right side materialised once, same rationale as `CrossProduct`.

### Set/Bag preservation

`NestedLoopJoin` preserves the multiplicity tag, like `Filter` and
`CrossProduct`. No duplicates introduced or removed.

## Sub-steps

Three steps. Each is one commit, with tests, leaving the project in a
working state.

### 1. `Physical.NestedLoopJoin` operator and evaluator

`Physical.t` gains the new constructor. `Eval` gains the
corresponding case (sketch above). No translate/lower/parser work
yet — the new operator is reachable only by hand-constructing
`Physical.t` values in OCaml. That's enough to test the evaluator in
isolation.

Files modified:

- `lib/physical.ml` — add `NestedLoopJoin` constructor.
- `lib/eval.ml` — add evaluation case (mirrors `CrossProduct` with
  predicate fused).

Tests: `test_eval.ml` gains a `nested_loop_join` group:

- Hand-construct
  `NestedLoopJoin { left = FullScan {table = "users"}; right = FullScan {table = "orders"}; predicate = users.id = orders.user_id }`
  and assert the six matched rows.
- True predicate (degenerate): produces the full 30-row cross.
- False predicate: produces zero rows.
- Schema check: combined schema preserves both inputs' qualifiers.

End state: `dune test` green; the operator works when constructed
directly, but isn't yet user-reachable.

### 2. `Translate` rewrite rule

`Translate` gains the more-specific `Restrict` over `CrossProduct`
case ahead of the existing general `Restrict` case. Existing
behaviour for stand-alone `Restrict` and stand-alone `CrossProduct`
is unchanged.

Files modified:

- `lib/translate.ml` — add the new pattern as the first match arm
  for `Restrict`.

Tests: `test_translate.ml` gains a group asserting the rewrite:

- `Restrict(CrossProduct(Scan "users", Scan "orders"), pred)` →
  `NestedLoopJoin(FullScan "users", FullScan "orders", pred)` —
  pattern-match on the result.
- `Restrict(Scan "users", pred)` (no cross product) → still
  `Filter(FullScan "users", pred)` — the rewrite must not fire here.
- `CrossProduct(Scan "users", Scan "orders")` (no restrict) → still
  `CrossProduct(...)` — likewise.

End state: hand-written `users | cross orders | restrict P` queries
already produce `NestedLoopJoin` plans, observable via the existing
end-to-end paths. The slice-4 cross-product tests still pass (their
end-state is plan-shape-agnostic — they assert tuples).

### 3. `Ast.Join`, `Lower`, parser, end-to-end

The user-visible step.

Files modified:

- `lib/ast.ml` — add `Join` constructor.
- `lib/lower.ml` — desugar `Ast.Join` to
  `Logical.Restrict(Logical.CrossProduct(...), predicate)`.
- `lib/parser.ml` — add `join_step` reading
  `keyword "join" *> identifier *> keyword "on" *> predicate`. Two
  new keywords: `join`, `on`. Use the `keyword` helper so a relation
  called `joinery` doesn't trip it. Add `join_step` to the pipeline
  alternation alongside `restrict_step`, `project_step`,
  `cross_step`.
- `lib/parser.mli` — public-API doc updates if needed.

Tests:

- `test_parser.ml`: parses `users | join orders on users.id = orders.user_id`;
  rejects `join` with no relation; rejects `join orders` with no `on`;
  rejects `join orders on` with no predicate; doesn't trigger on
  `joinery` or `oncology` as identifiers.
- `test_lower.ml`: `Ast.Join` lowers to
  `Logical.Restrict(Logical.CrossProduct(...), predicate)`.
- `test_eval.ml` and/or `test_dovetail.ml` (integration): run
  `users | join orders on users.id = orders.user_id` end-to-end and
  assert the six expected rows. Output-only — the rewrite is already
  pinned by step 2's translate tests.

Manual smoke after this step: open the binary, run the demo from
*Goal*, confirm both the `join` form and the `cross | restrict` form
return identical results. Update `README.md`'s layer-table rows to
mention `Join` (Ast row only) and `NestedLoopJoin` (Physical row).

End state: the demo from *Goal* works end-to-end via the REPL.

## Out of scope (deferred, intentionally)

- `using <columns>` — schema-altering equi-join sugar.
- Self-joins / aliasing / `rename` — blocked on
  `users | join users on ...` producing fully ambiguous columns.
- `Logical.Join` as a first-class node — collapsed into
  `Restrict(CrossProduct(...))` for now; revisit when the optimiser
  arrives or when we need richer join structure (outer joins, etc.).
- Predicate pushdown — `users | cross orders | restrict users.age > 21`
  produces a sub-optimal `NestedLoopJoin` plan; correct, but a future
  rewrite rule's job to fix.
- Equi-join detection / hash join / merge join — physical-layer
  futures; their hooks are in place via the new node and translate
  rewrite.
- Indexed nested-loop — slice 6/7. Will replace the inner side of
  `NestedLoopJoin` with an index probe.

## Verification

After step 3:

- `opam exec -- dune build @fmt --auto-promote` clean.
- `opam exec -- dune build` clean.
- `opam exec -- dune test` green; new tests in
  `test_eval.ml`, `test_translate.ml`, `test_parser.ml`,
  `test_lower.ml`, plus an end-to-end integration test.
- Manual REPL: open the binary, type:
  - `users | join orders on users.id = orders.user_id` — six rows.
  - `users | cross orders | restrict users.id = orders.user_id` —
    same six rows.

  A degenerate `on true` smoke would be nice, but the slice-2
  predicate grammar is comparison-only, so a bare boolean isn't a
  legal predicate. Lifting that restriction is a sublanguage
  extension and out of scope here.

## Open questions

Captured here as they come up; resolved at end of slice.

- (none currently)
