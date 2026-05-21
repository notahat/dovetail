module Value = Dovetail_core.Value
module Expression = Dovetail_core.Expression
module Ddl = Dovetail_ddl
module Plan = Dovetail_plan

type t =
  | Relation_name of string
  | Restrict of { input : t; predicate : Expression.t }
  | Project of { input : t; columns : Plan.Projection.t }
  | CrossProduct of { left : t; right : t }
  | Join of { left : t; right : t; predicate : Expression.t }
  | RelationLiteral of { columns : string list; rows : Value.data list list }

type mutation = Insert of { table : string; source : t }
type plan = Query of t | Mutation of mutation
type program = Pipeline of plan | Ddl of Ddl.Statement.t
