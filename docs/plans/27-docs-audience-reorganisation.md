# Docs audience reorganisation

This is a docs/meta plan rather than a code slice. It keeps the slice
numbering for continuity, but touches no `lib/` behaviour beyond the
doctest harness wiring.

## Context

Recent commits moved docs into `design/` and `archive/` folders, but the
organising principle was still muddy. We want docs filed by **audience**:

- **tutorial/** — new users learning the query language.
- **reference/** — advanced users looking up a specific operator, type,
  or expression form.
- **internals/** — coders who want to understand how Dovetail is built.
- **design/** — the maintainer setting direction (design notes); slice
  **plans/** stay a top-level sibling.

Constraints settled during planning:

- `design/` today is a tangle of past/present/future, some of it
  superseded. We are **not** untangling it now. The only internals doc
  trusted enough to move is `architecture.md` (and it likely needs a
  review later). `ir-types.md`, `type-ladder.md`, `type-system.md`,
  `literals-as-a-ladder.md`, `dml-design.md`, and `archive/` all stay
  put in `design/` for a later pass.
- `reference/` is not a straight move: it becomes a `README.md` index
  plus **one flat file per item** (each source, operator, sink,
  expression form, and type).
- Type pages are **authored fresh** from the user-facing material already
  scattered through the operator and expression docs; `type-system.md` is
  left untouched in `design/`.
- `plans/` files are **frozen history** — their references to
  `docs/query-language*.md` are narrative of past work and are **not**
  rewritten when files move.

## Target structure

```
docs/
  README.md                     NEW — top-level index across the four audiences
  tutorial/
    README.md                   was query-language.md (running the REPL, example tables)
    walkthrough.md              was query-language-tutorial.md
  reference/
    README.md                   NEW — index grouping the items below
    relation-reference.md  scalar-literal.md  row-literal.md
    relation-literal.md    catalog.md                          (sources)
    restrict.md  project.md  cross.md  join.md
    unqualify.md  tables.md  type.md                           (operators)
    insert-into.md  create-table.md  drop-table.md             (sinks)
    literals.md  column-references.md  comparisons.md
    boolean-operators.md  parentheses.md  precedence.md
    projections.md                                             (expressions)
    int64.md  string.md  bool.md
    row-type.md  relation-type.md  catalog-type.md             (types, authored fresh)
  internals/
    architecture.md             was design/architecture.md (flagged for later review)
    ubiquitous-language.md      was docs/ubiquitous-language.md
  design/                       UNCHANGED (the tangle — untangle later)
    archive/                    UNCHANGED
  plans/                        UNCHANGED (frozen history)
```

Source material: `query-language-pipeline-operators.md` already has one
subsection per source/operator/sink, and `query-language-expressions.md`
one per expression form — each becomes a self-contained file (title,
**Syntax**, semantics, worked example, links back to the index and
related items). Both monolith files are deleted once fully split.

## Live links to fix (everything else is frozen history)

- **`README.md`** — the `docs/query-language.md` link retargets to the
  new tutorial landing page.
- **Doctest harness** — `test/integration/dune` (deps) and
  `test/integration/test_documentation.ml` (`verified_files`) currently
  hard-code the four user doc paths. Switch both to **glob** markdown
  under `docs/tutorial/` and `docs/reference/`, plus `README.md`
  explicitly. The test discovers files by walking those two dirs
  (mirrored into the build tree by the dune `glob_files`/`glob_files_rec`
  dep); exact glob form to be confirmed against the watcher.
  Internals/design/plans are excluded — they carry no runnable `>` REPL
  blocks.
- **`internals/ubiquitous-language.md`** outbound links (root → one level
  deeper): `../lib/...` → `../../lib/...`, `design/type-ladder.md` →
  `../design/type-ladder.md`, `plans/06-...md` → `../plans/06-...md`.
- **`internals/architecture.md`** outbound links (design/ → internals/,
  same depth): its one link, `[type-ladder.md](type-ladder.md)`, becomes
  `../design/type-ladder.md`.
- Inter-doc links **among the moving/splitting files** are rewritten as
  part of each split.
- **Tidy:** `test/surface_ra/test_scalar_roundtrip.ml` has a stale
  `docs/type-system.md` comment reference (already wrong — the file is in
  `design/`). Fix to `docs/design/type-system.md` while in the area.

## Steps

Each step is one commit, ends with the build and tests green, and stays
near the ~5-file / ~200-line ceiling. The doctest stays green at every
step.

0. **Commit this plan.**
1. **Tutorial + internals moves.** `git mv` the tutorial pair into
   `docs/tutorial/` (→ `README.md`, `walkthrough.md`) and
   `architecture.md` + `ubiquitous-language.md` into `docs/internals/`.
   Rewrite the moved files' outbound links. Retarget the README link and
   update the two doctested tutorial paths in the harness (internals docs
   aren't doctested, so no harness change for them).
2. **Reference monoliths in + harness to glob.** `git mv`
   `query-language-pipeline-operators.md` → `reference/pipeline-operators.md`
   and `query-language-expressions.md` → `reference/expressions.md` (still
   monoliths, still doctest-clean). Switch the harness to glob
   `docs/tutorial` + `docs/reference` + `README.md`, so every later
   reference file is picked up automatically.
3. **Split sources** (5 files) out of `pipeline-operators.md`; begin
   `reference/README.md` with the Sources section.
4. **Split operators** (7 files); extend the index.
5. **Split sinks** (3 files); the `pipeline-operators.md` monolith is now
   empty — delete it.
6. **Split expressions** (7 files) out of `expressions.md`; delete that
   monolith.
7. **Author type pages** (6 fresh files: `int64`, `string`, `bool`,
   `row-type`, `relation-type`, `catalog-type`) from the existing
   user-facing material; finish `reference/README.md`.
8. **Top-level index + tidy.** Add `docs/README.md` linking the four
   audiences; fix the stale `test_scalar_roundtrip.ml` comment; final
   sweep for any dangling live links.

## Verification

- The `dune runtest -w` watcher stays green through every step; the
  `documentation` doctest suite (`test/integration/`) re-runs every REPL
  block in the relocated/split files against a fresh demo-seeded
  environment, so a broken example or wrong expected output fails there.
- After step 2, confirm the glob actually picks up files by adding a
  reference file and watching the doctest count grow.
- Manual link check: `rg -n '\]\(' docs/tutorial docs/reference
  docs/internals README.md` and spot-resolve each relative target; plan/
  design references intentionally excluded.
- Optional end-to-end: `./dovetail --demo-data dovetail-data` and run a
  couple of the documented examples by hand to confirm the prose still
  matches the engine.
