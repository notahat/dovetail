(** Logical-to-physical translation.

    [translate] picks a physical execution strategy for each logical operator.
    For slice 1 the choice is trivial — every {!Logical.Scan} becomes a
    {!Physical.FullScan} — but the layer exists from day one so that index
    scans, join algorithm choice, and operator-tree restructuring have a home
    when later slices need them.

    No optimisation happens here in slice 1: the function is a structural
    rewrite. An optimiser, when it lands, will sit between {!Lower} and
    {!Translate} (or replace {!Translate} entirely; that decision is deferred).
*)

val translate : Logical.t -> Physical.t
(** [translate plan] rewrites [plan] into an equivalent physical plan. Slice 1
    maps [Scan] to [FullScan]. *)
