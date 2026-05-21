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
[`lib/surface_ra/ast.mli`](../lib/surface_ra/ast.mli), and is the
output of the parser and the input to `Lower`.

## IR — Intermediate representation

A structured representation of a query that sits between two
other layers, designed to make one specific kind of
transformation tractable. Each IR has a single job: it
exposes the structure that the next stage needs to operate
on, and hides detail that stage shouldn't have to care
about.

Dovetail has two IRs between the AST and the executor:

- **Logical IR**
  ([`lib/plan/logical.mli`](../lib/plan/logical.mli)) —
  relational algebra. Says *what* the query computes:
  scans, restrictions, projections, products, joins.
  Independent of execution strategy. The output of `Lower`,
  the input of `Translate`.
- **Physical IR**
  ([`lib/plan/physical.mli`](../lib/plan/physical.mli)) —
  concrete execution plan. Says *how* the query runs:
  cursors, filters, nested-loop joins, point lookups. The
  output of `Translate`, the input of `Eval`.

The pipeline overall is AST → Logical IR → Physical IR →
execution, with each arrow a transformation between
representations. Splitting the work this way lets each layer
focus: lowering doesn't worry about strategy, translation
doesn't worry about syntax, evaluation doesn't worry about
algebra.

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
whose `data` sequence pulls rows lazily from those cursors.
The cursors are only valid while their transaction is alive;
if `eval` returned the relation directly, callers could
hold it past the point where it's safe to iterate. Instead
`eval` takes a consumer continuation, invokes it with the
relation, and tears the cursors down when the continuation
returns. The relation's lifetime is structurally bounded by
the call to `eval`.

See [`lib/execution/eval.mli`](../lib/execution/eval.mli) for the
entry-point signature and slice 6
([`docs/plans/06-slice-6-streaming-cps-executor.md`](plans/06-slice-6-streaming-cps-executor.md))
for the rationale behind the conversion to CPS.
