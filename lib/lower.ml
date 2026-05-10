let lower (ast : Ast.t) : Logical.t =
  match ast with Relation_name name -> Scan { table = name }
