# 03 — Slice 2: Selection (σ) via the RA language

The second vertical slice. End-state: typing `users | select id = 3` at
the REPL returns the matching row. The predicate sublanguage starts at
its smallest — a single comparison of one column against one literal,
equality and inequality only.

## Goal

```
> users | select id = 3
| id | name  | email             | active |
|----|-------|-------------------|--------|
|  3 | Carol | carol@example.com | true   |

> users | select active = true
... three rows: Alice, Carol, Dave ...

> users | select name = "Alice"
... one row ...

> users | select id <> 3
... four rows ...
```

Error cases reach the REPL and don't crash it:

```
> users | select unknown_col = 3
error: Predicate.resolve: unknown column "unknown_col"

> users | select name = 1
error: Predicate.resolve: type mismatch: column "name" is String, literal is Int64
```

Everything from slice 1 (`users` alone) keeps working.

## Slice-2 architectural decisions

### Predicate scope at slice start

`column op literal` only. No `and`/`or`/`not`, no parens, no nested
expressions, no arithmetic on column references. Boolean composition
and richer expressions are natural follow-up slices.

### Comparison operators

Equality only: `=` and `<>`. Equality compares `Value.t` structurally,
so it's well-defined on every value type. Ordering operators
(`<`, `<=`, `>`, `>=`) defer to a later slice or a follow-up step
within slice 2 if scope creeps.

### Column resolution

Column names live in the IRs, not positions. Logical and Physical
predicates carry the user's column name (`"id"`, etc.). When the
executor starts pulling tuples, it caches name→position once per
scan and the per-row work is `tuple.(cached_position)`.

The conceptual rule: ordering is an executor concern, not an IR
concern; IRs stay human-readable for debugging and EXPLAIN-style
introspection.

### Predicate type

Lives in `lib/predicate.{ml,mli}`, shared across IRs. Single-constructor
sum with an inline record, matching existing layer patterns:

```ocaml
type op = Equal | NotEqual
type t = Compare of { column_name : string; op : op; literal : Value.t }
```

Plus a helper that owns predicate evaluation logic:

```ocaml
val resolve : Schema.t -> t -> (Schema.tuple -> bool)
```

`resolve` is called once when the filter operator starts. It validates
that the named column exists, that its kind matches the literal's type,
and caches the column's position. Returns a closure that does only the
position-indexed comparison per row. Errors (unknown column, type
mismatch) raise before any tuples are pulled.

### Pipeline AST shape

Recursive — each `|` wraps the previous expression. Mirrors the
recursive shape of `Logical` and `Physical` IRs so `Lower` and
`Translate` stay one-line-per-case structural rewrites:

```ocaml
(* Ast *)
type t =
  | Relation_name of string
  | Select of { input : t; predicate : Predicate.t }

(* Logical *)
type t =
  | Scan of { table : string }
  | Select of { input : t; predicate : Predicate.t }

(* Physical *)
type t =
  | FullScan of { table : string }
  | Filter of { input : t; predicate : Predicate.t }
```

Logical uses `Select` (algebraic σ, matches the surface keyword);
Physical uses `Filter` (execution-engine convention; same logical/
physical naming split as `Scan`/`FullScan`). Pipelines parse
left-associative.

### Keyword reservation

None. Identifier parsing is unchanged from slice 1; the parser
disambiguates by grammatical position. A column or relation called
`select` parses fine and produces a semantic error only if the name
doesn't resolve.

*Future improvement:* better error messages around misspelled keywords
("did you mean `select`?") want either reservation or a recovery-style
parser. Revisit when error-message investment becomes a slice's focus.

### Set/Bag preservation

`Filter` preserves the input's tag. Slice 2's `Eval` keeps returning
`` [`Bag] `` because nothing yet produces sets, but the principle is
recorded so slice 7 (set/bag operators) doesn't trip on it.

### Literal syntax

- **Signed integer literals**: `-1`, `0`, `42`.
- **String literals**: `"..."` with `\"` and `\\` escapes only.
  Multi-char escapes (`\n`, `\t`, hex) wait until something needs them.
- **Bool literals**: `true`, `false`.

### Predicate operand order

Grammar is strictly `<column-name> <op> <literal>`. `3 = id` is a parse
error in slice 2; the symmetric form can land later if it's wanted.

### Error type

`Parser.error` stays `string` (the slice-1 alias). Errors from
`Predicate.resolve` raise `Failure` and are caught by the REPL's
existing handler. No structural change to the error story for slice 2.

## Sub-steps

Six steps. Each is one commit, with tests, leaving the project in a
working state. Build from the bottom: each step adds one layer, and
from step 2 onward each step ends with a runnable query at the layer
just introduced.

### 1. Predicate module

`lib/predicate.{ml,mli}` with the `op`, `t`, and `resolve` introduced
above. `resolve` validates column existence, validates kind
compatibility, caches the column's position, and returns a closure for
per-row evaluation.

Tests: `test/test_predicate.ml`. Equality on each of the three value
types. Inequality. Unknown column raises with a clear message. Type
mismatch raises with a clear message. Position-cache correctness
(predicate referencing a column that's not at index 0).

End state: pure module, no integration yet.

### 2. Physical.Filter + Eval

Add `| Filter of { input : t; predicate : Predicate.t }` to
`Physical.t`. Add the `Filter` case to `Eval.eval`:

```ocaml
| Filter { input; predicate } ->
    let { schema; tuples } = eval environment transaction input in
    let evaluator = Predicate.resolve schema predicate in
    { schema; tuples = Seq.filter evaluator tuples }
```

Tests: `test_eval.ml` grows with end-to-end cases. Populate fixture,
build a `Physical.Filter` by hand around a `FullScan`, evaluate, assert
filtered rows. Cover equality on each value type, inequality, predicate
matching all rows, predicate matching zero rows, unknown column raises,
type mismatch raises.

End state: filtering works at the physical layer.

### 3. Logical.Select + Translate

Add `| Select of { input : t; predicate : Predicate.t }` to `Logical.t`.
Update `Translate.translate` to map
`Select { input; predicate } → Filter { input = translate input; predicate }`.

Tests: `test_translate.ml` adds a Select case — structural unit
(`Select → Filter`) plus the pipeline integration (build
`Logical.Select`, translate, evaluate, assert rows).

End state: filtering works at the logical layer.

### 4. Ast.Select + Lower

Add `| Select of { input : t; predicate : Predicate.t }` to `Ast.t`.
Update `Lower.lower` similarly. One-line structural rewrite.

Tests: `test_lower.ml` adds the structural unit and the pipeline
integration (build `Ast.Select`, lower, translate, evaluate, assert
rows).

End state: filtering works at the AST layer.

### 5. Parser literals and predicate parsing

Grammar additions:

- **Literals**: signed `int64` (digits with optional leading `-`),
  `bool` (`true`/`false`), `string` (`"..."` with `\"`/`\\` escapes).
- **Comparison ops**: `=` and `<>`.
- **Predicate combinator**: `<column-name> <op> <literal>` producing
  `Predicate.Compare`.

Expose `Parser.parse_predicate : string -> (Predicate.t, error) result`
in the public API. The predicate sublanguage is self-contained enough
to make it a defensible public entry point, and exposing it gives step
5 a real testable artifact before pipeline syntax lands in step 6.

Tests: `test_parser.ml` covers `id = 3`, `name = "Alice"`,
`name = "with \"quotes\""`, `active = true`, `active = false`,
`id = -1`, plus the inequality form. Reject empty input, malformed
syntax, mismatched-quotes strings, identifier-on-the-right
(`3 = id`), etc.

End state: predicates parse standalone from strings. No surrounding
query syntax yet.

### 6. Parser pipeline + select

Grammar additions:

- **Pipeline operator** `|`, left-associative.
- **`select` keyword** wrapping a predicate: `select <predicate>` is a
  pipeline step.
- **Top-level grammar** updated to allow zero or more pipeline steps
  after the relation reference.

Tests: `test_parser.ml` covers the full surface syntax: `users`,
`users | select id = 3`, `users | select id = 3 | select active = true`,
etc. Reject malformed pipelines (leading `|`, `select` without a
predicate, trailing `|`). End-to-end pipeline integration test: parse,
lower, translate, evaluate, assert rows.

After step 6, run the binary manually to confirm the demo from the
Goal section. Update `README.md` to extend the layer diagram
description to mention selection — probably just a sentence in the
Layers table for `Logical`/`Physical`.

End state: the demo from the Goal section works end-to-end via the
REPL.

## Open questions

Captured here as they come up; resolved at end of slice.

- (none currently)
