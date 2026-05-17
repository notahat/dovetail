# 11 — Slice 11: Insert

The eleventh vertical slice, and the first to write data into
the database under user direction. End-state: a user at the
REPL can type a relation literal piped into an `insert into
<table>` sink, the row is committed to LMDB inside a write
transaction, and the REPL reports the affected-row count. The
plumbing — relation-literal sublanguage, a `Query`/`Mutation`
wrapper at every IR layer, read/write transaction dispatch,
and an `eval_result` variant — lands together so update and
delete (slice 12) can drop in additively.

The README's roadmap entry for slice 11 reads "DML as an
RA-language extension. Statement-level forms for inserting
rows, alongside the existing pipeline syntax. Update and
delete may land here or follow on." This slice narrows that
to **insert only**; the slice is already substantial once the
wrapper and write-transaction machinery are counted, and
update + delete share the upstream-identity validator that
naturally bundles them together.

The design that shapes this slice lives in
[`docs/plans/dml-design.md`](dml-design.md). That document
covers insert, update, and delete coherently so that insert's
surface isn't quietly determined by the cases it doesn't have
to handle. This slice plan implements the insert-shaped
subset of that design. Note that the design doc's "statement
form" framing in the README predates the design itself —
under the design, DML lives in pipeline position, not as a
separate statement stratum.

## Context

Slices 1–10 grew Dovetail's read path: a pipeline RA
language with `restrict`, `project`, `cross`, `join`, an
expression sublanguage for predicates, primary-key point
lookups, and an indexed nested-loop join. Every top-level
input today opens a read transaction, runs through the
parser → AST → Lower → Logical → Translate → Physical → Eval
pipeline, and prints a bordered table.

The storage stack and catalog already support writes — the
fixture uses them to seed `users` and `orders` on first run —
but the query language has had no way to address them. Slice
11 closes that gap with the smallest user-driven mutation
surface that exercises every piece of new machinery the DML
design introduces.

## Goal

End-state artefacts:

1. A new relation-literal sublanguage in the parser:
   `{column: value, column: value, ...}`. Single-row,
   named-pair form only.
2. A new pipeline operator `insert into <table>` that consumes
   the upstream relation and writes its rows to the named
   table.
3. New IR shape at each layer: a `plan = Query of t |
   Mutation of mutation` wrapper at `Logical` and `Physical`;
   a flat AST that the parser admits but Lower rejects when
   a sink appears mid-pipeline.
4. An `eval_result = Query of [`Bag] Relation.t | Mutation of
   { affected_rows : int }` variant returned through the
   existing CPS entry point.
5. A `Logical.classify : plan -> [`Read | `Write]` classifier
   that the REPL uses to pick between `with_read_transaction`
   and `with_write_transaction`.
6. REPL output for mutations: a one-line status `inserted N
   row` / `inserted N rows`, pluralised on `N = 1`.

After slice 11, the canonical worked example is:

```
> {id: 9, user_id: 1, description: "Pretzel", amount: 9} | insert into orders
inserted 1 row
> orders | restrict id = 9
│ orders.id │ orders.user_id │ orders.description │ orders.amount │
├───────────┼────────────────┼────────────────────┼───────────────┤
│         9 │              1 │ Pretzel            │             9 │
```

Every validation case errors usefully at the earliest layer
that can detect it: duplicate column at parse time, schema
mismatch at translate time, primary-key collision at eval
time.

## Slice-11 architectural decisions

### Scope: insert only

Update and delete are deferred to slice 12. They share the
upstream-identity validator and the operator classification
table the design doc describes — splitting update from delete
would be the wrong cut, and bundling all three with insert
makes the slice unwieldy.

Insert alone exercises every piece of new machinery the
design introduces: the relation-literal sublanguage, the
wrapper IR shape, write-transaction dispatch, the
`eval_result` variant, the REPL's affected-row rendering.
Update and delete add the validator and (for update) an
assignments expression sublanguage; both are substantial
additions on top.

Cost: DDL slides from slice 12 to slice 13, and the minimal
SQL frontend from 13 to 14. The README's slice ordering is
firm; the numbering isn't load-bearing.

Rejected alternatives:

- **All three operators in slice 11.** Honest to the design
  doc's "designed together" framing, but the slice gets
  large, and update + delete machinery (the upstream-identity
  validator, the assignments sublanguage) is independent of
  insert.
- **Insert + delete (no update).** Delete adds the validator
  but not the assignments sublanguage — smaller jump than
  "all three". Slightly awkward: leaves update as a stranded
  follow-on whose only new machinery is assignments.

### Relation-literal sublanguage: single-row named-pair form only

The design doc names two literal forms:

```
{id: 7, name: "Pretzel", amount: 9}                       -- single-row
(id, name, amount) { (7, "Pretzel", 9), (8, "Donut", 3) } -- multi-row
```

Slice 11 ships only the first. The REPL is the only consumer
of mutation today; bulk loads aren't a real use case yet
(fixtures handle that, DDL hasn't landed so there are no
user-created tables to bulk-load into). Single-row exercises
every interesting validation case except duplicate primary
keys *across rows of the literal itself*, which the multi-row
form is the only thing that can produce.

The two forms are grammatically independent productions, so
adding the multi-row form later is purely additive.

### Value position: bare literals, no expression IR yet

The design says "the value position is a full expression."
In insert context column references are rejected (no row in
scope), and arithmetic and function calls aren't on the
near-term roadmap. Today "full expression" reduces to
"literal."

This slice parses the value position as a bare `Value.t`
literal: `Int64`, `String`, `Bool`. The existing literal
parser used by `Expression` is reused.

The IR carries the assignments as `(string * Value.t) list`
for slice 11. When the update slice (or later) introduces a
value-expression IR — needed for `{amount: amount + 1}` —
this widens to `(string * Expression.t) list` without
breaking surrounding shape.

### Literal is a first-class `relation_expr`

The literal sits at `relation_expr` in the grammar alongside
bare table names. Typing `{id: 7, name: "x"}` alone in the
REPL parses as a valid pipeline and prints a one-row
relation. This matches the design doc's regime B: the
literal is a self-contained relation expression, and the
language doesn't artificially restrict where relations can
appear.

### `RelationLiteral` schema: bare names, value-inferred kinds, empty PK

A `RelationLiteral` evaluates to a `Relation.t` whose
`Schema.t` is derived directly from the literal's contents:

- **Kinds** are read off the value at each column position:
  `7` → `Int64`, `"Pretzel"` → `String`, `true` → `Bool`.
- **Primary key** is empty. A derived relation has no PK,
  matching the existing convention for `Project` and
  `CrossProduct` output schemas.
- **Qualifier** is `None` for every field. The literal
  carries no name; bare keys go in, bare names come out.
  `Schema.field.qualifier` is already `string option`, and
  `Schema.find_field` already resolves unqualified
  references — so downstream operators (in regime B) can
  reference literal columns bare with no infrastructure
  change.

REPL rendering of a one-row literal therefore prints with
bare column headers, no leading dots and no synthetic
qualifier:

```
> {id: 7, name: "Pretzel", amount: 9}
│ id │ name    │ amount │
├────┼─────────┼────────┤
│  7 │ Pretzel │      9 │
```

Rejected: a synthetic qualifier like `"_"` or `"literal"`.
Visible and artificial; pollutes downstream resolution
without earning anything.

This is also strictly less parser code than a positional
restriction would require — `insert into` consumes a
`relation_expr` like any other pipeline operator.

### AST shape: wrapper, mirroring Logical

The AST grows a top-level wrapper:

```ocaml
type plan      = Query of pipeline | Mutation of mutation
and pipeline   = ...      (* unchanged shape, sans sinks *)
and mutation   = Insert of { source : pipeline; table : string }
```

"Mutation is terminal in a pipeline" is a structural rule —
you cannot syntactically write `users | insert into x |
restrict ...`. Encoding that in the grammar (and the AST
type) is more honest than encoding it in a validator at
Lower.

The grammar:

```
pipeline       := query_pipeline ("|" sink)?
query_pipeline := relation_expr ("|" query_op)*
query_op       := restrict | project | cross | join
sink           := "insert" "into" identifier
```

Lower then becomes a clean case-by-case translation with no
structural check needed — the type system did it.

Rejected: a flat AST where `Insert` is one more `pipeline_op`
constructor alongside `Restrict`, `Project`, etc., with Lower
asserting at runtime that no operators follow it. Simpler
parser, but pushes a syntactic invariant into a semantic
layer where it doesn't belong, and is inconsistent with the
wrapper at Logical (next section).

### IR wrapper at Logical and Physical

The Logical IR grows a top-level wrapper of the same shape:

```ocaml
type plan     = Query of t | Mutation of mutation
and mutation  = Insert of { table : string; source : t }
```

Plus a new source operator `Logical.RelationLiteral { columns;
rows }` so that relation literals are first-class sources of
the algebra, parallel to `Scan`.

`Physical.plan` mirrors this exactly. `Translate.translate`
becomes `Logical.plan -> Physical.plan` (one outer
pattern-match; the inner relation tree translates by the
existing logic).

The wrapper enforces the invariant "mutations do not appear
inside relations" in the type system, removing a class of bug
that would otherwise need a validator. It also lines up
naturally with the `eval_result` variant — every layer's
top-level shape is the same `Query | Mutation` split, with
conversions a uniform pattern-match-and-rebuild.

Note that `Insert`'s `source` field is typed `t`, not `plan`
— the source of a mutation is a relation, not another plan.
That is what enforces "mutations don't nest" inside the
wrapper: a `Mutation _` cannot syntactically appear under
another `Mutation _`, since the only way to reach a
`mutation` is through the outer `plan` wrapper.

When slice 12 adds update and delete, the wrapper machinery
is reused as-is; only the `mutation` constructor list grows.

### Validation: where each check lives

| Check                                            | Layer       | Rationale                                                                 |
| ------------------------------------------------ | ----------- | ------------------------------------------------------------------------- |
| Duplicate column names within a literal          | Parser      | Pure structural property of the literal; no catalog needed.               |
| Qualified column name in a literal key           | Parser      | The literal grammar admits bare identifiers only.                         |
| Literal columns are a permutation of the target  | Translate   | Catalog-driven; Translate already takes `~catalog` and resolves schemas.  |
| Each value's kind matches the target schema      | Translate   | Same as above.                                                            |
| Primary-key collision against existing storage   | Eval (sink) | Cannot be known until the write happens.                                  |

Error messages name the offending columns ("missing columns:
description, amount") and, for kind mismatches and PK
collisions, name the offending value.

Translate is the right home for catalog-driven static checks:
it is already the layer that consults the catalog, and
"literal columns match the target schema" is in the same
family of work as "PK column matches for IndexLookup."

The upstream-identity validator the design doc describes
(for update and delete) is a separate concern with a
different shape — a tree walk classifying each operator. It
lands in slice 12 alongside update and delete; insert needs
none of it.

### Eval: single CPS entry point, `eval_result` variant

`Eval.eval` keeps its existing continuation-passing shape and
the variant lands as its return type:

```ocaml
type eval_result =
  | Query    of [ `Bag ] Relation.t
  | Mutation of { affected_rows : int }

val eval :
  Storage.environment ->
  [> `Read ] Storage.transaction ->
  Physical.plan ->
  (eval_result -> 'a) ->
  'a
```

The `Mutation` payload carries the count only, not the verb.
The REPL has the `Physical.plan` in scope at the dispatch
site (it just translated and evaluated it) and reads the
verb off the plan's mutation constructor for the output.
Keeping the verb off the variant keeps it minimal — the
result is the *result* of the work, not a redescription of
the request — and means slice 12 needs no change to
`eval_result` when update and delete land.

Rejected: a two-entry-point split (`eval_query` CPS,
`eval_mutation` plain). The two-signature shape matches each
operation's natural cardinality more honestly, but commits
the executor to a precedent where every new sink kind grows
the entry-point list. Keeping a single CPS entry point holds
the line on the existing pattern; the small awkwardness of
the variant in the mutation arm (no live cursor scope
actually needed inside the continuation) is the right
tradeoff.

### Read/write transaction dispatch

The REPL picks between `with_read_transaction` and
`with_write_transaction` based on a one-liner classifier on
the Logical plan:

```ocaml
val classify : plan -> [ `Read | `Write ]
(* match plan with Query _ -> `Read | Mutation _ -> `Write *)
```

Always opening a write transaction would unnecessarily
serialise read-only queries against LMDB's writer lock.
Lazily opening a write transaction inside Eval would put
transaction concerns in the wrong layer (the existing scope-
bound transaction model is explicit at the REPL level for a
reason).

The REPL also reads the mutation verb off the plan at the
same dispatch site, so the classifier and the verb come from
the same source of truth.

### PK collision: get-before-put

The insert sink performs a `Storage.get` against the target
table immediately before each `Storage.put` and raises a
`Failure` if the key is already bound. LMDB's single-writer
guarantee inside a write transaction makes this safe — no
TOCTOU window exists.

Atomicity is inherited from the surrounding
`with_write_transaction`: the sink raises on collision,
`with_write_transaction` aborts the transaction in its
exception path, and any writes the sink had already issued
within the same transaction are discarded. A multi-row
insert (once the multi-row literal lands) therefore commits
all-or-nothing. For slice 11's single-row literal this
matters only as design contract — there's only one write per
transaction — but the contract is established here.

Rejected for this slice: adding a `Storage.put_if_absent`
primitive backed by LMDB's `MDB_NOOVERWRITE` flag. Cleaner
long-term, but raises Storage API questions (does the
existing `put` semantics change? how do errors distinguish
key-already-present from other failures?) that are better
resolved when update and delete have also touched the
storage write path. The switch later is local to the sink.

### REPL output: one-line affected-row status

Mutation output is a single line:

```
inserted 1 row
inserted 5 rows
```

No table name (the user just typed it), no
trailing-newline-and-blank, plural form on `N != 1`. The
REPL's existing try/with for `Failure` catches and prints
mutation errors in the same shape as query errors.

## Steps

Six steps, structured bottom-up after one vertical opener.
Step 1 lands `RelationLiteral` end-to-end as its own
self-contained piece, since it's independent of the wrapper
machinery. Steps 2–4 then introduce the wrapper and the
insert sink one layer-pair at a time, with a one-line
adapter at the seam between converted and not-yet-converted
layers — no `assert false` stubs anywhere. Step 5 is a
polish pass over error-message wording. Step 6 extends the
user-facing documentation now that the surface is stable.

Each step ends with `dune test` green, formatter clean, and
a sensible commit.

### Step 1 — `RelationLiteral` end-to-end

A self-contained vertical slice: add a relation-literal
source operator across every layer it touches.

- **Parser:** named-pair literal grammar
  (`{column: value, ...}`); single-row form only. Trailing
  commas allowed. Reject duplicate column names and
  qualified column keys at parse time.
- **Ast:** new `RelationLiteral { columns; rows }`
  constructor in `relation_expr` position.
- **Logical, Physical:** new matching `RelationLiteral`
  constructor on the existing flat `t`.
- **Lower, Translate:** pass-through.
- **Eval:** new case that produces a one-row `Relation.t`
  whose tuple sequence yields the literal's values.

After this step, typing `{id: 7, name: "Pretzel", amount: 9}`
at the REPL prints a one-row relation with the inferred
schema. No wrapper, no Mutation, no write transactions.

Tests:

- Parser unit tests for the literal forms, including the
  duplicate-column and qualified-key parse errors.
- Per-layer unit tests for Logical, Translate, Eval
  handling.
- One end-to-end test that runs a literal through
  `Repl.run` and asserts the rendered output.

### Step 2a — Physical + Eval, additive

Land the new types and the insert sink as a *second* entry
point alongside the existing one, so the change is purely
additive and existing callers (REPL, all current tests)
keep working unchanged. The canonical-entry-point swap
follows in step 2b.

- **Physical:** new `plan = Query of t | Mutation of
  mutation`; new `mutation = Insert { table; source }`.
  The existing `Physical.t` is untouched.
- **Eval:** new `eval_result = Query of [`Bag] Relation.t
  | Mutation of { affected_rows : int }`; new entry
  `eval_plan : Storage.environment -> [> `Read]
  Storage.transaction -> Physical.plan -> (eval_result ->
  'a) -> 'a`. The `Query` arm delegates to the existing
  `Eval.eval`; the `Mutation` arm fully implements the
  insert sink: iterate the source, do `Storage.get` then
  `Storage.put` per row, count writes, return `Mutation
  { affected_rows }`. PK collision raises `Failure` with a
  clear message. The existing `Eval.eval` keeps its
  current signature.
- **Storage:** new `as_write_transaction : [> `Read]
  transaction -> [`Read | `Write] transaction` coercion
  helper. The insert sink needs to call `Storage.put`; the
  perm phantom is purely compile-time, so the helper is a
  no-op at runtime but loosens the static type. Documented
  as unsafe-in-general, safe inside the sink because the
  REPL classifier (slice-2b / slice-3) will guarantee a
  write transaction at runtime.
- **Row_codec:** new `encode_row : Schema.t -> Schema.tuple
  -> string * string`, the inverse of `decode_row`. The
  sink uses it to serialise a tuple into the (key, value)
  pair that `Storage.put` expects, without having to
  hand-roll the split per table the way `Fixture` does.
- **Translate, REPL:** unchanged. The new entry isn't
  reachable from user input yet.

Tests:

- Eval Insert sink tested by hand-constructing
  `Physical.plan = Mutation (Insert {...})` and invoking
  `Eval.eval_plan` inside `Storage.with_write_transaction`.
  Happy path and PK-collision-against-storage.
- `Row_codec.encode_row` round-trip tested against
  `decode_row` for the fixture schemas.
- All existing tests stay green with zero changes.

### Step 2b — Canonical entry-point swap

Swap the canonical entry. The pattern-match-on-`eval_result`
and the Mutation rendering land at the REPL here, alongside
the corresponding Translate signature change. The work is
mechanical fan-out across callers; isolating it in its own
commit keeps the diff readable.

- **Eval:** delete the old `eval`. Rename `eval_plan` to
  `eval` (signature is now `Physical.plan -> (eval_result
  -> 'a) -> 'a`).
- **Translate:** signature becomes `Logical.t ->
  Physical.plan`; output is wrapped in `Physical.Query`.
  No Mutation arm yet — Logical is still flat.
- **REPL:** pattern-matches `eval_result`. Query branch
  uses the existing print path; Mutation branch
  implements the affected-row status output (`inserted N
  row` / `inserted N rows`, pluralised on `N = 1`).
  Transaction dispatch remains hardcoded to
  `with_read_transaction` for this step — no classifier
  yet, and Mutation is unreachable from user input.
- **Existing tests:** every caller of `Eval.eval` updates
  to the new shape (either via thin test helpers that
  wrap with `Physical.Query` and unwrap the result, or
  inline). Translate tests that assert structurally on
  the produced plan switch to a `plan_testable` and wrap
  their expected with `Physical.Query`.

Tests:

- REPL Mutation rendering exercised via a small unit test
  that feeds a Mutation `eval_result` through the
  rendering helper directly (since no end-to-end path
  reaches it yet).
- All existing query tests remain green after the
  signature swap.

### Step 3 — Translate + Logical

Add the wrapper at Logical, the classifier, and Translate's
Mutation handling with catalog-driven validation. Lower
gets the one-line adapter at the seam with the still-flat
Ast.

- **Logical:** new `plan = Query of t | Mutation of
  mutation`; new `mutation = Insert { table; source }`;
  new `classify : plan -> [`Read | `Write]`.
- **Translate:** signature is now
  `Logical.plan -> Physical.plan`. The `Query` arm is the
  previously-temporary wrap, now real. The `Mutation` arm
  looks up the target table in the catalog, validates that
  the literal's columns are a permutation of the schema's
  columns, validates each value's kind against the schema,
  and produces `Physical.Mutation (Insert {...})`.
- **Lower:** temporarily wraps its existing output in
  `Logical.Query (...)`. No Mutation arm yet — Ast is still
  flat.
- **REPL:** starts using `classify` to pick between
  `with_read_transaction` and `with_write_transaction`. No
  user-produced Mutation yet, but the dispatch is wired.

Tests:

- Translate Mutation arm tested by hand-constructing
  `Logical.plan = Mutation (Insert {...})`. Happy path
  plus each validation error (missing column, unknown
  column, kind mismatch).
- `classify` unit tests for both arms.
- All existing query tests remain green.

### Step 4 — Parser + Ast + Lower

Add the wrapper at Ast, the sink production at the parser,
and the Mutation arm at Lower. The last adapter dissolves
and the slice becomes end-to-end user-visible.

- **Ast:** new `plan = Query of pipeline | Mutation of
  mutation`; new `mutation = Insert { source; table }`.
  Grammar shape:

  ```
  pipeline       := query_pipeline ("|" sink)?
  query_pipeline := relation_expr ("|" query_op)*
  sink           := "insert" "into" identifier
  ```

- **Parser:** sink production; wraps the result in
  `Ast.Query` or `Ast.Mutation` based on whether a sink
  appeared. A `query_op` after a sink is a parse error
  ("unexpected token after `insert into <table>`").
- **Lower:** signature now `Ast.plan -> Logical.plan`; two
  real arms.

Tests:

- Parser unit tests for the sink production and the
  mid-pipeline-sink rejection.
- Lower unit tests for `Ast.Mutation → Logical.Mutation`.
- End-to-end integration test via `Repl.run` against the
  fixture: insert a fresh row into `orders`, assert the
  status line, follow up with a scan asserting the row is
  present.

After this step the slice is functionally complete.

### Step 5 — Validation polish

A sweep over the error-message UX now that every layer is
in place. Confirm wording is consistent across the stack;
ensure error messages name the offending columns or values
where applicable; backfill any missing per-error unit
tests:

- Missing columns (Translate) — error names which columns
  are missing.
- Unknown columns (Translate) — error names which columns
  are unknown.
- Kind mismatch (Translate) — error names the column, the
  expected kind, and the provided kind.
- Primary-key collision against storage (Eval) — error
  names the PK value and the target table.
- Duplicate column in literal (Parser) — error names the
  duplicate column.
- Qualified column key in literal (Parser) — error names
  the offending key.

This step is borderline-skippable if the per-layer steps
were thorough enough; it's kept as a deliberate
"step back and review the error UX" pass with the whole
stack in front of us.

### Step 6 — Documentation

Extend the user-facing docs now that the surface and error
wording are stable. All new examples are doctested via the
extractor from slice 10.

- **`docs/query-language.md` — new "Mutations" reference
  section.** Structured to accommodate update and delete
  additively in slice 12; today it contains one subsection
  for `insert into`. Follows the existing operator
  reference template (syntax line + description + worked
  example).
- **`docs/query-language.md` — new "Relation literals"
  sublanguage section.** Sits alongside the existing
  expression and projection sublanguages. Covers the
  single-row named-pair form, the rules (bare column
  names; trailing commas allowed; empty literal is an
  error; duplicate columns are an error), and a worked
  example showing a literal alone in the REPL printing as
  a one-row relation.
- **`docs/query-language.md` — tutorial extension.** One
  short paragraph at the end of the existing tutorial:
  insert a fresh row into `orders` with a literal, then
  re-query to show the new row. Gives DML a tutorial-
  shaped first impression rather than relegating it to
  reference.
- **README — layer tables.** Add a `RelationLiteral` row
  to the Logical / Physical operator table. Update the
  `Eval` row's description to mention the `eval_result`
  variant and the `Query | Mutation` plan wrapper.
- **README — layer diagram unchanged.** The existing
  diagram is dense and the read/write symmetry at Eval is
  already implied by the arrows.
- **README — roadmap unchanged.** The roadmap update is
  deferred to slice 12 per the out-of-scope item below;
  rewriting the slice 11 entry mid-DML would be premature.

Tests:

- Doctest extractor green on the new examples in
  `docs/query-language.md`. Specifically: an `insert into`
  example block, followed by a re-query block that
  observes the new row, exercises the extractor's handling
  of state changes across consecutive examples in one
  file. If the extractor resets state per block, the
  re-query block won't see the inserted row, and the
  extractor itself will need a small extension (out of
  scope here; flag and address if it happens).

After this step the slice is shippable.

## Verification

End-of-slice manual smoke (in the REPL against the fixture):

- Insert a fresh row into `orders` using a single-row literal;
  confirm the affected-row line, then scan the table to see
  the new row.
- Insert with a missing column; confirm an error naming the
  missing column, table state unchanged.
- Insert with an unknown column; confirm an error naming the
  unknown column.
- Insert with a kind mismatch (e.g. a `String` where an
  `Int64` is expected); confirm an error.
- Insert with a duplicate primary key against an existing
  row; confirm an error, table state unchanged.
- Insert with a duplicate key in the literal (`{id: 1, id:
  2, ...}`); confirm a parser error.
- Type a bare relation literal at the prompt with no `|
  insert into ...`; confirm it prints as a one-row relation.
- Issue a read-only query while the smoke runs; confirm
  output is unchanged from before the slice.
- Insert a fresh row, exit the REPL, restart it against the
  same data directory, and re-query the table; confirm the
  row persists across REPL sessions. This is the slice's
  first user-driven persistent write — no new code is
  required for durability (LMDB and the existing storage
  layer handle it) but the round-trip is worth confirming.

A note on test infrastructure for the integration tests
that exercise the insert sink: each test needs an LMDB
environment with state isolated from every other test, so
that writes from one test don't leak into another. The
expectation is that the existing test pattern — whatever
slice 1's fixture-test setup established for read-only
tests — already provides a per-test temp directory or
similar, and that mutation tests reuse it without
modification. If it turns out that pattern materialises
state lazily on first read in a way that doesn't survive
mutation, the test helper grows a small extension; flag
and address in step 4 when the first end-to-end mutation
test lands.

Plus the usual: `opam exec -- dune test` is green; `opam
exec -- dune build @fmt --auto-promote` leaves the tree
clean.

## Out of scope

- **Update and delete.** Slice 12, together with the
  upstream-identity validator.
- **Multi-row literal form** `(cols) { (vals), ... }`. Slice
  12 or later, when bulk-load use cases exist.
- **Value-expression IR.** Slice 12 (for update's
  `{amount: amount + 1}`-shaped assignments) or later.
- **Upsert semantics.** A separate future operator; the
  design doc keeps insert's "error on conflict" pure.
- **`RETURNING`-style mutation output.** An opt-in for
  composable mutation sinks. Future slice.
- **Insert-from-query in any tested form.** Grammatically
  legal (regime B: any pipeline can flow into `insert
  into`), but useless without DDL — every fixture table
  already has rows whose PKs would collide on re-insert. The
  insert sink will accept any source plan; tests will use
  literal sources only.
- **`MDB_NOOVERWRITE` and a `Storage.put_if_absent`
  primitive.** Future Storage refinement, when update and
  delete have also touched the write path.
- **Multi-statement input, explicit `begin` / `commit` /
  `rollback`.** Beyond list in the README; orthogonal to
  this slice.
- **README roadmap update.** The README's slice-11 entry
  says "Statement-level forms ... Update and delete may land
  here or follow on." That wording predates the DML design
  doc (which puts DML firmly in pipeline position, not as a
  statement stratum) and the scope cut to insert only. A
  README pass is worth doing alongside slice 12, when the
  full mutation surface is in place to describe.
