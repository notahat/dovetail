module Scalar = Dovetail_core.Scalar
module Expression = Dovetail_core.Expression
module Relation = Dovetail_core.Relation
module Ddl = Dovetail_ddl
module Plan = Dovetail_plan

type type_field = { name : string; kind : Scalar.kind }

type type_expression = {
  fields : type_field list;
  refinements : Relation.refinement list;
}

type t =
  | Relation_name of string
  | Restrict of { input : t; predicate : Expression.t }
  | Project of { input : t; columns : Plan.Projection.t }
  | CrossProduct of { left : t; right : t }
  | Join of { left : t; right : t; predicate : Expression.t }
  | RelationLiteral of { columns : string list; rows : Scalar.value list list }
  | Insert of { table : string; source : t }
  | Type of { input : t }
  | Scalar_literal of Scalar.value
  | Row_literal of (string * Scalar.value) list
  | Relation_literal_typed of {
      kind : Relation.kind;
      rows : (string * Scalar.value) list list;
    }

type program = Pipeline of t | Ddl of Ddl.Statement.t
