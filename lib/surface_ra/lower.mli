(** AST-to-logical lowering.

    [lower] converts the surface AST into a logical plan: it strips away the
    syntactic layer and replaces each AST node with the relational-algebra
    operator it denotes. The result is independent of how the user wrote the
    query, so later stages can reason in algebraic terms. *)

module Plan = Dovetail_plan
module Row = Dovetail_core.Row
module Relation = Dovetail_core.Relation

val lower_column_reference : Ast.column_reference -> Row.column_reference
(** [lower_column_reference reference] is the AST-to-logical translation for a
    column reference: structurally identity today, with the helper existing for
    the layering rather than the work. *)

val lower_row_type : Ast.type_expression -> Row.kind
(** [lower_row_type type_expression] turns a parsed row-type expression into a
    {!Row.kind}. Each {!Ast.type_field} becomes a {!Row.field} with
    [qualifier = None] — the surface row-type syntax has no qualifier form.
    [type_expression.refinements] must be empty; {!Parser.parse_row_type}
    guarantees this for parsed input. Not yet called from anywhere; wired in
    once the lowering pipeline grows a row-type path. *)

val lower_refinement : Ast.refinement -> Relation.refinement
(** [lower_refinement refinement] is the AST-to-logical translation for a
    refinement clause. For [Ast.Primary_key references] it discards the
    qualifier slot from each reference -- the surface grammar admits only bare
    identifiers inside a [primary key (...)] clause, so qualified references are
    an upstream-invariant violation. *)

val lower_projection : Ast.projection -> Plan.Projection.t
(** [lower_projection projection] translates an AST-side projection into its
    {!Plan.Projection.t} counterpart by mapping {!lower_column_reference} over
    each column. Structurally identity today — both sides are a list of column
    references — with the helper existing for the layering. *)

val lower_relation_type : Ast.type_expression -> Relation.kind
(** [lower_relation_type type_expression] turns a parsed relation-type
    expression into a {!Relation.kind}. The fields become the [row_kind] (each
    with [qualifier = None]); each {!Ast.refinement} is translated via
    {!lower_refinement}. *)

val lower : Ast.t -> Plan.Logical.t
(** [lower ast] rewrites [ast] into an equivalent logical plan.

    [Relation_name] becomes [Scan]; [Ast.Restrict], [Ast.Project], and
    [Ast.CrossProduct] map to their like-named [Logical] counterparts;
    [Ast.Join { left; right; predicate }] desugars to
    [Logical.Restrict (Logical.CrossProduct { left; right }, predicate)] --
    [Logical] has no [Join] node; the join is just sugar at this layer, and
    {!Translate} is responsible for collapsing the
    [Restrict]-over-[CrossProduct] shape into [Physical.NestedLoopJoin].
    [Ast.Insert] maps to [Logical.Insert] with the source lowered in place;
    [Ast.Unqualify] maps to [Logical.Unqualify] the same way. *)
