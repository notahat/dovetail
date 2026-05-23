# 18 — Slice 18: Rename `Value` → `Scalar` and `data` → `value`

Align the `lib/core/` vocabulary with the surface language committed
to in [`docs/type-system.md`](../type-system.md). The ladder's
bottom-rung module becomes `Scalar` (no longer `Value`), and the
"data" half of every rung becomes `value`. After this slice, the code
and the surface speak the same words at every rung, with `kind` as
the one documented internal-only term (forced by OCaml's `type`
keyword).

No behaviour changes. Pure rename, compiler-guided.

## Context

`docs/type-system.md` commits to user-facing vocabulary that maps the
ladder onto two patterns: `name: type` for the static-shape half and
`name = value` for the payload half. The internal code calls these
`kind` and `data` respectively. The `kind` → `type` split is forced
(OCaml reserves `type`), and the
[CLAUDE.md naming subsection](../../CLAUDE.md) documents it. The
`data` → `value` split is not forced — `value` is a legal identifier
— and exists only as historical residue from before the surface
language existed.

The natural surface-side names are `Row.value`, `Relation.value`,
`Catalog.value`. The wart is at the leaf: a `Value` module exporting
a `value` type produces `Value.value`, which is honest but redundant.
The fix folded in here is to rename the `Value` module itself to
`Scalar`. The rung is genuinely scalar-vs-composite — one cell vs an
ordered row vs a stream of rows — so the name fits, and the rename
removes the only naming awkwardness the field-rename would otherwise
introduce.

[`type-ladder.md`](../type-ladder.md) is the documented exception:
it describes the as-built code shape and uses `kind` and (after this
slice) `value`, with the `Scalar` module name updated throughout.

## Goal

End-state vocabulary in `lib/core/`:

```ocaml
module Scalar = struct
  type kind  = Int64 | String | Bool
  type value = Int64 of int64 | String of string | Bool of bool
  (* no Scalar.t — the rung still has no carrier, same as today *)
end

module Row = struct
  type field = { name : string; kind : Scalar.kind; qualifier : string option }
  type kind  = field list
  type value = Scalar.value array
end

module Relation = struct
  type refinement = Primary_key of string list
  type kind  = { row_kind : Row.kind; refinements : refinement list }
  type 'tag t = { kind : kind; value : Row.value Seq.t }
    constraint 'tag = [< `Set | `Bag ]
end
```

`Catalog` is not part of `lib/core/` today; nothing needs renaming
there in this slice.

Files renamed:
- `lib/core/value.ml`  → `lib/core/scalar.ml`
- `lib/core/value.mli` → `lib/core/scalar.mli`
- `lib/core/dune` module list updated

Architectural docs updated to the new vocabulary:
- `docs/type-ladder.md`
- `docs/architecture.md`
- `docs/literals-as-a-ladder.md`
- `docs/type-system.md`
- `docs/ubiquitous-language.md`

Old slice plans (`docs/plans/00-…` through `17-…`) are *not* updated
— they are historical records of what was true at the time. Same
policy as the tuple → row rename (`3dada70`).

## Decisions

- **Module name: `Scalar`** (not `Datum`, `Atom`, `Primitive`). The
  rung is scalar-vs-composite; "Scalar" reads correctly without
  suggesting a specific representation. Confirmed in conversation.
- **Staged across multiple commits**, not one. Each step ends with a
  passing build and tests, and a sensible reader can read each commit
  on its own. The module rename and the field rename are
  conceptually distinct moves, so they merit separate commits.
- **Module rename first, field rename second.** This avoids a middle
  state with `Value.value` on disk. After step 1 we have
  `Scalar.data` (fine to read); after step 2 we have `Scalar.value`
  (final form).
- **TDD does not apply.** Pure rename with no behaviour change. The
  watcher's green light and the existing test suite are the gate.
- **No retroactive update of old slice plans.** Architectural docs
  describing current state get the new vocabulary; historical slice
  plans keep their original words.

## Steps

### Step 1 — Rename `Value` module to `Scalar`

`lib/core/value.{ml,mli}` → `lib/core/scalar.{ml,mli}`. Update the
module list in `lib/core/dune`. Sweep every `Value.` reference (~454
across ~52 files) to `Scalar.`. Update every `module Value =
Dovetail_core.Value` alias (~20 sites) to
`module Scalar = Dovetail_core.Scalar` and the corresponding `Value.`
prefixes inside those files. Update doc comments referring to
"Value" (the rung name, when used as a name rather than a generic
word) to "Scalar".

After this step the surface state is: `Scalar.kind`, `Scalar.data`,
`Row.data`, `Relation.t.data`. Project builds, tests pass.

### Step 2 — Rename `Scalar.data` → `Scalar.value`

Rename the `data` type in `lib/core/scalar.mli` and `scalar.ml` to
`value`. Update every `Scalar.data` reference across the project to
`Scalar.value`. This includes the type position inside `Row.data`'s
right-hand side, which becomes `Scalar.value array` — the
`Row.data` name itself stays for now.

After this step: `Scalar.value`, `Row.data` (typed `Scalar.value
array`), `Relation.t.data` (typed `Row.data Seq.t`). Build and tests
green.

### Step 3 — Rename `Row.data` → `Row.value`

Rename the `data` type in `lib/core/row.mli` and `row.ml` to `value`.
Update every `Row.data` reference to `Row.value`. This includes the
type position inside `Relation.t`'s `data` field, which becomes
`Row.value Seq.t` — the field is still named `data` for now.

After this step: `Scalar.value`, `Row.value`, `Relation.t.data`
(typed `Row.value Seq.t`). Build and tests green.

### Step 4 — Rename `Relation.t`'s `data` field → `value`

Pure record-field rename. Update the field declaration in
`relation.mli` and `relation.ml`, then chase the compiler through
every pattern match that destructures the field and every
construction that names it. The type on the right-hand side
(`Row.value Seq.t`) is already correct from step 3.

The compiler catches every type-level and field-level reference. The
manual eyeball pass is for `let data = ...` local bindings that are
unrelated to the field — grep for `data` after the sweep and confirm
remaining hits are intentional.

After this step the surface state is final: `Scalar.kind`,
`Scalar.value`, `Row.value`, `Relation.t.value`. Build and tests
green.

### Step 5 — Update architectural docs

Pass over the five doc files listed in **Goal**. The substantive
update is `type-ladder.md`, which describes the as-built shape
verbatim — every code block and surrounding sentence changes.
`architecture.md`, `literals-as-a-ladder.md`, `type-system.md`, and
`ubiquitous-language.md` get lighter touch-ups where they reference
`Value.` or `data` by name.

Old slice plans in `docs/plans/00-…` through `17-…` are untouched.

Step 5 is documentation-only; no rebuild needed beyond formatting.

### Out of scope

- **Adding `Catalog` to `lib/core/`.** The catalog rung is still
  storage-only; `lib/storage/catalog.ml` is unchanged. The
  ladder-framework slice (17) was explicit about deferring this and
  nothing in the type-system design changes that.
- **`Scalar.t`.** The leaf rung has no carrier today and doesn't
  need one. Adding `Scalar.t` would only make sense if values needed
  to be passed around without their kind being recoverable from the
  constructor — they don't.
- **`*.t` renames at other rungs.** `Row` and `Relation` keep their
  current `t` conventions (no `Row.t`; `Relation.t` exists and pairs
  kind with value). The `t` story is settled.
- **Surface-language changes.** Nothing in the parser, lowering, or
  evaluation changes. The pipe-style syntax committed to in
  `type-system.md` is a separate slice.
- **`ubiquitous-language.md` rewrites beyond the rename.** The doc
  may want a fuller entry on the kind/type and (now) the data/value
  alignment, but that's a documentation pass, not part of this
  rename.

## Sizing

Single sitting; mechanical with a small number of judgment-call
spots. Step 1 is the largest by reference count (~454) but the most
uniform — a single module-name sweep with the alias lines as the
trickiest part. Steps 2, 3, and 4 are progressively smaller — Scalar
references first, then Row, then the Relation field rename, each
naturally bounded by the type it touches. Step 4 carries the only
record-field destructure ripple. Step 5 is documentation.

Each step ends with the dune watcher green and the test suite passing
before commit, per the project's per-step rule.
