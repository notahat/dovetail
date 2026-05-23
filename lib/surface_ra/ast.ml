module Scalar = Dovetail_core.Scalar
module Expression = Dovetail_core.Expression
module Ddl = Dovetail_ddl
module Plan = Dovetail_plan

type t =
  | Relation_name of string
  | Restrict of { input : t; predicate : Expression.t }
  | Project of { input : t; columns : Plan.Projection.t }
  | CrossProduct of { left : t; right : t }
  | Join of { left : t; right : t; predicate : Expression.t }
  | RelationLiteral of { columns : string list; rows : Scalar.value list list }
  | Insert of { table : string; source : t }
  | Type of { input : t }

type program = Pipeline of t | Ddl of Ddl.Statement.t
