let rec lower (ast : Ast.t) : Logical.t =
  match ast with
  | Relation_name name -> Scan { table = name }
  | Restrict { input; predicate } -> Restrict { input = lower input; predicate }
  | Project { input; columns } -> Project { input = lower input; columns }
  | CrossProduct { left; right } ->
      CrossProduct { left = lower left; right = lower right }
  | Join { left; right; predicate } ->
      Restrict
        {
          input = CrossProduct { left = lower left; right = lower right };
          predicate;
        }
