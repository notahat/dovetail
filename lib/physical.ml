type t =
  | FullScan of { table : string }
  | Filter of { input : t; predicate : Predicate.t }
