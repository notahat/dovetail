let rec translate (plan : Logical.t) : Physical.t =
  match plan with
  | Scan { table } -> FullScan { table }
  (* Recognise an inner join: a Restrict whose immediate input is a
     CrossProduct fuses into a single NestedLoopJoin that evaluates the
     predicate inside the pair-emitting loop. The match for this case must
     come before the general [Restrict] case below, since OCaml's [match]
     is first-match. The rewrite fires unconditionally on shape -- it does
     not inspect which inputs the predicate references -- so a predicate
     that only touches one side still becomes a NestedLoopJoin rather than
     being pushed down. Predicate pushdown is a separate, future rewrite. *)
  | Restrict { input = CrossProduct { left; right }; predicate } ->
      NestedLoopJoin
        { left = translate left; right = translate right; predicate }
  | Restrict { input; predicate } ->
      Filter { input = translate input; predicate }
  | Project { input; columns } -> Project { input = translate input; columns }
  | CrossProduct { left; right } ->
      CrossProduct { left = translate left; right = translate right }
