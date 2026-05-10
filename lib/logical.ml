type t =
  | Scan of { table : string }
  | Restrict of { input : t; predicate : Predicate.t }
  | Project of { input : t; columns : Projection.t }
