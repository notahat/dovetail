# Code review — post-slice-11

A pass over the whole codebase after eleven slices of growth. Not focused
on the insert work specifically; the goal is to surface places where the
shape of the codebase has drifted, where slice-1 scaffolding is overdue
for a haircut, and where the abstractions are or aren't earning their
keep. Each item is a suggestion to consider, not a directive — tradeoffs
called out where they exist.

Items are roughly ordered by leverage within each section.

## Status

The ten items in the Ranked TL;DR have all shipped (commits `dede5b7`
through `2d3131d`). Each subsection in the body below is annotated with
its status: **[done]** for items that landed, **[open]** for items not
yet actioned. The "Smaller items by file" section is mostly **[open]** —
it was below the TL;DR cut. Cross-cutting captures for `CLAUDE.md` are
also **[open]**.

## Architecture-level themes

### Stale slice-1 scaffolding in `Fixture` — **[done]** (TL;DR 1, commit `dede5b7`)

`lib/fixture.ml:50-66` defines `encode_users_row` and `encode_orders_row`
by hand, with `_ -> assert false` arms covering shapes that never occur
because the only callers are the literal rows declared in the same file.
These two functions were necessary in slice 1; slice 11 added
`Row_codec.encode_row : Schema.t -> Schema.tuple -> string * string`,
which does the same job generically given a schema.

Suggested change: delete both per-table encoders and the `~encode_row`
parameter on `populate_table` (line 70). `populate_table` calls
`Row_codec.encode_row schema row` directly. Net change: ~20 lines
deleted, one degree of freedom removed, the `assert false` arms vanish.

Why: this is the cleanest "earlier slices' code that the codebase has
since grown past" item in the review.

### `Row_codec.split_primary_key` is `Schema.assemble_tuple`'s inverse — move it home — **[done]** (TL;DR 6, commit `50de0f6`)

`Row_codec` currently owns half of a bijection (`encode_row` → bytes) and
calls `Schema.assemble_tuple` for the other half (`decode_row` → tuple).
But `encode_row`'s helper `split_primary_key` (line 41-57) is the
algebraic inverse of `Schema.assemble_tuple`, and lives in the wrong
module.

Suggested change: move it to `Schema` as `split_tuple : t -> tuple ->
Value.t list * Value.t list` (PK values, non-PK values, both in field
order modulo PK position). `Row_codec` shrinks to ~30 lines of pure
composition. The "single-column int64 PK only" check moves with it.

Why: the round-trip `assemble_tuple ∘ split_tuple = id` (and converse)
is a property worth being able to test at the `Schema` layer without
involving bytes at all.

### `Translate`'s optimiser rewrites are unnamed — **[done]** (TL;DR 5, commit `75eb671`)

`Translate` already runs two distinct rewrite rules: PK-equality →
`IndexLookup`, and join-on-PK → `IndexedNestedLoopJoin`. The module-level
doc-comment acknowledges them, but in the code they're a sequence of
helper functions (`partition_pk_conjunct`, `partition_join_pk_conjunct`,
`try_match_conjunct`) without a label for the rule each one implements.

`try_match_conjunct` (translate.ml:172-187) returns a 4-tuple that
`partition_join_pk_conjunct` wraps in a 5-tuple that `translate_relation`
then destructures inline. The same shape, deconstructed three times.

Suggested change:

- Give the join match its own record: `type indexed_join_match = {
  outer_logical; inner_table; outer_key_column; inner_position;
  residual_conjuncts }`. One destructure, one home for the doc comment.
- Give each rule a name: `rewrite_point_lookup`,
  `rewrite_indexed_nested_loop_join`, both returning `Physical.t option`.
- `translate_relation`'s `Restrict { input = CrossProduct ... }` arm
  (translate.ml:236-289) currently has the 5-tuple unpacking in its body;
  with the record and named rule it shrinks from 28 lines to ~8.

Why: the optimiser is going to grow. Once predicate pushdown or
projection pushdown lands, you'll want a third rule to slot in. Naming
the rules now sets the precedent; pulling them into a `Rewrite` submodule
is the natural next step when there's a third.

Trade-off: the rule-naming convention is mildly more code today for code
that's about to need it. Pete: this is your call — could equally be
deferred until slice 13/14 when more rules force the issue. Flagging
because it's the place the architecture most clearly wants something
next.

### Eval has two CPS entry points; the ref-through-fold inside `evaluate_insert` can still go — **[done]** (TL;DR 8, commit `7e9317d`)

Post-review change: `eval_mutation` was originally synchronous (returned
`int`); a follow-up converted it to CPS to mirror `eval`. The mutation
entry's return shape (an `int`) doesn't carry a scoped resource today,
but routing it through a continuation keeps the REPL dispatch arms
structurally uniform and leaves room for slice-12-onwards mutation
outputs (RETURNING-style row streams) to slot in additively. The two
honest signatures argument lost to the symmetry-at-call-sites argument
once the RETURNING horizon was factored in.

Wart that's still there inside the mutation path: `evaluate_insert`
(eval.ml:351-368) threads `affected_rows : int ref` through `Seq.iter`,
with `insert_one_row` (eval.ml:329-344) taking the current count *as a
parameter* and returning `current + 1`. The pattern is fold-shaped but
called inside `Seq.iter`.

Suggested change: make `insert_one_row` return `unit` and use `incr
affected_rows` in the iter body. The future multi-row case still lands
cleanly. Drops two parameters from `insert_one_row` and removes the
"take a count, return count + 1" oddity.

### IR triplication: live with it, but unify the kind-inference rule — **[open]**

The `RelationLiteral { columns; rows }` record and the
`plan = Query of t | Mutation of mutation` wrapper are now copy-pasted
across `Ast`, `Logical`, `Physical`. Three copies isn't bad in OCaml
(each IR's constructor list is closed and `match` on each layer wants
its own type), and a shared module would add indirection for what's
currently ~12 lines of duplication.

The bit that *will* drift is the "schema is inferred from the first
row's value kinds" rule, which is described in `logical.mli:38-42`,
`physical.mli:85-94`, and implemented in `Eval`. Suggested change: a
single `Relation_literal.schema_of : columns:string list ->
first_row:Value.t list -> Schema.t` helper, called from both
schema-construction sites. The constructor records stay where they are.

Why: documentation about a rule in two `.mli` files plus an
implementation in a third file is a drift trap. One implementation
eliminates the trap without disturbing the IR layering.

### `Physical.format` should leave room for `Logical.format` — **[open]**

Only `Physical` has a `format`/`format_plan` (used by
`--show-physical`). When a Translate rewrite produces a surprising
plan, the first thing you'll want is to look at the input — i.e.
`Logical.format`. Add it now (or note as upcoming) and pull the
shared rendering helpers (`render_columns` at physical.ml:21-22 is
purely about `Projection.t` and doesn't belong in `Physical` at all)
into the relevant sub-language modules: `Projection.format`,
`Expression.format` already exists.

## Naming and consistency

### `Insert` field-order drift across IR layers — **[done]**

- `Ast.mutation = Insert { source : t; table : string }` (ast.mli:60-61)
- `Logical.mutation = Insert { table : string; source : t }` (logical.mli:46)
- `Physical.mutation = Insert { table : string; source : t }` (physical.mli:97)

`Ast` is the odd one out. Realign to `{ table; source }` everywhere.

### Error-message prefix convention is consistent but undocumented — **[done]** (CLAUDE.md "Error messages" section; "failed:" dropped from Eval PK-collision)

Every user-facing error string in the codebase starts with `Module:` or
`Module: operation:`. `Translate: insert into %S: ...`, `Eval: insert
into %S failed: ...`, `Projection.resolve: ...`, `Schema.assemble_tuple:
...`. Worth capturing in `CLAUDE.md`'s naming section.

Small inconsistency: `Eval` uses `... failed: ...` for the PK-collision
case; nobody else uses "failed". Drop it for consistency.

### Abbreviations slipping into local bindings — **[done]** (`schema.ml` renamed; `row_codec.ml` `pk_position` spots already deleted by TL;DR 6's refactor)

The "spell things out" rule is well-followed in the public API but
slips occasionally in locals:

- `schema.ml:81`: `expected_pk_count` → `expected_primary_key_count`.
- `row_codec.ml:33`: `pk_position` → `primary_key_position` (which is
  also the name of the helper on line 29, so this would resolve the
  shadow).
- `row_codec.ml:42-54`: `pk_position`, also.

Not urgent; mention because consistency on these is cheap.

## Functions getting long, doing too much, or oddly shaped

### `Schema.find_field` (schema.ml:27-67) — 41 lines, duplicated ladders — **[done]** (TL;DR 3, commit `8027b92`)

The qualified and unqualified branches each pattern-match `matching` for
`[one] / [] / many` with the "no match" arm being byte-identical. Worth
flattening to a single dispatch:

```ocaml
let find_field schema reference =
  let matching = fields_with_position_matching_name schema reference.name in
  let matching =
    match reference.qualifier with
    | None -> matching
    | Some qualifier ->
        List.filter (fun (_, field) -> field.qualifier = Some qualifier) matching
  in
  match matching with
  | [ result ] -> Ok result
  | [] -> Error (Printf.sprintf "unknown column %S" (format_column_reference reference))
  | _ -> (* ambiguous *)
```

The ambiguous case now only fires for unqualified references with
multiple matches — which is the correct semantic (qualifier + name
should always be unique within a schema). The `internal error`
`Result.Error` on lines 42-49 becomes an `assert false` with a comment
explaining the invariant, rather than masquerading as a normal column
lookup failure that callers will surface verbatim in REPL output.

### `Parser.expression` (parser.ml:209-276) — 67 lines, one `fix` — **[done]** (TL;DR 10, commit `2d3131d` — kept nested, comment added)

The expression grammar is built as five precedence tiers (`term`,
`comparison_expression`, `not_expression`, `and_expression`, top-level
`or`) all nested as `let`s inside one `fix`. Each tier is independently
nameable.

Suggested change: pull `comparison_expression`, `not_expression`,
`and_expression` out as top-level bindings, leaving `expression = fix
(fun expression -> let term = ... in ... and_expression >>= ...)`. The
inner `fix` body shrinks from 67 lines to ~20.

Trade-off: the inner-let style keeps the precedence chain visible in one
place at the cost of length. The flattened style trades that for letting
each tier be docstring'd and tested independently. Pete's call.

Smaller: `term` (parser.ml:216-234) and `literal_value` (parser.ml:83-89)
share the leading-character dispatch on `"`, `-`, digit, letter. A
`literal_by_lookahead` helper would dry it up; not urgent.

### `Translate.validate_literal_against_target` (translate.ml:307-347) — 41 lines, four invariants — **[done]**

Four independent checks (missing columns, unknown columns, row arity,
per-column kind), each its own `if ... failwith ...`. Splitting into
`check_columns_match`, `check_row_arity`, `check_value_kinds` — each
`unit`-returning, raising on failure — makes the orchestration body four
lines and lets each check grow a more specific error.

### `Storage.with_iter_seq` (storage.ml:46-68) — two interlocking refs — **[done]**

`started : bool ref` and `exhausted : bool ref` encode a state machine
with four nominal states, two of which are unreachable. A tagged variant
makes the legal transitions explicit:

```ocaml
let state = ref `Before_first in
let next_pair () =
  match !state with
  | `Exhausted -> None
  | `Before_first -> ... first call ...
  | `Active -> ... next call ...
in
```

Why: a reader can list the states in two seconds rather than reasoning
about two booleans' joint truth values.

### `doctest.ml` extractor — heavily mutable — **[done]**

`parse_session_lines` (doctest.ml:64-93, 30 lines, 3 refs),
`extract_sessions` (doctest.ml:100-128, four refs), `split_outputs`
(doctest.ml:166-201, 36 lines, hand-rolled scanner with `while` and
position mutation). All would read better as folds. The "functional
core, imperative shell" preference applies — these are pure parsers and
have no I/O justifying the mutable shapes.

## Error-handling discipline — **[done]** (TL;DR 4, commit `a62cc77`; schema.ml spot rolled into commit `8027b92`)

All four flagged spots have been reclassified to `assert false` with one-line
invariant comments. The slice-1 `"?"` fallback in `primary_key_value_text`
for composite PKs has been kept and labelled `TODO(composite-pk)`.

The rule from `~/.claude/CLAUDE.md`: exceptions are for exceptional
cases; fail early; never silently swallow. Mostly followed. A few
places to tidy:

- **`eval.ml:307-325` `primary_key_value_text`** returns `"?"` from two
  branches. One ("composite key") is genuinely a future-feature gap —
  fine, but worth a `TODO(composite-pk)` marker. The other (the
  `find_field` failure on line 324) is an internal invariant violation
  if it ever fires: by the time we're rendering an error for a row we
  already encoded, the PK column exists in the schema. Replace with
  `assert false` plus a one-liner comment, or extract a small helper
  that raises with a clear "internal: PK column not found in schema
  after successful row encode" message.

- **`row_codec.ml:35`** wraps a `Schema.find_field` `Error` as
  `failwith "Row_codec.encode_row: primary-key column not in schema:
  ..."`. This branch fires only if `schema.primary_key` names a column
  that isn't in `schema.fields`, which is a catalog-construction
  invariant violation. Same treatment: `assert false` with a comment.

- **`storage.ml:14, 19`** — `failwith "Storage.with_read_transaction:
  transaction was aborted"` for the `None` branch from `Lmdb.Txn.go`.
  Worth tracing through what this case actually means at the lmdb-ocaml
  level. If it's "the callback raised and lmdb re-raised", then the
  inner exception has already propagated and this branch is unreachable
  → `assert false`. If it's "the callback returned `None` somehow",
  document what that looks like.

- **`schema.ml:42-49`** — the `Error "internal error: ..."` path
  discussed above.

The common thread: a few places that genuinely mean "this can't happen,
the invariants upstream guarantee it" are using `failwith` or `Error`,
which makes them look like user-reachable failures. `assert false` (with
a one-line comment about the invariant) is the right form for these, and
matches the precedent at `expression.ml:185, 197, 212, 227`.

## Documentation drift

### Stale "Slice N introduces X" sentences in `.mli` files — **[done]** (TL;DR 2, commit `fe260ca`)

Several module docs lead with a per-slice changelog that has gone stale:

- `ast.mli:8-10`: only mentions slices 1, 2, 11.
- `logical.mli:9-12`: mentions slices 1, 2.
- `physical.mli:8-9`: mentions slices 1, 2.
- `lower.mli:9`: slices 1, 2.
- `translate.mli:24-29`: similar.
- `projection.mli:9-11`: slice 4 detail.

These were useful while the module had two operators and one slice in
its history; they no longer earn their keep, because the next slice's
addition won't be the most interesting thing about the module.

Suggested change: replace each with a single forward-looking sentence
about *what the module does today*, and let per-constructor doc comments
carry the rest. Slice history lives in `git log` and `docs/plans/`.

### Doc that's drifted from code — **[done]**

- `physical.mli:118-125` enumerates `Filter`, `Project`,
  `NestedLoopJoin` as examples of operators that "carry a parameter
  inside parentheses". `IndexLookup`, `IndexedNestedLoopJoin`, and
  `RelationLiteral` all do too but aren't mentioned. Either enumerate
  fully or describe the pattern abstractly.

- `expression.ml:22-30` `describe_expression`: returns generic labels
  for `Compare`/`And`/`Or`/`Not` operands because the grammar doesn't
  nest them in operand position *today*. The comment says so; worth
  promoting that to a `(* Pre: ... *)`-style marker so it's visible
  when the precondition becomes false.

## Misplaced code

### `parse_cli` belongs in `lib` — **[done]** (TL;DR 9, commit `e5696f8`)

`bin/main.ml:18-39` parses argv and handles `--show-physical` /
`--data-directory`. It's interesting code with edge cases (duplicate
flag rejection, default directory) and currently has zero tests.

Suggested change: move `cli_options` and `parse_cli` into `lib/cli.ml`
+ `.mli`, returning a `result` so `bin/main.ml` does the printing and
exiting. Add `test/test_cli.ml`. Matches the stated pattern of "bulk of
work lives in `Dovetail.*` so it's testable without subprocess
spawning."

### `Physical.render_columns` belongs in `Projection` — **[open]**

`physical.ml:21-22` is pure formatting of a `Projection.t` with zero
physical-plan concerns. Move to `Projection.format` (formatter-based,
matching `Expression.format`).

## Tests

### `test_helpers.ml` should grow common boilerplate — **[done]** (TL;DR 7, commit `2421976`)

Three patterns are reinvented across multiple test files:

- **temp_dir + open environment + populate fixture**: appears in
  `test_eval_insert.ml` (lines 23, 67, 88), `test_doctest.ml` (lines
  106, 131, 147), and likely others. Suggest
  `with_fixture_environment (fun environment -> ...)` in `test_helpers`.

- **capturing formatter output into a string**: `test_repl.ml:20-31`,
  `test_pipeline.ml:289-299`, `doctest.ml:135-148`. Suggest
  `with_captured_formatter : (Format.formatter -> unit) -> string`.

- **a stdin-from-a-list `input_line` shim**: in `test_repl.ml:8-15`
  and inlined in `doctest.ml:138-145`. Move to `test_helpers`.

### Placeholder testables hurt failure diffs — **[done]**

`test_helpers.ml:110-116` defines `tuple_list_testable` and
`physical_testable` with placeholder printers (`<tuples>`,
`<physical>`). On failure, Alcotest shows `<tuples> vs <tuples>`. A
real one-line printer — `Value.to_string` of each element, joined —
would make these failures self-diagnosing. (And `Value` arguably wants
a `to_string` anyway; see below.)

### A handful of plain-language test name nits — **[open]**

Mostly good; one outlier:

- `test_eval_relation_literal.ml`: the test
  "yields a one-row relation with value-inferred kinds and no qualifier"
  bundles four `Alcotest.check`s on different attributes. Per the
  global rule of one assertion per test, split into separate tests for
  field names, inferred kinds, qualifier-and-PK absence, and tuple
  contents.

### `test_dovetail.ml` discards subprocess exit status — **[done]**

`test_dovetail.ml:27` does `let _ = Unix.close_process_full ...` —
masking a binary crash. Capture and assert `WEXITED 0`.

## Smaller items by file — **[open]** (entire section below the TL;DR cut)

### `lib/value.ml` — **[done]**

- The codebase has multiple per-module value renderers
  (`Kind.to_string`, `eval.ml:307-311 render_value_for_error`,
  presumably more in REPL output). A single `Value.format` /
  `Value.to_string` exposed from `Value` would centralise the
  decision-making about quoting strings, etc.

### `lib/projection.ml`

- `check_no_duplicates` (lines 13-21) uses a `Hashtbl` for what's
  always going to be a handful of columns. An `O(n²)` list walk would
  be simpler and clearer at these sizes. Worth either commenting on
  the hashtable choice or switching.

### `lib/relation.ml`

- The `'tag` phantom on `'tag t` is paying its way only if `print`
  someday distinguishes `[`Set]` from `[`Bag]` (or some other consumer
  does). After 11 slices, nothing distinguishes. Worth a check that
  the type parameter is on track to earn its keep when the relevant
  slice (set/bag/distinct) lands.

### `lib/parser.ml`

- `parse_predicate` (line 369) accepts the full expression grammar but
  is named for the predicate use case. Either rename to
  `parse_expression` and have `parse_predicate` be a thin alias, or
  leave a comment that "predicate" is the use-site name not the
  grammar shape.

- `plan_parser` (line 354) builds an `option (function)` only to
  pattern-match it on the next line. A direct `<|>` between
  "pipeline + sink" and "pipeline alone" reads flatter.

### `lib/parser.ml` — small ergonomic items

- `relation_literal_pair` (parser.ml:99-108) returns a 3-tuple with a
  trailing `bool` for "qualified key seen". A named record would survive
  future fields.

- `check_for_duplicate_columns` (parser.ml:140-153): the inner recursive
  `scan` is just threading a `seen` hashtable. `List.iter` over a
  `Hashtbl` or a `StringSet` fold would be flatter.

### `lib/physical.ml`

- `format_at` (lines 28-67) is 40 lines, a deliberate single dispatch
  over operators. The 35-line guideline says "if you can't, that's a
  signal to break it up". This one resists breakup — a comment naming
  the function as a known exception would close the loop. **[done]**

- `format_mutation_at` (lines 74-77) takes `indent` always-zero. Either
  inline `0` or commit to threading it through. Defer until update +
  delete arrive.

### `lib/eval.ml`

- The slice-11 banner comment (eval.ml:269-273) reads like a commit
  message rather than module documentation. Trim or replace with one
  line tying `eval_mutation` to `eval` ("the mutation entry evaluates
  its source through [eval] inside its own scope, then writes").

### `lib/repl.ml`

- `evaluate_and_print` (lines 32-64) is 33 lines and contains two
  near-identical arms. Extract `print_query_result` and
  `print_mutation_result` so the main function reduces to the
  transaction-kind switch.

- The two `failwith "internal error: ..."` branches in those arms
  (asserting `Query → Query` and `Mutation → Mutation` post-translate)
  duplicate the same shape. A small `unreachable_classification`
  helper, or just `assert false` with a comment, would be cleaner.

## Cross-cutting captures for `CLAUDE.md` — **[done]** (CLAUDE.md "Error messages" section now covers the prefix style, `failwith` vs `assert false`, and `TODO(slice-N)` marker conventions)

A few project conventions are being followed consistently but aren't
captured anywhere. Worth a brief paragraph in `CLAUDE.md`:

- **Error message style**: `Module: detail` or `Module: operation:
  detail`. Use `failwith`, not `invalid_arg`, except for argument-shape
  precondition violations (`assemble_tuple`'s length checks).
- **`failwith` vs `assert false`**: `failwith` for user-reachable
  failures (genuine exceptional cases the user can recover from or
  retry); `assert false` (with a one-line comment) for invariants the
  layering upstream is supposed to guarantee.
- **`TODO(slice-N)` markers** for the slice-1 / slice-6 limitation
  notes (composite PK, non-int64 PK, Marshal-based value encoding).
  Right now those notes appear in prose across four files; a
  searchable marker would shorten the lift when they're addressed.

## Ranked TL;DR

If only some of this gets touched, in priority order:

1. **[done]** Delete `Fixture.encode_users_row`/`encode_orders_row`; use
   `Row_codec.encode_row`. ~20 lines deleted, one parameter removed.
   (commit `dede5b7`)
2. **[done]** Drop the slice-history sentences from the six `.mli` files.
   (commit `fe260ca`)
3. **[done]** Tighten `Schema.find_field` to one dispatch and reclassify the
   qualified-ambiguous case as `assert false`. (commit `8027b92`)
4. **[done]** Sort out `failwith` vs `assert false` in the four flagged spots.
   (commit `a62cc77`)
5. **[done]** Name the indexed-join match (record) and the two `Translate` rules
   (`rewrite_point_lookup`, `rewrite_indexed_nested_loop_join`).
   (commit `75eb671`)
6. **[done]** Move `Row_codec.split_primary_key` to `Schema` as `split_tuple`.
   (commit `50de0f6`)
7. **[done]** Add `with_fixture_environment` and `with_captured_formatter` to
   `test_helpers`; consolidate the duplicated setup. (commit `2421976`)
8. **[done]** Replace `evaluate_insert`'s ref-through-fold with `incr` + `unit`-
   returning `insert_one_row`. (commit `7e9317d`)
9. **[done]** Promote `parse_cli` to `lib/cli.ml`; add `test_cli.ml`.
   (commit `e5696f8`)
10. **[done]** Either flatten `Parser.expression` into top-level precedence tiers
    or accept the inner-let shape and leave a comment. Kept nested,
    comment added. (commit `2d3131d`)

Slice 12 (update + delete) will land an upstream-identity validator and
an assignments sublanguage. The naming-the-rewrites pass (item 5) and
the validator-shape rationalisation (item 4) are the two pieces of
groundwork that pay off there.
