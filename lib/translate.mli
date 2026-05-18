(** Logical-to-physical translation.

    [translate] picks a physical execution strategy for each logical operator.
    Most operators map one-for-one (a {!Logical.Scan} becomes a
    {!Physical.FullScan}, [Logical.Restrict] becomes [Physical.Filter], and so
    on), but the layer also hosts the rewrite rules that recognise patterns
    worth executing as something other than the literal translation: an equality
    on a primary key becomes [IndexLookup], and a restrict over a cross product
    becomes a [NestedLoopJoin] (further folded into [IndexedNestedLoopJoin] when
    the join is on a primary key). Future rules -- predicate pushdown,
    projection pushdown -- will sit alongside these. *)

module Schema = Dovetail_core.Schema

val translate :
  catalog:(string -> Schema.t option) -> Logical.plan -> Physical.plan
(** [translate ~catalog plan] rewrites [plan] into an equivalent physical plan.
    A {!Logical.Query} translates to {!Physical.Query} wrapping the
    rewrite-recognised relation tree; a {!Logical.Mutation} translates to
    {!Physical.Mutation} after the literal source has been validated against the
    target schema (see below).

    Relation-tree rewrites: slice 1 maps [Scan] to [FullScan]; slice 2 adds
    [Restrict] -> [Filter]; slice 3 adds [Project] -> [Project]; slice 4 adds
    [CrossProduct] -> [CrossProduct]; slice 5 adds the first non-structural
    rewrite, [Restrict (CrossProduct (L, R), pred)] ->
    [NestedLoopJoin (L, R, pred)]. Slice 8 adds the [IndexLookup] rewrite on
    [Restrict (Scan t, pk = K)], which is why the catalog handle is needed.

    Mutation arm: looks up the target table in the catalog (failing if absent),
    then -- when the source is a {!Logical.RelationLiteral} -- validates that
    the literal's columns are a permutation of the target schema's column names
    and that each value's kind matches the target schema. Each error message
    names the offending columns or column/kind pair so the user can locate the
    mismatch from the wording alone. Non-literal sources translate without
    shape-level checks; the sink itself enforces column coverage at eval time
    (insert-from-query is grammatically legal but untested in slice 11).

    [catalog] is consulted by rewrites and the Mutation arm both -- currently
    the [IndexLookup] rewrite (which needs the primary-key column to recognise
    the pattern) and the Mutation arm (which needs the target schema). A
    callback returning [None] for every name is harmless for queries; for a
    mutation it surfaces as the "unknown table" error.

    The slice-5 rewrite fires on shape alone -- it does not inspect which inputs
    [pred] references. So [Restrict (CrossProduct (L, R), one_sided_pred)] still
    becomes a [NestedLoopJoin], even though pushing [one_sided_pred] down onto
    the relevant input would produce a better plan. Predicate pushdown is a
    separate, future rewrite. *)
