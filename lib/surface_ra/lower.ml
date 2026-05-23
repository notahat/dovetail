module Plan = Dovetail_plan
module Row = Dovetail_core.Row
module Relation = Dovetail_core.Relation

let lower_type_fields (fields : Ast.type_field list) : Row.kind =
  List.map
    (fun ({ name; kind } : Ast.type_field) : Row.field ->
      { name; kind; qualifier = None })
    fields

let lower_row_type (type_expression : Ast.type_expression) : Row.kind =
  match type_expression.refinements with
  | [] -> lower_type_fields type_expression.fields
  | _ :: _ ->
      (* Parser.parse_row_type rejects any refinement clause, so a
         type_expression reaching this helper has an empty refinements list. *)
      assert false

let lower_relation_type (type_expression : Ast.type_expression) : Relation.kind
    =
  {
    row_kind = lower_type_fields type_expression.fields;
    refinements = type_expression.refinements;
  }

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
  | Type { input = Type _ } -> failwith "type: input is already a type"
  | Type { input } -> Type_op { input = lower input }
