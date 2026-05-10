type t =
  | FullScan of { table : string }
  | Filter of { input : t; predicate : Predicate.t }
  | Project of { input : t; columns : Projection.t }
  | CrossProduct of { left : t; right : t }
  | NestedLoopJoin of { left : t; right : t; predicate : Predicate.t }
