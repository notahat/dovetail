# 04 — Slice 4: Cross product (×)

The fourth vertical slice. End-state: typing `users | cross orders` at
the REPL yields every (user, order) pair, and
`users | cross orders | restrict users.id = orders.user_id` filters to
the matched ones.

This slice ships cross product on its own; inner join (`Join` operator,
`join...on` surface) lands in slice 5. The two were originally grouped
in `00-initial-plan.md` but have been split so each slice has one clear
demo and a focused step list. Slice 3 (projection) shipped before
this slice, as the original ordering required.

The other big move in slice 4 is the predicate sublanguage's first real
extension since slice 2: column-vs-column comparisons and qualified
column references. Cross product produces results with same-name
columns coming from different relations (both `users` and `orders`
have an `id` column) — qualified refs are how the user disambiguates
them.

## Goal

```
> orders
| orders.id | orders.user_id | orders.description | orders.amount |
|-----------|----------------|--------------------|---------------|
|         1 |              1 | Coffee             |             5 |
... 6 rows ...

> users | restrict name = email
... 0 rows; smoke-tests unqualified column = column ...

> users | restrict users.id = 3
| users.id | users.name | users.email       | users.active |
|----------|------------|-------------------|--------------|
|        3 | Carol      | carol@example.com | true         |

> users | cross orders
... 30 rows; combined schema with qualified columns from both inputs ...

> users | cross orders | restrict users.id = orders.user_id
... 6 rows: matched (user, order) pairs ...
```

Error cases reach the REPL and don't crash it:

```
> users | cross orders | restrict id = 3
error: Predicate.resolve: ambiguous column reference "id":
  matches "users.id" and "orders.id"

> users | restrict orders.id = 3
error: Predicate.resolve: unknown column "orders.id"
```

Everything from earlier slices keeps working.

## Slice-4 architectural decisions

### Slice scope

Cross product only. Inner join (`Join` operator) is slice 5. The split
keeps each slice to ~4 steps with a single end-to-end demo: slice 4
ships the multi-relation foundation (fixture, predicate evolution,
cross product), slice 5 ships the dedicated `Join` operator on top of
it.

### IR shapes

```ocaml
(* Ast *)
| CrossProduct of { left : t; right : t }

(* Logical *)
| CrossProduct of { left : t; right : t }

(* Physical *)
| CrossProduct of { left : t; right : t }
```

Same constructor name in all three layers, mirroring the convention
slice 3 set with `Project`. Cross product has one execution strategy
(nested loop), so there's no strategy-naming distinction to make. When
slice 5 adds `Physical.NestedLoopJoin`, the asymmetry between
`CrossProduct` and `NestedLoopJoin` will reflect reality — join has
multiple strategies on the roadmap (hash, merge), cross product
doesn't.

### Predicate evolution

Two-step. Step 2 introduces `term` with plain-string columns; step 3
restructures the column reference into a qualified shape:

```ocaml
(* After step 2 *)
type term = Column of string | Literal of Value.t
type t = Compare of { left : term; op : op; right : term }

(* After step 3 *)
type column_reference = { qualifier : string option; name : string }
type term = Column of column_reference | Literal of Value.t
```

Step 2's plain-string column is deliberate: the qualifier doesn't earn
its keep until step 3 introduces the parser path and resolution
machinery for it. We pay a small refactor cost (`Column of string` →
`Column of column_reference` plus a few call sites) to keep step 2 as
small as it can be, in line with the project's "don't pre-shape for
known-but-not-yet-needed features" stance.

### Schema with qualifiers

```ocaml
type field = { name : string; kind : Value.Kind.t; qualifier : string option }
```

`Scan { table }` populates each field's qualifier with `Some table`.
Cross product preserves both inputs' qualifiers — the result schema is
`left.fields ++ right.fields` with each field carrying the qualifier
it had on its way in.

### Resolution rule

`Predicate.resolve` calls into a generalised `Schema.find_field` that
takes the predicate's optional qualifier:

- **Qualified ref** (`Some q, name`): match the unique field whose
  `qualifier = Some q` and `name = name`. Error if no such field.
- **Unqualified ref** (`None, name`): match by name. If exactly one
  field has that name, use it. If multiple, error with a message
  naming the conflicting qualifiers
  (`ambiguous column reference "id": matches "users.id" and "orders.id"`).

This is the SQL behaviour. Single-relation queries written without
qualifiers keep working — they only become ambiguous after a cross
product introduces a second relation with overlapping names.

### Primary keys on intermediate results

`primary_key = []` for the cross-product result, following the
convention slice 3 set with `Projection.resolve`: derived schemas
don't carry primary-key information at this point in the project. PK
info is only meaningful for base tables today (used by `Scan` to
decode keys); intermediate-result PKs aren't queried by any operator
yet, so empty-list is honest. The right time to revisit is when
`IndexScan` (slice 6) or the optimiser starts wanting PK info on
non-base relations.

### Surface syntax

`users | cross orders` — `cross` is a new pipeline keyword, parsed
the same way as `restrict`. Right-hand side is a relation reference
(slice-2 grammar; nesting and sub-pipelines aren't in scope here).

The dotted form for qualified column refs is `<id>.<id>` with no
whitespace allowed around the dot; this disambiguates from a future
floating-point literal grammar without committing to one now.

### Eval implementation

Nested-loop product, with the right side materialised once:

```ocaml
| CrossProduct { left; right } ->
    let left_relation = eval environment transaction left in
    let right_relation = eval environment transaction right in
    let right_tuples = List.of_seq right_relation.tuples in
    let combined_tuples =
      Seq.flat_map
        (fun left_tuple ->
          List.to_seq right_tuples
          |> Seq.map (fun right_tuple ->
                 Array.append left_tuple right_tuple))
        left_relation.tuples
    in
    let combined_schema =
      { fields = left_relation.schema.fields @ right_relation.schema.fields
      ; primary_key = []
      }
    in
    { schema = combined_schema; tuples = combined_tuples }
```

Materialising the right side avoids re-opening LMDB cursors per
left-tuple. Streaming the right would require either re-evaluating the
right sub-plan from scratch each time (expensive and awkward across
operators) or threading cursor reset through `Storage`. With our
6-row orders fixture the memory cost of materialisation is nothing,
and the slice-1 storage abstraction stays unchanged.

### Set/Bag preservation

Cross product preserves the multiplicity tag, matching the rule slice
3 recorded for `Filter` (slice 3 separately downgraded `Project` to
`Bag` because dropping columns can introduce duplicates; cross product
does not have that property). Slice 4's `Eval` continues returning
`` [`Bag] `` because nothing yet produces sets — the principle is
recorded in prose so slice 8 (set/bag operators) doesn't trip on it.

## Sub-steps

Four steps. Each is one commit, with tests, leaving the project in a
working state and (from step 1 onward) with a runnable REPL
improvement.

### 1. Add `orders` fixture

`Fixture` gains an `orders_schema`, `orders_rows`, an
`encode_orders_row`, and an extension to `populate_if_empty` to write
the orders subDB and catalog entry on first run.

Schema (4 columns, single-column int64 PK; mirrors `users`):

- `id : Int64` (PK) — *intentionally* conflicts with `users.id` to
  exercise qualified refs and disambiguation.
- `user_id : Int64` — references `users.id`.
- `description : String`.
- `amount : Int64`.

Rows (6 rows; Dave deliberately has no orders, Alice and Carol each
have two):

```
(1, 1, "Coffee",   5)   — Alice
(2, 1, "Bagel",    4)   — Alice
(3, 2, "Tea",      3)   — Bob
(4, 3, "Sandwich", 8)   — Carol
(5, 3, "Cake",     6)   — Carol
(6, 5, "Cookie",   2)   — Eve
```

Cross product is then 5 × 6 = 30 rows; the future inner-join match
set is 6 rows.

Tests: `test_fixture.ml` grows with orders parallels of the existing
users tests (schema written, rows written, idempotent, raw-bytes
roundtrip). `test_helpers.ml` gains `expected_orders_rows`.

End state: typing `orders` at the REPL prints the six rows.

### 2. Unqualified column = column

`Predicate.t` generalises:

```ocaml
type term = Column of string | Literal of Value.t
type t = Compare of { left : term; op : op; right : term }
```

`Predicate.resolve` evaluates either side: `Literal` is the literal
value; `Column name` looks the column up in the schema (still by name
only — qualifiers come in step 3) and reads the corresponding tuple
position. The position cache extends to "one cached position per
`Column` operand".

Parser: the predicate combinator reads two `term`s (column or literal)
either side of the operator. The grammar disambiguates by lookahead in
the same style as the literal parser.

Tests: `test_predicate.ml` and `test_parser.ml` get column=column
cases. `users | restrict name = email` (zero rows; smoke test) and
`orders | restrict id = user_id` (matches the two orders where the
order's id equals the user_id, modulo the actual fixture data; the
exact count depends on the fixture but exercises the int64 path).

End state: `users | restrict name = email` and `orders | restrict
id = user_id` parse, evaluate, and return the right rows.

### 3. Qualified column references

The meaty step. Combined into one because the structural change
(`Schema.field` qualifier) has no testable user-visible behaviour on
its own and is tightly coupled to the parser/Predicate/Eval feature
work.

- `Schema.field` gains `qualifier : string option`.
- `Schema.find_field` evolves: signature changes to take an optional
  qualifier (or a `column_reference`-shaped argument) and applies the
  resolution rule (qualified = match exact; unqualified = match by
  unique name, error on ambiguity, error on unknown).
- `Fixture` sets `qualifier = Some "users"` / `Some "orders"` on its
  schemas. Catalog serialisation is `Marshal`-based, so no encoding
  change.
- `Predicate.t`'s `Column` term restructures to carry
  `column_reference = { qualifier : string option; name : string }`.
- `Projection.t` restructures the same way: from `string list` to
  `column_reference list`. Both column-ref-carrying types make the
  jump together so the parser, the IR, and the resolver agree on a
  single shape. Slice 3's plan flagged this refactor as a bullet
  belonging to slice 4 step 3.
- `Parser` parses `<id>` as unqualified and `<id>.<id>` as qualified;
  no whitespace allowed around the dot. Both `predicate` and
  `project_columns` reuse the new `column_reference` parser.
- `Predicate.resolve` and `Projection.resolve` both call into the
  generalised `Schema.find_field` with the term's qualifier,
  propagating the disambiguation error with a clear message naming the
  conflicting qualifiers.

Tests: `test_schema.ml` covers `find_field` resolution rules
(qualified hit; unqualified unique hit; unqualified ambiguous error;
unknown-column and unknown-qualifier errors). `test_predicate.ml`,
`test_projection.ml`, `test_parser.ml` get qualified-form cases. The
slice-2/3 unqualified-resolves-uniquely path keeps working unchanged
for single-relation queries.

End state: `users | restrict users.id = 3` and `users | project
users.name` parse and evaluate identically to their unqualified
forms. (Ambiguity tests come in
step 4 once cross product introduces a real ambiguity case.)

### 4. Cross product

`Ast.CrossProduct`, `Logical.CrossProduct`, and
`Physical.CrossProduct`, all `of { left : t; right : t }`. `Lower` and
`Translate` recurse into both sides. `Eval` implements nested-loop as
sketched in *Eval implementation* above, materialising the right side.

Parser: `cross` joins `restrict` and `project` as a pipeline-step
alternative, `whitespace *> "cross" *> whitespace *> relation_name`.
Use the `keyword` helper so a column or relation called `crossroads`
doesn't accidentally trigger the keyword.

Tests: `test_translate.ml`, `test_lower.ml`, `test_eval.ml`,
`test_parser.ml` all grow a cross-product group. The end-to-end
integration test parses
`users | cross orders | restrict users.id = orders.user_id` and
asserts the expected six rows. Ambiguity test:
`users | cross orders | restrict id = 3` errors with the ambiguity
message (both inputs have an `id` column).

After step 4, run the binary manually to confirm the demos from the
Goal section. Update `README.md`'s layer diagram example and the
`Ast`/`Logical`/`Physical` rows in the layers table to mention cross
product (slice 3 already added the `Ast` row alongside `Logical` and
`Physical`).

End state: the demo from the Goal section works end-to-end via the
REPL.

## Open questions

Captured here as they come up; resolved at end of slice.

- (none currently)
