module Scalar = Dovetail_core.Scalar
module Expression = Dovetail_core.Expression
module Relation = Dovetail_core.Relation
module Row = Dovetail_core.Row
module Ddl = Dovetail_ddl
module Plan = Dovetail_plan

type type_field = {
  qualifier : string option;
  name : string;
  kind : Scalar.kind;
}

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
  | Insert of { table : string; source : t }
  | Unqualify of { input : t }
  | Type of { input : t }
  | Scalar_literal of Scalar.value
  | Row_literal of (Row.column_reference * Scalar.value) list
  | Relation_literal of {
      kind : Relation.kind;
      rows : (Row.column_reference * Scalar.value) list list;
    }

type program = Pipeline of t | Ddl of Ddl.Statement.t
