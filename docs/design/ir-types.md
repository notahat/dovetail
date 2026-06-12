# IR types

**Status: mixed — every section below carries its own status line.**
The document interleaves as-built description with proposal. The two
big proposals, neither built: the `Typed_logical` GADT (no such
module exists — `Typecheck` validates a `Logical.t` and returns it
unchanged) and the function-call surface AST (the shipped AST has a
dedicated constructor per operator and no `Call` node). The
`Logical.t`, `Physical.t`, and `Term.t` sections describe the code
as it is, with the divergences noted in place.

The OCaml types that represent a query at each stage of the pipeline,
from the surface AST through the logical and physical IRs to the
runtime payloads `Eval` produces.

## Guiding principle: two vocabularies

**Status: as-built from `Logical` onward; proposal at the surface.**
`Logical` and `Physical` share their composition vocabulary exactly
as described. The surface-AST half describes the proposed AST in the
next section, not the shipped one — though the shipped AST does keep
its own expression and type-expression forms, reaching outside
`surface_ra` only for `Scalar`.

Each IR layer is built from two vocabularies:

- **Operator vocabulary** — the constructors of the layer's `t`
  type. Every layer owns its operator vocabulary outright; the
  whole point of having separate IRs is to express different sets
  of operators (surface forms, algebraic operators, execution
  strategies).
- **Composition vocabulary** — the sublanguages operators contain
  (expressions, projections) and the kind/value types the algebra
  is over (scalars, rows, relations, column references).

The two vocabularies are owned differently in different parts of
the pipeline:

- **The surface AST owns both.** Its operator vocabulary is the
  surface-form pipeline nodes; its composition vocabulary is the
  user's textual forms — names not yet resolved, kinds spelled as
  the user typed them, literals as raw OCaml values. `Lower`
  translates both vocabularies into their semantic counterparts in
  a single pass.
- **From `Logical` onwards, only the operator vocabulary diverges.**
  `Logical` and `Physical` share a single composition vocabulary,
  rooted in `core` (and in shared `plan` sub-modules like
  `Plan.Projection` for the IR-agnostic sublanguages). An
  expression inside `Logical.Restrict` is the same `Expression.t`
  as one inside `Physical.Filter`; a projection inside
  `Logical.Project` is the same `Projection.t` as one inside
  `Physical.Project`. `Translate` swaps operator names and selects
  execution strategies but doesn't reshape any
  composition-vocabulary value.

Treating composition vocabulary as shared library code keeps the
duplication burden honest. Types are duplicated exactly when they
need to be — across the syntax/semantics boundary, where the
surface form and the resolved form are different things — and not
when they don't, as between two IRs over the same algebra.

## Surface AST (`lib/surface_ra/`)

**Status: proposal — not built.** The shipped AST
([`ast.mli`](../../lib/surface_ra/ast.mli)) takes the opposite shape
on the key choice: every operator is a dedicated constructor
(`Restrict`, `Project`, `Join`, …), there is no generic `Call` node
and no operator registry, and expressions live in a separate
`expression` type rather than inside `t`. This whole section — atoms,
supporting records, the twelve-constructor `t`, and the
registry-driven Lower — describes a possible future reshaping, not
the code.

The AST is the structure the parser produces and `Lower` consumes.
Two design choices shape it:

- **The surface is function-call style at the AST level.** Every
  operator the user applies is represented as a named function
  call — pipeline operators (`restrict(rel, predicate)`),
  comparison operators, boolean operators, refinement clauses
  (`primary_key(id)`). This is a statement about the AST, not
  about the concrete syntax: the parser is free to expose any
  user-facing form it wants and desugar to the function-call AST.
  Infix comparison (`a > b`), boolean operators (`a and b`), the
  pipe operator (`users | restrict(active)`), and brace shortcuts
  for high-frequency literals are all parser-level sugar that
  emits ordinary `Call` nodes — the AST only ever sees the
  post-parse function-call form.
- **Literals are structured constructors; operators are generic
  calls.** The literal forms — rows, row types, relations, relation
  types, catalog types — are a small fixed set, so each gets a
  dedicated AST node with a constrained shape. Operators are
  open-ended (new ones land as registry entries, not AST changes),
  so they all flow through a single `Call` constructor whose
  function name is a string.

The asymmetry is deliberate: Lower's dispatch on literals is
exhaustive at the type level (the compiler warns if a new literal
rung lands without handling), while the operator vocabulary stays
extensible without requiring an AST change per operator.

### Atoms

```ocaml
type column_reference = {
  qualifier : string option;
  name      : string;
}
```

`column_reference` captures any bare or dotted identifier:
`name`, `users.id`, `catalog`, `Int64`. Reserved identifiers
(built-in scalar kinds, the bare `catalog` source) are parsed as
`column_reference` values like any other; Lower decides which
names are reserved when it walks the tree.

### Supporting records

The literal constructors below share a few helper records:

```ocaml
type value_binding = {
  name  : column_reference;
  value : t;
}

and type_binding = {
  name            : column_reference;
  type_expression : t;
}

and refinement_clause =
  | Primary_key_clause of column_reference list
  (* Unique_clause, Foreign_key_clause, Check_clause, ... as they
     arrive. *)

and table_binding = {
  name          : string;
  relation_type : t;
}
```

`value_binding` and `type_binding` capture a name-and-payload pair
inside a row or type literal. `refinement_clause` is a closed
variant — every refinement the language supports is an AST
constructor, so adding a new one is a single AST change that the
compiler flags everywhere it's handled. `table_binding` is the
catalog-type analogue: a table name paired with its relation type.

### The AST

```ocaml
and t =
  (* Scalar literals. *)
  | Int_literal    of int64
  | String_literal of string
  | Bool_literal   of bool

  (* A reference to a name: bare [name] or qualified
     [qualifier.name]. Also covers reserved identifiers like
     [catalog], [Int64], [String], [Bool]. *)
  | Identifier of column_reference

  (* Structured literal forms with constrained shapes. *)
  | Row_value      of value_binding list
  | Row_type       of type_binding list
  | Relation_value of { relation_type : t; rows : t list }
  | Relation_type  of { fields      : type_binding list
                      ; refinements : refinement_clause list }
  | Catalog_type   of { tables      : table_binding list
                      ; refinements : refinement_clause list }

  (* Open-ended named operations: every pipeline operator, every
     comparison, every boolean operator, every other named call. *)
  | Call of { function_name : string; arguments : t list }
```

Twelve constructors. They fall into three groups:

- **Atoms.** `Int_literal`, `String_literal`, `Bool_literal`,
  `Identifier`. Terminal nodes carrying primitive values and names.
- **Structured literals.** `Row_value`, `Row_type`,
  `Relation_value`, `Relation_type`, `Catalog_type`. The five
  literal rungs that need an AST shape; each has a constrained
  payload that Lower can dispatch on exhaustively. Catalog values
  are spelled as the reserved `Identifier "catalog"`, not as a
  dedicated constructor — there is only one catalog, and its value
  form has no content of its own.
- **Operators.** `Call`. The single extension point. Every named
  operation flows through here; new operators are registry
  additions, not AST additions.

A few shape notes:

- **`Relation_value.relation_type` is `t`, not `Relation_type`.**
  Today only `Relation_type` literals appear at that position, but
  typing it as `t` leaves room for expressions that compute a
  relation type — a `Call` to `type_of`, a future
  relation-type-valued function, an identifier bound to a relation
  type at some outer scope.
- **`Catalog_type.refinements`** reuses `refinement_clause` until
  cross-table refinements (foreign keys, multi-table checks) need
  their own form. When that lands, the variant either grows new
  constructors or splits into two refinement-clause types.
- **`Row_type` and `Row_value` are separate constructors**, not a
  single `Row` constructor disambiguated by content. The two are
  semantically different at different rungs (a row type lives at
  the kind side of the ladder; a row value at the value side), and
  the constructor-level split lets Lower match on which one
  without inspecting the payload.

### What Lower owns

Lower walks `Ast.t` against the operator registry and produces a
`Logical.t`. The work splits into two clean parts:

- **Literal recognition.** Each structured literal constructor
  maps directly to a `Logical.t` constructor: `Row_value` →
  `Logical.Row_literal`, `Relation_value` →
  `Logical.Relation_literal`, and so on. Scalar literals map to
  `Logical.Scalar_literal`. `Identifier` resolves by position —
  table reference at scan position, column reference inside an
  expression, reserved name for scalar kinds and the catalog
  source.
- **Operator dispatch.** Each `Call`'s `function_name` looks up in
  the registry, which says which `Logical.t` constructor it
  becomes, what shape its arguments must take, and which positions
  expect which rungs. Unknown names, wrong argument counts, and
  obvious shape mismatches fail here with structured errors.

Both parts are purely surface-to-semantic translation — no catalog
lookups, no kind discipline, no validation against stored schemas.
That work belongs to `Typecheck`, which runs on the `Logical.t`
that Lower produces.

## Logical IR (`lib/plan/logical.mli`)

**Status: split — see the per-subsection lines.** The operator
vocabulary and the untyped `Logical.t` are as-built. `Typed_logical`
is a proposal: no such module exists. The `Typecheck` pass shipped
in the error-accumulating shape described here, but its success arm
returns the input `Logical.t` unchanged.

The logical IR is the algebraic representation of a query — what
the query *means* relative to the catalog and the kind ladder,
without committing to *how* it executes. There are two views of
the same vocabulary:

- **`Logical.t`** — a plain ADT. What `Lower` produces. Carries
  no static guarantees about rung or kind agreement; downstream
  consumers must tolerate any combination of operators and inputs
  the constructors permit.
- **`Typed_logical.t`** — a GADT-indexed form. What `Typecheck`
  produces from a `Logical.t` and a `Catalog.kind`. Carries
  static rung discipline (a `Project` cannot wrap a scalar
  source) and the post-validation kind discipline that today
  lives scattered across `Lower`, `Translate`, and `Eval`.

The two are written separately because `Lower` cannot in general
produce the typed form without doing typecheck's job along the
way; keeping the untyped form lets `Lower` stay a simple
surface-to-semantic walker.

### Operator vocabulary

The constructors are shared between the typed and untyped forms —
same algebra, same names. The vocabulary as it stands:

```
Scan, Restrict, Project, CrossProduct,
Relation_literal, Insert, Unqualify, Type_op,
Scalar_literal, Row_literal,
Drop_table, Create_table_empty, Create_table_seeded,
Catalog_source, Tables
```

Constructor names follow relational-algebra terms (σ → `Restrict`,
π → `Project`, × → `CrossProduct`) rather than SQL keywords; the
physical IR's vocabulary (`Filter`, `NestedLoopJoin`, …)
diverges from the logical one because Logical and Physical own
different operator vocabularies, per the guiding principle.

### Untyped form: `Logical.t`

Today's shape, unchanged. Every constructor is monomorphic.

```ocaml
type t =
  | Scan                of { table : string }
  | Restrict            of { input : t; predicate : Expression.t }
  | Project             of { input : t; columns : Projection.t }
  | CrossProduct        of { left : t; right : t }
  | Relation_literal    of { kind : Relation.kind; rows : Scalar.value list list }
  | Insert              of { table : string; source : t }
  | Unqualify           of { input : t }
  | Type_op             of { input : t }
  | Scalar_literal      of Scalar.value
  | Row_literal         of { fields : (Row.column_reference * Scalar.value) list }
  | Drop_table          of { table_name : string }
  | Create_table_empty  of { table_name : string; kind : Relation.kind }
  | Create_table_seeded of { table_name : string; source : t }
  | Catalog_source
  | Tables              of { input : t }
```

`Logical.t` admits trees that `Typecheck` will later reject —
`Project { input = Scalar_literal _; … }`, `Tables` over a
`Scan`, `Insert` whose source columns don't match the target.
That's a feature: the untyped form is the boundary `Lower` walks
to, and `Lower` shouldn't fail with kind errors. Errors are the
typecheck pass's job.

### Typed form: `Typed_logical.t`

**Status: proposal — not built.** There is no `Typed_logical`
module anywhere in `lib/`. Today `Typecheck.typecheck` returns the
input `Logical.t` unchanged on success; the GADT below is the shape
its success arm would widen to if the typed form lands.

The same operators, indexed by the rung of the result:

```ocaml
type rung = [ `Scalar | `Row | `Relation | `Catalog | `Kind ]

type _ t =
  | Scan             : { table : string }                                   -> [`Relation] t
  | Restrict         : { input : [`Relation] t; predicate : Expression.t }  -> [`Relation] t
  | Project          : { input : [`Relation] t; columns : Projection.t }    -> [`Relation] t
  | CrossProduct     : { left  : [`Relation] t; right : [`Relation] t }     -> [`Relation] t
  | Relation_literal : { kind : Relation.kind; rows : Scalar.value list list }
                                                                            -> [`Relation] t
  | Insert           : { table : string; source : [`Relation] t }           -> [`Relation] t
  | Scalar_literal   : Scalar.value                                         -> [`Scalar]   t
  | Row_literal      : { fields : ... }                                     -> [`Row]      t
  | Drop_table       : { table_name : string }                              -> [`Relation] t
  | Create_table_empty  : { table_name : string; kind : Relation.kind }     -> [`Relation] t
  | Create_table_seeded : { table_name : string; source : [`Relation] t }   -> [`Relation] t
  | Catalog_source   :                                                         [`Catalog]  t
  | Tables           : { input : [`Catalog] t }                             -> [`Relation] t
  | Unqualify        : { input : ([< `Relation | `Row] as 'rung) t }        -> 'rung       t
  | Type_op          : (* see below *)
```

The discipline this enforces:

- A `Project`, `Restrict`, `CrossProduct`, `Insert`, or `Unqualify`
  with a non-relation input is untypeable.
- `Tables` with a non-catalog input is untypeable — today's
  `Eval: tables: input is not a catalog` becomes impossible to
  construct.
- The rung of a whole pipeline is visible in its type: a value of
  `[`Relation] t` is a relation-producing query, `[`Scalar] t` is
  a scalar-producing query, etc.

Two operators don't fit the simple pattern:

**`Unqualify`** is rung-polymorphic: it accepts a relation or a
row and returns the same rung. The variant type-variable
constraint `([< `Relation | `Row] as 'rung)` expresses this
without further machinery.

**`Type_op`** takes input of any rung and produces a kind whose
rung mirrors the input — scalar in, scalar-kind out; relation
in, relation-kind out. OCaml's GADTs can't directly express a
type-level function `value_rung → kind_rung_at_that_level`. The
options, in increasing order of expressiveness and complexity:

1. *Coarse:* `Type_op : 'a t -> [`Kind] t`. The output rung is a
   single `[`Kind]` tag; the kind-rung information is lost.
   Simple but defeats the point of the index for this arm.
2. *Paired-rung index:* index by `(rung, [`Value | `Kind])`, with
   `Type_op` flipping the second component. Every other operator
   commits to `[`Value]` in its second slot. Adds friction
   everywhere in exchange for one operator's expressiveness.
3. *Existential wrapper:* let `Type_op` internally forget the
   input rung, exposing only the output rung. Clean externally,
   but a `Type_op` consumer has to use the rung-specific
   information at the time of construction rather than later.

The `Typed_logical` GADT can start with option (1) and grow into
(2) or (3) if the loss of precision starts to cost. Day one, the
five-tag rung covers the rung-discipline wins without forcing the
type-level-function question.

### The Typecheck pass

**Status: largely built.** The pass exists
([`typecheck.mli`](../../lib/plan/typecheck.mli)) and is
error-accumulating with structured errors as described; the
consolidation this section calls for has happened. Two divergences
from the sketch below: the success arm returns the validated
`Logical.t`, not a `Typed_logical.t`, and two of the listed checks
still fire at eval time — unqualify bare-name collisions, and the
create-table name-collision check.

```ocaml
val typecheck :
  catalog : Catalog.kind ->
  Logical.t ->
  (Typed_logical.t, Typecheck.error list) result
```

The pass is error-accumulating from day one: the `Error` arm
carries every problem it found in a single walk, not just the
first. `Ok` means the tree was sound enough to produce a
fully-indexed `Typed_logical.t`; `Error` means at least one
problem prevented that.

This shape serves two consumers without compromise:

- **The REPL** treats `Error errors` as a failure and renders each
  error with its prefix-and-detail string.
- **The LSP** publishes every error as a separate diagnostic, so
  the user sees all their problems at once rather than fixing
  them one round-trip at a time.

An earlier draft used `Typed_logical.t option * Typecheck.error
list` to leave a slot for non-fatal diagnostics (warnings,
deprecations) riding alongside a valid tree. That hedged against
a future need that doesn't actually exist yet, at the cost of an
"impossible" intermediate state (`Some _, _ :: _`) the type
allowed but the implementation never produced. When warnings do
land, the natural place for them is the success arm
(`Typed_logical.t * warning list`), not the error channel.

Typecheck is the single home for everything currently scattered
across `Lower.validate_typed_row`, `Translate.check_columns_match`
/ `check_value_kinds`, and the eager checks in `Eval`. The pass
walks `Logical.t` against a snapshot `Catalog.kind`, and either
produces a `Typed_logical.t` (rung-correct by construction,
kind-validated by traversal) or a structured `Typecheck.error`
that names the failure and points at the offending node.

What the pass checks:

- **Rung discipline** — every operator's input rungs match what
  it requires. Caught by the GADT itself; the pass's job is to
  refuse to produce a `Typed_logical.t` when the `Logical.t`'s
  shape would violate the indexing.
- **Column resolution** — every column reference in an
  `Expression` or a `Projection` resolves uniquely against its
  input row kind (today: `Expression.resolve`,
  `Projection.resolve`, run at `Eval` time).
- **Kind agreement** — comparisons agree on operand kind,
  predicates are Bool-kinded, `Insert` source columns match
  target columns by name and kind (today:
  `Translate.check_columns_match` / `check_value_kinds`).
- **Unqualify collisions** — bare names are unique after
  qualifier stripping.
- **Catalog lookups** — every `Scan`, `Insert`, `Drop_table`
  references a table the catalog knows about; every
  `Create_table_empty` doesn't collide with an existing name.

What stays at runtime, because it depends on values not kinds:

- **PK collisions on `Insert`** — discovered as rows arrive, not
  at typecheck time.
- **`Create_table_seeded`** — the target kind is derived from the
  source's runtime kind, so typecheck reports the source's static
  kind and the executor commits the actual kind at write time.

The pass is pure with respect to the catalog: it takes a
`Catalog.kind` value, doesn't reach into storage. That's how it
serves both the REPL (catalog snapshot from a live transaction)
and tools that don't have a database open (catalog snapshot from
a schema file).

### Language-server fit

**Status: proposal — no language server exists.** The pipeline
diagram's `Typecheck → Typed_logical` step today produces a
validated `Logical.t`. Of the two plumbing items at the end of this
section, structured errors have since landed (`Typecheck.error`
carries the offending names and kinds, though not positions); source
positions remain unbuilt.

A future language server is the second consumer of this pipeline,
and the typed/untyped split is what makes it tractable.

The LSP's request-handling pipeline mirrors the REPL's, minus
execution:

```
text → Parse → Ast → Lower → Logical → Typecheck → Typed_logical
                                            │
                                            └→ diagnostics
```

Each step is a candidate failure point and a candidate
information source. `Parse` produces syntax errors; `Lower`
produces surface-resolution errors; `Typecheck` produces kind and
rung errors. All three feed the LSP's `textDocument/diagnostic`
response.

For features beyond diagnostics, the typed IR earns its keep:

- **Hover** — "what's the kind of the expression under my
  cursor?" answers itself if the LSP can walk a `Typed_logical.t`
  and read off the rung at the matching node. The kind-discipline
  checks Typecheck did are now standing facts about every node.
- **Completion** — "what column names are valid here?" needs to
  know the row kind in scope at the cursor position. That kind is
  the input kind of whichever operator the cursor sits inside —
  derivable from `Typed_logical.t` without a separate analysis.
- **Go-to-definition for column references** — a column reference
  in an `Expression` resolves (during typecheck) to a specific
  field in a row kind. Threading the resolved position through
  into `Typed_logical` makes "jump to the schema declaration of
  this column" a constant-time lookup.

Two pieces of plumbing the LSP needs that the current pipeline
doesn't yet provide:

1. **Source positions threaded through the AST.** The LSP needs
   to map a `Typed_logical` node back to the byte range of the
   surface form it came from, so diagnostics and hover targets
   land at the right place. Today the AST carries no position
   information; adding it is a parser-level change that the LSP
   will eventually force.
2. **Structured errors instead of `Failure`.** Today every check
   raises `Failure (Printf.sprintf "Translate: …")` with a
   string. The LSP needs error values that carry a position, a
   category, and the offending names — `Typecheck.error` is the
   right place to introduce the structured form, and the REPL
   can render it back to a string with the same `Prefix: detail`
   shape it produces today.

The catalog snapshot is the one piece the LSP shares with the
REPL: `Catalog.kind` is just a value, and where it comes from
(live LMDB transaction, schema file, in-memory test fixture) is
the caller's choice. `Storage.Catalog.snapshot_kind` serves the
REPL; an LSP would call it when an editor is connected to a
running database, or load a `Catalog.kind` from disk when it
isn't. Neither case requires the `surface_ra` or `plan`
libraries to depend on `storage`.

## Physical IR (`lib/plan/physical.mli`)

**Status: as-built, with two arm shapes out of date.** In the
shipped [`physical.mli`](../../lib/plan/physical.mli), `IndexLookup`
carries `key : int64` rather than an `Expression.t`, and
`IndexedNestedLoopJoin` is
`{ outer; inner_table; outer_key_column; inner_position }` rather
than the left/right/index shape shown below. The "typed front door"
at the end of the section is a proposal — see its note.

The physical IR is the execution-strategy representation of a query
— what the query *does*, operator by operator, against the storage
engine. It's the layer `Eval` pattern-matches over, and the layer
where join and lookup strategies become concrete.

### Composition vocabulary: shared with Logical

Per the guiding principle, Physical and Logical share a single
composition vocabulary. An `Expression.t` inside `Physical.Filter`
is the same `Expression.t` as inside `Logical.Restrict`; a
`Projection.t` inside `Physical.Project` is the same one as inside
`Logical.Project`; `Row.kind`, `Relation.kind`, and `Scalar.value`
are the same values on either side. `Translate` does not reshape
any composition-vocabulary value as it walks from Logical to
Physical — it swaps operator names and selects strategies, nothing
more.

### Operator vocabulary: diverges from Logical

The operator vocabulary is where the two IRs part ways. Logical
names the algebra; Physical names the execution strategy.

```
FullScan, Filter, Project, CrossProduct,
IndexLookup, NestedLoopJoin, IndexedNestedLoopJoin,
Relation_literal, Insert, Unqualify, Type_op,
Scalar_literal, Row_literal,
Drop_table, Create_table_empty, Create_table_seeded,
Catalog_source, Tables
```

The mapping from Logical to Physical falls into two groups:

- **Mechanical lifts.** Most operators have a one-to-one Physical
  counterpart with the same shape: `Restrict` → `Filter`,
  `Project` → `Project`, `Scan` → `FullScan`, `CrossProduct` →
  `CrossProduct`, plus the literal, DDL, source, and `Insert` /
  `Unqualify` / `Type_op` / `Tables` / `Catalog_source` operators
  that carry their Logical name into Physical unchanged.
- **Strategy rewrites.** Two patterns get reshaped:
  - `Restrict(CrossProduct(left, right), predicate)` folds into a
    single `NestedLoopJoin { left; right; predicate }`. The Logical
    form is the algebraic statement ("the cross product, filtered");
    the Physical form is the execution strategy ("a nested loop
    that emits matching pairs").
  - When the join predicate is an equality against an indexed
    column on the right input, the rewrite picks
    `IndexedNestedLoopJoin` (probe the right's index per outer row)
    or `IndexLookup` (when the left side is a constant).

The strategy rewrites are where `Translate` does its interesting
work; the mechanical lifts are bookkeeping.

### Type: plain ADT

```ocaml
type t =
  | FullScan              of { table : string }
  | Filter                of { input : t; predicate : Expression.t }
  | Project               of { input : t; columns : Projection.t }
  | CrossProduct          of { left : t; right : t }
  | IndexLookup           of { table : string; key : Expression.t }
  | NestedLoopJoin        of { left : t; right : t; predicate : Expression.t }
  | IndexedNestedLoopJoin of { left : t; right : t; index : ...; predicate : Expression.t }
  | Relation_literal      of { kind : Relation.kind; rows : Scalar.value list list }
  | Insert                of { table : string; source : t }
  | Unqualify             of { input : t }
  | Type_op               of { input : t }
  | Scalar_literal        of Scalar.value
  | Row_literal           of { fields : (Row.column_reference * Scalar.value) list }
  | Drop_table            of { table_name : string }
  | Create_table_empty    of { table_name : string; kind : Relation.kind }
  | Create_table_seeded   of { table_name : string; source : t }
  | Catalog_source
  | Tables                of { input : t }
```

Unlike Logical, Physical has no GADT-indexed twin. The reasoning:

- **Translate is the only producer.** Typed_logical → Physical is
  a mechanical walk; if the input is well-typed, the output is
  well-typed too. There's no second author writing Physical trees
  whose constructions need policing.
- **Type errors land at Logical.** Every kind / rung / column
  error a user can hit is caught at Typecheck. Errors that would
  reach a hypothetical Typed_physical are compiler bugs in
  Translate, not user bugs.
- **Eval stays simple.** The executor pattern-matches over
  `Physical.t` and threads a single `Term.t` envelope. Adding a
  rung index would propagate through every operator's
  continuation signature without catching anything execution
  tests don't already catch.

The typed front door is at Translate's input, not Physical's
arms:

```ocaml
val translate : Typed_logical.t -> Physical.t
```

**Proposal.** With no `Typed_logical`, the shipped signature is
`translate : catalog:(string -> Relation.kind option) -> Logical.t
-> Physical.t`; the guarantees below hold by virtue of `Typecheck`
having validated the same `Logical.t` beforehand, not by type.

Whatever guarantees Typed_logical established stay in force as
Translate runs; once the result is a `Physical.t`, those
guarantees are invariants Translate is responsible for
preserving, but they're not re-stated in the Physical type.

### `Physical.kind_of`

```ocaml
val kind_of : catalog:(string -> Relation.kind option) -> t -> Relation.kind
```

Computes the result kind of a Physical node without executing it.
Two callers use it today:

- **Eval** — at points where the operator needs its input's row
  kind (column resolution, qualifier handling) before pulling any
  rows.
- **The planner / Translate** — when picking an execution
  strategy depends on the input's kind (e.g. is the column being
  joined on indexed?).

`kind_of` doesn't typecheck; it assumes the tree is well-formed
and computes. A malformed tree raises `Failure`, which from
Physical's standpoint is a compiler-bug signal, not a user-error
signal.

## Runtime payloads (`lib/core/term.mli`)

**Status: as-built.** Matches
[`term.mli`](../../lib/core/term.mli) arm for arm, catalog arms
included. The references to "the Typed_logical GADT" point at the
unbuilt proposal above.

`Term.t` is the unified payload that flows through Eval's
continuations and falls out the end of a pipeline. Everything an
operator emits — every intermediate value handed from one
operator's continuation to the next, plus the final value the
REPL renders — is a `Term.t`.

### Shape: rung × face

Term covers two orthogonal axes:

- **Rung** — scalar, row, relation, catalog. The four rungs of
  the kind ladder; the same four the Typed_logical GADT indexes
  over.
- **Face** — value or kind. Every rung has both. A row has a
  value (the field-by-field data) and a kind (the field-name and
  scalar-kind declarations); a relation has a value (the row
  stream) and a kind (the schema and refinements); and so on.

The cross-product gives eight arms:

```ocaml
type 'tag t =
  | Scalar_value   of Scalar.value
  | Scalar_kind    of Scalar.kind
  | Row_value      of Row.t
  | Row_kind       of Row.kind
  | Relation_value of 'tag Relation.t
  | Relation_kind  of Relation.kind
  | Catalog_value  of Catalog.value
  | Catalog_kind   of Catalog.kind
  constraint 'tag = [< `Set | `Bag ]
```

The `'tag` parameter is the `[`Set | `Bag]` multiplicity that
`Relation.t` already carries. It propagates through `Relation_value`
and is unconstrained on the other arms; Term doesn't *add* a phantom,
it just plumbs the one Relation already has.

### Why both faces

The kind arms are what `| type` and the upcoming `| schema` operators
produce. They share the envelope with the value arms because the
machinery is the same: an operator's continuation receives a `Term.t`,
and dispatching on the arm is how the consumer figures out what to do
— render a row, walk a cursor, format a schema. Splitting them into
separate types would mean two parallel pipelines through Eval, which
isn't worth it for what is, downstream, the same dispatch.

### Why not a GADT

Term is a plain ADT for the same reason Physical is: there's no second
author to police, and the runtime errors a GADT would prevent are
caught upstream at Typecheck. An indexed `'rung 'face Term.t` would
let Eval's signature carry the rung statically (as discussed in the
Physical section) — but at the cost of indexing every consumer, every
formatter, every test assertion. The win doesn't pay for the surface
area.

If a caller wants rung-static dispatch, the lever is the same as for
Physical: hold onto the `Typed_logical.t` alongside the result. The
rung is already in that value's type.

### Where Term sits in the libraries

`Term` lives in `core` alongside the kind-ladder modules it composes.
Both Logical and Physical reach into `core` for their composition
vocabulary, and Eval's continuation type names `Term.t` from the same
place. The REPL imports it for formatting; integration tests assert
against its arms. Nothing in `surface_ra` mentions it — Term is the
runtime side of the wall, not the surface side.

## Open questions and follow-ups

**Status: forward-looking by design.** Two items presuppose unbuilt
proposals: `Type_op`'s rung handling assumes `Typed_logical`, and
the registry question assumes the `Call`-based AST. The
source-positions item remains open; its structured-error half has
since landed as `Typecheck.error`.

Things this design defers rather than answers. Worth revisiting as
the relevant rungs come into focus, but not worth pinning down
upfront.

### `Type_op`'s rung handling

The Typed_logical section sketches three options for indexing
`Type_op`, and recommends starting with option 1 (coarse
`[`Kind]` output, losing the input's rung). That's fine while the
language only supports `value | type` and stops there. The moment
we want to chain — `users | type | …`, or `users | type | schema`
— the loss of precision starts to matter: downstream operators
have no way to constrain their input to "a kind of a relation"
versus "a kind of a row".

The right answer probably emerges from real use. Track it as the
operators that consume kinds land, and graduate to option 2 or
option 3 if option 1 starts forcing runtime dispatch that the
GADT could have eliminated.

### Source positions in the AST

Listed in the LSP section as plumbing the language server needs,
but it's a general improvement that pays off well before any LSP
work. Today every error message renders as
`Prefix: detail` with no cursor into the source — the user is
told *what* went wrong but not *where*. Threading byte ranges
through the AST, into Logical, and into `Typecheck.error` would
let even the REPL underline the offending span.

This is independent of the LSP slice and could land as its own
slice whenever the lift is worth the diagnostic improvement.

### Operator registry shape

Lower's dispatch on `Call` nodes goes through "the operator
registry" but the registry's shape is undefined. Real entries
will need to declare:

- The Logical constructor the call lowers to.
- The argument shapes (positional, named, optional) and the rung
  each argument expects.
- Any per-operator rules Lower applies before handing off to
  Typecheck (purely structural things — duplicate-argument
  detection, mutually-exclusive options).

Best deferred until two or three real entries are in hand;
generalising from one is always a guess. The dispatch mechanism
can stay informal — pattern-match on `function_name` — until the
right abstraction shows itself.

### When the typed/untyped Logical split stops earning its keep

The typed Logical form costs maintenance: every operator gets
named twice, every constructor change touches two definitions.
The split pays off as long as `Typecheck` has meaningful work to
do — rung discipline, kind agreement, column resolution,
structured errors for the LSP.

If a future direction (heavy compile-time rewrite passes that
work directly on the untyped form, a different LSP architecture,
…) reduces what Typecheck contributes to mechanical bookkeeping,
the split should collapse back to a single ADT. Watch for the
smell of trivial GADT arms that mirror their ADT counterparts
without adding constraint — that's the signal the typed form has
stopped paying for itself.
