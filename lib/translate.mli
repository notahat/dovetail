(** Logical-to-physical translation.

    [translate] picks a physical execution strategy for each logical operator.
    For slice 1 the choice is trivial — every {!Logical.Scan} becomes a
    {!Physical.FullScan} — but the layer exists from day one so that index
    scans, join algorithm choice, and operator-tree restructuring have a home
    when later slices need them.

    Slice 1-4 was a pure structural rewrite -- one logical constructor per
    physical constructor. Slice 5 introduces the first proper rewrite rule:
    [Restrict (CrossProduct (L, R), pred)] collapses into a single
    {!Physical.NestedLoopJoin}. The translation is still trivial in aggregate,
    but the door to a real optimiser is now open: future rewrite rules
    (predicate pushdown, equi-join detection) will sit alongside this one. *)

val translate : Logical.t -> Physical.t
(** [translate plan] rewrites [plan] into an equivalent physical plan. Slice 1
    maps [Scan] to [FullScan]; slice 2 adds [Restrict] -> [Filter]; slice 3 adds
    [Project] -> [Project]; slice 4 adds [CrossProduct] -> [CrossProduct]; slice
    5 adds the first non-structural rewrite,
    [Restrict (CrossProduct (L, R), pred)] -> [NestedLoopJoin (L, R, pred)]. *)
