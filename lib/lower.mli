(** AST-to-logical lowering.

    [lower] converts the surface AST into a logical plan: it strips away the
    syntactic layer and replaces each AST node with the relational-algebra
    operator it denotes. The result is independent of how the user wrote the
    query, so later stages can reason in algebraic terms.

    Slice 1 introduced [Relation_name]; slice 2 adds [Restrict]. Further nodes
    arrive as later slices introduce them. *)

val lower : Ast.t -> Logical.t
(** [lower ast] rewrites [ast] into an equivalent logical plan. Slice 1 maps
    [Relation_name name] to [Scan { table = name }]; slice 2 adds [Ast.Restrict]
    -> [Logical.Restrict]. *)
