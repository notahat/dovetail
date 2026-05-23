# 22 — Slice 22: `create table` and `drop table` as pipeline operators

Lands the pipe-form for `create table` and `drop table` from
[`docs/type-system.md`](../type-system.md). Retires the
corresponding `:`-sigil DDL statements.

Depends on [slice 21](21-slice-21-literal-syntax-flip.md) — the
type-expression grammar and the new relation literal are needed for
`create table`'s left side.

## Goal

After this slice:

```
(id: int64, name: string, primary key (id)) | create table users
relation (id: int64, name: string) {
  (id = 1, name = "alice"),
} | create table users
drop table users
```

all work. `:create table` and `:drop table` are gone.

## Scope

- **Three new pipeline operators.**
  - `Create_table_empty of { name : string; kind : Relation.kind }`
    — takes a relation-type on the left, creates an empty table.
  - `Create_table_seeded of { name : string; source : t }` — takes a
    relation-value on the left, creates the table *and* seeds it with
    the rows. Implemented as the two-step composition of
    `Create_table_empty` then an Insert-equivalent loading pass over
    `source`'s rows, all in one write transaction.
  - `Drop_table of { name : string }` — a *leaf* operator (no
    left-side input). The table name lives in the keyword.
- **Parser disambiguates `create table` at parse time.** The parser
  knows whether the left side is a type-expression or a value-
  yielding pipeline (different starting tokens — type-exprs start
  with `(` and contain `:` between names and types; values start
  with literals or identifiers and use `=`). It picks the right AST
  constructor up front. Lower doesn't re-classify at runtime.
- **`drop table` is a leaf, like `Relation_name`.** Grammar accepts
  `drop table <name>` standalone (no `|` before it). Joining
  `Relation_name`'s existing "no left side" pattern.
- **Result shapes.**
  - `create table` returns a one-row relation
    `(created: string) { (created = "users") }` — or similar, to be
    nailed down in the detailed plan; the principle is "everything
    returns a relation, including catalog-mutating operators."
  - `drop table` returns the same shape with `dropped` instead of
    `created`.
- **Retire `:create table` and `:drop table` from `lib/ddl/`.**
  Parser rules, AST constructors, executor cases, format-printer
  cases, and round-trip tests for these two statements go away.
  `lib/ddl/` shrinks but still holds `:list tables`.
- **Transaction classification.** The three new operators all
  require `[`Write]`. Existing tree-walk from slice 19 picks them up
  by declaring their required access.
- **Permission contravariance: reuse the slice 19 `Obj.magic`
  template.** `Eval.eval`'s transaction parameter is `[> `Read]`, but
  any storage `put` / `create_map` / `drop_map` needs
  `[`Read | `Write]`. Slice 19's `evaluate_insert` solved this by
  locally coercing with `Obj.magic` inside the write branch, justified
  by the invariant that `Logical.required_access` made the REPL pick a
  write transaction whenever an `Insert` appeared in the tree. The
  same template applies to `Create_table_*` and `Drop_table`: coerce
  locally, with a comment naming `required_access` as the upstream
  invariant. Don't relax `Eval.eval`'s signature to `[`Read | `Write]`
  — that would force pure-read pipelines to open a write transaction.

## Out of scope

- `alter table` and any other catalog-mutation operators. Future
  slices, parallel shape (one keyword-named sink per mutation kind).
- Schema-versioning on disk. Today's storage assumes the kind shape
  matches what's stored; `create_table_seeded` writes a kind and
  then rows in the same transaction, consistent with how `:create
  table` + `insert into` work today.
- Catalog rung (`catalog | tables`, etc.) — slice 23.
- Composite primary keys aren't a slice 22 concern; the existing
  `Relation.kind` already supports multi-column PKs.

## Key design decisions made during planning

- **Two AST nodes for `create table`, not one with a sum input.**
  The grammar already distinguishes type-expressions from value-
  yielding pipelines, so the parser disambiguates upfront. Lower has
  one obvious lowering per node; error messages stay local to the
  parse.
- **`create_table_seeded` is `create_table_empty` + insert-loading.**
  Executor implements it as the natural composition. Keeps the
  mental model "one transaction, schema write then row writes" with
  no new path.
- **Sinks aren't a category.** The slice 19 collapse made every
  operator return a relation; `create_table` and `drop_table` follow
  the same rule. Their result shapes are a small design call — match
  whatever shape Insert settled on, with whatever fields make sense
  per operator.

## Notes for follow-on slices

- Slice 23 retires `:list tables` and removes the now-empty
  `lib/ddl/` library wholesale. After slice 22, only `:list tables`
  remains in DDL.
- The `create table` / `drop table` result-row shapes ship with this
  slice. If the project later decides on a uniform "operation
  result" shape across all sinks, that's a refactor that touches
  Insert (slice 19), this slice's two operators, and any future
  sinks. Worth keeping the shapes consistent or at least
  intentionally distinct.
- Reserved-word check before grammar lands: `create`, `drop`, `table`
  enter the keyword set in this slice. Check test fixtures and
  examples for any column or table named `create`, `drop`, or
  `table`.
