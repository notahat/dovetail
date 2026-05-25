module Plan = Dovetail_plan
module Scalar = Dovetail_core.Scalar
module Row = Dovetail_core.Row
module Relation = Dovetail_core.Relation
module StringSet = Set.Make (String)

let lower_column_reference (reference : Ast.column_reference) :
    Row.column_reference =
  { qualifier = reference.qualifier; name = reference.name }

let lower_type_fields (fields : Ast.type_field list) : Row.kind =
  List.map
    (fun ({ qualifier; name; kind } : Ast.type_field) : Row.field ->
      { name; kind; qualifier })
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

(* Render a field's display name as the user wrote it: dotted
   [qualifier.name] when qualified, bare [name] otherwise. Used in
   {!validate_typed_row}'s diagnostics so errors quote the same spelling the
   user typed (and the relation kind declares). *)
let format_field_display_name (field : Row.field) : string =
  Row.format_column_reference { qualifier = field.qualifier; name = field.name }

(* Validate one self-describing row against a relation kind, returning the
   row's values in the kind's field order. Matches each row entry against
   its kind field by qualified name -- a kind field [users.id] is bound by
   a row entry [(users.id = ...)] and not by [(id = ...)]. Raises [Failure]
   with a user-facing message if the row's qualified names don't exactly
   match the kind's, or if any value's kind doesn't match the declared
   field kind. *)
let validate_typed_row (kind : Relation.kind)
    (row : (Ast.column_reference * Scalar.value) list) : Scalar.value list =
  let row_field_names =
    StringSet.of_list
      (List.map
         (fun (reference, _) -> Ast.format_column_reference reference)
         row)
  in
  let kind_field_names =
    StringSet.of_list
      (List.map
         (fun (field : Row.field) -> format_field_display_name field)
         kind.row_kind)
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
  let lookup_value (field : Row.field) =
    let target = format_field_display_name field in
    let _, value =
      List.find
        (fun (reference, _) ->
          String.equal (Ast.format_column_reference reference) target)
        row
    in
    value
  in
  List.map
    (fun (field : Row.field) ->
      let value = lookup_value field in
      let value_kind = Scalar.kind_of value in
      if value_kind <> field.kind then
        failwith
          (Format.asprintf
             "Lower: relation literal: field %S expected %a but got %a"
             (format_field_display_name field)
             Scalar.format_kind field.kind Scalar.format_kind value_kind);
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
  | Unqualify { input } -> Unqualify { input = lower input }
  | Type { input = Type _ } -> failwith "type: input is already a type"
  | Type { input } -> Type_op { input = lower input }
  | Scalar_literal value -> Scalar_literal value
  | Row_literal fields ->
      let fields =
        List.map
          (fun (reference, value) -> (lower_column_reference reference, value))
          fields
      in
      Row_literal { fields }
  | Relation_literal { kind; rows } ->
      let normalized_rows = List.map (validate_typed_row kind) rows in
      Relation_literal { kind; rows = normalized_rows }
  | Drop_table { table_name } -> Drop_table { table_name }
  | Create_table_empty { table_name; type_expression } ->
      Create_table_empty
        { table_name; kind = lower_relation_type type_expression }
  | Create_table_seeded { table_name; source } ->
      Create_table_seeded { table_name; source = lower source }
  | Catalog_source -> Catalog_source
  | Tables { input } -> Tables { input = lower input }
