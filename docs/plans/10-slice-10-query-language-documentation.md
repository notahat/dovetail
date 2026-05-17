# 10 — Slice 10: Query-language documentation

The tenth vertical slice, and the first that delivers no
runtime behaviour. End-state: a new `docs/query-language.md`
gives a reader who already knows SQL a working guide to
Dovetail's pipeline-style query language — what runs in the
REPL today, how to spell each operator, and how the expression
and projection sublanguages compose. A doctest extractor runs
every example block through the REPL during `dune test` so the
doc cannot silently drift from the implementation.

The slice description in the README's roadmap reads "Short
tutorial intro followed by reference sections for each operator
and for the expression and projection sublanguages. Covers only
what exists." That is the brief; the rest of this document is
the design that delivers it.

## Context

Slices 1–9 grew the query language to the point where it
deserves a written guide: bare relation references, `restrict`,
`project`, `cross`, `join ... on`, an expression sublanguage
with six comparison operators and boolean composition, and a
projection sublanguage that takes bare or qualified column
references. The `.mli` files document each layer for someone
reading the code; the slice plans document each addition for
someone reviewing the design. Neither addresses the reader who
wants to *use* the REPL.

The README's "Query language examples" section has carried
that load to date — three worked examples, three or four
operators apiece, deliberately illustrative rather than
systematic. It is the right shape for a project README but the
wrong shape for a reference: a reader who wants to know what
`restrict` accepts cannot find it.

Slice 10 closes that gap with one new document and a small
test that runs every example through the REPL. No runtime
code changes; the storage stack, executor, and IRs are
untouched.

## Goal

End-state artefacts:

1. `docs/query-language.md` — the new guide.
2. `test/test_documentation.ml` plus a `test/doctest.ml`
   helper — an alcotest suite that, for each markdown file in
   a configurable list (initially `docs/query-language.md` and
   `README.md`), extracts every `> `-prefixed example block,
   runs the queries through `Repl.run` against a freshly
   populated fixture environment, and asserts the rendered
   output matches what the markdown claims.
3. `README.md` trimmed: the "Query language examples" section
   shrinks to one teaser example plus a link to the new doc.

The doc itself targets a SQL-literate reader. Tables, joins,
predicates, and projections are familiar concepts; the
unfamiliar thing is the pipeline syntax (`relation | op | op
...`) and how each operator spells out in Dovetail. The
tutorial shows that by example; the reference systematises it.

Concretely, the doc's table of contents looks like:

```
# Query language
## Running the REPL
## The fixture
## Tutorial
## Reference: pipeline operators
  ### Relation references
  ### restrict
  ### project
  ### cross
  ### join
## Reference: expressions
  ### Literals
  ### Column references
  ### Comparisons
  ### Boolean operators
  ### Parentheses
  ### Precedence and associativity
## Reference: projections
```

After slice 10, every public surface of the query language
that exists at HEAD is described in one document, every code
example in that document is executed during `dune test`, and a
reader can go from "I know SQL" to "I can write Dovetail
queries against the fixture" without reading any source.

## Slice-10 architectural decisions

### Audience and scope: SQL-literate, strict "covers only what exists"

Two cross-cutting decisions shape every other choice in this
slice.

**Audience.** The doc assumes the reader knows what a table,
row, column, join, predicate, and projection are. It does not
explain relational algebra and does not use σ/π/× notation.
That notation lives appropriately in the `.mli` files and
slice plans; the user-facing doc would only obscure the
pipeline syntax that is actually new to the reader. The
tutorial's job is to translate familiar concepts ("filter
rows", "pick columns", "join two tables") into Dovetail's
pipeline spelling.

**Strict scope.** "Covers only what exists" is read literally:
no mentions of NULLs, sorting, limiting, aggregation,
distinct, set operators, DML, DDL, sub-queries, or any other
SQL feature that has not yet landed in the engine. A reader
who reaches for those features will find they don't parse —
the doc deliberately does not anticipate that. The roadmap in
the README is the appropriate home for "what's coming"; the
query-language doc is a present-tense document.

Rejected alternative: an "Inline mentions where natural" or
"Not yet supported" section that calls out missing SQL-isms.
Both bleed the scope discipline that the slice description
sets. The cost — a SQL-literate reader briefly confused when
`order by` fails to parse — is small, and the roadmap is one
README away.

### Single file: `docs/query-language.md`

The doc is one markdown file under `docs/`, not a folder of
files and not an expansion of the README in place.

A folder would over-structure the current content — five
operators and two small sublanguages are not enough to justify
the navigation cost of multiple files. The README would grow
uncomfortably large if the full reference moved into it, and
the README's job is to introduce the project rather than
document its query language. A new file under `docs/` matches
the project's existing convention for design content (`docs/
plans/...`) and gives the reference content a stable home.

The README's "Query language examples" section shrinks to one
striking example (the canonical join-and-project) plus a
"See [`docs/query-language.md`](docs/query-language.md) for
the full guide." link. README keeps a taste of the language
without duplicating the reference.

### Top-level structure: tutorial then reference

The doc opens with three orientation sections — Running the
REPL, The fixture, Tutorial — and then turns into a reference.

- **Running the REPL.** A few lines: `./dovetail` boots the
  REPL against the default data directory, queries are typed
  one per line, `Ctrl-D` exits. Points the curious to the
  README for build/install detail. No mention of
  `--show-physical`; that flag is dev-facing.
- **The fixture.** A dedicated section showing the two
  fixture tables (`users` and `orders`) with their column
  lists, kinds, primary keys, and the rows the REPL boots
  with. Every later example reads against this data, so the
  reader has it in one place to refer back to.
- **Tutorial.** A single growing example: start with `users`,
  add `| restrict active`, add `| project name, email`, bring
  in `orders` via `| cross orders`, convert to `| join orders
  on users.id = orders.user_id`, finish with another
  `| project`. Each addition is one paragraph of prose and one
  query/output pair, all reading the same fixture so the
  reader can follow the data through the transformations. The
  goal is to give the reader the *feel* of pipeline composition
  before the reference systematises it.

Then the reference, in three parts: pipeline operators,
expressions, projections.

Rejected alternatives:

- **One operator per file under a `docs/query-language/`
  folder.** Over-structured for current content volume; adds
  navigation cost without payoff.
- **No separate tutorial; each reference section opens with a
  motivating example.** The slice description explicitly asks
  for a tutorial intro, and the pipeline syntax benefits from
  one continuous narrative that *composes* operators —
  per-section intros can't show composition.
- **Tutorial as a dissection of the canonical join query.**
  Tighter but front-loads the most complex example; the
  growing version meets the reader where they are.

### Operator reference template: syntax, description, example

Each pipeline operator (relation reference, `restrict`,
`project`, `cross`, `join`) gets a subsection of identical
shape:

```
### restrict

**Syntax:** `<input> | restrict <predicate>`

Keeps rows of `<input>` for which `<predicate>` evaluates to
true. The predicate must resolve to a Bool; see [Reference:
expressions](#reference-expressions) for the predicate
language. The output schema is `<input>`'s schema unchanged.

\```
> users | restrict active
│ users.id │ users.name │ ... │
...
\```
```

Three parts: a syntax line in code formatting, a short prose
description that covers semantics and any edge cases worth
flagging (output schema, kind constraints, qualifier
behaviour), and one worked example. Notes that would otherwise
be a bullet list are folded into the description prose.

The uniformity matters. A reader scanning for "what does
`project` do to qualifiers?" knows to look in `project`'s
description paragraph; a reader who wants the syntax knows to
look at the syntax line. Per-operator templates that vary in
structure make the doc harder to scan.

Rejected alternatives:

- **Syntax + description + example + a Notes bullet list per
  operator.** Half the operators would have an empty Notes
  block; the description paragraph can carry the same content
  without the structural overhead.
- **Multiple examples per operator.** Reads richer but bloats
  the doc and shifts emphasis from systematic reference to
  cookbook. The tutorial already carries the multi-example
  load; the reference's job is to be tight.

### Expression sublanguage: subsection per construct + precedence table

The expression reference has six subsections:

- **Literals** — `int64` (`-1`, `0`, `42`), string (`"..."`
  with `\"` and `\\` escapes), bool (`true`, `false`).
- **Column references** — bare (`name`) and qualified
  (`users.name`); no whitespace around the dot; resolution
  rules (unique-match required).
- **Comparisons** — six operators (`=`, `<>`, `<`, `<=`, `>`,
  `>=`); kind rules (`=` and `<>` accept any matching kind,
  the four ordering ops accept Int64 or String).
- **Boolean operators** — `and`, `or`, `not`; short-circuit
  evaluation; Bool operands only.
- **Parentheses** — grouping for precedence override.
- **Precedence and associativity** — a small table covering
  the full hierarchy (atoms tightest, then comparisons, `not`,
  `and`, `or` loosest), with associativity noted per level.

Each construct subsection follows the same syntax + description
+ example template as the operators. The precedence table
sits at the end as a one-stop reference for "which way does
this bind".

The structure mirrors the parser MLI's own organisation of the
grammar from atoms outward, which keeps the doc and the
implementation talking about the language in the same terms.

Rejected alternatives:

- **Grammar block up top, prose underneath.** A BNF-ish block
  is precise but slow to read; subsection-per-construct
  matches how SQL-literate readers look things up ("what's
  the syntax for a string literal?" → jump to Literals).
- **Just a precedence table + worked examples.** Too sparse
  for a reference; the per-construct breakdown captures kind
  rules and resolution semantics that a table cannot.

### Projection sublanguage: one short section

The projection language is a single grammar production
(comma-separated column references). The reference is one
section, not subsections: syntax, description (order
preserved; bare or qualified column references accepted;
duplicate references rejected; output schema retains each
column's qualifier from the input), and one worked example.

Parallel structure with the expression reference would
over-engineer a language that has one production.

### Doctest extractor: convention, scope, infrastructure

A small test helper extracts every doctest block from a
configurable list of markdown files, runs the queries through
the REPL against a fresh fixture-populated environment, and
asserts the rendered output matches what the doc claims.

**Block convention.** A fenced code block (triple-backtick) is
treated as a REPL session if and only if its first non-blank
line starts with `> ` (a single greater-than followed by a
space). Inside a session, every line that starts with `> ` is
a query; the following lines (up to the next `> ` or the end
of the block) are the expected rendered output of that query.
Fenced blocks that don't start with `> ` are ignored — shell
snippets, OCaml code, and ASCII diagrams pass through
untouched.

This convention is unambiguous against the existing prose
style (no Dovetail query begins with anything other than an
identifier, so `> ` never appears as the first character of a
real query line) and requires no new fence-language tag. It
reads naturally as markdown.

**Scope.** The test takes an explicit list of files. The
initial list is `["docs/query-language.md"; "README.md"]`.
README is included because its surviving teaser example is
the same shape and benefits from the same protection against
drift. Auto-scanning the whole repo is rejected: it would
sweep up plan documents whose `> `-prefixed lines may be
illustrative pseudo-output rather than executable queries.

**Infrastructure.** A new helper `test/doctest.ml` exposes a
function shaped roughly:

```ocaml
val verify_file :
  Storage.environment ->
  markdown_path:string ->
  (unit, error) result
```

which parses the markdown, runs every doctest session against
`environment`, and returns a structured error on first
mismatch. The alcotest entry `test/test_documentation.ml`
opens a fresh fixture-populated env per file (mirroring
`test_repl.ml`'s `run_with_input` pattern) and asserts each
file verifies clean.

The extractor reuses `Repl.run` rather than calling parser /
lower / translate / eval directly: doctests assert what the
*user* sees, which means going through the same code path the
REPL does, including the same `Relation.print` formatting.

**Comparison model.** The captured REPL output for a session
is split on its `> ` prompts; each segment between prompts is
the rendered output of the preceding query. Comparison against
the doc's expected output is byte-for-byte after trimming a
single trailing newline (the formatter emits one;
copy-pasting into markdown does not always preserve it). A
mismatch reports the file path, the query, and a unified-diff
view of expected vs. actual.

**Errors are out of doctest scope.** Every example in the doc
is a successful query that produces a rendered table. The doc
does not include intentional-error examples; the extractor
correspondingly does not need to recognise expected-error
blocks. If a future slice motivates documenting error
behaviour, the convention can be extended (e.g., an `! ` prefix
for expected-error blocks).

### No runtime code changes

Slice 10 touches `docs/`, `README.md`, and `test/` only. No
`.ml` or `.mli` files in `lib/` or `bin/` change. The
`Repl.run` interface is sufficient for the doctest extractor;
no new public API is needed.

This is the first slice with that shape, and it is worth
stating explicitly: the per-layer unit + per-step integration
test pattern from the codebase conventions applies to
behaviour-changing slices. Slice 10's testing burden lives
entirely in the doctest suite, which *is* the per-step
integration test.

## Sub-steps

Each step is one commit, ends with `dune test` green, and
leaves the project in a working state. Per-step the test
suite gains coverage of whatever doc content that step adds.

### Step 1 — Doctest extractor and skeleton doc

Add `test/doctest.ml` (the extractor and verifier) and
`test/test_documentation.ml` (the alcotest entry). Create
`docs/query-language.md` with just enough content to exercise
the extractor end to end: a top-level heading, a "Running the
REPL" section with a one-paragraph description and one query
block (`> users` showing the full fixture), and a "The
fixture" section showing the two tables' schemas and rows
inline (using prose plus a query block per table — `> users`
and `> orders` — so the rendered rows in the doc are
verified, not hand-copied).

Wire `test/test_documentation.ml` into `test/dune` and into
`test_dovetail.ml`'s alcotest entry. Initial file list:
`["docs/query-language.md"]`. README is not yet in scope;
step 4 adds it.

Tests:

- `test/test_documentation.ml` — runs the verifier against
  `docs/query-language.md` and asserts it succeeds.
- `test/test_doctest.ml` (a separate unit-test file alongside
  the helper) — small focused tests on the extractor:
  - A fenced block whose first non-blank line starts with `> `
    is recognised as a session.
  - A fenced block whose first line does not start with `> `
    is ignored.
  - A session with multiple `> ` queries splits cleanly.
  - A doc whose expected output disagrees with the actual REPL
    rendering produces a `Mismatch` error carrying the query
    and the diff (test by feeding a hand-built markdown
    fragment with deliberately-wrong expected output).
  - A doc with no doctest sessions verifies trivially clean.

After this step, the extractor is exercised by real content,
the doc has a skeleton, and adding more sections is a matter
of writing markdown and watching the test stay green.

### Step 2 — Intro and tutorial

Extend `docs/query-language.md` with the Tutorial section
(after Running the REPL and The fixture from step 1). The
tutorial builds one query in stages, each stage one paragraph
of prose and one query block:

1. `users` — every row of the table, qualifiers visible in the
   header.
2. `users | restrict active` — introduce the pipe and the
   `restrict` operator using the Bool column.
3. `users | restrict active | project name, email` — introduce
   `project`; note that the column qualifiers carry through.
4. `users | cross orders` — introduce `cross`; show the
   combined schema, motivate why a raw cross product is rarely
   what you want.
5. `users | join orders on users.id = orders.user_id` —
   introduce `join ... on`; explain qualified column references
   in the `on` clause.
6. `users | join orders on users.id = orders.user_id | project
   name, description, amount` — finish with a projection over
   the join, the canonical multi-operator query.

Six query blocks; every one is a doctest. The prose between
them is the *only* place the doc explains pipeline composition
in narrative form — the reference sections that follow are
deliberately tighter.

Tests:

- `test/test_documentation.ml` — the existing verifier picks
  up the new blocks automatically; the test should remain
  green after this step.

### Step 3 — Pipeline operator reference

Add the `## Reference: pipeline operators` section with five
subsections (`### Relation references`, `### restrict`, `###
project`, `### cross`, `### join`). Each subsection follows
the syntax + description + example template:

- **Relation references** — bare table name; reads the whole
  table; output schema is the table's schema; qualifiers
  default to the table name.
- **restrict** — pipe form, predicate must resolve to Bool,
  output schema unchanged, qualifier behaviour unchanged.
- **project** — comma-separated column references; bare or
  qualified; order preserved; duplicates rejected. (Cross-
  refs the projection sublanguage section.)
- **cross** — combined schema is left's fields followed by
  right's, each retaining its qualifier; predicate-free.
- **join** — sugar for `cross` plus `restrict` on the
  `on`-clause predicate; same combined-schema rule as `cross`;
  the predicate language is the same as `restrict`'s.

Each subsection has one worked example as a query block, all
reading the fixture, all doctested.

Tests:

- `test/test_documentation.ml` — verifier covers the new
  examples automatically.

### Step 4 — Expression reference, projection reference, README teaser

Add the `## Reference: expressions` section with subsections
for literals, column references, comparisons, boolean
operators, parentheses, and a closing precedence /
associativity table. Add the `## Reference: projections`
section as a single short section.

Most subsections include a doctested example query that
demonstrates the construct (string literal in a comparison, a
qualified-column-reference comparison, an `and`/`or`/`not`
combination, a parenthesised override of precedence, a
projection with duplicates-rejected behaviour shown only
through a successful example since errors are out of doctest
scope).

Then update the README:

1. Trim the existing "Query language examples" section to one
   teaser example — the canonical join with a trailing
   projection, the same query the tutorial ends on. (Keeps the
   reader's first impression of the language vivid in the
   README itself.)
2. Add a "See [`docs/query-language.md`](docs/query-language.md)
   for the full guide." sentence under the teaser.
3. Extend the doctest extractor's file list in
   `test/test_documentation.ml` to include `"README.md"`. The
   teaser example becomes a verified doctest.

Tests:

- `test/test_documentation.ml` — verifier now scans both
  files; green after the README trim.

After step 4, the slice is complete: full guide in place,
every example verified, README pointing at the guide with one
illustrative example of its own.

## Verification

End-of-slice manual smoke:

- `opam exec -- dune test` is green; `test_documentation`
  exercises every example block in `docs/query-language.md`
  and `README.md`.
- `opam exec -- dune build @fmt --auto-promote` leaves the
  tree clean.
- `./dovetail` boots; entering each tutorial-section query
  produces output that matches the doc verbatim. (Redundant
  with the test, but a useful sanity check that the doc-as-
  written reads naturally when followed line by line.)
- The README still gives a reader-with-no-context a sense of
  the language in under a minute, and points unambiguously at
  the new guide for everything else.

## Out of scope

- **Features that don't exist yet.** No mentions of NULLs,
  sorting, limit, distinct, aggregation, group by, set
  operators, DML, DDL, sub-queries, expressions that produce
  non-bool values at the top level of a predicate, or any
  other SQL feature whose engine support is still on the
  roadmap. The README's roadmap remains the home for
  "what's coming".
- **Documenting `--show-physical` and the physical-plan
  layer.** Dev-facing; lives appropriately in the slice plans
  and the README's layer diagram, not in the user guide.
- **Relational-algebra notation (σ, π, ×) in the user doc.**
  The `.mli` files and slice plans use these terms; the user-
  facing doc does not.
- **Error-message documentation and intentional-error
  examples.** All doctest examples are successful queries. If
  a future slice motivates documenting error behaviour, the
  doctest convention can be extended (e.g., an `! ` prefix
  for expected-error blocks).
- **An EXPLAIN-style introspection guide.** Plan introspection
  is on the roadmap; when it lands, it will get its own slice
  and likely its own doc section.
- **SQL surface coverage.** A SQL frontend is slice 13; its
  documentation is that slice's concern, not slice 10's.
- **An internals walkthrough that follows a query through the
  layers.** Listed in the README's "Beyond" backlog; out of
  scope here.
