(** AST-to-logical lowering.

    [lower] converts the surface AST into a logical plan: it strips away the
    syntactic layer and replaces each AST node with the relational-algebra
    operator it denotes. The result is independent of how the user wrote the
    query, so later stages can reason in algebraic terms.

    Slice 1 introduced [Relation_name]; slice 2 adds [Restrict]. Further nodes
    arrive as later slices introduce them. *)

val lower : Ast.t -> Logical.t
(** [lower ast] rewrites [ast] into an equivalent logical plan. [Relation_name]
    becomes [Scan]; [Ast.Restrict], [Ast.Project], and [Ast.CrossProduct] map to
    their like-named [Logical] counterparts.
    [Ast.Join { left; right; predicate }] desugars to
    [Logical.Restrict (Logical.CrossProduct { left; right }, predicate)] --
    [Logical] has no [Join] node; the join is just sugar at this layer, and
    {!Translate} is responsible for collapsing the
    [Restrict]-over-[CrossProduct] shape into [Physical.NestedLoopJoin]. *)
