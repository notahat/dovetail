# Documentation overhaul

A docs/meta plan, like slice 27. It keeps the slice numbering for
continuity. The only `lib/`-adjacent code it touches is the doctest
harness (to teach it the SQL surface) and the dune setup (to enable
odoc).

## Context

A full audit of the documentation (tutorial, reference, internals,
design, archive, plans, and the `.mli` layer) found two first-rate
areas and a clear pattern in the rest: **quality tracks enforcement**.
The RA reference is excellent because every example is doctested. The
`.mli` docs are excellent because a convention demands them. Where
nothing mechanical keeps the docs honest, they have drifted.

The specific problems this plan addresses, in rough priority order:

1. **As-built vs as-imagined is blurred.** `design/ir-types.md`
   documents a `Typed_logical.t` GADT at length; no such module
   exists (`Typecheck` validates and returns the plain `Logical.t`).
   The doc's preamble says "as-designed", but the biggest divergence
   has no callout. `archive/ddl-design.md` describes a `:`-sigil DDL
   grammar that was never built; `archive/dml-design.md` describes
   future work; nothing distinguishes the two kinds of dead.
   Slice 27 deliberately deferred this untangling — this plan is the
   deferred pass.
2. **Load-bearing design rationale is trapped in plan files.** The
   CPS executor design (plan 06), the point-lookup conjunct
   recognition (plan 08), the indexed-join shape (plan 09), and the
   SQL frontend design (plan 28) exist only as frozen history.
   `internals/ubiquitous-language.md` links into plan 06 because
   there is nowhere else to point. Plans don't get updated when the
   code changes, so this knowledge will silently rot.
3. **No doc follows a query through the system.** The architecture
   map and the `.mli` docs exist, but nothing traces one query from
   text through AST, logical plan, typecheck, physical plan, and CPS
   evaluation. The README roadmap already names this gap.
4. **SQL is a second-class citizen.** Its reference examples are
   excluded from the doctest harness (`TODO(sql-doctest)`), the
   tutorial never mentions it, and its pages are thinner than the RA
   equivalents.
5. **The tutorial teaches a fraction of the language.** It covers
   restrict/project/cross/join against demo data and stops; a reader
   can finish it unable to create a table.
6. **The `.mli` excellence is invisible.** There is no odoc build, so
   the best documentation in the project is only readable file by
   file in the source.
7. **Assorted smaller drift**: empty "Next up" roadmap section,
   partial operator list in the README, duplicate tutorial links, no
   plans index, missing ubiquitous-language entries (`Lower`,
   `Typecheck`, `Translate`, `Physical`), `architecture.md` omits
   `Typecheck` from the pipeline story, RA reference has no error
   examples and doesn't mention keyword case-sensitivity.

## Decisions settled during planning

- **Status banners, not a directory rename.** Every doc in `design/`
  and `archive/` gets a one-line status banner under its title, one
  of: **As-built** (describes the code as it is), **Proposal — not
  built**, **Superseded — _what shipped instead_**, or **Historical
  record**. The directory contract sharpens to: `internals/` is
  as-built only; `design/` is direction-setting and every doc carries
  its status. Renaming `design/` to `proposals/` was considered and
  rejected — some design docs are partly as-built, and the banner
  carries the same signal with less churn.
- **`ir-types.md` is reworked in place, not split.** The as-built IR
  shapes are already documented where they matter (the `.mli` files
  and `internals/architecture.md`); moving prose out of `ir-types.md`
  would duplicate them. Instead each major section gets an explicit
  status line, and the `Typed_logical` material is unambiguously
  marked as a proposal with a "today" callout stating what
  `Typecheck` actually returns.
- **Plans stay frozen history, with one exception.** A plan whose
  design content is promoted to a living doc gets a one-line banner
  at the top pointing at the promoted doc. Nothing else in a closed
  plan is rewritten.
- **Promotion becomes part of the workflow.** A slice isn't done
  until any durable design rationale in its plan has a home outside
  `plans/`. This lands as a `CLAUDE.md` workflow rule so it applies
  to every future slice.
- **The query-lifecycle walkthrough is not doctested.** Its REPL
  blocks need `--show-logical` / `--show-physical` output, which the
  harness runs without. Its examples are captured from the real
  binary and hand-checked; the doc says so. Extending the harness to
  understand plan-printing sessions is possible later but out of
  scope here.
- **Doctest SQL support lands before any new SQL prose.** The
  tutorial's SQL leg and any SQL reference work happen after the
  harness verifies `sql> ` sessions, so no new hand-checked examples
  are written.

## Target structure

```
docs/
  README.md                 sharpened contract for internals/ vs design/
  tutorial/
    README.md               + pointer to the SQL leg
    walkthrough.md          unchanged
    tables.md               NEW — create table, insert, literals, drop
    sql.md                  NEW — the walkthrough query, in SQL
  reference/
    ra/                     + error examples, case-sensitivity note
    sql/                    now doctested
  internals/
    architecture.md         + Typecheck in the pipeline story
    ubiquitous-language.md  + Lower/Typecheck/Translate/Physical,
                              surface-name → IR-name mapping;
                              plan-06 link retargeted to executor.md
    executor.md             NEW — promoted from plan 06
    optimization.md         NEW — promoted from plans 08 + 09
    sql-frontend.md         NEW — promoted from plan 28
    storage.md              NEW — encoding, key format, catalog
                              persistence, transaction/cursor lifetime
    query-lifecycle.md      NEW — one query traced end to end
  design/                   every doc gains a status banner;
                            ir-types.md reworked with per-section status
  archive/                  every doc gains a status banner
  plans/
    README.md               NEW — index: one line + status per slice
```

## Steps

Each step is one commit, ends with the build and tests green, and
stays near the ~5-file / ~200-line ceiling. Steps 1–6 are quick,
mostly-mechanical truth fixes; the new documents follow. Later steps
depend on earlier ones only where noted.

0. **Commit this plan.**
1. **README and small-fix sweep.** Fill or drop the empty "Next up"
   roadmap section; make the README operator list complete or mark it
   illustrative; note that the Docker image applies `--demo-data` and
   that `/data` is a volume; fix the duplicate links in
   `tutorial/README.md`.
2. **Status banners.** Add the status banner to every doc in
   `archive/` (`ddl-design.md` → Superseded, naming what shipped:
   DDL became ordinary pipeline operators; `dml-design.md` →
   Proposal, insert shipped, update/delete not built;
   `library-structure.md`, `post-slice-11-review.md` → Historical
   record; `literals-as-a-ladder.md` → Proposal) and to
   `design/type-system.md` and `design/type-ladder.md` (with
   per-rung status in the latter: which rungs are fully built, which
   kind-side only). Sharpen the internals-vs-design contract in
   `docs/README.md`.
3. **Rework `ir-types.md`.** Per-section status lines; the
   `Typed_logical` sections explicitly marked Proposal with a callout
   stating that `Typecheck` today returns the input `Logical.t`
   unchanged and no `Typed_logical` module exists. The downstream
   sections that assume it (`Translate`'s input type, the LSP
   sketch) get the same marking.
4. **Architecture and vocabulary.** Add `Typecheck` to
   `architecture.md`'s pipeline narrative (between lowering and
   translation). Add `Lower`, `Typecheck`, `Translate`, and
   `Physical plan` entries to `ubiquitous-language.md`, plus a short
   mapping of surface names to IR names (`restrict` → `Restrict` →
   `Filter`).
5. **SQL doctests (TDD).** Failing unit tests first in
   `test/integration/test_doctest.ml`: a block whose first non-blank
   line starts with `sql> ` is a session on the SQL surface. Then
   teach `doctest.ml` per-block prompt detection — each session
   carries its surface, `capture_repl_output` and `split_outputs`
   use the matching prompt marker, and verification passes
   `~surface:` to `Repl.run`. Add `docs/reference/sql` to
   `verified_files` in `test_documentation.ml` and to the
   `glob_files` deps in `test/integration/dune`; remove the
   `TODO(sql-doctest)`. Fix any SQL examples the harness flags.
6. **Plans index.** `docs/plans/README.md`: one line per slice with
   status (done / in progress / superseded-by). No per-plan metadata
   headers — the index is the single place status lives, so closing
   a slice means one edit.
7. **Promote the executor design.** `internals/executor.md` from
   plan 06: why LMDB cursor scoping forces CPS, why
   `Map.to_dispenser` and friends don't work, the right-side
   materialisation tradeoff, how the `eval_*` modules compose.
   Banner at the top of plan 06 pointing here; retarget the
   `ubiquitous-language.md` link from the plan to the new doc.
8. **Promote the optimization design.** `internals/optimization.md`
   from plans 08 + 09: conjunct recognition and the fold-vs-residual
   split for point lookups; the indexed-nested-loop-join shape,
   `inner_position`, tiebreakers, and the syntactic-equivalence
   invariant. Banners on both plans.
9. **Promote the SQL frontend design.** `internals/sql-frontend.md`
   from plan 28: the parse/lower separation, why lowering targets the
   same `Logical.t`, why `SELECT *` is identity (no Project node),
   the result-renderer design. Banner on plan 28.
10. **Storage internals.** `internals/storage.md`: the LMDB key
    format and byte-comparability requirement, row encoding (Marshal,
    and that it's a known limitation), how the catalog persists, and
    the transaction/cursor lifetime story behind the lazy `Seq.t` —
    mined from the `storage/` and `execution/` `.mli` docs and the
    cursor-scoping material in plan 06 / `executor.md`.
11. **Query lifecycle walkthrough.** `internals/query-lifecycle.md`:
    `users | restrict active | project name` traced text → AST →
    `Logical.t` → typecheck → `Physical.t` → CPS evaluation →
    rendered relation, using real `--show-logical` /
    `--show-physical` output captured from the binary. States
    up front that its examples are hand-checked, and why. Cross-link
    from `architecture.md`. This closes the roadmap's "internals
    walkthrough" item — update the README roadmap to match.
12. **Tutorial: tables chapter.** `tutorial/tables.md`: create table
    → insert → query it → drop, introducing relation/row/scalar
    literals and the `catalog` and `type` operators along the way.
    Doctested automatically via the existing tutorial glob.
13. **Tutorial: SQL leg.** `tutorial/sql.md`: the walkthrough's final
    query rewritten in SQL, showing both surfaces drive the same
    engine; link from `tutorial/README.md` and `docs/README.md`.
    Doctested via step 5's `sql> ` support (extend the tutorial glob
    handling if the harness assumed RA-only there).
14. **Reference polish.** Add an error example to the RA pages where
    errors are part of the contract (`restrict`, `project`, `join`,
    `create-table`, `insert-into` at minimum) — error output is
    plain REPL output, so these doctest like any other example. Add
    the keyword case-sensitivity note to `reference/ra/README.md`.
    Give `projections.md`'s bare-vs-qualified duplicate quirk a
    worked example and a TODO marker per conventions. Note
    short-circuiting in `sql/boolean-operators.md`.
15. **odoc build.** Add odoc to the dev dependencies and make
    `dune build @doc` part of the verified workflow; fix any markup
    warnings it surfaces. Mention the command in the README's
    building section.
16. **Workflow rule + final sweep.** Add the promotion rule to
    `CLAUDE.md` (closing a slice includes promoting durable design
    rationale out of the plan, and adding the plan's line to
    `plans/README.md`). Final link sweep across `docs/` and
    `README.md`.

## Verification

- The `dune runtest -w` watcher stays green through every step. After
  step 5 the `documentation` suite covers `reference/sql/` too; new
  tutorial chapters (steps 12–13) are picked up by the existing
  globs, so every new example is machine-verified from the moment it
  lands.
- Step 5's TDD gate: the new `test_doctest.ml` cases fail before the
  `doctest.ml` change and pass after.
- Status banners: `rg -L "^\*\*Status" docs/design docs/archive`
  (or equivalent) shows every file carrying one after step 2/3.
- Promoted docs: `rg -n "plans/" docs/internals docs/tutorial
  docs/reference README.md` returns nothing after step 7 — live docs
  no longer depend on plan files.
- `dune build @doc` completes without warnings after step 15.
- Manual link sweep at step 16: `rg -n '\]\(' docs README.md` and
  spot-resolve relative targets, excluding frozen plans.
