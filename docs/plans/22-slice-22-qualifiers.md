# 22 — Slice 22: Qualifier syntax and canonical output

Lands the qualifier extension from
[`docs/type-system.md`](../type-system.md): qualified names in row
literals and type expressions, qualifier-preserving canonical output,
the `unqualify` pipe stage, and the no-silent-drop rule at sinks.
Closes the gap left over from slice 21 — relation output was supposed
to flip to the canonical relation-literal form there but slipped.

Depends on [slice 21](21-slice-21-literal-syntax-flip.md). The
formatters this slice extends (`Row.format`, `Row.format_kind`,
`Relation.format`, `Relation.format_kind`) all landed in slice 21;
the type-expression grammar this slice extends is from the same
slice.

## Goal

After this slice:

```
users
| join orders on users.id = orders.user_id
                                  -- renders as a relation literal
                                     with qualified field names
users | type                       -> (users.id: int64,
                                       users.name: string,
                                       primary key (users.id))
(users.id = 1) | insert into users -- rejected: insert into refuses
                                      qualified input
users
| join orders on users.id = orders.user_id
| project users.id, orders.id
| unqualify                        -- rejected: collision on `id`
users
| join orders on users.id = orders.user_id
| project users.id, orders.user_id
| unqualify                        -- rows with bare `id` and
                                      `user_id`
```

## Scope

- **Formatters preserve qualifiers.** `Row.format`, `Row.format_kind`,
  `Relation.format`, and `Relation.format_kind` emit `qualifier.name`
  when a field carries one and bare `name` when it doesn't. The
  `unqualified_row_kind` strip currently inside `Relation.format`
  goes away.
- **REPL renders relation values in canonical form.** `Term.format`
  dispatches `Relation_value` to `Relation.format` (canonical relation
  literal) rather than `Relation.print` (the table-shaped renderer).
  `Relation.print` is deleted; the literal form is the form.
- **Parser accepts qualified field names** in row literals
  (`(users.id = 1)`) and type expressions (`(users.id: int64)`).
  Reuses the dotted-identifier parse path that column references
  already use (`parser.ml`'s column-reference rule).
- **`insert into` rejects qualified input rows.** A qualified field
  reaching `insert into` fails with an `Eval: insert into "<table>":`
  error naming the offending qualifier(s) and pointing at `unqualify`
  as the explicit-strip operator.
- **New `unqualify` pipe stage.** Relation-to-relation and row-to-row.
  Drops every field's qualifier. Collisions on the resulting bare
  names are an error.
- **Regression test for filter/project ambiguity.** The resolution
  rule (bare-when-unambiguous, qualified-when-ambiguous) is already
  correct in `Row.find_field`; if a test asserting both arms doesn't
  exist, add one.

## Out of scope

- `create table`'s qualifier-rejection rule. `create table` lands in
  the create/drop slice; the rejection rule is documented in
  `type-system.md` and applies to it from day one. Not this slice's
  problem.
- Catalog literal rendering. Catalog rung lands in its own slice;
  this slice's formatters are the building blocks it will reuse.
- Bag/set markers on relation literals (still deferred).
- Positional row syntax inside relation literals (still deferred).

## Key design decisions made during planning

- **One formatter per shape, qualifiers always preserved.** Considered
  keeping `Relation.format` qualifier-stripping and adding a separate
  `format_qualified`, but two formatters for the same shape with a
  "remember which one" rule is the bad-for-readers configuration. One
  formatter; the qualifier is part of the field, so it renders.
- **`Relation.print` is deleted, not parked.** The table renderer made
  sense when canonical form wasn't end-to-end; with the literal form
  now the documented output, carrying a second mode is surface area
  without payoff.
- **`unqualify` works on both rows and relations.** Symmetric with
  `insert into`, which accepts either today. The collision rule
  applies identically — a row with two same-named fields after
  stripping fails the same way a relation does.
- **Validation lives in Eval, not Translate.** `insert into`'s
  qualifier check needs the runtime input row kind. The source might
  be a literal (qualifier-less) or a join output (qualifier-present)
  and Translate can't always tell statically. Putting the check in
  Eval keeps the rule on the runtime side where the actual rows are.
- **Filter/project ambiguity is already done.** `Row.find_field`
  (lib/core/row.ml:47) already implements bare-when-unambiguous /
  qualified-when-ambiguous resolution. Both `Projection.resolve` and
  `Expression.evaluate` route through it. No code change needed; a
  test if one is missing.

## Notes for follow-on slices

- `create table` (slice 23): the input-validation pattern from
  step 5 is the template — reject qualified input, point at
  `unqualify` in the error.
- Catalog literal slice (slice 24): reuse
  `Relation.format` and `Relation.format_kind` directly for the
  per-relation rendering inside the catalog literal. Qualifiers on
  catalog-stored fields (currently `Some table_name` per
  `Ddl_executor.fields_with_qualifier`) round-trip into the catalog
  literal too — confirm during that slice that the catalog literal's
  per-relation type is the qualified one.
- Watch for snapshot-style integration tests under
  `test/integration/`; step 3 will rewrite a lot of expected output.
  The diff is mechanical but reviewable on its own.

## Steps

Six steps. Step 1 changes the formatters; step 2 swings the REPL
dispatch and deletes `Relation.print`; step 3 sweeps the mechanical
fixture refresh into its own commit so the diff is reviewable on its
own. Step 4 extends the parser. Step 5 adds the `insert into`
validation that step 4's input syntax makes reachable. Step 6 is
`unqualify`.

### Step 1 — Formatters preserve qualifiers

Change `Row.format`, `Row.format_kind`, and `Relation.format_kind` to
emit `Row.format_field_name field` (which respects the qualifier)
in place of `field.name`. Remove the `unqualified_row_kind` strip
inside `Relation.format`.

This step has visible REPL behaviour change for `| type`: stored
relations carry `qualifier = Some table_name` on every field (per
`Ddl_executor.fields_with_qualifier`), so `users | type` will now
render `(users.id: int64, ...)` instead of `(id: int64, ...)`.
Integration tests that assert `| type` output get updated here.

*Tests:* unit tests for each formatter on qualified inputs; existing
unqualified tests stay green unchanged; integration tests for `users
| type` get expected-output refreshes.

### Step 2 — REPL renders relations via `Relation.format`

Switch `Term.format`'s `Relation_value` arm to `Relation.format`.
Delete `Relation.print` and its helpers (`format_header_separator`,
`column_widths`, `is_numeric_kind`, etc.) and any now-orphaned
imports. Add a focused integration test asserting canonical
qualified output for a post-join relation — concrete proof the new
path is the one running.

Existing fixtures still asserting table-form output break here on
purpose; step 3 sweeps them.

*Tests:* one new positive integration test (post-join canonical
render). Many existing tests are red at the end of this step —
expected and tracked.

### Step 3 — Refresh fixtures and doc snippets

Mechanical sweep. Every integration test, demo-data snippet, doc
example, and CLI help string that quotes table-form output gets
rewritten to the new canonical form. Stored relations render with
qualified field names throughout (per step 1), so a `users` query
at the REPL prints
`relation (users.id: int64, users.name: string, primary key (users.id)) { ... }`.

Single commit so the diff is reviewable in one pass. The watcher
goes green at the end of this step.

*Tests:* existing test corpus turns green. No new tests at this
step.

### Step 4 — Parser accepts qualified field names

Extend the row-literal parser to accept `users.id = 1` field
positions; extend the type-expression parser to accept
`users.id: int64` field positions. Reuses the dotted-identifier
parse from the existing column-reference rule. The qualifier
round-trips into `Row.field.qualifier` (for type expressions) and
into the row literal's field list (for values).

Duplicate-name handling: `(users.id = 1, orders.id = 2)` is
allowed because the qualified names differ;
`(users.id = 1, users.id = 2)` is rejected. The existing
duplicate-name check operates on qualified field names already
when present.

*Tests:* parser unit tests for qualified row literals, qualified
row-type expressions, qualified relation-type expressions, mixed
qualified/unqualified fields in one literal, and the qualified-name
duplicate rule.

### Step 5 — `insert into` rejects qualified input

Eval's `insert into` path validates that every field on the input
row kind has `qualifier = None`. A qualified field produces an error
prefixed `Eval: insert into "<table>":` naming the offending
fields and suggesting `unqualify` upstream.

*Tests:* unit test for the validation; integration test piping a
join into `insert into` and asserting the error; integration test
confirming that the `unqualify` workaround (after step 6 lands)
unblocks the same pipeline.

### Step 6 — `unqualify` pipe stage

New `Ast.Unqualify` node, Logical/Physical constructors, Translate
case, Eval implementation. Accepts either a relation or a row on the
left. Builds a new row kind by setting every `field.qualifier` to
`None`; rejects the result if any two fields now share a bare name,
with an error like
`Eval: unqualify: collision on "id": fields "users.id" and "orders.id"`.

The operator is the identity on inputs that already have no
qualifiers — a row or relation with bare names passes through
unchanged.

*Tests:* per-layer unit tests; integration tests covering a
post-join `unqualify` (clean), a colliding `unqualify` (error),
`unqualify` on an already-unqualified relation (no-op), `unqualify`
on a row literal, and the full chain
`users | join orders on … | project users.id, orders.user_id | unqualify | insert into joined`.
