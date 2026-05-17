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

val translate :
  catalog:(string -> Schema.t option) -> Logical.t -> Physical.plan
(** [translate ~catalog plan] rewrites [plan] into an equivalent physical plan,
    wrapped in {!Physical.Query}. Slice 1 maps [Scan] to [FullScan]; slice 2
    adds [Restrict] -> [Filter]; slice 3 adds [Project] -> [Project]; slice 4
    adds [CrossProduct] -> [CrossProduct]; slice 5 adds the first non-structural
    rewrite, [Restrict (CrossProduct (L, R), pred)] ->
    [NestedLoopJoin (L, R, pred)]. Slice 8 adds the [IndexLookup] rewrite on
    [Restrict (Scan t, pk = K)], which is why the catalog handle is needed.

    The return type is {!Physical.plan} because slice 11 step 3 widens
    {!Logical.t} into a [Query | Mutation] wrapper; step 2b lands the wrapper on
    the physical side and the REPL's dispatch on it, in advance of the
    logical-side change so the existing call sites have a stable shape to
    consume. Until step 3 lands, every output is a {!Physical.Query} -- there is
    no [Mutation] arm in the logical IR yet to translate from.

    [catalog] is consulted only by rewrites that need a table's schema --
    currently the [IndexLookup] rewrite, which needs to know the primary-key
    column to recognise the pattern. A callback returning [None] for every name
    (or one that doesn't know about the scanned table) is harmless: the
    catalog-dependent rewrites simply skip, and translation falls back to the
    same shape it would produce without the schema.

    The slice-5 rewrite fires on shape alone -- it does not inspect which inputs
    [pred] references. So [Restrict (CrossProduct (L, R), one_sided_pred)] still
    becomes a [NestedLoopJoin], even though pushing [one_sided_pred] down onto
    the relevant input would produce a better plan. Predicate pushdown is a
    separate, future rewrite. *)
