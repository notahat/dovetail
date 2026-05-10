let rec translate (plan : Logical.t) : Physical.t =
  match plan with
  | Scan { table } -> FullScan { table }
  | Restrict { input; predicate } ->
      Filter { input = translate input; predicate }
  | Project { input; columns } -> Project { input = translate input; columns }
  | CrossProduct { left; right } ->
      CrossProduct { left = translate left; right = translate right }
