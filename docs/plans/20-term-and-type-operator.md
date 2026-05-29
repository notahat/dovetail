# Slice 20: Term carrier and the type operator

First substantive slice of the [type-system work](../design/type-system.md).
Introduces `Core.Term`, the unified pipeline-payload carrier; threads
it through every IR layer; lands the `type` operator at the relation
rung; retires `:describe`.

Depends on [slice 19](19-collapse-mutations-into-pipeline.md)
— the pipeline is already one universe by the time this slice runs.

## Goal

After this slice, a pipeline's evaluation result is a `Term.t`, not a
`_ Relation.t`. The user can type `users | type` to see the relation
type of `users`; the `:describe users` form goes away.

`Term.t` is the rung-aware union of "anything that flows through a
pipe or falls out the end of one." In this slice it has two arms:

```ocaml
type 'tag t =
  | Relation_value of 'tag Relation.t
  | Relation_kind  of Relation.kind
```

Other arms grow incrementally as later slices need them.

## Scope

- New module `lib/core/term.ml{,i}` defining `Term.t` (two arms) and
  `Term.format`. Renderer dispatches per arm; `Relation_kind` formats
  in the new surface syntax (`(id: int64, name: string, primary key
  (id))`).
- New kind formatter `Relation.format_kind` and any scalar/row pieces
  it needs (`Scalar.format_kind` printing lowercase keywords —
  `int64`/`string`/`bool` — replacing the capitalised
  `Scalar.kind_to_string` form in user-facing output).
- New AST node `Type of { input : t }` in `Ast.t`. New Logical
  node `Type_op` and Physical node ditto. Lower/Translate pass them
  through; they sit at the root of a pipeline only (nothing in slice
  20's grammar consumes a kind on the left).
- `Eval.eval`'s signature becomes `... -> Term.t`. The Type case
  reads the input's static `Relation.kind` (via a
  `Physical.kind_of` helper) without materialising the input — no
  cursors open, no rows pulled. Every other case wraps its relation
  result as `Term.Relation_value`.
- Parser learns one new keyword: `type` as a unary pipe operator.
- REPL's single print path dispatches on `Term.t` arms.
- `:describe` removed from `lib/ddl/`: parser rule, AST constructor,
  executor case, and any tests. `lib/ddl/` is smaller but still
  present (other `:`-statements remain).
- "type: input is already a type" error: `users | type | type` is
  rejected. Implementation lives wherever it's most natural — likely
  at the lowering boundary when the second Type_op's input is itself
  a Type_op. Test it.

## Out of scope

- Scalar / row / catalog rungs of `type`. They come online
  automatically in [slice 21](21-literal-syntax-flip.md) when
  the literal forms become valid pipeline sources, and in
  [slice 24](24-catalog-rung.md) for catalog. `Term.t` only
  grows arms for new things this slice constructs.
- Literal-syntax changes (the curly-brace relation literal stays
  as-is).
- `Core.Catalog`. Catalog rung lands in slice 24 alongside its
  consumer operators.

## Key design decisions made during planning

- **B-style threading: `Term.t` reaches into Lower/Translate/Physical.**
  Every IR layer's *output* type changes shape — though in this slice
  the only non-relation case is `Type_op`. Hybrid C (Term only at the
  Eval boundary) was considered and rejected: we want to commit to the
  unified universe sooner rather than later. See [type-system.md
  §"pipe stages across the ladder"](../design/type-system.md).
- **No GADTs for the IR.** Flat sums with the lowering pass
  responsible for producing well-formed combinations; bugs produce
  clear runtime failures rather than silent wrong behaviour. Revisit
  if the operator zoo grows enough that the type-system protection
  starts earning its cost.
- **`Term.t` lives in `lib/core/`.** Vocabulary type for the whole
  ladder; same reasoning that puts Scalar/Row/Relation there. Core
  doesn't consume Term itself; execution produces it.
- **Flat sum, nominal constructors, grow incrementally.** Pattern
  matches are grouped by face (kinds first, then values) for
  readability. Polymorphic variants and GADTs both rejected for the
  usual idiom-vs-cost reasons.
- **No `Core.Catalog` in this slice.** Slice 23 introduces it
  alongside the operators that consume it.

## Gotchas surfaced in slice 19

- **CPS continuation placement.** Changing `Eval.eval`'s return type
  from `'a` parameterised by a `Relation.t -> 'a` continuation to
  `'a` parameterised by a `Term.t -> 'a` continuation touches every
  operator. The subtle one: when an operator calls `eval` recursively
  (as `Insert` does on its `source`), `continue` must sit *inside*
  the inner eval's callback, not after it. Putting `continue` after
  constrains the outer eval's return type to whatever the preceding
  statement returns (typically `unit`), defeating polymorphism.
  Slice 19's `evaluate_insert` is the worked example. The same shape
  applies to any future operator that recurses on a sub-tree before
  handing a result downstream.

## Notes for follow-on slices

- Slice 21 grows `Term.t` by four arms (Scalar_value, Scalar_kind,
  Row_value, Row_kind) as new literal sources come online.
- Slice 22 doesn't touch `Term.t` — `create_table`/`drop_table` produce
  relation results, which fit the existing `Relation_value` arm.
- Slice 23 grows `Term.t` by two arms (Catalog_value, Catalog_kind)
  and introduces `Core.Catalog`.
- The doc's note about "type applied to a type is an error" needs a
  test in this slice. Resolved during planning: the rejection lives in
  `Lower.lower`, since that's the first layer with the full pipeline
  shape in hand and the cleanest place to emit a user-facing message
  before any IR layer carries an invariant about it.

## Steps

Nine steps. The first four are pure additions with no callers; step 5
is the one big structural change (every operator's eval call shape);
steps 6–8 build the `type` operator from helper to surface; step 9
retires `:describe`.

### Step 1 — `Scalar.format_kind` (lowercase keywords)

Add `Scalar.format_kind : Format.formatter -> kind -> unit` printing
`int64` / `string` / `bool` (lowercase). The existing
`Scalar.kind_to_string` form (`Int64` / `String` / `Bool`) stays for
now — its callers in `lib/ddl/` keep producing the capitalised
canonical form until step 9 removes them.

*Tests:* unit tests in `test/core/` for each constructor.

### Step 2 — `Row.format_kind`

Add `Row.format_kind` rendering a row kind as
`(name: type, name: type)`, or `()` for the empty row kind. Builds on
step 1's `Scalar.format_kind` for the type side. Qualifiers are
dropped (the surface syntax has no qualifier form; see
[type-system.md §"qualifiers on row fields"](../design/type-system.md)).

*Tests:* unit tests covering empty, single-field, multi-field, and
qualifier-stripping cases.

### Step 3 — `Relation.format_kind`

Add `Relation.format_kind` rendering a relation kind as the row-type
form with refinement clauses interleaved:
`(id: int64, name: string, primary key (id))`. Empty refinements
list elides the `primary key` clause. No new callers yet.

*Tests:* unit tests for the no-refinement and `Primary_key` cases,
including a composite primary key.

### Step 4 — `Core.Term` module

New `lib/core/term.ml{,i}` with the two-arm union
(`Relation_value`, `Relation_kind`) and `Term.format` dispatching per
arm — `Relation_value` formats via `Relation.print`-equivalent path,
`Relation_kind` formats via `Relation.format_kind` from step 3. Not
yet wired anywhere.

*Tests:* unit tests on `Term.format` for both arms.

### Step 5 — Thread `Term.t` through Eval (structural)

Change `Eval.eval`'s continuation from `[`Bag] Relation.t -> 'a` to
`Term.t -> 'a`. Every existing operator wraps its relation result as
`Term.Relation_value` before calling its `continue`. REPL's
`print_result` callback receives a `Term.t` and pattern-matches; the
`Relation_kind` arm is `assert false`-with-comment until step 7
makes it reachable. Atomic change — the layers can't be partially
migrated.

No user-visible behaviour change. The biggest step in the slice;
keeping it atomic because the signature change drives the touch list
mechanically.

*Tests:* the existing Eval test corpus updates from receiving
`Relation.t` callbacks to receiving `Term.t`. No new behavioural
tests at this step — step 8's end-to-end test covers the wider shape.

### Step 6 — `Physical.kind_of` helper

Add `Physical.kind_of : t -> Relation.kind`: a pure inspector that
walks a physical plan and returns its result kind without opening
cursors. The catalog-touching `FullScan` / `IndexLookup` /
`IndexedNestedLoopJoin` cases take a `catalog` lookup parameter
(mirroring `Translate.translate`'s shape).

Existing `Translate.translate` already computes per-operator kinds
inline; this step factors that knowledge into a reusable helper. The
old inline computation stays where it is — `kind_of` is a new entry
point for step 8's `Type_op` evaluator, not a refactor of existing
call sites.

*Tests:* unit tests for each operator constructor in `test/plan/`.

### Step 7 — `Type` constructor across IR layers + Eval handling

Add the constructor:

- `Ast.Type of { input : t }`
- `Logical.Type_op of { input : t }` — `required_access` recurses
  into `input`.
- `Physical.Type_op of { input : t }`
- `Lower.lower` and `Translate.translate` pass `Type` through.
- `Eval.eval` handles `Physical.Type_op { input }` by computing
  `Physical.kind_of input` (step 6) and calling `continue` with
  `Term.Relation_kind kind`. No cursors opened.
- `Logical.format` and `Physical.format` render the new constructor.

Unreachable from the REPL — the parser doesn't know `type` yet — but
testable at each layer by building values directly.

*Tests:* round-trip + format tests at each layer; an Eval test that
builds `Type_op (FullScan { table = "users" })` against a seeded
catalog and asserts the resulting `Term.Relation_kind` carries the
expected kind. The REPL's `Relation_kind` arm in step 5 becomes
reachable here — its `assert false` becomes a real `Term.format`
call, exercised by step 8's end-to-end test.

### Step 8 — Parser keyword + `type | type` rejection + end-to-end

Parser learns `type` as a unary pipe operator (no parens, no
arguments). `Lower.lower` matches `Ast.Type { input = Ast.Type _ }`
and raises `failwith "type: input is already a type"`. The check
lives at Lower because that's the first layer with the full pipeline
shape and the natural place to emit a user-facing message before any
IR carries an invariant about non-nested `Type_op`s.

*Tests:*

- Parser unit tests: `users | type` parses to `Ast.Type { input =
  Relation_name "users" }`; `users | type | type` parses (no
  syntactic restriction); bare `type` without input is a parse error.
- Lower unit test for the `type | type` rejection.
- End-to-end integration test in `test/integration/`:
  `users | type` prints the relation type in the new surface syntax,
  matching what `:describe users` produced before the rename
  (modulo `int64` lowercase and `:` between name and type).

### Step 9 — Retire `:describe`

Remove:

- The `:describe` parser rule in `lib/ddl/parser.ml`.
- `Statement.Describe` constructor and the `Described` arm of
  `read_result`.
- `Ddl_executor`'s `Describe` case.
- `Ddl_format`'s `Describe` case.
- `Statement.of_kind` (the canonical-form-from-kind adapter has no
  remaining caller).
- The REPL's `Listed | Described` dispatch loses its `Described`
  arm; `Listed` stays.
- `Scalar.kind_to_string` if its last caller was the DDL formatter
  (check at the step; otherwise leave for a later cleanup).

`lib/ddl/` shrinks but stays — `:list tables`, `:drop table`, and
`:create table` are still around (slice 22 retires the last two).

*Tests:* delete `:describe`-specific tests; round-trip tests for the
other three DDL statements stay green.
