# Type ladder

The shape that the `lib/core/` modules — `Scalar`, `Row`, `Relation` —
follow, and the rules for adding to it. Pairs with
[`literals-as-a-ladder.md`](literals-as-a-ladder.md), which sketches
the design; this file describes what got built.

## The rungs

Four rungs, each composing the one below:

| Rung       | Shape          | Carrier     |
| ---------- | -------------- | ----------- |
| `Scalar`   | a single typed value          | `kind` + `value` |
| `Row`      | an ordered list of values     | `kind` + `value` |
| `Relation` | a stream of rows, plus refinements on the contents | `kind` + `value` + `t` |
| `Catalog`  | a named collection of relations, plus cross-table refinements | `kind` + `value` + `t` (not yet built as a value) |

At each rung the vocabulary is the same:

- **`kind`** is the static shape — what something is, with no payload.
- **`value`** is a payload at that shape — the actual contents.
- **`t`** is the carrier that pairs a `kind` with its `value`.

The uniformity is the point. Once a reader knows what `kind` and `value`
mean at one rung, they know what to look for at every other rung; new
operators and conversions name themselves the same way at any level.

`kind` is the documented internal exception to the
[surface/internal vocabulary split](type-system.md): user-facing
strings say "type", but OCaml reserves `type` as a keyword, so the
code side calls it `kind`. The payload half is `value` on both sides.

## Per-rung detail

### `Scalar` ([`lib/core/scalar.mli`](../lib/core/scalar.mli))

```
type kind = Int64 | String | Bool
type value = Int64 of int64 | String of string | Bool of bool
```

A `Scalar.kind` is one of three tags; a `Scalar.value` is the same tag
with a payload. The two share constructor names so OCaml's
type-directed disambiguation usually picks the right one without
annotation.

There is no `Scalar.t`. A scalar *is* its own carrier — pairing a
`Scalar.value` with its `Scalar.kind` adds no information
(`Scalar.kind_of` recovers the kind in one step), so the rung stops
at `kind` and `value`.

### `Row` ([`lib/core/row.mli`](../lib/core/row.mli))

```
type field = { name : string; kind : Scalar.kind; qualifier : string option }
type kind = field list
type value = Scalar.value array
```

A `Row.kind` is an ordered list of named, typed, optionally-qualified
fields. A `Row.value` is the cells themselves, in field order; an array
so column lookups are O(1) on the hot path.

There is no `Row.t` either. A row is consumed in the context of a
relation, which already pairs the kind with each row's value — pairing
them per-row would just inflate the working set.

### `Relation` ([`lib/core/relation.mli`](../lib/core/relation.mli))

```
type refinement = Primary_key of string list
type kind = { row_kind : Row.kind; refinements : refinement list }
type 'tag t = { kind : kind; value : Row.value Seq.t }
  constraint 'tag = [< `Set | `Bag ]
```

A `Relation.kind` is a `Row.kind` plus a list of refinements that
constrain the contents beyond the row shape. A `Relation.t` is a
`kind` paired with a lazy `Seq.t` of rows in that shape.

This is the rung where `t` earns its keep. A relation's row sequence is
useless without its kind: callers need the field list to interpret
positions, and downstream operators need the refinements to know
whether they can rely on primary-key uniqueness. The phantom `'tag`
distinguishes set from bag semantics so the type system can reject
combinations that would silently change them.

### `Catalog` ([`lib/storage/catalog.mli`](../lib/storage/catalog.mli))

A catalog is the database one rung up: a named collection of relations
plus the cross-table refinements (foreign keys, …) that constrain how
those relations relate to one another. The framework shape it will
eventually take:

```
type refinement = Foreign_key of { ... } | ...
type kind = { table_kinds : (string * Relation.kind) list; refinements : refinement list }
type value = (string * [ `Bag ] Relation.t) list
type t = { kind : kind; value : value }
```

Only the kind side exists today, and it is implicit. `Storage.Catalog`
is an imperative shell over LMDB — `get` / `put` / `list_table_names`
/ `delete` — operating on a persistent map from table name to
`Relation.kind`. No cross-table refinements are tracked yet, so the
kind is effectively just the named map; no `Catalog.kind` record
type names it. The value side does not exist at all: the rows
themselves live in per-table storage subDBs, accessed through
`Engine` rather than through any catalog-shaped value.

The rung is named here because the framework expects it, and because
several near-term features (foreign keys, database literals,
multi-table diffs) want a value to talk about. The shape above is the
target; today's `Storage.Catalog` is the as-built starting point.

## Refinements

`Relation.refinement` is the open-ended part of the kind. Today there
is one constructor — `Primary_key of string list` — but the list shape
is deliberate: each new refinement is a new constructor, not a new
field on the record. The pattern for adding one:

1. Add the constructor (`Unique of string list`, `Check of Expression.t`,
   `Cardinality of int`, …).
2. Update the catalog codec if the refinement is persisted.
3. Teach the operators that care about it; operators that don't care
   pass refinements through.

Derived relations — projection, cross product, join — drop refinements
by default (the result list is empty). They cannot in general preserve
the input's primary key or uniqueness claims, so the conservative
choice is to forget. An operator that *can* prove a refinement still
holds is free to copy it through; none do yet.

The same pattern applies one rung up: `Catalog`'s refinements
constrain how its relations relate to one another (foreign keys,
cross-table check expressions, …) rather than constraining a single
relation's contents. None exist yet; the constructor list is empty
until the first cross-table constraint arrives.

## Literals

The ladder framing came from asking what a *literal* at each rung
would look like (see [`literals-as-a-ladder.md`](literals-as-a-ladder.md)).
The realized literals so far:

- **Scalar literal** — `42`, `"alice"`, `true`. Appears in expression
  position (a predicate's right-hand side, a projected value) and as a
  pipeline source in its own right; the latter parses straight into
  `Ast.Scalar_literal` and threads through `Logical.Scalar_literal` /
  `Physical.Scalar_literal` to `Term.Scalar_value`.
- **Row literal** — the named-field tuple form `(name = value, ...)`,
  e.g. `(id = 1, name = "alice", active = true)`. Used as the rows
  inside a relation literal, and on its own as a pipeline source that
  yields a single row; the standalone form threads through
  `Ast.Row_literal` → `Logical.Row_literal` → `Physical.Row_literal`
  → `Term.Row_value`.
- **Relation literal** — the typed form
  `relation (id: int64, name: string) { (id = 1, name = "alice"), ... }`.
  The `relation (...)` head declares the relation's kind (row fields
  plus any refinements); the brace-delimited body is a comma-separated
  list of row literals validated against that kind during lowering.
  Lowers to `Logical.Relation_literal { kind; rows }` and on to
  `Physical.Relation_literal`.

- **Catalog literal** — DDL as text that denotes a catalog value:
  sketched in [`literals-as-a-ladder.md`](literals-as-a-ladder.md),
  not built. Today's `create table` / `drop table` are catalog
  *mutations*, not a literal form; a catalog literal would name a
  whole catalog value the way a relation literal names a whole
  relation value.
