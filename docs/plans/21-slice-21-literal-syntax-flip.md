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

## Steps

Eight steps. Step 1 grows `Term.t` with the new arms (pure addition,
no wiring). Steps 2–3 land the type-expression grammar and its
lowering helpers as a standalone piece, not yet consumed by a
pipeline. Steps 4–5 add scalar and row literals as pipeline sources,
each end-to-end through every IR layer. Steps 6–8 are the relation-
literal migration: parse the new form additively, flip every
fixture/snippet, then delete the old rule.

The old `{col: val}` syntax stays parseable across steps 6 and 7 —
that internal coexistence is contained inside the slice; nothing
ships in that state.

### Step 1 — `Term.t` grows four arms

Add `Scalar_value`, `Scalar_kind`, `Row_value`, `Row_kind` to
`Term.t`. `Term.format` dispatches the new arms to `Scalar.format`,
`Scalar.format_kind`, `Row.format`, and `Row.format_kind` (the kind
formatters landed in slice 20). No other wiring — the new arms are
unreachable until later steps construct them.

*Tests:* unit tests in `test/core/term.ml` covering `Term.format` on
each new arm.

### Step 2 — Type-expression AST + parser

New AST node for type expressions covering both row-type
(`(id: int64, name: string)`) and relation-type
(`(id: int64, ..., primary key (id))`) forms. Parser parses both;
row-type rejects `primary key` clauses, relation-type accepts them.
Exposed as a parser entry point for testability; not yet wired into
the pipeline grammar.

Reserved-word check: `int64`, `string`, `bool`, `primary`, `key`
enter the grammar here. The `relation` keyword arrives in step 6.

*Tests:* parser unit tests covering empty row, single field,
multiple fields, refinement on relation-type, refinement rejected on
row-type, and reserved-word handling.

### Step 3 — Type-expression lowering helpers

Helpers in `Lower` (or a co-located module) that turn the
type-expression AST from step 2 into `Row.kind` and `Relation.kind`.
No new callers yet — the helpers stand ready for steps 4–6.

*Tests:* unit tests on the lowering helpers for each shape.

### Step 4 — Scalar literal as pipeline source

New `Ast.Scalar_literal of Scalar.value`. Parser accepts a bare
scalar literal at pipeline-source position. New Logical / Physical
constructors thread it through; `Translate` and `Eval` handle the
new arm; Eval emits `Term.Scalar_value`. The REPL's `Term.format`
dispatch (from step 1) renders the result.

End-to-end behaviour: `42` prints `42`; `42 | type` prints `int64`.
Lower's `type | type` rejection (from slice 20) now triggers when
the input root is a scalar-typed pipeline too — add tests for the
new failure modes.

*Tests:* per-layer unit tests for the new constructor; end-to-end
integration test in `test/integration/` covering `42`, `"hello"`,
`true`, and `42 | type`.

### Step 5 — Row literal as pipeline source

New `Ast.Row_literal` carrying a list of `(name, value)` pairs.
Parser accepts `(id = 1, name = "alice")` at pipeline-source
position. Logical / Physical / Translate / Eval thread it through;
Eval emits `Term.Row_value`. Empty row `()` is accepted; duplicate
field names are rejected at parse or lower time (decide where during
implementation — likely the parser, matching the relation-literal
precedent).

Watch for grammar ambiguity: a bare parenthesised expression already
parses as a grouped expression atom. The disambiguator is the `=` —
a row literal has `name = value` inside, an expression doesn't.

End-to-end behaviour: `(id = 1, name = "alice")` prints the row;
`(id = 1, name = "alice") | type` prints
`(id: int64, name: string)`.

*Tests:* per-layer unit tests; integration test covering single
field, multiple fields, empty row, and `| type` on each.

### Step 6 — New `relation (T) { rows }` literal parses (additive)

Parser learns the new form, embedding a relation-type expression
(step 2) and a comma-separated list of row literals (step 5) with a
permitted trailing comma. `Ast.RelationLiteral` grows a new shape
carrying `kind : Relation.kind` and `rows : (string * Scalar.value)
list list` (or a list of `Row.value` — pick during
implementation). Lower validates each row against the declared kind
and produces the same logical-plan node the old shape produces. Old
`{col: val}` syntax still parses for now.

Multi-row literals work via the new form. Empty `relation (T) {}`
works.

*Tests:* parser tests for empty, single-row, multi-row, trailing
comma, and row/kind mismatch (parse or lower error). End-to-end
integration test piping the new literal through `restrict` and
`project`.

### Step 7 — Migrate fixtures and snippets

Flip every test fixture, demo-data snippet, doc example, and CLI
help string from `{col: val}` to `relation (T) { rows }`. Mechanical
search-and-replace, but lands as its own commit so the diff is
reviewable on its own. The watcher stays green throughout — both
syntaxes still parse.

*Tests:* the existing test corpus continues to pass; no new tests at
this step.

### Step 8 — Remove the old `{col: val}` syntax

Drop the old parser rule, the old `Ast.RelationLiteral` constructor
shape (if step 6 introduced a parallel one rather than reshaping in
place), the matching Lower case, and `Relation_literal.kind_of` if
its last caller is gone (the new shape carries the kind explicitly,
so inference isn't needed at the literal). Reserved-word audit:
confirm `relation` doesn't collide with any column or table name in
the remaining corpus.

*Tests:* a parser test asserts the old syntax is now a parse error;
otherwise the surviving corpus stays green.
