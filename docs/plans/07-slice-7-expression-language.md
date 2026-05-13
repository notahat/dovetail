# 07 — Slice 7: Expression language

The seventh vertical slice. End-state: the predicate sublanguage
becomes a small general expression language with ordering
comparisons, boolean composition (`and`, `or`, `not`), and
parentheses. The `Predicate` module is renamed to `Expression`,
and its IR generalises from a single `Compare` node to an
expression tree.

This slice doesn't add a new operator or storage path. It widens
what users can write inside `restrict`, `join ... on`, and any
future operator that takes a predicate, and it sets the IR shape
that computed columns and future expression-valued positions
(projection expressions, aggregation arguments, …) will plug into.

## Context

After slices 1–5 the predicate sublanguage is a single
`Compare { left; op; right }` with `op ∈ {Equal, NotEqual}` and
each side being a column reference or a literal. That was enough
to land the operators those slices needed, and the type has
explicitly stayed minimal until a slice forced more.

Slice 8 (primary-key range scans) needs ordering comparisons and
`and`-conjunctions to recognise `id >= 10 and id <= 100` as a
range. Rather than bolt those onto `Compare` and stop there, this
slice does the predicate-language work end-to-end: ordering ops,
full boolean composition, parens, and the IR generalisation that
makes a standalone `restrict active` valid.

The work is its own slice — distinct from slice 8 — because the
themes don't share much: predicate evaluation/parser surface here
vs physical-planner pattern matching there. Bundling them would
mix two unrelated bodies of work in one commit history.

## Goal

```
> users | restrict age > 21
... rows where age > 21 ...

> users | restrict active
... rows where the bool column [active] is true ...

> users | restrict (name = "Alice" or name = "Bob") and active
... rows matching the composed predicate ...

> users | restrict not active
... rows where [active] is false ...
```

Everything from earlier slices keeps working unchanged. EXPLAIN
output (`--show-physical`) renders the new expression forms
faithfully through the formatter.

## Slice-7 architectural decisions

### Single expression tree, not a separate boolean layer

`Predicate.t` becomes a general expression tree where
comparisons, boolean operators, columns, and literals are all
nodes. Boolean composition isn't a separate layer above
comparisons; everything is `Expression.t`.

```ocaml
type comparison_op =
  | Equal | NotEqual | Less | LessEqual | Greater | GreaterEqual

type t =
  | Literal of Value.t
  | Column of Schema.column_reference
  | Compare of { left : t; op : comparison_op; right : t }
  | And of t * t
  | Or of t * t
  | Not of t
```

Two consequences worth naming:

- **`restrict active` works.** A standalone `Column` reference is
  a valid expression; if it resolves to a `Bool`, it's a valid
  predicate. The old `Compare`-only shape forced `active = true`.
- **Computed columns and other expression-valued positions get
  the same tree later.** Adding arithmetic operators (`+`, `-`,
  …) or function calls is additive on this shape; we don't pay
  for them now.

The alternative — keep `Compare` as the predicate root and add
`And`/`Or`/`Not` constructors around it, leaving `term` as the
type of comparison operands — would have been a smaller
refactor. We've rejected it because it leaves the `active = true`
wart in place and means a second restructure when computed
columns arrive.

### Module rename: `Predicate` → `Expression`

The type is no longer specifically a predicate; "predicate" is a
role (top-level expression that resolves to `Bool`). The module
is renamed to `Expression` so the name describes the type, not
the role. Field names at use sites stay role-flavoured:
`Filter { predicate : Expression.t }`,
`NestedLoopJoin { predicate : Expression.t }`. That keeps the
"this expression must be a predicate" expectation visible at the
use site.

### Ordering ops apply to `Int64` and `String` only

`<`, `<=`, `>`, `>=` are defined for `Int64` (numeric ordering)
and `String` (lexicographic). `Bool` participates in `=` and
`<>` but not the ordered comparisons.

Both sides of a comparison must agree on kind, as today. No
coercion. A `Bool` operand to `<` raises the existing
kind-mismatch failure with a clear message.

### Precedence and associativity

From lowest to highest binding:

1. `or` — left-associative.
2. `and` — left-associative.
3. `not` — prefix unary.
4. Comparisons (`=`, `<>`, `<`, `<=`, `>`, `>=`) —
   **non-associative**. `1 < x < 10` is a parse error, not
   `(1 < x) < 10`.
5. Atoms: literals, column references, parenthesised
   expressions.

So `a > 5 and b < 10 or not c` parses as
`((a > 5) and (b < 10)) or (not c)`. `not a = 5` parses as
`not (a = 5)` — `not` is looser than comparison, matching SQL.

Parens always available for overrides.

### Strict kind checking, single resolver shape

`Expression.resolve` keeps its existing surface:

```ocaml
val resolve : Schema.t -> t -> (Schema.tuple -> bool)
```

Internally the resolver walks the tree producing a
`tuple -> Value.t` function and a `Value.Kind.t` at each node.
The top-level call checks the kind is `Bool` (otherwise it
raises with a clear message — predicate position requires a Bool
expression) and wraps the value-producing function as a
bool-producing one.

A general value-producing resolver (`Schema.t -> t -> tuple ->
Value.t`) can be exposed when computed columns force it. We
don't pre-build it.

### Surface syntax for keywords

`and`, `or`, `not` are keywords, lowercase, with word breaks
enforced via the existing `keyword` helper — same convention as
`restrict`/`project`/`cross`/`join`/`on`. `<>` stays as the
not-equal spelling.

`(` and `)` group expressions. No whitespace constraints around
them.

## Sub-steps

Six commits plus a verification stage. Each commit is one step,
ends with `dune build`/`dune test` green and the formatter run,
leaving the project in a working state. Reviews happen between
steps.

### 1. Rename `Predicate` → `Expression`

Pure rename. `lib/predicate.ml` and `lib/predicate.mli` become
`lib/expression.ml` and `lib/expression.mli`. All `Predicate.`
references across the codebase update. No type changes, no
behaviour change.

Files modified:

- `lib/predicate.ml` → `lib/expression.ml`.
- `lib/predicate.mli` → `lib/expression.mli`.
- Every `Predicate.` reference in `lib/` and `test/`.
- `lib/dune` if the module list is explicit.

Tests: existing test suite passes unchanged. No new tests; the
rename has no testable behaviour.

End state: identical behaviour to before; the module is named
after its type, not its role.

### 2. Restructure IR to an expression tree

`term` goes away; `Literal` and `Column` lift to constructors of
`Expression.t`; `Compare`'s `left`/`right` fields become
`Expression.t`. Resolver and formatter recurse over the tree.

The one new behaviour falls out of the new shape: a standalone
`Column` (or `Literal`) is a valid `Expression.t`, and if it
resolves to `Bool` the predicate machinery accepts it. So
`restrict active` works without further work in this step.

Files modified:

- `lib/expression.ml`, `lib/expression.mli` — new constructors,
  recursive resolver and formatter, updated `.mli` doc comments.
- `lib/parser.ml` — `term` parser merges into the comparison
  side; the top-level `predicate` parser still produces a
  Bool-kinded expression. Standalone column or literal at the
  top of a predicate position is accepted by the parser; kind
  checking at resolve catches the non-Bool case.

Tests (TDD; failing first):

- `restrict active` returns rows where `active` is true.
- `restrict 5 = 5` still parses and runs (degenerate, but the
  IR admits it; the kind is `Bool` so the predicate position is
  satisfied).
- `restrict id` (column of kind Int64) raises the kind-mismatch
  error from the resolver — message names the expression
  position and the offending kind.
- Existing tests carry through without changes; the new IR
  shape is an internal refactor for every existing query.

End state: the IR is generalised; one new query shape
(`restrict active`) works; everything else unchanged.

### 3. Add ordering comparison ops

`Less`, `LessEqual`, `Greater`, `GreaterEqual` join the
`comparison_op` enum. Resolver dispatches by op; uses
`Stdlib.compare` (or per-kind compare) for `Int64` and `String`,
and rejects `Bool` operands with a kind-aware error message.
Formatter renders the new ops. Parser recognises `<`, `<=`,
`>`, `>=`, dispatching by lookahead (extends the existing
pattern that disambiguates `=` and `<>`).

Files modified:

- `lib/expression.ml`, `lib/expression.mli` — extend
  `comparison_op` and the resolver/formatter.
- `lib/parser.ml` — extend `comparison_op` parser; add a
  helper for the `Bool`-rejection error path if useful.

Tests (TDD; failing first):

- `restrict id > 3` returns the expected subset.
- `restrict name >= "C"` returns the expected subset.
- `restrict active > false` raises the kind-mismatch error,
  with a message that names `Bool` as the offending kind.
- Parser tests for each new op spelling.

End state: ordering ops work on the kinds where they're
defined; the parser disambiguates the four new operators
against the existing `=`/`<>`.

### 4. Add `And` and `Or`

New IR constructors; resolver evaluates short-circuit (left
first, only evaluate right if needed); formatter renders with
the keywords and parens where required by precedence; parser
adds the two boolean composition levels (`or` lowest, `and`
between `or` and comparison), left-associative.

No parens in the grammar yet — that's step 5. So `a and b and c`
works, `a or b and c` parses by precedence as `a or (b and c)`,
but `(a or b) and c` is not yet expressible.

Files modified:

- `lib/expression.ml`, `lib/expression.mli` — new constructors,
  resolver (short-circuit), formatter.
- `lib/parser.ml` — two new precedence levels in the expression
  grammar; reuse the existing `keyword` helper.

Tests (TDD; failing first):

- `restrict id > 5 and active` returns the intersection.
- `restrict name = "Alice" or name = "Bob"` returns the union.
- `restrict id > 5 and id < 10 and active` parses
  left-associatively and returns the expected rows.
- `restrict id = 1 or id = 2 and active` parses as
  `id = 1 or (id = 2 and active)` (precedence test).
- Short-circuit: in a predicate
  `restrict false and <something that would error>`, the
  resolver does not evaluate the right side. Pin with a small
  contrived expression that would raise if evaluated.

End state: full boolean composition without parens; precedence
matches Q10.

### 5. Add parens to the atom production

The atom grammar gains `'(' expression ')'`. No new IR — parens
exist only in the surface syntax. Formatter inserts parens only
where precedence would otherwise change meaning.

Files modified:

- `lib/parser.ml` — atom parser gains a paren branch.
- `lib/expression.ml` — formatter's paren-insertion logic.

Tests (TDD; failing first):

- `restrict (a or b) and c` parses such that `a or b` is the
  left operand of `and`.
- `restrict ((id = 1))` works (redundant parens accepted).
- `restrict (` fails with a parse error (unbalanced).
- Formatter round-trip on a representative expression includes
  parens only where needed.

End state: parens override precedence; full surface
expressivity reached up to but excluding `not`.

### 6. Add `Not`

New IR constructor; resolver inverts; formatter renders `not `
with the right binding. Parser adds the prefix-unary `not` at
the level between comparison and `and`.

Files modified:

- `lib/expression.ml`, `lib/expression.mli` — `Not` constructor,
  resolver, formatter.
- `lib/parser.ml` — `not_expression` production between
  `and_expression` and `comparison`.

Tests (TDD; failing first):

- `restrict not active` returns the complement of `restrict
  active`.
- `restrict not a = 5` parses as `not (a = 5)`.
- `restrict not (a > 5 and b < 10)` parses as expected.
- `restrict not not active` parses (no syntactic restriction on
  stacked `not`) and equals `restrict active`.

End state: the surface language matches the description in the
initial plan's "Predicate sublanguage" line.

### 7. End-to-end verification

No code change beyond what step 6 left. The slice's verification
stage:

- `opam exec -- dune build @fmt --auto-promote` clean.
- `opam exec -- dune build` clean.
- `opam exec -- dune test` green.
- Manual REPL: open the binary, run:
  - `users | restrict age > 21` (ordering).
  - `users | restrict active` (standalone bool column).
  - `users | restrict (name = "Alice" or name = "Bob") and active`
    (full composition with parens).
  - `users | restrict not active` (`not`).
  - `users | join orders on users.id = orders.user_id and orders.amount > 4`
    (the new ops work in `join ... on` predicates too).

This is a verification stage, not a commit; skip if step 6 left
everything green.

## Out of scope (deferred, intentionally)

- **Arithmetic and function-call expressions** (`age + 1`,
  `upper(name)`). The expression tree admits them as additive
  constructors; we don't add them until a slice needs them
  (projection expressions, aggregations).
- **Three-valued logic / `NULL` semantics.** Option columns
  exist in the type system but no fixture uses them yet.
  `option`-aware predicate handling is its own future work.
- **Chained comparisons** (`1 < x < 10`). Explicitly a parse
  error this slice; non-associative comparisons are the
  deliberate choice.
- **Predicate pushdown.** Predicates with new surface still get
  evaluated above the operator they came from; reordering for
  efficiency is the optimiser's job.

## Open questions

Captured here as they come up; resolved at end of slice.

- (none currently)
