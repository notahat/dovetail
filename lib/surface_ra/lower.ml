module Plan = Dovetail_plan
module Scalar = Dovetail_core.Scalar
module Row = Dovetail_core.Row
module Relation = Dovetail_core.Relation
module StringSet = Set.Make (String)

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

(* Validate one self-describing row against a relation kind, returning the
   row's values in the kind's field order. Raises [Failure] with a user-facing
   message if the row's field names don't exactly match the kind's, or if any
   value's kind doesn't match the declared field kind. *)
let validate_typed_row (kind : Relation.kind)
    (row : (string * Scalar.value) list) : Scalar.value list =
  let row_field_names = StringSet.of_list (List.map fst row) in
  let kind_field_names =
    StringSet.of_list
      (List.map (fun (field : Row.field) -> field.name) kind.row_kind)
  in
  (if not (StringSet.equal row_field_names kind_field_names) then
     let missing = StringSet.diff kind_field_names row_field_names in
     let extra = StringSet.diff row_field_names kind_field_names in
     let detail =
       if not (StringSet.is_empty missing) then
         Printf.sprintf "missing field %S" (StringSet.choose missing)
       else Printf.sprintf "unexpected field %S" (StringSet.choose extra)
     in
     failwith (Printf.sprintf "Lower: relation literal: %s" detail));
  List.map
    (fun (field : Row.field) ->
      let value = List.assoc field.name row in
      let value_kind = Scalar.kind_of value in
      if value_kind <> field.kind then
        failwith
          (Format.asprintf
             "Lower: relation literal: field %S expected %a but got %a"
             field.name Scalar.format_kind field.kind Scalar.format_kind
             value_kind);
      value)
    kind.row_kind

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
  | Insert { table; source } -> Insert { table; source = lower source }
  | Type { input = Type _ } -> failwith "type: input is already a type"
  | Type { input } -> Type_op { input = lower input }
  | Scalar_literal value -> Scalar_literal value
  | Row_literal fields -> Row_literal { fields }
  | Relation_literal { kind; rows } ->
      let normalized_rows = List.map (validate_typed_row kind) rows in
      Relation_literal { kind; rows = normalized_rows }
