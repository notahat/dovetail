type t =
  | Relation_name of string
  | Restrict of { input : t; predicate : Predicate.t }
  | Project of { input : t; columns : Projection.t }
  | CrossProduct of { left : t; right : t }
