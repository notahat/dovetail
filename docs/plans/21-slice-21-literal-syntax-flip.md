# 21 — Slice 21: Literal-syntax flip

Replaces the current `{col: val}` relation literal with the new
`relation (type) { rows }` form from
[`docs/type-system.md`](../type-system.md). Adds standalone row and
scalar literals as pipeline sources. Introduces the type-expression
grammar (the bit inside the parens of a relation literal). Grows
`Term.t` to cover the scalar and row rungs.

Depends on [slice 20](20-slice-20-term-and-type-operator.md) — `Term`
is already threaded through every layer; this slice adds arms to it
and adds new source-side AST nodes that produce those arms.

## Goal

End-state literal universe:

```
42 | type                               -> int64
(id = 1, name = "alice") | type         -> (id: int64, name: string)
relation (id: int64, name: string) { (id = 1, name = "alice") } | type
                                        -> (id: int64, name: string)
```

The old `{col: val}` syntax is gone. Every test fixture, doc snippet,
and example uses the new forms.

## Scope

- **Type-expression grammar.** Parser parses `(id: int64, name: string)`
  as a row-type expression and `(id: int64, name: string, primary key
  (id))` as a relation-type expression. Row-type rejects refinements;
  relation-type accepts the `primary key (...)` clause (only
  refinement supported today, per `Relation.kind`). New AST shape for
  type expressions; `Lower` turns them into `Row.kind` / `Relation.kind`.
- **Row literal as value.** `(id = 1, name = "alice")` parses as a row
  literal, produces `Term.Row_value`.
- **Scalar literals as sources.** `42`, `"hello"`, `true` work as
  bare pipeline sources, producing `Term.Scalar_value`. (Today scalar
  literals appear only inside the curly-brace relation literal.)
- **New relation literal.** `relation (id: int64, name: string) {
  (id = 1, name = "alice"), (id = 2, name = "bob") }` parses,
  embedding a row-type expression and a sequence of row literals.
  Multi-row literals work in this slice (the current single-row
  limitation goes away).
- **Old `{col: val}` syntax removed.** Parser drops the rule; AST
  drops the constructor; Lower drops the case. Every test fixture and
  doc snippet that uses it gets migrated.
- **`Term.t` grows four arms:** `Scalar_value`, `Scalar_kind`,
  `Row_value`, `Row_kind`. Pattern matches across the codebase grow
  with them; the compiler tells us where.
- **Kind formatters at the new rungs.** `Row.format_kind` for `(id:
  int64, ...)`, `Scalar.format_kind` already lands in slice 20.
- **`type` operator now exercised at scalar and row rungs.** No
  changes to the operator itself; the new source arms just flow
  through and produce the corresponding kind.

## Out of scope

- `create table` / `drop table` (slice 22). They want type-expression
  inputs but the typing machinery lands here first.
- Catalog rung (slice 23).
- Bag/set markers on relation literals (deferred per type-system.md
  open question). Defaults to bag, matching the rest of the system.
- Positional row syntax inside relation literals (where the header
  supplies names). Rows stay self-describing for v1; positional comes
  later if at all.

## Key design decisions made during planning

- **Single slice, no additive coexistence phase.** Considered splitting
  into "additive new forms" + "remove old" but rejected: shipping two
  syntaxes for the same thing in an intermediate state is the worst-
  for-readers configuration. The migration is mechanical and lands in
  one diff.
- **Self-describing rows everywhere.** A row literal inside a
  relation literal still carries its own field names. The type
  declared in the relation literal's parens is checked against the
  rows; mismatches are a parse-time or lower-time error. Positional
  rows are a future syntax.
- **Multi-row literals come along for free.** The single-row
  limitation in current `RelationLiteral` is a parser quirk, not an
  IR constraint. The new grammar accepts a comma-separated list
  (trailing comma permitted).

## Notes for follow-on slices

- Slice 22 reuses the type-expression grammar landed here: `(id:
  int64, ..., primary key (id)) | create table users` parses a
  relation-type expression on the left.
- Slice 23 reuses both grammars (catalog literal embeds relation-
  type and relation-value forms).
- Watch for reserved-word conflicts: `int64`, `string`, `bool`,
  `relation`, `primary`, `key` enter the grammar in this slice. Check
  test fixtures for existing column or table names that would now
  parse as keywords.
- The "type: input is already a type" error (from slice 20) now has
  new failure modes: `(id: int64) | type`, `(id: int64, primary key
  (id)) | type`. Test them.
