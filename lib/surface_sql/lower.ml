module Plan = Dovetail_plan

let lower (ast : Ast.t) : Plan.Logical.t =
  match ast with
  | Select { select_list = All; from; where = None } -> Scan { table = from }
  | Select { where = Some _; _ } ->
      (* TODO(sql-where): lower the predicate to a Restrict over the Scan. *)
      failwith "WHERE clause is not yet supported"
