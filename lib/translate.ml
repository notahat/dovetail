let rec translate (plan : Logical.t) : Physical.t =
  match plan with
  | Scan { table } -> FullScan { table }
  | Restrict { input; predicate } ->
      Filter { input = translate input; predicate }
