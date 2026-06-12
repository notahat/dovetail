# Ubiquitous language

Shared vocabulary for Dovetail. Terms defined here have one
meaning across the codebase, slice plans, design docs, and
this guide; if you find a term used differently somewhere,
that is the bug.

The list grows organically as terms come up — there is no
attempt at completeness. Add an entry when you find yourself
explaining what a word means, or when two pieces of writing
use the same word to mean different things.

## AST — Abstract syntax tree

The structured form of a query as the parser produces it,
before any semantic interpretation. The AST mirrors the
*syntax* the user typed: each node corresponds to a grammar
production, and the tree's shape reflects the way operators
were composed in the source text.

The AST does not yet know what anything *means*. A
syntactically valid query may still refer to tables that do
not exist, columns that do not match a schema, or operators
in combinations that are semantically nonsense. Those checks
belong to later layers.

In Dovetail the AST lives in
[`lib/surface_ra/ast.mli`](../../lib/surface_ra/ast.mli), and is the
output of the parser and the input to `Lower`.

## Catalog

The database's collection of named tables, plus any invariants
that span tables (foreign keys, cross-table check expressions,
and so on — none implemented yet). What `create table` and
`drop table` mutate, and what queries consult to resolve a
table name to the relation behind it.

The top rung of the type ladder, though the framework-shaped
value type for a catalog hasn't been built yet — today the
catalog exists only as the operations against persistent
storage that read and write it. The target shape is sketched in
[`docs/design/type-ladder.md`](../design/type-ladder.md); the as-built operations
live in
[`lib/storage/catalog.mli`](../../lib/storage/catalog.mli).

## CPS — Continuation-passing style

A control-flow shape in which a function, instead of
returning its result, takes a *continuation* — a callback —
and invokes it with the result. The continuation does
whatever comes next; the function never returns to its
caller in the ordinary sense.

CPS is useful when a result has a limited lifetime that is
tied to resources the function controls. The function can
hand the result to the continuation, let the continuation
use it, and then tear down the resources when the
continuation returns — all without the result ever escaping
the resource's scope.

Dovetail's executor is CPS-shaped for exactly that reason.
`Eval.eval` opens database cursors to produce a `Relation.t`
whose `value` sequence pulls rows lazily from those cursors.
The cursors are only valid while their transaction is alive;
if `eval` returned the relation directly, callers could
hold it past the point where it's safe to iterate. Instead
`eval` takes a consumer continuation, invokes it with the
relation, and tears the cursors down when the continuation
returns. The relation's lifetime is structurally bounded by
the call to `eval`.

See [`lib/execution/eval.mli`](../../lib/execution/eval.mli) for the
entry-point signature and slice 6
([`docs/plans/06-streaming-cps-executor.md`](../plans/06-streaming-cps-executor.md))
for the rationale behind the conversion to CPS.

## IR — Intermediate representation

A structured representation of a query that sits between two
other layers, designed to make one specific kind of
transformation tractable. Each IR has a single job: it
exposes the structure that the next stage needs to operate
on, and hides detail that stage shouldn't have to care
about.

Dovetail has two IRs between the AST and the executor:

- **Logical IR**
  ([`lib/plan/logical.mli`](../../lib/plan/logical.mli)) —
  relational algebra. Says *what* the query computes:
  scans, restrictions, projections, products, joins.
  Independent of execution strategy. The output of `Lower`,
  the input of `Translate`.
- **Physical IR**
  ([`lib/plan/physical.mli`](../../lib/plan/physical.mli)) —
  concrete execution plan. Says *how* the query runs:
  cursors, filters, nested-loop joins, point lookups. The
  output of `Translate`, the input of `Eval`.

The pipeline overall is AST → Logical IR → Physical IR →
execution, with each arrow a transformation between
representations. Splitting the work this way lets each layer
focus: lowering doesn't worry about strategy, translation
doesn't worry about syntax, evaluation doesn't worry about
algebra.

## Lower

The pass that converts a surface AST into the logical IR. Each
surface has its own (`Surface_ra.Lower`, `Surface_sql.Lower`), and
both target the same `Logical.t` — that shared target is what lets
two query languages drive one engine.

Lowering is purely syntactic-to-semantic: it maps surface forms onto
algebra constructors and desugars conveniences (`join … on` becomes
a restriction over a cross product), but it never consults the
catalog. Whether a table exists or a column resolves is `Typecheck`'s
job, one step later.

## Physical plan

The concrete execution strategy for a query: which cursors to open,
which join algorithm to run, point lookup versus full scan, and
where writes happen. The output of `Translate` and the input of
`Eval`. Where the logical IR says *what* a query computes, the
physical plan says *how* — the same distinction drawn under **IR**
above.

Lives in [`lib/plan/physical.mli`](../../lib/plan/physical.mli).
The `--show-physical` flag on the binary prints the chosen plan for
a query.

## Relation

A collection of rows that all share the same shape, plus any
constraints on the contents beyond the shape itself — today,
just which columns form the primary key. What you get back from
a scan, and what every query operator produces and consumes.

A relation is also tagged with whether it's a set (no
duplicates) or a bag (duplicates allowed). The two flavours
behave differently under operators like projection, and the
distinction is tracked so that an operator can't silently
change a relation's multiplicity behind a caller's back.

A relation is alive only inside the transaction that produced
it: pulling its rows reads from open cursors that close when
the transaction does. That lifetime constraint is the reason
the executor is CPS-shaped (see above).

The third rung of the type ladder; see
[`docs/design/type-ladder.md`](../design/type-ladder.md) and
[`lib/core/relation.mli`](../../lib/core/relation.mli).

## Row

A fixed-shape grouping of values — one record's worth of data.
The shape is an ordered list of named, typed columns; the row is
the values at each of those columns, in column order. Rows have
no identity of their own beyond their contents, and they always
travel with the shape that gives the values their meaning.

A column in a row may carry a qualifier (e.g. `users.id` rather
than just `id`) when the row has been built from several inputs
that might otherwise have name collisions. Qualifiers are how
joins and cross products keep their columns apart.

The second rung of the type ladder; see
[`docs/design/type-ladder.md`](../design/type-ladder.md) and
[`lib/core/row.mli`](../../lib/core/row.mli).

## Scalar

A single piece of data the database can hold — an integer, a
string, a boolean. The smallest thing Dovetail can store or
compute with. A scalar has a *kind* (which of the supported types
it is) and a payload (the bits for that type).

The bottom rung of the type ladder; see
[`docs/design/type-ladder.md`](../design/type-ladder.md) and
[`lib/core/scalar.mli`](../../lib/core/scalar.mli).

## Translate

The pass that converts the logical IR into a physical plan, picking
an execution strategy for each operator. Most operators map
one-for-one; the interesting work is the rewrite rules that
recognise patterns worth executing as something better than the
literal translation — an equality on a primary key becomes an
`IndexLookup`, a restriction over a cross product becomes a
`NestedLoopJoin` (folded further into `IndexedNestedLoopJoin` when
the join is on a primary key).

Translate consults the catalog for table kinds — that's how it
recognises a primary-key pattern — but it does not validate;
`Typecheck` has already run by the time Translate sees the plan.
Lives in [`lib/plan/translate.mli`](../../lib/plan/translate.mli).

## Typecheck

The validation pass between `Lower` and `Translate`. It walks the
logical plan against a snapshot of the catalog's kinds and checks
everything that can be known before any rows move: every column
reference resolves, comparison operands agree on kind, predicates
are boolean, insert sources match their target's columns, referenced
tables exist.

Two properties matter to its callers. It accumulates errors — one
walk reports every problem, not just the first — and on success it
returns the plan unchanged; the pass validates but does not (yet)
produce a separate typed IR. The catalog snapshot is taken inside
the same transaction later used for execution, so the kinds it
validated against can't shift before evaluation. Lives in
[`lib/plan/typecheck.mli`](../../lib/plan/typecheck.mli).

## One operator, three names

The same operation deliberately changes name as it crosses layers:
the surface speaks the user's language, the logical IR speaks
relational algebra, and the physical plan names the execution
strategy. The mapping for the operators that rename:

| Surface           | Logical IR                       | Physical plan                              |
| ----------------- | -------------------------------- | ------------------------------------------ |
| bare table name   | `Scan`                           | `FullScan`, or `IndexLookup` when a restriction pins the primary key |
| `restrict`        | `Restrict`                       | `Filter`                                   |
| `join … on`       | `Restrict` over a `CrossProduct` | `NestedLoopJoin`, or `IndexedNestedLoopJoin` when joining on a primary key |

A renaming marks a real change of meaning: `Restrict` is the
algebra's σ, a statement about *what* rows survive; `Filter` is the
executor's strategy of passing matching rows through. Operators that
keep one name across layers (`Project`, `CrossProduct`, `Insert`, …)
do so because the strategy *is* the literal translation.
