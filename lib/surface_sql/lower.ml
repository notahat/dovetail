module Plan = Dovetail_plan
module Expression = Dovetail_core.Expression
module Row = Dovetail_core.Row

let lower_column_reference (reference : Ast.column_reference) :
    Row.column_reference =
  { qualifier = reference.qualifier; name = reference.name }

let lower_comparison_op (op : Ast.comparison_op) : Expression.comparison_op =
  match op with
  | Equal -> Equal
  | NotEqual -> NotEqual
  | Less -> Less
  | LessEqual -> LessEqual
  | Greater -> Greater
  | GreaterEqual -> GreaterEqual

let rec lower_expression (expression : Ast.expression) : Expression.t =
  match expression with
  | Literal value -> Literal value
  | Column reference -> Column (lower_column_reference reference)
  | Compare { left; op; right } ->
      Compare
        {
          left = lower_expression left;
          op = lower_comparison_op op;
          right = lower_expression right;
        }
  | And (left, right) -> And (lower_expression left, lower_expression right)
  | Or (left, right) -> Or (lower_expression left, lower_expression right)
  | Not operand -> Not (lower_expression operand)

let lower (ast : Ast.t) : Plan.Logical.t =
  match ast with
  | Select { select_list; from; where } -> (
      let scan : Plan.Logical.t = Scan { table = from } in
      let filtered =
        match where with
        | None -> scan
        | Some predicate ->
            Restrict { input = scan; predicate = lower_expression predicate }
      in
      match select_list with
      | All -> filtered
      | Columns _ ->
          (* TODO(sql-project): lower the column list to a Project over the
             filtered sub-plan. *)
          failwith "column-list SELECT is not yet supported")
