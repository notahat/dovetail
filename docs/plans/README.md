# Slice plans

One plan per slice of the build, numbered in the order they ran.
Plans are frozen history: once a slice closes, its plan is not
updated to track later changes to the code. Two conventions keep
them useful anyway:

- **Status lives here, and only here.** The table below is the
  single place that records each slice's state, so closing a slice
  means one edit. The plans themselves carry no status metadata.
- **Promoted design content is bannered.** When a plan's durable
  design rationale gets promoted into a living doc (under
  `docs/internals/` or `docs/design/`), the plan gains a one-line
  banner pointing at the promoted doc. Everything else in a closed
  plan stays as written.

"Done" means the slice shipped; the code may well have been
reworked by later slices, and the plan describes the state of the
world at the time it ran. Where a slice's user-facing surface was
wholesale retired later, the status says so.

| Plan                                                                | Status |
| ------------------------------------------------------------------ | ------ |
| [00 — Initial plan](00-initial-plan.md)                             | Foundational design; the document the slices grew from. |
| [01 — Scan a table](01-scan-a-table.md)                             | Done. |
| [02 — Restriction](02-restriction.md)                               | Done. |
| [03 — Projection](03-projection.md)                                 | Done. |
| [04 — Cross product](04-cross-product.md)                           | Done. |
| [05 — Inner join](05-inner-join.md)                                 | Done. |
| [06 — Streaming CPS executor](06-streaming-cps-executor.md)         | Done. |
| [07 — Expression language](07-expression-language.md)               | Done. |
| [08 — Primary-key point lookup](08-primary-key-point-lookup.md)     | Done. |
| [09 — Indexed nested-loop join](09-indexed-nested-loop-join.md)     | Done. |
| [10 — Query-language documentation](10-query-language-documentation.md) | Done. |
| [11 — Insert](11-insert.md)                                         | Done. |
| [12 — List and drop tables](12-list-and-drop-tables.md)             | Done; the `:`-command surface it built was later retired in favour of pipeline operators (slices 23–24). |
| [13 — DDL and library prep](13-ddl-and-library-prep.md)             | Done; the `dovetail.ddl` sub-library it extracted was deleted in slice 24. |
| [14 — Describe and create table](14-describe-and-create-table.md)   | Done; `:create table` was retired by slice 23, and the `type` operator (slice 20) took over `describe`'s role. |
| [15 — Retire the fixture](15-retire-fixture.md)                     | Done. |
| [16 — Full sub-library setup](16-full-sub-library-setup.md)         | Done. |
| [17 — Apply the ladder framework](17-ladder-framework.md)           | Done. |
| [18 — Scalar and value rename](18-scalar-and-value-rename.md)       | Done. |
| [19 — Collapse mutations into the pipeline](19-collapse-mutations-into-pipeline.md) | Done. |
| [20 — Term carrier and the type operator](20-term-and-type-operator.md) | Done. |
| [21 — Literal-syntax flip](21-literal-syntax-flip.md)               | Done. |
| [22 — Qualifiers](22-qualifiers.md)                                 | Done. |
| [23 — `create table` and `drop table` as pipeline operators](23-create-and-drop-table.md) | Done. |
| [24 — Catalog rung](24-catalog-rung.md)                             | Done. |
| [25 — AST decoupling](25-ast-decoupling.md)                         | Done. |
| [26 — Typecheck extraction](26-typecheck-extraction.md)             | Done. |
| [27 — Docs audience reorganisation](27-docs-audience-reorganisation.md) | Done. |
| [28 — SQL frontend](28-sql-frontend.md)                             | Done. |
| [29 — Documentation overhaul](29-documentation-overhaul.md)         | Done. |
