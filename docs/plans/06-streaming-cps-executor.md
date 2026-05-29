# Slice 6: Streaming CPS executor

Not a query-language slice. End-state: `Eval` becomes a streaming
continuation-passing executor, where the storage cursor's lifetime
extends through the consumer's iteration of the result. User-visible
behaviour is unchanged; the internal shape changes to enable true
lazy iteration.

## Context

Today, every `Storage.iter_seq` call opens a cursor inside
`Lmdb.Cursor.go`, drains it eagerly into a list, and returns the list
wrapped as a `Seq.t`. The sequence *looks* lazy but isn't — by the
time it reaches the caller, every row is already in memory. Each
`FullScan` therefore allocates O(table) before any operator above it
sees a tuple.

For the slice 1–5 fixtures this is fine. Once we run queries against
real tables, it isn't. Streaming requires the cursor to be alive while
the consumer iterates.

## Goal

```ocaml
(* Today's eager shape: *)
let relation = Eval.eval env txn plan in
List.of_seq relation.tuples  (* every row already in memory *)

(* Target shape: *)
Eval.eval env txn plan (fun relation ->
    List.of_seq relation.tuples  (* rows pulled lazily from the cursor *))
```

The consumer's callback runs inside whatever cursor scopes the plan
opens. Memory usage drops to O(1) per cursor for linear pipelines
(`FullScan`/`Filter`/`Project` chains). Joins still buffer their
right input (see *Out of scope*).

## Why CPS

The `lmdb`-ocaml package only exposes cursors as scope-bound resources
(`Lmdb.Cursor.go (fun cursor -> ...)`); we can't open one and keep it as
a value. So the cursor's scope must wrap whatever consumes the
resulting sequence. In our pipeline, the consumer is the caller of
`Eval.eval`. The way to compose those two scopes is
continuation-passing style: `Eval.eval` takes a consumer continuation
and invokes it *inside* the cursor scope, instead of returning a
relation that would outlive the cursor.

### Alternative paths investigated and ruled out

1. **`Lmdb.Map.to_dispenser`** appears to give a streaming iterator,
   but internally opens its own read transaction. LMDB rejects both
   nested read-inside-read (`MDB_BAD_TXN`-class) and a second top-level
   read on the same thread (`MDB_BAD_RSLOT`). Both error modes
   confirmed empirically.

2. **Direct cursor management via `Lmdb_bindings.cursor_open`** would
   require a `dbi` handle. `Lmdb.Map.t` is abstract and the package
   exposes no accessor that returns the underlying `dbi`. The only way
   to bypass `Cursor.go`'s scope is `Obj.magic` against the package's
   private record layout, which we reject.

Neither finding is captured in code; both are documented here so we
don't redo the investigation.

## Architectural decisions

### CPS at the `Eval` boundary, not deeper

`Storage.with_iter_seq` is the new scope-bound primitive. `Eval.eval`
takes a continuation. Operators inside `Eval` nest continuations
internally. Nothing above `Eval` needs to know it's CPS — the REPL and
tests already consume the relation inside `with_read_transaction`'s
callback, so they adopt the new shape with a one-line change each.

### Replace, don't accumulate

The end state has one entry point (`Eval.eval`, CPS-shaped) and one
streaming primitive (`Storage.with_iter_seq`). The current
`Eval.eval` and `Storage.iter_seq` are deleted at the end. During the
conversion both paths exist side by side — the new path is built up
under `Eval.eval_cps`, then renamed to `eval` once everything is
green.

### `let*` deferred to an optional follow-up

The bare CPS form has explicit `fun continuation -> ...` nesting at
every operator. Linear pipelines stay readable; the joins, with two
nested `eval_cps` calls each, are the painful case. A local `let*`
binding operator in `eval.ml` would flatten those into sequential
bindings.

We deliberately defer introducing `let*` until after the conversion is
complete. The joins land first as raw CPS (steps 6, 7) so we can see
the unsoftened shape; step 10 — optional — can then demonstrate the
before/after if we want it.

### Right-side materialisation in joins stays

`CrossProduct` and `NestedLoopJoin` re-iterate their right input,
which a one-shot streaming seq cannot do. The right side continues to
materialise via `List.of_seq`. Streaming both sides of a join needs a
different algorithm (hash join, merge join); that's separate work.

## Out of scope

- Hash join / merge join. The two existing join operators
  (`CrossProduct`, `NestedLoopJoin`) require re-iteration of their
  right input, so the right side continues to materialise even after
  this work.
- Storage-level concurrency or multi-threaded readers. We continue to
  assume one read transaction per query, single thread.
- Effect-handler-based equivalents (OCaml 5 effects). Possible future
  refactor; out of scope here.

## Sub-steps

Nine main steps plus one optional follow-up. Each is one commit, with
tests where appropriate, leaving the project in a working state.
Reviews happen between steps.

### 1. `Storage.with_iter_seq`

Add a scope-bound streaming primitive alongside `iter_seq`:

```ocaml
val with_iter_seq :
  map ->
  [> `Read ] transaction ->
  ((string * string) Seq.t -> 'a) ->
  'a
```

Implementation: `Lmdb.Cursor.go` plus `Seq.unfold` so the seq pulls
pairs from the live cursor on demand. The sequence is one-shot and is
only valid inside the callback. The `.mli` doc comment spells out both
constraints.

Files modified:

- `lib/storage.ml`, `lib/storage.mli` — add `with_iter_seq`.

Tests: `test_storage.ml` gains a `with_iter_seq` group:

- Streams pairs in key order.
- Sequence is one-shot (re-iterating an exhausted seq yields nothing).
- Partial consumption (caller exits the callback before draining)
  doesn't blow up the surrounding transaction.
- Empty map yields an empty seq.

End state: `iter_seq` unchanged; new primitive available but unused.

### 2. `Eval.eval_cps` thin wrapper

Add the CPS entry point:

```ocaml
val eval_cps :
  Storage.environment ->
  [> `Read ] Storage.transaction ->
  Physical.t ->
  ([ `Bag ] Relation.t -> 'a) ->
  'a
```

Initial implementation delegates to `eval`:

```ocaml
let eval_cps env txn plan continue = continue (eval env txn plan)
```

No streaming yet. Identical behaviour to `eval` for every plan shape.

Files modified:

- `lib/eval.ml`, `lib/eval.mli` — add `eval_cps`.

Tests: parity check. A small fixture-driven test that runs the same
plan through `eval` and `eval_cps`, asserts identical schemas and
tuples. Covers `FullScan`, `Filter`, `Project`, `CrossProduct`,
`NestedLoopJoin`. This same parity test stays in the suite through
steps 3–7 as the regression net.

End state: `dune test` green; `eval_cps` exists but every operator
still goes through `eval`.

### 3. `FullScan` streaming

Add `evaluate_full_scan_streaming` using `Storage.with_iter_seq`.
`eval_cps`'s `FullScan` branch calls it directly; other branches fall
through to `continue (eval ...)`.

Files modified:

- `lib/eval.ml` — extract `lookup_table_resources` shared between the
  eager and streaming `FullScan` evaluators, add
  `evaluate_full_scan_streaming`, dispatch in `eval_cps`.

Tests: the parity test from step 2 already covers this — `FullScan`
plans now exercise the streaming path; tuples must match. No new test
needed.

End state: a `FullScan`-only plan via `eval_cps` streams end-to-end.

### 4. `Filter` streaming

Convert the `Filter` branch of `eval_cps` to recurse:

```ocaml
| Filter { input; predicate } ->
    eval_cps env txn input (fun input_relation ->
      let evaluator = Predicate.resolve input_relation.schema predicate in
      continue
        { schema = input_relation.schema
        ; tuples = Seq.filter evaluator input_relation.tuples
        })
```

`Predicate.resolve` still runs eagerly, so type errors surface before
the consumer sees any tuples — same observable behaviour as today.

Files modified:

- `lib/eval.ml` — convert the `Filter` branch.

Tests: parity test covers it.

End state: `Filter(FullScan)` plans stream.

### 5. `Project` streaming

Same shape as `Filter`. Convert the branch in `eval_cps`.

Files modified:

- `lib/eval.ml` — convert the `Project` branch.

Tests: parity test covers it.

### 6. `CrossProduct` streaming

Convert the branch in `eval_cps` as raw nested CPS:

```ocaml
| CrossProduct { left; right } ->
    eval_cps env txn left (fun left_relation ->
      eval_cps env txn right (fun right_relation ->
        let right_tuples = List.of_seq right_relation.tuples in
        let combined_schema = ... in
        let combined_tuples = Seq.flat_map ... in
        continue
          { schema = combined_schema; tuples = combined_tuples }))
```

Right side continues to materialise via `List.of_seq` — documented in
the `eval.ml` comment as a known consequence of the re-iteration
requirement. The cursor scopes nest naturally: outer = left, inner =
right, consumer's continuation runs at the deepest point.

Files modified:

- `lib/eval.ml` — convert the `CrossProduct` branch.

Tests: parity test covers it.

### 7. `NestedLoopJoin` streaming

Same shape as `CrossProduct`. Same caveat on right-side
materialisation.

Files modified:

- `lib/eval.ml` — convert the `NestedLoopJoin` branch.

Tests: parity test covers it.

End state: every operator's `eval_cps` branch is in CPS form. `eval`
is still present and tests still run against it.

### 8. Migrate callers

Switch every caller of `Eval.eval` to `Eval.eval_cps`. Each call site
gains one layer of callback nesting; no other change.

Files modified:

- `lib/repl.ml` — `evaluate_and_print` switches to `eval_cps`. The
  `match ... with | exception Failure -> ...` becomes `try ... with
  Failure -> ...` since the success-arm body now lives inside a
  continuation. (Subtle behaviour change documented in step 8's commit
  message: the `try/with` now catches errors that arise during
  `Relation.print`, not only during `eval`. That's unavoidable in a
  streaming world and is almost certainly the right behaviour anyway.)

- `test/test_eval.ml`, `test/test_dovetail.ml`, anywhere else that
  calls `Eval.eval` — switch to `eval_cps`.

Tests: the parity test from step 2 is removed at the end of this
step. All tests now go through `eval_cps`.

End state: `eval` is unused.

### 9. Remove the eager path

Delete:

- `Eval.eval`, `evaluate_full_scan`, `evaluate_cross_product`,
  `evaluate_nested_loop_join` (the eager originals).
- `Storage.iter_seq` and its tests.

Rename `Eval.eval_cps` to `Eval.eval`. Update `.mli` doc comments
throughout — drop "exploratory" wording, drop comparisons with the old
path. `Storage.with_iter_seq` keeps its name; the `with_` prefix
signals the scope-bound shape and matches the existing convention
(`with_read_transaction`, `with_write_transaction`,
`with_environment`).

Files modified:

- `lib/eval.ml`, `lib/eval.mli` — delete eager evaluators; rename.
- `lib/storage.ml`, `lib/storage.mli` — delete `iter_seq`.
- `test/test_storage.ml` — delete `iter_seq` tests.
- `lib/repl.ml`, `test/test_eval.ml`, etc — update call sites to use
  the renamed `eval`.

Tests: still green.

End state: one streaming entry point, one streaming primitive, no
eager fallback. The conversion is complete.

### 10. Optional: introduce `let*` (readability follow-up)

Once the conversion is complete, evaluate whether a local `let*`
binding operator improves readability — especially in the join
branches. The mechanic is small:

```ocaml
let ( let* ) action continue = action continue
```

`let* x = action in body` desugars to `action (fun x -> body)`. The
operator is the identity; it exists purely for the syntactic
flattening. Refactoring `CrossProduct` and `NestedLoopJoin` would turn
their two-level nested lambdas into two sequential bindings, with the
rest of the body at the outer indentation.

This step is not load-bearing — every operator works correctly without
it. The point is to compare the with-and-without versions side by side
once we can see the full impact, and only adopt `let*` if the
readability win is clearly worth the extra concept.

Files modified:

- `lib/eval.ml` — define `let*`, refactor the converted branches.

Tests: existing tests stay green; no new tests.

## Verification

After each step:

- `opam exec -- dune build @fmt --auto-promote` clean.
- `opam exec -- dune build` clean.
- `opam exec -- dune test` green.

After step 9:

- Manual REPL: open the binary, run a few queries from the existing
  slices' verification steps — `users`, `users | restrict ...`,
  `users | project ...`, `users | cross orders`, `users | join orders
  on ...`. Each should behave identically to before, with no visible
  difference from the user's side.

## Risk and reversal

Steps 1–8 are each independently revertable: the eager path remains
the authoritative implementation until step 9. If a step surfaces
unexpected behaviour, it can be rolled back in isolation.

Step 9 is the point of no return — once `Eval.eval` is deleted, the
old path is gone. Should be the last commit before declaring the
conversion complete, and follow a deliberate review of the whole new
path against the existing test suite.

Step 10 is an optional readability refactor that can be done, or not,
at any later point.

## Open questions

Captured here as they come up; resolved at end of work.

- (none currently)
