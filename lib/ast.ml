type t =
  | Relation_name of string
  | Restrict of { input : t; predicate : Expression.t }
  | Project of { input : t; columns : Projection.t }
  | CrossProduct of { left : t; right : t }
  | Join of { left : t; right : t; predicate : Expression.t }
  | RelationLiteral of { columns : string list; rows : Value.t list list }

type mutation = Insert of { table : string; source : t }
type plan = Query of t | Mutation of mutation
type program = Pipeline of plan | Ddl of Statement.t
