# DML in the RA query language

**Status: partly built, the rest proposal.** `insert` shipped as the
`insert into` pipeline sink. `update` and `delete` remain unbuilt;
the designs here — including the upstream-identity validator — are
the starting point when they land.

This document captures the design of data-modification operators
(insert, update, delete) in the surface RA query language. All three
are designed together so the surface is coherent, and so insert's
shape isn't quietly determined by the cases it doesn't have to
handle. Which subset lands in any particular slice is a slice-plan
decision, not a design-doc decision.

This is a design document, not a slice plan.

## Scope

In scope here:

- Surface syntax for `insert`, `update`, and `delete`.
- A new sublanguage of relation literals.
- The constraint on the upstream of `update` and `delete`.
- The shape of the IR nodes and the eval-result type.
- The execution and transaction model surfaced through the REPL.

Out of scope here, mentioned only as context:

- DDL (`create table` / `drop table`) — separate later slice.
- Insert-from-query and `RETURNING`-style mutation outputs — future
  additions that this design accommodates without rework.
- Semijoin and antijoin as new pipeline operators — repeatedly relevant
  here because they're what the design assumes for cross-table mutation,
  but their own slice will design them properly.
- Explicit `begin` / `commit` / `rollback` — already on the Beyond list
  in the README.

## Conceptual model

The surface language has two universes of first-class values, kept
deliberately separate.

- **Relations.** Schema-tagged streams of rows. Composition lives in
  *pipelines*: a relation enters from the left, operators transform it,
  a relation comes out the right. Some operators have side effects on
  storage too (`insert`, future `update`/`delete`), but they still
  return a relation — typically a small reporting one. Atoms in this
  universe are table names, parenthesised sub-pipelines, and relation
  literals. The composition operator is `|`, plus binary operators
  like `cross` / `join` that take a second relation.
- **Scalars.** `Int64`, `String`, `Bool` values. Composition lives in
  *expressions*: `=`, `and`, `not`, eventually `+`, function calls.
  Atoms are literals and column references. The current row is implicit
  context when an expression is evaluated inside a pipeline operator.

These two universes are not stratified arbitrarily: they correspond to
two different kinds of thing in the relational world. SQL blurs the
line, with awkward consequences (scalar context vs table context,
three-valued logic, ambiguous column references). Pipeline RA keeps
them clean.

There are three places where things compose:

| Position                          | Allowed              | Examples                                                                |
| --------------------------------- | -------------------- | ----------------------------------------------------------------------- |
| Pipeline in pipeline position     | Any pipeline         | Right side of `join`/`cross`/`semijoin`; source of `insert`/`update`/`delete` |
| Expression in expression position | Any expression       | `(a + b) * (c - d)`                                                     |
| Expression in pipeline position   | Expression with row  | `restrict <expr>`, `join … on <expr>`, `update {col: <expr>}`           |

One position is deliberately omitted: pipeline-in-expression position
(SQL's subqueries — `EXISTS (SELECT …)`, `x IN (SELECT …)`, scalar
subqueries). Almost every SQL subquery pattern exists because SQL's
binary algebra is impoverished — the only binary operator is `JOIN`,
which always emits pairs with both schemas. A pipeline RA with a
richer binary-operator vocabulary (semijoin, antijoin, eventually
group-then-join) reaches the same use cases through binary operators
on relations, not through relations in expressions. The remaining tail
(true scalar subqueries returning one value per outer row) is rare
enough to defer indefinitely.

This frame retroactively justifies the rest of the design:

- DML lives in pipeline position. The "statement form" the README
  alluded to is just a pipeline whose source happens to be a literal;
  no separate grammar stratum.
- The upstream constraint on `update`/`delete` is the practical
  embodiment of "the input must name a single base table".
- Sub-pipelines as binary-operator right operands (deferred to a later
  slice) are the general-purpose compositional mechanism that lets
  cross-table mutation read as a chain of semijoins.

## Top-of-grammar shape

```
program       := pipeline
pipeline      := relation_expr ("|" pipeline_op)*
relation_expr := identifier                       -- bare table name
              |  "(" pipeline ")"                 -- sub-pipeline (future)
              |  relation_literal                 -- new in this design
pipeline_op   := restrict | project | cross | join             -- existing
              |  semijoin | antijoin                            -- future
              |  "insert" "into" identifier                     -- write
              |  "update" row_literal                           -- write
              |  "delete"                                       -- write
```

There is no separate "statement" form. Every input is a pipeline.
`insert` (and future `update` / `delete`) are pipe operators like any
other — relation in, relation out. They happen to be write operators,
so the REPL opens a write transaction when one appears anywhere in
the tree, and the parser rejects extra pipe-steps after them as a
surface-syntax rule. Each one hands the printer a small reporting
relation — for `insert` today, a one-row `(insert_count: int64)` —
so every pipeline output renders through the same path.

## Relation literals

A new sublanguage. Two surface forms, both desugaring to the same
internal representation `(columns: [name, …], rows: [(value, …), …])`.

**Named-pair form (single row):**

```
{id: 7, user_id: 1, description: "Pretzel", amount: 9}
```

**Header + positional rows form (multi-row):**

```
(id, user_id, description, amount) {
  (7, 1, "Pretzel", 9),
  (8, 2, "Donut",   3),
}
```

The header in parens names the columns once; each value tuple is
positional within the header. The single-row form is the natural
ergonomics for REPL use; the multi-row form is the natural ergonomics
for bulk loads. Both produce a relation literal of the same shape.

Rules common to both forms:

- Column names are bare. Qualifiers (`users.id`) are rejected — the
  qualifier is either redundant with the sink's target or wrong.
- Trailing commas are allowed everywhere.
- An empty literal is an error.
- Duplicate column names within a literal are an error.
- The value position is a full expression. In an insert context the
  expression must not reference columns (there is no row in scope);
  in an update context the current row's columns are in scope.

The literal carries its own schema: a `{id: 7, name: "x"}` literal is
intrinsically a one-row relation with schema `{id: Int64, name: String}`.
That property keeps the literal a self-contained relation expression,
which matters for regime B — the literal can in principle feed any
pipeline operator, not just a sink.

## Insert

```
{...row literal...} | insert into <table>
```

- The literal carries its own column names. The sink validates that
  the literal's columns are a permutation of the target table's
  columns and that each column's value kind matches the schema.
- Missing columns → error. We have no defaults and no NULLs; every
  column must be specified. Error names the missing columns.
- Unknown columns → error. Same wording.
- Primary-key collision with an existing row → error. The sink does a
  `get` before each `put` to detect this; LMDB's single-writer
  guarantee makes a TOCTOU check unnecessary. Long-term we can switch
  to LMDB's `MDB_NOOVERWRITE` flag for atomic put-if-absent.
- Duplicate primary keys *across rows of the literal itself* → error,
  detected at validation before any storage write. The error names the
  duplicate value, not just "PK conflict".
- All-or-nothing atomicity. The whole insert runs in one LMDB write
  transaction; any conflict aborts the transaction and leaves the
  table unchanged.
- Affected-rows count = source-relation cardinality (because partial
  success can't happen).

Upsert semantics are deliberately not part of `insert`. A future slice
can add a separate operator (`upsert into`, or similar) with explicit
overwrite intent; conflating the two would make `insert into` ambiguous
at the call site.

## Update

```
<identity-preserving pipeline> | update {col: expr, col: expr, ...}
```

The "set" clause reuses the named-pair row-literal syntax, with two
differences in interpretation:

- The literal is *partial*: only changed columns appear; unmentioned
  columns retain their current values.
- The value position is a full expression with the current row's
  columns in scope, so future forms like `{amount: amount + 1}` and
  `{active: not active}` will work as soon as the expression language
  supports them.

Other rules:

- Unknown column → error.
- Empty `{}` → error.
- Updating primary-key columns is allowed (semantically a
  delete-and-reinsert in storage). Forbidding it would be artificial
  scope-cutting; the semantics are clean if the new PK doesn't
  collide.
- Affected-rows count = rows that matched the upstream pipeline,
  whether or not their values actually changed. (Matches SQL's
  standard interpretation.)

## Delete

```
<identity-preserving pipeline> | delete
```

- Bare `| delete`; the target table is implicit from the upstream. A
  redundant `delete from <table>` clause would create the possibility
  of disagreement.
- Empty pipeline result → no-op, not an error. The REPL reports
  zero rows affected.
- Unrestricted form (`orders | delete`) is allowed. The pipeline
  semantics make it unambiguous, and the REPL's affected-rows count
  makes the scope of what happened visible. Any "safety mode" guard
  is a separate, orthogonal feature.
- Affected-rows count = rows removed.

## Upstream constraint on update and delete

The upstream pipeline of an `update` or `delete` sink must yield rows
that retain their identity as rows of a single base table. Each output
row must trace back to exactly one disk row of one table and carry
that table's full schema unchanged.

Operator classification:

| Operator                    | Identity-preserving over its input? |
| --------------------------- | ----------------------------------- |
| `Scan` (base case)          | Yes                                 |
| `Restrict`                  | Yes                                 |
| `Project`                   | No — drops columns, possibly PK     |
| `CrossProduct`, `Join`      | No — rows are pairs                 |
| (future) `Sort`, `Limit`    | Yes                                 |
| (future) `Semijoin`         | Yes, over left input                |
| (future) `Antijoin`         | Yes, over left input                |
| (future) `Distinct`         | No — merges multiple disk rows      |
| (future) `Union`            | No — rows aren't from one table     |
| (future) `Aggregate`        | No — output rows are summaries      |

The constraint is enforced as a validation pass on the lowered logical
tree — not in the grammar (the AST mirrors syntax, not semantics) and
not at runtime (the error message is far better at validation time).
The pass walks the upstream of each `Update` / `Delete`, classifies
each operator, and errors if any non-preserving operator is present
or if the upstream doesn't resolve to a single `Scan`.

Cross-table mutation cases ("delete orders belonging to inactive
users") aren't expressible through the existing operator set. They fit
the constraint as soon as semijoin lands:

```
orders
  | semijoin users on orders.user_id = users.id and not users.active
  | delete
```

Multi-hop versions ("delete A based on data in C, where A→B→C") work
through nested semijoins, which require sub-pipelines on the right of
binary operators (also a separate later concern):

```
A | semijoin (B | semijoin C on B.id = C.b_id and <pred>)
    on A.id = B.a_id
  | delete
```

A flat chain (`A | semijoin B on … | semijoin C on B.id = C.b_id`)
does *not* work — after the first semijoin, B's columns are out of
scope, breaking the bridge.

## IR shape

The logical IR gains mutation constructors directly inside `Logical.t`,
alongside `Scan`, `Restrict`, `Project`, etc. Each carries the target
table explicitly so the IR is self-describing and so the validator
has something to check the upstream's root `Scan` against.

```ocaml
type t =
  | Scan of { table : string }
  | Restrict of { input : t; predicate : Expression.t }
  | Project of { input : t; columns : Projection.t }
  | CrossProduct of { left : t; right : t }
  | RelationLiteral of { columns : string list; rows : Scalar.value list list }
  | Insert of { table : string; source : t }
  (* future: Update, Delete *)
```

There is no separate `mutation` type or `plan` wrapper — every operator
lives on `t`. The physical IR mirrors the same shape. `Insert` evaluates
inside the eval entry point's existing transaction (a write transaction,
picked by the REPL via `Logical.required_access` walking the tree),
reads its source pipeline through the same streaming `eval`, and applies
the per-row write.

## Eval result and the REPL

Every operator returns a relation, including the write operators.
`Insert` returns a one-row relation with kind `(insert_count: int64)`;
`Update` and `Delete` will follow the same shape (`update_count`,
`delete_count`). The eval entry point therefore has a single signature
for every operator:

```ocaml
val eval :
  environment ->
  [> `Read ] transaction ->
  Physical.t ->
  ([ `Bag ] Relation.t -> 'a) ->
  'a
```

The REPL renders whatever falls out — read and write pipelines both
go through `Relation.print`, so the bordered-table format is uniform.
Pluralisation is no longer the REPL's problem; the user reads `1` or
`3` directly from the `insert_count` cell.

The parser currently rejects extra pipe-steps after `insert into ...`
as a surface-syntax rule, but the IR carries no such restriction. If a
future `RETURNING`-style opt-in wants to compose writes into larger
pipelines, the IR is already shaped to accommodate it; only the
parser rule has to relax.

## Transactions

- **One transaction per top-level REPL input.** Read or write,
  depending on the operation.
- **No explicit `begin` / `commit` / `rollback`.** That's a separate
  Beyond-list item and shouldn't be pre-empted here.
- **No `;`-separated multi-statement input.** When/if it arrives, the
  natural shape is `;`-separated statements forming a single atomic
  batch — but the atomicity story, error-recovery, and grammar are a
  later design.
- **Read vs write decided pre-eval.** A small classifier looks at the
  root of the logical tree and returns `[ `Read | `Write ]`; the REPL
  picks `with_read_transaction` or `with_write_transaction`
  accordingly. Always opening a write transaction would unnecessarily
  serialise pure queries against LMDB's writer lock; opening one
  lazily inside eval would put transaction concerns in the wrong
  layer.
- **Error path** reuses the existing exception/abort machinery.
  Mutation errors raise; `with_write_transaction` aborts; the existing
  `try ... with Failure message ->` in `evaluate_and_print` prints the
  error and the REPL loops.

## What this design accommodates without rework

These are the items the design is consciously prepared for, even
though they belong to later slices. None of them require revisiting
the decisions here.

- **Semijoin and antijoin** as identity-preserving binary operators.
  Drop into the operator classification table; nothing else changes.
- **Sub-pipelines as binary-operator right operands.** A grammar lift
  on the `relation_expr` nonterminal. Unlocks multi-hop semijoin
  patterns, CTE-style intermediate naming, and join-on-filtered-subquery.
- **Upsert** as a separate operator. Keeps `insert`'s "error on
  conflict" semantics intact.
- **RETURNING-style mutation outputs** as an explicit opt-in. Write
  operators already return relations in the IR; the parser's
  "nothing after `insert into`" rule is what makes them
  default-terminal at the surface, and a RETURNING opt-in would
  relax that rule.
- **Insert-from-query.** `(users | restrict active) | insert into
  active_users`. Already legal under regime B; just needs the target
  table to exist (which means DDL).
- **Multi-statement input** and **explicit transactions** — both
  orthogonal to everything above.

