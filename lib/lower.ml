let rec lower_relation (ast : Ast.t) : Logical.t =
  match ast with
  | Relation_name name -> Scan { table = name }
  | Restrict { input; predicate } ->
      Restrict { input = lower_relation input; predicate }
  | Project { input; columns } ->
      Project { input = lower_relation input; columns }
  | CrossProduct { left; right } ->
      CrossProduct { left = lower_relation left; right = lower_relation right }
  | Join { left; right; predicate } ->
      Restrict
        {
          input =
            CrossProduct
              { left = lower_relation left; right = lower_relation right };
          predicate;
        }
  | RelationLiteral { columns; rows } -> RelationLiteral { columns; rows }

let lower_mutation (Ast.Insert { source; table }) : Logical.mutation =
  Insert { table; source = lower_relation source }

let lower (ast : Ast.plan) : Logical.plan =
  match ast with
  | Query relation -> Query (lower_relation relation)
  | Mutation mutation -> Mutation (lower_mutation mutation)
