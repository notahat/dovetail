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

(* Slice 11 step 3 widens Lower's output to [Logical.plan] so the Logical IR
   can carry the Query/Mutation wrapper alongside the relation tree. The Ast
   is still flat -- no sink production yet -- so every output is a
   [Logical.Query] for the moment. The Mutation arm appears in step 4
   alongside the Ast wrapper. *)
let lower (ast : Ast.t) : Logical.plan = Query (lower_relation ast)
