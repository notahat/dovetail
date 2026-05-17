type t =
  | Scan of { table : string }
  | Restrict of { input : t; predicate : Expression.t }
  | Project of { input : t; columns : Projection.t }
  | CrossProduct of { left : t; right : t }
  | RelationLiteral of { columns : string list; rows : Value.t list list }
