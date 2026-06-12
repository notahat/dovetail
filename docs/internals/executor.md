# Executor

How `lib/execution/` runs a physical plan, and why it has the shape
it has. The load-bearing facts: the executor is in
continuation-passing style because LMDB scopes cursors to a callback;
rows stream lazily from live cursors at O(1) memory per cursor for
linear pipelines; joins materialise their right input; and each
operator lives in its own `eval_*` module, with `Eval.eval` as a thin
dispatcher.

## Why CPS: cursor lifetime

The `lmdb` OCaml package only exposes cursors as scope-bound
resources — `Lmdb.Cursor.go (fun cursor -> ...)` — so a cursor cannot
be opened and held as a value. A streaming relation's `value`
sequence pulls rows from a live cursor on demand, which means
whatever consumes the relation must run *inside* the cursor's scope.

Continuation-passing style is how those two scopes compose.
[`Eval.eval`](../../lib/execution/eval.mli) takes a consumer
continuation and invokes it with the result at the deepest point of
whatever cursor scopes the plan opened; when the continuation
returns, the cursors are torn down. The relation's lifetime is
structurally bounded by the call to `eval` — it cannot escape,
because `eval` never returns it.

The CPS boundary stops at `Eval`. The REPL and tests already consume
results inside `Storage.Engine.with_read_transaction`'s callback, so
above the executor the shape is just one more callback layer.

### Ruled-out alternatives

Two seemingly simpler paths were investigated and rejected when the
executor went streaming; recorded here so the investigation isn't
redone.

- **`Lmdb.Map.to_dispenser`** looks like a streaming iterator but
  internally opens its own read transaction. LMDB rejects both a
  read transaction nested inside another (`MDB_BAD_TXN`-class) and a
  second top-level read transaction on the same thread
  (`MDB_BAD_RSLOT`). Both failure modes were confirmed empirically.
- **Direct cursor management via `Lmdb_bindings.cursor_open`** needs
  a `dbi` handle, and `Lmdb.Map.t` is abstract with no accessor that
  exposes one. The only way past `Cursor.go`'s scoping is `Obj.magic`
  against the package's private record layout — rejected.

## The streaming primitives

[`Storage.Engine.with_iter_seq`](../../lib/storage/engine.mli) is
the scope-bound primitive under everything: it opens a cursor and
hands its callback a one-shot `Seq.t` that pulls key-value pairs from
the live cursor in key order. The sequence is valid only inside the
callback, and partial consumption is safe — remaining state is torn
down when the callback returns.

[`Table_access.build_table_relation`](../../lib/execution/table_access.mli)
layers the catalog on top: it resolves a table name to its kind and
storage handle, opens the cursor, and hands its callback a
`Relation.t` whose `value` sequence decodes rows straight off the
cursor.

## How the `eval_*` modules compose

Each physical operator has its own module — `Eval_full_scan`,
`Eval_filter`, `Eval_cross_product`, and so on —
and [`Eval.eval`](../../lib/execution/eval.ml) is a thin dispatcher:
one `match` over `Physical.t`, one delegation per arm.

Operators with sub-plans need to recurse, but they cannot call
`Eval.eval` directly — `Eval` depends on the operator modules, so the
reverse dependency would be a module cycle. Instead `Eval` passes
itself in as a parameter, typed by
[`Eval_recurse`](../../lib/execution/eval_recurse.mli) (a
types-only module that depends on neither side). There are two
recursor forms:

- **`eval_relation`** — evaluates a sub-plan and hands the consumer
  its `Relation.t` directly, asserting the term is a
  `Relation_value`. Most operators take this form; the assertion is
  safe because relational sub-plans only ever produce relation
  values (kinds arise only from `Type_op`, which sits at the
  pipeline root).
- **`eval`** — the full-`Term.t` form, for the operators that branch
  on non-relation arms (`Unqualify` accepts rows, `Tables` accepts a
  catalog).

Inside an operator, nested scopes are sequenced with a local CPS
bind:

```ocaml
let ( let* ) action continue = action continue
```

`let* x = action in body` desugars to `action (fun x -> body)` — the
operator is the identity and exists purely to flatten what would
otherwise be one lambda-nesting level per scope. The joins, which
open two input scopes before their body runs, are where it earns its
keep.

## Right-side materialisation in joins

`CrossProduct` and `NestedLoopJoin` loop over their left input and
re-iterate the right input once per left row. A one-shot streaming
sequence cannot be replayed, so both operators materialise the right
side with `List.of_seq` before looping
(see [`eval_cross_product.ml`](../../lib/execution/eval_cross_product.ml)).
Streaming both sides of a join needs a different algorithm — hash
join, merge join — which is future work; until then memory is
O(|right|) for these operators and O(1) per cursor everywhere else.

`IndexedNestedLoopJoin` sidesteps the issue rather than solving it:
it never builds the inner side as a relation at all, instead probing
the inner table's storage by key once per outer row. The rewrite
rules in [`Translate`](../../lib/plan/translate.mli) decide when it
applies.

## Errors and write atomicity

Operators raise `Failure` for user-reachable problems and resolve
what they can eagerly — predicate resolution, for instance, runs
before any rows are pulled — so most failures surface before the
consumer's continuation is invoked. A raise inside an `Insert`
propagates through `Storage.Engine.with_write_transaction`'s
exception path, aborting the transaction, so multi-row inserts
commit all-or-nothing.
