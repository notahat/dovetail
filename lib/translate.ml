let translate (plan : Logical.t) : Physical.t =
  match plan with Scan { table } -> FullScan { table }
