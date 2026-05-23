# 19 — Slice 19: Collapse mutations into the pipeline universe

Prep slice for the [type-system work](../type-system.md). No new
user-visible features; reshapes the pipeline so every operator
produces a relation, removing the today fork between queries and
mutations.

## Goal

Today the AST/IR/Eval has two parallel universes: queries (return a
relation) and mutations (return a write-result status). The REPL
dispatches on the plan arm, and `Eval` has two entry points (`eval`,
`eval_mutation`).

After this slice there is one universe. `Insert` is a regular
pipeline operator that returns a one-row relation describing what
happened — for now, `(insert_count: int64) { (insert_count = N) }`.
The REPL has one print path; `Logical.classify` becomes a tree walk
that asks each operator whether it needs write access.

## Scope

- Remove `Ast.mutation`, `Logical.mutation`, `Physical.mutation`. Fold
  `Insert` into `Ast.t` / `Logical.t` / `Physical.t` as a regular
  pipeline operator.
- `Insert`'s evaluator returns a one-row `Relation.t` with kind
  `(insert_count: int64)`. Eval merges into one entry point.
- `Logical.classify` becomes a recursive walk: each operator declares
  its required transaction access; the plan's access is the max across
  the tree. The REPL still chooses read vs write transaction up
  front based on the result.
- REPL's `print_query_result` / `print_mutation_status` collapse into
  one printer. The `inserted N rows` status line goes away; an insert
  prints a one-row table like any other relation. Golden tests for
  this output change.
- `Ast.program` simplifies to `Pipeline of t | Ddl of ...` (no inner
  `plan` wrapper).

## Out of scope

- Anything to do with `Core.Term`, the `type` operator, or non-relation
  outputs. This slice still has every pipeline producing a `_
  Relation.t`. `Term` lands in [slice 20](20-slice-20-term-and-type-operator.md).
- DDL retirement. `:`-sigil DDL still works after this slice; the
  `lib/ddl/` library is untouched.

## Key design decisions made during planning

- **Insert's result shape is a one-row relation.** Future RETURNING-
  style streams replace the `insert_count` row when the system grows
  to support them; the shape change is a later slice.
- **No structural "sinks terminate pipelines" guarantee.** Today
  `Insert`'s `source : t` field structurally prevents nested or
  trailing mutations. After the collapse, `... | insert into a | insert
  into b` is grammatically valid and runs the first insert, then tries
  to insert the resulting row into `b` (which fails at row-shape check
  if the shapes don't match). The structural guarantee disappears;
  runtime row-shape errors catch the obvious misuses.
- **Transaction classification is a tree walk, not a plan-arm pattern
  match.** Each operator answers `required_access : [`Read | `Write]`.
  REPL still chooses one transaction up front.

## Notes for follow-on slices

- Slice 20 introduces `Core.Term` and routes `Insert`'s output through
  it (as `Term.Relation_value`). The collapse done here makes that
  one boundary instead of two.
- The `(insert_count = N)` result is provisional. When [slice 22](22-slice-22-create-and-drop-table.md)
  adds `create_table` and `drop_table`, those operators return their
  own result-row shapes (e.g. `(created: string) { (created = "users")
  }`). Consider whether a uniform shape across sinks is worth
  designing then.

## Steps

Three steps. The first is prep with no behaviour change; the second
ships the user-visible result-shape change for Insert; the third is
the pure structural collapse.

### Step 1 — `Logical.required_access` tree walk (prep)

Today `Logical.classify : plan -> [`Read | `Write]` is `Query → Read |
Mutation → Write`. Introduce an internal recursive walker
`Logical.required_access : t -> [`Read | `Write]`. Every existing
operator declares `Read`. `Logical.classify`'s `Query` arm now calls
the walker; the `Mutation` arm stays `Write`.

Pure refactor — public behaviour unchanged, all existing tests pass.
When `Insert` moves into `t` in step 3, the walker is where its
`Write` declaration lands.

*Tests:*

- New unit tests on `required_access` for representative trees:
  `Scan` is `Read`; `Restrict { input = Scan; ...}` is `Read`;
  `CrossProduct { Scan; Scan }` is `Read`. Boring but pins the
  walker's shape so step 3 can confidently add the `Write` case.
- Existing classify tests stay green unchanged.

### Step 2 — Insert returns a one-row relation; drop the status line

`Eval.eval_mutation`'s continuation changes from `int -> 'a` to
`Relation.t -> 'a`. Insert's evaluator builds a one-row `Relation.t`
with kind `(insert_count: int64)` and value `(insert_count = N)`.
REPL's `print_mutation_result` calls `Relation.print` on the result
— no more status-line rendering. `format_mutation_status` deletes.

After this step `eval` and `eval_mutation` have matching continuation
signatures, which lines up the merge in step 3. User-visible change:
`insert into …` now prints a one-column, one-row table instead of
`inserted N rows`.

*Tests:* TDD as per project convention.

- Failing unit test on `Eval.eval_mutation`: inserting a 3-row source
  returns a `Relation.t` with kind `(insert_count: int64)` and a
  single row whose value is `3`.
- Make it pass.
- REPL integration tests for `insert into ...` update from
  `inserted N rows` to the one-row table render.

### Step 3 — The structural collapse

The atomic shape change. All in one commit because the layers can't
be partially migrated and still compile.

- `Ast.mutation`, `Ast.plan`, `Logical.mutation`, `Logical.plan`,
  `Physical.mutation`, `Physical.plan` deleted.
- `Insert of { table : string; source : t }` joins `Ast.t` /
  `Logical.t` / `Physical.t` as a regular constructor.
- `Ast.program` simplifies to `Pipeline of t | Ddl of ...` — no
  inner `plan` wrapper.
- `Lower.lower`'s signature changes from `Ast.plan -> Logical.plan`
  to `Ast.t -> Logical.t`. The `lower_mutation` helper folds back
  into `lower_relation` (renamed to just `lower`). Same for
  `Translate.translate`.
- `Logical.classify` renamed to `Logical.required_access`; the
  walker from step 1 grows its `Insert` case returning `Write`.
  REPL's call site updates. (Don't keep `classify` as a wrapper —
  arm-classification no longer makes sense post-collapse and the
  new name is the honest one.)
- `Logical.format_plan` and `Physical.format_plan` deleted; their
  callers use `format`. `format` learns to render `Insert` (the
  existing `format_plan`'s `Mutation` rendering moves into `format`).
- `Eval.eval_mutation` deleted; `Eval.eval` handles `Physical.Insert`
  as a regular case (the existing `evaluate_insert` logic now lives
  inside `eval`). The continuation signature already matches from
  step 2.
- REPL's two print paths (`print_query_result`,
  `print_mutation_result`) merge into one. Both already call
  `Relation.print` on the result after step 2; merging is mostly
  deleting the dispatch.

No user-visible behaviour change in this step — the Insert table
render already shipped in step 2.

*Tests:* substantial churn but mostly mechanical.

- Round-trip tests for AST/Logical/Physical formatting update to the
  new constructor placement (constructors that lived under `Mutation
  (Insert ...)` now live under `Insert ...` at the top of `t`).
- `Lower.lower` test for Insert updates to the new shape.
- `Translate.translate` test for Insert updates to the new shape.
- `Eval.eval` gains a test case for Insert (was only in
  `eval_mutation` before); `eval_mutation` tests delete.
- `Logical.required_access` test grows an Insert case returning
  `Write`.
- REPL integration tests for `insert into ...` stay green — the
  output already changed in step 2.
- DDL round-trip tests untouched.

## Open questions for implementation

- **Step 2's continuation type change.** The signature change in
  `eval_mutation` is observable to callers (the REPL today, possibly
  tests too). If the change ripples wider than expected, consider an
  internal helper while keeping the old continuation shape, and do
  the rename in step 3. Probably not an issue given how localised
  `eval_mutation` is, but worth checking before the edit.
