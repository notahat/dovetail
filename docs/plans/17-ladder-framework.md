# Slice 17: Apply the ladder framework

Refactor `lib/core/` so the type vocabulary matches the conceptual
ladder developed in
[`docs/literals-as-a-ladder.md`](../literals-as-a-ladder.md): at each
rung of the data model (value, row, relation, catalog) there is a
*kind* type describing shape, a *data* type holding values, and where
useful a *bundled* `t` type pairing them. No behaviour changes. No
new refinements or invariants beyond what `Schema.t` already encodes
(primary key); those land in a later slice.

Slice number is provisional — if SQL frontend stays as the next slice,
renumber this to whatever follows it. The work is independent of the
SQL frontend and could land before or after.

## Context

Today, `lib/core/schema.ml` carries the framework's `Row.kind` (the
field list) and `Relation.kind` (the field list plus the primary key
as the one refinement) bundled in a single `Schema.t`. `Schema.tuple
= Value.t array` is the row data. `Relation.t = { schema; tuples; tag
}` is the bundled relation. There is no separate refinement type —
the primary key is a hardcoded field. There is no `Catalog.kind` in
`core`;
`lib/storage/catalog.ml` exposes operations on the on-disk catalog but
no value-shaped in-memory description.

The scratch exploration in `scratch/ladder.ml` settled on the
following shape:

```ocaml
module Value    = struct  type kind / type data           end
module Row      = struct  type kind / type data           end
module Relation = struct
  type refinement
  type kind = { row_kind : Row.kind; refinements : refinement list }
  type data = Row.data list (* or Seq.t in reality *)
  type t    = { kind; data }
end
module Catalog  = struct
  type invariant
  type kind = { relation_kinds : ...; invariants : invariant list }
  (* data and t deliberately absent: catalog data lives on disk *)
end
```

The migration is mostly rename-and-factor of an already-correct shape,
not a structural rewrite.

## Goal

End-state artefacts in `lib/core/`:

1. `Value` module renamed to use the framework vocabulary:
   `Value.Kind.t` becomes `Value.kind` (submodule flattened away);
   `Value.t` becomes `Value.data`. No `Value.t` — Value doesn't
   need a bundled form because each value already carries its kind
   via its constructor tag.
2. New `Row` module with `Row.kind` (field list with qualifier) and
   `Row.data` (the array previously named `Schema.tuple`).
3. `Schema` renamed and refactored into `Relation` with:
   - `type refinement = Primary_key of string list` (nested, single
     starting constructor)
   - `type kind = { row_kind : Row.kind; refinements : refinement list }`,
     replacing the hardcoded `primary_key` field on `Schema.t`
   - `type data = Row.data Seq.t` (preserving today's `tuples`
     stream shape)
   - `type 'tag t = { kind; data } constraint 'tag = [< `Set | `Bag ]`,
     preserving the phantom tag
4. Every consumer (`lib/`, `bin/`, `test/`) updated to the new names.
5. `docs/architecture.md` notes the new vocabulary.

The catalog rung is deliberately not part of this slice. Unlike the
row and relation rungs, `Catalog.kind` and `Catalog.invariant` have
no existing equivalent in the code — there's no in-memory value
that aggregates the catalog today; `lib/storage/catalog.ml` is a
persistent map accessed entry-by-entry. Creating those types now,
with no caller, would be building abstractions for hypothetical
future use. They land in whichever later slice first needs them
(catalog-level invariant enforcement, catalog literals, or
dump/load).

No behaviour changes anywhere. The phantom set/bag tag, the
qualifier semantics, the persistence path, the parser, and every
operator behave identically.

Excluded from this slice: new refinement constructors (`Unique`,
`Check`, `Functional_dependency`, etc.), validation enforcement, the
entire catalog rung (`Catalog.kind`, `Catalog.invariant`, foreign-
key enforcement), and any catalog-literal print/parse. Those are
the framework *paying off*; the slice's job is making them
inexpensive to add later.

## Decisions

Resolved during the grill-me pass before step 1.

1. **Module shape: `Relation.kind`.** Each rung is one module
   containing co-equal types `kind`, `data`, and (where useful) `t`.
   Matches the scratch. The project's `.t` convention says a
   module's *primary* type is `t`, which doesn't preclude sibling
   types alongside; `Value.Kind.t` already coexists with `Value.t`
   in the existing code, so the pattern is already in use.

2. **Column qualifier stays on `Row.kind`'s field.** Identical to
   today's `Schema.field.qualifier : string option`. Optional;
   `None` for unjoined relations; scan stamps in `Some table_name`.
   No new type machinery.

3. **Set/bag tag stays as a phantom on `Relation.t`.** Identical to
   today. The phantom does static work that runtime refinement
   values can't replicate, so folding it into the framework would
   regress. `Relation.t` retains its `'tag` parameter; the
   framework lives underneath.

4. **`Row.data = Value.t array`.** Identical to current
   `Schema.tuple`. Array gives O(1) positional lookup, which the
   hot path (Eval, the codec) relies on. Scratch used `list` for
   readability only.

5. **`refinement` nested inside `Relation`.** The scratch's shape,
   not a separate `Refinement` module. The type starts with one
   constructor (`Primary_key`); if it grows complicated enough to
   warrant pulling out later, we'll do it then.

6. **Alias-during-migration, not hard rename.** Introduce
   `Relation.kind` as an alias of `Schema.t` early, migrate
   references piecemeal (likely one sub-library per commit during
   step 4), delete `Schema.t` only when nothing references it.
   Same shape as slice 16's storage shim pattern, chosen for the
   same reviewability reason. Same approach is used for the
   `Value` rename in step 1.

7. **`Value` renames too, for framework consistency.** Going
   halfway on consistency would leave `Value` as the framework's
   one exception. The rename is `Value.Kind.t` → `Value.kind`
   (submodule flattened) and `Value.t` → `Value.data`. The
   resulting constructor-name overlap (`Int64`, `String`, `Bool`
   defined for both `kind` and `data` in the same module) is
   handled by OCaml's type-directed disambiguation in essentially
   every realistic call site; the rare bare-list case
   (`[Int64; String]` without a type annotation) needs an
   annotation. This is small and bounded.

## Steps

### Step 1 — Rename `Value` to use `{kind, data}`

The Value rename is end-to-end before any of the Schema work starts,
because everything below it (rows, refinements, relation kinds)
references `Value.kind` and `Value.data` in their type signatures.
Doing it first means subsequent steps can be written in the new
vocabulary directly.

Three sub-commits inside this step:

- **1a — Add aliases.** Inside `lib/core/value.ml/mli`, add:

  ```ocaml
  type kind = Kind.t = Int64 | String | Bool
  type data = t = Int64 of int64 | String of string | Bool of bool
  ```

  These are *type-and-constructor* re-exports: `Value.kind` and
  `Value.Kind.t` become the same type with the same constructors;
  `Value.data` and `Value.t` likewise. Callers can use either form
  interchangeably during the migration.

- **1b — Migrate consumers.** Replace `Value.Kind.t` with
  `Value.kind` and `Value.t` with `Value.data` across `lib/`,
  `bin/`, `test/`. Likely one sub-commit per sub-library
  (`core`, `storage`, `plan`, `ddl`, `surface_ra`, `execution`,
  `frontend`) to keep diffs reviewable.

- **1c — Remove the old names.** Delete `module Kind` and
  `type t` from `lib/core/value.ml/mli`. The new types stand on
  their own. Build green.

Tests: no new tests; the existing test suite proves equivalence.

### Step 2 — Add `Row` module

New `lib/core/row.ml/mli`:

```ocaml
type field = { name : string; kind : Value.kind; qualifier : string option }
type kind  = field list
type data  = Value.data array
```

Existing `Schema.field` and `Schema.tuple` stay; the new module
duplicates them as the framework names. Nothing rewires yet. Tests:
none new (the types are aliases of existing ones); ensure the build
stays green.

### Step 3 — Introduce `Relation.kind` (with nested `refinement`)

New types inside `Relation`:

```ocaml
type refinement = Primary_key of string list
type kind = { row_kind : Row.kind; refinements : refinement list }
```

Conversion functions to/from `Schema.t` (which still exists during
the migration). Old callers continue using `Schema.t`; new callers
can use `Relation.kind`. Tests: round-trip a few real schemas
through the conversion, plus a round-trip for `primary_key` ↔
`[Primary_key keys]`.

### Step 4 — Migrate references

Largest commit. Every `Schema.t` reference in `lib/`, `bin/`,
`test/` becomes a reference to `Relation.kind`. Cross-library
aliases (`module Schema = Dovetail_core.Schema` everywhere) get
rewritten. The conversion shims from steps 2–3 disappear as their
last consumers are updated.

Likely sub-commits inside the step if the diff is too large to
review at once, split by sub-library boundary (one commit per
consumer library).

### Step 5 — Remove `Schema`

Delete `lib/core/schema.ml/mli` and any conversion shims left from
earlier steps. At this point nothing references it. No new tests;
the build staying green is the verification.

### Out of scope

- New refinement constructors (`Unique`, `Check`, `Functional_dependency`, cardinality bounds).
- Validation: actually enforcing refinements at insert/update.
- Foreign-key enforcement: wiring `Catalog_invariant.t` into the
  storage layer so FKs are checked.
- Catalog literals: print/parse for `Catalog_kind` or any catalog
  data.
- Any change to the on-disk catalog format.

These are individual slices' worth of work each.

## Sizing

Step 1 is several sub-commits but each one is mechanical (an alias
add, then per-sub-library migrations, then a deletion). Steps 2–3
are each small (one or two new files, conversion glue, trivial
tests). Step 4 is the bulk of the work — touches every
library — but is mechanical once the new vocabulary is decided.
Step 5 is cleanup. Whole slice is probably 5–7 commits depending on
how step 4 splits.

The framework migration ends at the end of step 5. The framework
*paying off* — new refinements, FK enforcement, etc. — is later
slices.
