module Plan = Dovetail_plan

let lower (ast : Ast.t) : Plan.Logical.t =
  match ast with Select { select_list = All; from } -> Scan { table = from }
