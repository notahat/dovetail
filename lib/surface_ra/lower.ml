module Plan = Dovetail_plan

let rec lower (ast : Ast.t) : Plan.Logical.t =
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
  | RelationLiteral { columns; rows } -> RelationLiteral { columns; rows }
  | Insert { table; source } -> Insert { table; source = lower source }
  | Type { input } -> Type_op { input = lower input }
