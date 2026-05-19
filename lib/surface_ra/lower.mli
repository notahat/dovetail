(** AST-to-logical lowering.

    [lower] converts the surface AST into a logical plan: it strips away the
    syntactic layer and replaces each AST node with the relational-algebra
    operator it denotes. The result is independent of how the user wrote the
    query, so later stages can reason in algebraic terms. *)

module Plan = Dovetail_plan

val lower : Ast.plan -> Plan.Logical.plan
(** [lower plan] rewrites [plan] into an equivalent logical plan.

    The [Query] arm rewrites the relation tree: [Relation_name] becomes [Scan];
    [Ast.Restrict], [Ast.Project], and [Ast.CrossProduct] map to their
    like-named [Logical] counterparts; [Ast.Join { left; right; predicate }]
    desugars to
    [Logical.Restrict (Logical.CrossProduct { left; right }, predicate)] --
    [Logical] has no [Join] node; the join is just sugar at this layer, and
    {!Translate} is responsible for collapsing the
    [Restrict]-over-[CrossProduct] shape into [Physical.NestedLoopJoin].

    The [Mutation] arm carries the sink across: an [Ast.Insert] becomes a
    [Logical.Insert] with the source's relation tree lowered in place. *)
